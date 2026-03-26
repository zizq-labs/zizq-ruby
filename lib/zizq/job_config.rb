# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require "digest"
require "json"

module Zizq
  # Shared class-level configuration DSL for Zizq job classes.
  #
  # This module provides the queue, priority, retry, backoff, retention,
  # and uniqueness configuration methods. It is extended onto job classes
  # by `Zizq::Job` and can also be used with ActiveJob via
  # `Zizq::ActiveJobConfig`.
  #
  # Modules including this module must implement `zizq_serialize` and
  # `zizq_deserialize` to define how job arguments are serialized for the API.
  module JobConfig
    # @rbs!
    #   # The class name where this is included (invisible to steep without this).
    #   def name: () -> String?
    #
    #   # Serialize job arguments. Implemented by the including module.
    #   def zizq_serialize: (*untyped, **untyped) -> untyped

    # Declare the default queue for this job class.
    #
    # If not called, defaults to "default". Jobs enqueued for this class will
    # use the specified queue unless explicitly overridden during
    # [`Zizq::enqueue`] or by overriding `::zizq_enqueue_options` on the job
    # class.
    def zizq_queue(name = nil) #: (?String?) -> String
      if name
        @zizq_queue = name
      else
        @zizq_queue || "default"
      end
    end

    # Declare the default priority for this job class.
    #
    # If not called, defaults to the default priority on the Zizq server.
    # Jobs enqueued for this class will use the specified priority unless
    # explicitly overridden during [`Zizq::enqueue`] or by overriding
    # `::zizq_enqueue_options` on the job class.
    def zizq_priority(priority = nil) #: (?Integer?) -> Integer?
      if priority
        @zizq_priority = priority
      else
        @zizq_priority
      end
    end

    # Declare the default retry limit for this job class.
    #
    # The job may fail up to the number of times specified by the retry limit
    # and will exponentially backoff. Once the retry limit is reached, the
    # job is killed and becomes part of the dead set.
    #
    # If not configured, the server's default is used.
    def zizq_retry_limit(limit = nil) #: (?Integer?) -> Integer?
      if limit
        @zizq_retry_limit = limit
      else
        @zizq_retry_limit
      end
    end

    # Declare the default backoff configuration for this job class.
    #
    # Times are specified in seconds (optionally fractional).
    # In a Rails app `ActiveSupport::Duration` is supported too.
    #
    # All three parameters must be specified together and are used in the
    # following exponential backoff formula:
    #
    #   delay = base + attempts**exponent + rand(0.0..jitter)*attempts
    #
    # Example:
    #
    #   zizq_backoff exponent: 4.0, base: 15, jitter: 30
    #
    # If not configured, the server's default backoff policy is used.
    def zizq_backoff(exponent: nil, base: nil, jitter: nil) #: (?exponent: Numeric?, ?base: Numeric?, ?jitter: Numeric?) -> Zizq::backoff?
      if exponent || base || jitter
        unless exponent && base && jitter
          raise ArgumentError, "all of exponent:, base:, jitter: are required"
        end

        @zizq_backoff = { exponent: exponent.to_f, base: base.to_f, jitter: jitter.to_f }
      else
        @zizq_backoff
      end
    end

    # Declare the default retention configuration for this job class.
    #
    # Times are specified in seconds (optionally fractional).
    # In a Rails app `ActiveSupport::Duration` is supported too.
    #
    # Both parameters are optional — only the ones provided will be sent
    # to the server. Omitted values use the server's defaults.
    #
    # Example:
    #
    #   zizq_retention completed: 0, dead: 7 * 86_400
    #
    # If not configured, the server's default is used.
    def zizq_retention(completed: nil, dead: nil) #: (?completed: Numeric?, ?dead: Numeric?) -> Zizq::retention?
      if completed || dead
        result = {} #: Hash[Symbol, Float]

        result[:completed] = completed.to_f if completed
        result[:dead] = dead.to_f if dead

        @zizq_retention = result
      else
        @zizq_retention
      end
    end

    # Declare uniqueness for this job class.
    #
    # Requires a pro license.
    #
    # When enabled, duplicate jobs with the same unique key are rejected
    # at enqueue time. The optional scope controls how long the
    # uniqueness guard lasts:
    #
    #   :queued  — unique while "scheduled" or "ready" (server default)
    #   :active  — unique while "scheduled", "ready", or "in_flight"
    #   :exists  — unique until the job is reaped by the server
    #
    # Examples:
    #
    #   zizq_unique true                   # unique, server default scope
    #   zizq_unique true, scope: :active   # unique while active
    #   zizq_unique false                  # disable (e.g. in a subclass)
    #
    def zizq_unique(unique = nil, scope: nil) #: (?bool?, ?scope: Zizq::unique_scope?) -> bool
      if unique.nil?
        @zizq_unique || false
      else
        @zizq_unique = !!unique
        @zizq_unique_scope = scope
        @zizq_unique
      end
    end

    # Declare or read the uniqueness scope for this job class.
    #
    # Usually set via `zizq_unique true, scope: :active` but can also
    # be set independently.
    def zizq_unique_scope(scope = nil) #: (?Zizq::unique_scope?) -> Zizq::unique_scope?
      if scope
        @zizq_unique_scope = scope
      else
        @zizq_unique_scope
      end
    end

    # Compute the unique key for a job with the given arguments.
    #
    # The default implementation uses the class name and hashes the
    # normalized serialized payload. Override this method to customize
    # uniqueness — for example, to ignore certain arguments:
    #
    #   def self.zizq_unique_key(user_id, template:)
    #     super(user_id)  # unique per user, ignoring template
    #   end
    def zizq_unique_key(*args, **kwargs) #: (*untyped, **untyped) -> String
      payload = normalize_payload(zizq_serialize(*args, **kwargs))
      "#{name}:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    # Build a `Zizq::EnqueueOptions` instance from the class-level job config.
    #
    # Subclasses can override this to implement dynamic logic such as
    # priority based on arguments:
    #
    #   def self.zizq_enqueue_options(user_id, template:)
    #     opts = super
    #     opts.priority = 0 if template == "urgent"
    #     opts
    #   end
    def zizq_enqueue_options(*args, **kwargs) #: (*untyped, **untyped) -> EnqueueOptions
      EnqueueOptions.new(
        queue:        zizq_queue,
        priority:     zizq_priority,
        retry_limit:  zizq_retry_limit,
        backoff:      zizq_backoff,
        retention:    zizq_retention,
        unique_while: zizq_unique ? zizq_unique_scope : nil,
        unique_key:   zizq_unique ? zizq_unique_key(*args, **kwargs) : nil
      )
    end

    private

    # Deep-sort all Hash keys so that serialization is deterministic
    # regardless of insertion order or JSON library.
    def normalize_payload(obj) #: (untyped) -> untyped
      case obj
      when Hash
        obj.sort_by { |k, _| k.to_s }.map { |k, v| [k, normalize_payload(v)] }.to_h
      when Array
        obj.map { |v| normalize_payload(v) }
      else
        obj
      end
    end
  end
end
