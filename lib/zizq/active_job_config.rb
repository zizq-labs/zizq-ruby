# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require_relative "job_config"

module Zizq
  # Zizq configuration DSL for ActiveJob classes.
  #
  # Extend this module in an ActiveJob subclass to allow enqueueing jobs via
  # `Zizq.enqueue` and to gain access to Zizq features like unique jobs,
  # backoff, and retention:
  #
  #   class SendEmailJob < ApplicationJob
  #     extend Zizq::ActiveJobConfig
  #
  #     zizq_unique true, scope: :active
  #     zizq_backoff exponent: 4.0, base: 15, jitter: 30
  #
  #     def perform(user_id, template:)
  #       # ...
  #     end
  #   end
  #
  # Serialization uses ActiveJob's own format so that GlobalID, Time, and
  # other ActiveJob-supported types are handled correctly. The Zizq worker
  # must use the ActiveJob dispatcher:
  #
  #   Zizq.configure do |c|
  #     c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
  #   end
  module ActiveJobConfig
    include JobConfig

    # @rbs!
    #   # ActiveJob::Base.new — invisible to steep without this.
    #   def new: (*untyped, **untyped) -> untyped
    #
    #   # ActiveJob::Base.queue_name — invisible to steep without this.
    #   def queue_name: () -> String?

    # Use ActiveJob's `queue_name` as the default queue, falling back to
    # any explicit `zizq_queue` setting, then "default".
    def zizq_queue(name = nil) #: (?String?) -> String
      if name
        super
      else
        @zizq_queue || queue_name || "default"
      end
    end

    # Serialize using ActiveJob's own format.
    #
    # Creates a temporary ActiveJob instance to produce the canonical
    # serialized form. Returns the full serialized hash (including
    # `job_class`, `arguments`, `queue_name`, etc.) so that the payload
    # stored in Zizq matches what `ActiveJob::Base.execute` expects.
    def zizq_serialize(*args, **kwargs) #: (*untyped, **untyped) -> Hash[String, untyped]
      new(*args, **kwargs).serialize
    end

    # Deserialization is handled by ActiveJob::Base.execute on the worker
    # side. This method is not used in the ActiveJob dispatch path.
    def zizq_deserialize(_payload) #: (untyped) -> [Array[untyped], Hash[Symbol, untyped]]
      raise NotImplementedError,
        "ActiveJob handles deserialization via ActiveJob::Base.execute"
    end

    # Override unique key generation to hash only the arguments portion
    # of the serialized payload. The full payload contains volatile fields
    # (job_id, enqueued_at, etc.) that change per instance.
    def zizq_unique_key(*args, **kwargs) #: (*untyped, **untyped) -> String
      arguments = new(*args, **kwargs).serialize["arguments"]
      payload = normalize_payload(arguments)
      "#{name}:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    # Generate a jq expression that exactly matches payloads with the given
    # arguments.
    #
    # This is used for filtering in Zizq::Query.
    #
    # Generates an expression of the form:
    #
    #   .arguments == ["a","b",{"example":true,"_aj_ruby2_keywords":["example"]}]
    def zizq_payload_filter(*args, **kwargs) #: (*untyped, **untyped) -> String
      arguments = zizq_serialize(*args, **kwargs)["arguments"]
      ".arguments == #{JSON.generate(arguments)}"
    end

    # Generate a jq expression that matches jobs whose positional args
    # start with the given values and whose kwargs contain the given
    # key/value pairs.
    #
    # This is used for filtering in Zizq::Query.
    #
    # Generates expressions of the form:
    #
    #   (.arguments[0:2] == ["a","b"])
    #
    # or
    #
    #   (.arguments[0:2] == ["a","b"]) and
    #   (.arguments[-1] | has("_aj_ruby2_keywords")) and
    #   (.arguments[-1] | contains({"example":true}))
    def zizq_payload_subset_filter(*args, **kwargs) #: (*untyped, **untyped) -> String
      arguments = zizq_serialize(*args, **kwargs)["arguments"]

      # ActiveJob flattens arguments into a single array, but marks kwargs with
      # "_aj_ruby2_keywords" => ["key1", "key2", ...] in the last element of
      # the array where kwargs are present. We need to detect this to generate
      # a suitable expression.
      serialized_args, serialized_kwargs =
        if arguments.size > 0
          # See what the last argument looks like. It might be kwargs.
          maybe_kwargs = arguments.pop

          # If it's got "_aj_ruby2_keywords" then it is kwargs.
          if maybe_kwargs.is_a?(Hash) && maybe_kwargs["_aj_ruby2_keywords"]
            # We only want the actual kwargs, not the marker.
            [arguments, maybe_kwargs.except("_aj_ruby2_keywords")]
          else
            # It wasn't kwargs, so put it back.
            [arguments.push(maybe_kwargs), nil]
          end
        else
          [arguments, nil]
        end

      parts = [] #: Array[String]
      parts << %Q<(.arguments[0:#{serialized_args.size}] == #{JSON.generate(serialized_args)})>

      if serialized_kwargs
        parts << %Q<(.arguments[-1] | has("_aj_ruby2_keywords"))>
        parts << %Q<(.arguments[-1] | contains(#{JSON.generate(serialized_kwargs)}))>
      end

      parts.join(" and ")
    end
  end
end
