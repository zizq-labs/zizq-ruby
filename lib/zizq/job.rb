# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require_relative "job_config"

module Zizq
  # Mixin which all valid job classes must include.
  #
  # This module must be included in a class to make it a valid Zizq job. The
  # class name becomes the job type, and the worker resolves types back to
  # classes via `Object.const_get` (which naturally triggers any autoload
  # logic).
  #
  #   class SendEmailJob
  #     include Zizq::Job
  #
  #     zizq_queue "emails"   # optional, defaults to "default"
  #
  #     def perform(user_id, template:)
  #       puts "Sending #{template} email to user #{user_id}"
  #     end
  #   end
  #
  # The job can be configured through class methods to set the queue, priority
  # etc. Classes can also override `::zizq_enqueue_options` to implement
  # dynamically configured jobs based on their arguments.
  module Job
    def self.included(base) #: (Class) -> void
      base.extend(ClassMethods)
    end

    # Default dispatcher for Zizq jobs.
    #
    # Resolves the job class from the type string, deserializes the
    # payload, and calls `#perform`. Any object that responds to
    # `#dispatch(job)` can replace this as a custom dispatcher via
    # `Zizq.configure { |c| c.dispatcher = MyDispatcher.new }`.
    #
    # The contract is simple: return normally → ack, raise → nack.
    #
    # @rbs job: Resources::Job
    # @rbs return: void
    def self.dispatch(job)
      job_class = Object.const_get(job.type)

      unless job_class.is_a?(Class) && job_class.include?(Zizq::Job)
        raise "#{job.type} does not include Zizq::Job"
      end

      zizq_job_class = job_class #: Zizq::job_class
      instance = zizq_job_class.new
      instance.set_zizq_job(job)

      args, kwargs = zizq_job_class.zizq_deserialize(
        job.payload || { "args" => [], "kwargs" => {} }
      )

      instance.perform(*args, **kwargs)
    end

    module ClassMethods
      include JobConfig

      # Serialize positional and keyword arguments for the `#perform` method
      # into a payload hash suitable for sending to the server.
      #
      # The result must be a JSON encodable Hash.
      #
      # The default implementation generates a hash of the form:
      #
      #   { "args" => [ 42, "Hello" ], "kwargs" => { "template": "example" } }
      #
      # If you override this method you almost certainly need to override
      # `::zizq_deserialize` too. Any failure to deserialize the arguments will
      # cause the job to fail and backoff according to the backoff policy.
      def zizq_serialize(*args, **kwargs) #: (*untyped, **untyped) -> Hash[String, untyped]
        { "args" => args, "kwargs" => kwargs.transform_keys(&:to_s) }
      end

      # Deserialize a payload hash back into positional and keyword arguments.
      #
      # The payload is a JSON decoded Hash.
      #
      # The default implementation receives a Hash of the form:
      #
      #   { "args" => [ 42, "Hello" ], "kwargs" => { "template": "example" } }
      #
      # And returns an array for `args` and `kwargs` of the form:
      #
      #   [ [ 42, "Hello" ], {template: "example"} ]
      #
      # Because the default implementation uses a JSON decoded Hash, any symbol
      # keys that were present at enqueue-time will be string keys after
      # decoding.
      #
      # Any failure to deserialize the arguments will cause the job to fail and
      # backoff according to the backoff policy.
      def zizq_deserialize(payload) #: (Hash[String, untyped]) -> [Array[untyped], Hash[Symbol, untyped]]
        args   = payload.fetch("args")
        kwargs = payload.fetch("kwargs").transform_keys(&:to_sym)
        [args, kwargs]
      end
    end

    # This is your job's main entrypoint when it is run by the worker.
    #
    # Override this method in your job class to define the work to perform.
    # Declare any positional and keyword arguments your job needs.
    #
    # Strong recommendation: stick to keyword arguments because they are much
    # easier to evolve over time in a backwards compatible way with any already
    # enqueued jobs.
    def perform(*args, **kwargs) #: (*untyped, **untyped) -> void
      raise NotImplementedError, "#{self.class.name}#perform must be implemented"
    end

    # --- Metadata helpers ---
    #
    # These delegate to the Resources::Job instance set by the worker
    # before calling #perform, giving the job access to its server-side
    # metadata.

    # The unique job ID assigned by the server.
    def zizq_id = @zizq_job&.id         #: () -> String?

    # How many times this job has previously been attempted (0 on the first
    # run, 1 on the second, etc...).
    def zizq_attempts = @zizq_job&.attempts   #: () -> Integer?

    # The queue this job was dequeued from.
    def zizq_queue = @zizq_job&.queue      #: () -> String?

    # The priority this job was enqueued with.
    def zizq_priority = @zizq_job&.priority   #: () -> Integer?

    # Time at which this job was dequeued (fractional seconds since the Unix
    # epoch). This can be converted to `Time` by using `Time.at(dequeued_at)`
    # but that is intentionally left to the caller due to time zone
    # considerations.
    def zizq_dequeued_at = @zizq_job&.dequeued_at #: () -> Float?

    # @api private
    # Set by the worker before calling #perform. Receives the full
    # Resources::Job object so all metadata is available through delegation.
    def set_zizq_job(job) #: (Resources::Job) -> void
      @zizq_job = job
    end
  end
end
