# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Builder for collecting multiple job params to be sent as a single bulk
  # request via `Zizq.enqueue_bulk`.
  #
  #   Zizq.enqueue_bulk do |b|
  #     b.enqueue(MyApp::FooJob, 42)
  #     b.enqueue(MyApp::OtherJob, 42, x: 7)
  #   end
  class BulkEnqueue
    attr_reader :requests #: Array[EnqueueRequest]

    def initialize #: () -> void
      @requests = [] #: Array[EnqueueRequest]
    end

    # Collect a job class enqueue. Accepts the same arguments as
    # `Zizq.enqueue`.
    #
    # @rbs job_class: Class & Zizq::JobConfig
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueRequest) -> void
    # @rbs return: void
    def enqueue_job_class(job_class, *args, **kwargs, &block)
      @requests << Zizq.build_enqueue_request(
        job_class,
        *args,
        **kwargs,
        &block
      )
    end

    # Collect an enqueue, by class or by raw inputs.
    #
    # Both forms of `Zizq.enqueue` work here too:
    #
    #   b.enqueue(SendEmailJob, 42, template: "welcome")
    #   b.enqueue(queue: "emails", type: "send_email", payload: {...})
    #
    # @rbs skip
    # @rbs!
    #   def enqueue: (
    #     Class & Zizq::JobConfig job_class,
    #     *untyped args,
    #     **untyped kwargs
    #   ) ?{ (EnqueueRequest) -> void } -> void
    #   | (
    #     queue: String,
    #     type: String,
    #     payload: untyped,
    #     ?priority: Integer?,
    #     ?delay: Zizq::to_f?,
    #     ?ready_at: Zizq::to_f?,
    #     ?retry_limit: Integer?,
    #     ?backoff: Zizq::backoff?,
    #     ?retention: Zizq::retention?,
    #     ?unique_key: String?,
    #     ?unique_while: Zizq::unique_scope?,
    #     ?batch: Zizq::batch?,
    #     ?budgets: Array[Zizq::budget_binding_params]?
    #   ) ?{ (EnqueueRequest) -> void } -> void
    def enqueue(*args, **kwargs, &block)
      return enqueue_job_class(*args, **kwargs, &block) unless args.empty?

      begin
        # See `Zizq.enqueue` for why only this branch is wrapped.
        enqueue_raw(**kwargs, &block) # steep:ignore InsufficientKeywordArguments
      rescue ArgumentError => e
        raise ArgumentError, e.message, caller(1)
      end
    end

    # Collect a raw enqueue. Accepts the same arguments as
    # `Zizq.enqueue_raw`.
    #
    # @rbs skip
    # @rbs!
    #   def enqueue_raw: (
    #     queue: String,
    #     type: String,
    #     payload: untyped,
    #     ?priority: Integer?,
    #     ?delay: Zizq::to_f?,
    #     ?ready_at: Zizq::to_f?,
    #     ?retry_limit: Integer?,
    #     ?backoff: Zizq::backoff?,
    #     ?retention: Zizq::retention?,
    #     ?unique_key: String?,
    #     ?unique_while: Zizq::unique_scope?,
    #     ?batch: Zizq::batch?,
    #     ?budgets: Array[Zizq::budget_binding_params]?
    #   ) ?{ (EnqueueRequest) -> void } -> void
    def enqueue_raw(queue:, type:, payload:, **opts)
      req = EnqueueRequest.new(queue:, type:, payload:, **opts)
      yield req if block_given?
      @requests << req
    end

    # Build a scoped enqueue helper that applies the given overrides to a
    # single enqueue inside this bulk block. Sugar for the block form:
    #
    #   b.enqueue_with(ready_at: Time.now + 3600).enqueue(OtherJob, 42)
    #
    # is equivalent to:
    #
    #   b.enqueue(OtherJob, 42) { |req| req.ready_at = Time.now + 3600 }
    #
    # @rbs overrides: Hash[Symbol, untyped]
    # @rbs return: EnqueueWith
    def enqueue_with(**overrides)
      EnqueueWith.new(self, overrides)
    end

    # Nested bulk is a no-op — we're already inside a bulk block, so we
    # just yield this same builder. This exists to satisfy the
    # `_EnqueueTarget` interface, which lets `EnqueueWith#enqueue_bulk`
    # work uniformly against both the top-level `Zizq` module and a
    # `BulkEnqueue` instance without branching on target type.
    #
    #   Zizq.enqueue_bulk do |b|
    #     b.enqueue_with(priority: 0).enqueue_bulk do |b2|
    #       b2.enqueue(MyJob, 1)
    #       b2.enqueue(MyJob, 2)
    #     end
    #   end
    #
    # @rbs &block: (BulkEnqueue) -> void
    # @rbs return: self
    def enqueue_bulk(&block)
      yield self
      self
    end
  end
end
