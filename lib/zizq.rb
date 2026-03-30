# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require_relative "zizq/version"
require_relative "zizq/error"
require_relative "zizq/configuration"

# Autoloaded when first accessed — avoids loading heavy deps at require time.
autoload :MessagePack, "msgpack"

module Zizq
  autoload :AckProcessor,    "zizq/ack_processor"
  autoload :ActiveJobConfig, "zizq/active_job_config"
  autoload :Backoff,         "zizq/backoff"
  autoload :BulkEnqueue,     "zizq/bulk_enqueue"
  autoload :Client,          "zizq/client"
  autoload :EnqueueRequest,  "zizq/enqueue_request"
  autoload :Job,             "zizq/job"
  autoload :JobConfig,       "zizq/job_config"
  autoload :Middleware,      "zizq/middleware"
  autoload :Lifecycle,       "zizq/lifecycle"
  autoload :Resources,       "zizq/resources"
  autoload :Worker,          "zizq/worker"

  # Sentinel indicating a field should not be included in the request.
  # Used as the default for update parameters.
  module UNCHANGED; end

  # Sentinel indicating a field should be sent as null to reset to server default.
  module RESET; end

  @client_mutex = Mutex.new

  class << self
    # Returns the client configuration.
    #
    # The configuration can be updated by calling [`Zizq::configure`].
    #
    # This configuration is for the client only. Worker parameters are
    # configured on a per-run basis for flexibility.
    def configuration #: () -> Configuration
      @configuration ||= Configuration.new
    end

    # Yields the global configuration ready for updates, which should be done
    # during application initialization, before any jobs are enqueued or
    # worked.
    #
    #   Zizq.configure do |c|
    #     c.url = "http://localhost:7890"
    #     c.format = :msgpack
    #     c.dequeue_middleware.use(MyDequeueMiddleware.new)
    #   end
    def configure #: () { (Configuration) -> void } -> void
      yield configuration
    ensure
      @client = nil # shared client is potentially stale
    end

    # Returns a shared client instance built from the global configuration.
    #
    # The client is memoized so that persistent HTTP connections are reused
    # across calls, reducing TCP connection overhead.
    def client #: () -> Client
      @client ||= begin
        @client_mutex.synchronize do
          break @client if @client

          configuration.validate!
          @client = Client.new(
            url: configuration.url,
            format: configuration.format,
            ssl_context: configuration.ssl_context
          )
        end
      end
    end

    # Resets all global state: configuration and shared client.
    # Intended for use in tests.
    def reset! #: () -> void
      @client&.close
      @client = nil
      @configuration = nil
    end

    # Enqueue a job by class with positional and keyword arguments.
    #
    # By default all arguments are serialized as JSON, which means hashes with
    # symbol keys will become hashes with string keys. The serialization
    # behaviour can be changed by implementing `::zizq_serialize` and
    # `::zizq_deserialize` as class methods on the job class.
    #
    # Default job options can be overridden at enqueue-time by providing a
    # block which receives a mutable `Zizq::EnqueueRequest` instance.
    #
    #   Zizq.enqueue(SendEmailJob, 42, template: "welcome")
    #   Zizq.enqueue(SendEmailJob, 42) { |o| o.queue = "priority" }
    #
    # Job classes may also override `::zizq_enqueue_options` to implement
    # dynamically computed options, such as dynamic prioritisation. This class
    # method accepts the same arguments as the `#perform` method and returns an
    # instance of `Zizq::EnqueueRequest`. Any overrides may call `super` and
    # modify the result.
    #
    #   class SendEmailJob
    #     include Zizq::Job
    #
    #     zizq_priority 1000
    #
    #     def self.zizq_enqueue_options(user_id, template:)
    #       opts = super
    #       opts.priority /= 2 if template == "welcome"
    #       opts
    #     end
    #
    #     def perform(user_id, template:)
    #       # ...
    #     end
    #   end
    #
    # @rbs job_class: Class & Zizq::job_class
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueRequest) -> void
    # @rbs return: Resources::Job
    def enqueue(job_class, *args, **kwargs, &block)
      req = build_enqueue_request(job_class, *args, **kwargs, &block)
      req = configuration.enqueue_middleware.call(req)
      client.enqueue(**req.to_enqueue_params)
    end

    # Enqueue a job by providing raw inputs to the Zizq server.
    #
    # This is for advanced use cases such as enqueueing jobs for consumption in
    # other programming languages.
    #
    #   Zizq.enqueue_raw(
    #     queue: "emails",
    #     type: "send_email",
    #     payload: {user_id: 42, template: "welcome"}
    #   )
    #
    # If using this method to enqueue a job that is intended for consumption in
    # the Ruby client itself a custom dispatcher implementation is likely
    # required:
    #
    #   Zizq.configure do |c|
    #     c.dispatcher = MyDispatcher.new
    #   end
    #
    # @rbs queue: String
    # @rbs type: String
    # @rbs payload: untyped
    # @rbs priority: Integer?
    # @rbs ready_at: Zizq::to_f?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs return: Resources::Job
    def enqueue_raw(queue:, type:, payload:, **opts)
      req = EnqueueRequest.new(queue:, type:, payload:, **opts)
      req = configuration.enqueue_middleware.call(req)
      client.enqueue(**req.to_enqueue_params)
    end

    # Enqueue multiple jobs atomically in a single bulk request.
    #
    # This can significantly imprive throughput when many jobs need to be
    # enqueued collectively. There is no upper limit on the number of jobs in
    # the request though generally it is probably wise to keep this to less
    # than 1000 jobs unless you have strong atomicity requuirements for a
    # larger number of jobs..
    #
    # Yields a builder object whose `#enqueue` method accepts the same
    # arguments as `Zizq.enqueue`. All collected jobs are sent as a
    # single `POST /jobs/bulk` request and an array of jobs is returned in the
    # same order as the inputs.
    #
    #   Zizq.enqueue_bulk do |b|
    #     b.enqueue(ProcessPaymentJob, 7)
    #     b.enqueue(SendEmailJob, 42, template: "welcome")
    #     b.enqueue(SendEmailJob, 42) { |o| o.queue = "priority" }
    #   end
    #
    # @rbs &block: (BulkEnqueue) -> void
    # @rbs return: Array[Resources::Job]
    def enqueue_bulk(&block)
      builder = BulkEnqueue.new
      yield builder
      return [] if builder.requests.empty?

      jobs = builder.requests.map do |req|
        configuration.enqueue_middleware.call(req).to_enqueue_params
      end

      client.enqueue_bulk(jobs:)
    end

    # @api private
    # Build an EnqueueRequest for a single job class enqueue.
    #
    # @rbs job_class: Class & Zizq::job_class
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueRequest) -> void
    # @rbs return: EnqueueRequest
    def build_enqueue_request(job_class, *args, **kwargs, &block)
      unless job_class.is_a?(Class) && job_class < Zizq::Job
        raise ArgumentError, "#{job_class.inspect} must include Zizq::Job"
      end

      zizq_job_class = job_class #: Zizq::job_class
      req = zizq_job_class.zizq_enqueue_request(*args, **kwargs)
      yield req if block_given?
      req
    end
  end
end
