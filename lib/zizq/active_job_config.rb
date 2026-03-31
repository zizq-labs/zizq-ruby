# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require_relative "job_config"

module Zizq
  # Zizq configuration DSL for ActiveJob classes.
  #
  # Extend this module in an ActiveJob subclass to gain access to Zizq
  # features like unique jobs, backoff, and retention:
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

    # Serialize arguments using ActiveJob's serialization format.
    #
    # Creates a temporary ActiveJob instance to produce the canonical
    # serialized form, including `_aj_ruby2_keywords` markers for kwargs.
    # This ensures unique key generation uses the same format as the
    # enqueued payload.
    #
    # This is needed so that unique job keys can be correctly generated.
    def zizq_serialize(*args, **kwargs) #: (*untyped, **untyped) -> Array[untyped]
      new(*args, **kwargs).serialize["arguments"]
    end

    # Deserialization is handled by ActiveJob::Base.execute on the worker
    # side. This method is not used in the ActiveJob dispatch path.
    def zizq_deserialize(_payload) #: (untyped) -> [Array[untyped], Hash[Symbol, untyped]]
      raise NotImplementedError,
        "ActiveJob handles deserialization via ActiveJob::Base.execute"
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
      payload = zizq_serialize(*args, **kwargs)
      ".arguments == #{JSON.generate(payload)}"
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
      payload = zizq_serialize(*args, **kwargs)

      # ActiveJob flattens arguments into a single array, but marks kwargs with
      # "_aj_ruby2_keywords" => ["key1", "key2", ...] in the last element of
      # the array where kwargs are present. We need to detect this to generate
      # a suitable expression.
      serialized_args, serialized_kwargs =
        if payload.size > 0
          # See what the last argument looks like. It might be kwargs.
          maybe_kwargs = payload.pop

          # If it's got "_aj_ruby2_keywords" then it is kwargs.
          if maybe_kwargs.is_a?(Hash) && maybe_kwargs["_aj_ruby2_keywords"]
            # We only want the actual kwargs, not the marker.
            [payload, maybe_kwargs.except("_aj_ruby2_keywords")]
          else
            # It wasn't kwargs, so put it back.
            [payload.push(maybe_kwargs), nil]
          end
        else
          [payload, nil]
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
