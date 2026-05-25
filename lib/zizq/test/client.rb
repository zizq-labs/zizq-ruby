# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Test
    # A `Zizq::Client` stand-in for use in test suites.
    #
    # Buffers `enqueue` / `enqueue_bulk` calls in memory and returns
    # synthetic `Resources::Job` instances (with generated ids) so that
    # callers depending on the regular client's return contract don't
    # need to special-case test mode.
    #
    # Read operations (`get_queues`, `list_jobs`, `count_jobs`, …) are
    # explicitly not supported in test mode and raise `NotSupported`.
    # Tests that need those should either run against a real server or
    # stub at a higher level.
    #
    # Activated indirectly via `Zizq.configuration.test_mode = true` —
    # `Zizq.client` then lazily builds a `Test::Client` instead of a
    # real `Client`.
    class Client < Zizq::Client
      # Raised when test-mode code reaches an operation that isn't
      # supported (queries, queue listing, worker streams, etc.).
      class NotSupported < Zizq::Error; end

      # Length of a real scru128 id in its base-32 representation.
      # Synthetic test ids are sized to match (`test` prefix + zero
      # padded counter) so they fit anywhere a real id would.
      ID_LENGTH = 25
      ID_PREFIX = "test"

      # Paired view of a single enqueue: the original
      # `EnqueueRequest` (with full submission metadata —
      # `unique_key`, `unique_while`, retry config, etc.) and the
      # synthetic `Resources::Job` returned to callers (the same
      # shape the dispatcher receives at drain time).
      Entry = Struct.new(:request, :job, keyword_init: true)

      def initialize #: () -> void
        # Skip the parent's HTTP setup — we don't open connections in
        # test mode. The parent's @http and friends stay nil; methods
        # that would touch them are overridden below.

        @entries = [] #: Array[Entry]
        @mutex = Mutex.new
      end

      # Buffered jobs, in submission order. Suitable for both
      # assertion-style introspection (`.queue`, `.type`, `.payload`,
      # `.ready_at`) and feeding into the dispatcher at drain time.
      def enqueued_jobs #: () -> Array[Resources::Job]
        @mutex.synchronize { @entries.map(&:job) }
      end

      # Original `EnqueueRequest`s in submission order. Useful when a
      # test needs metadata that doesn't survive onto `Resources::Job`
      # (`unique_key`, `unique_while`, `delay` before `ready_at`
      # resolution, etc.).
      def enqueued_requests #: () -> Array[EnqueueRequest]
        @mutex.synchronize { @entries.map(&:request) }
      end

      # Reset the buffer. Called between tests via `Zizq::Test.reset!`.
      def clear! #: () -> void
        @mutex.synchronize { @entries.clear }
      end

      def close #: () -> void
      end

      # @rbs override
      def enqueue(queue:,
                  type:,
                  payload:,
                  priority: nil,
                  ready_at: nil,
                  retry_limit: nil,
                  backoff: nil,
                  retention: nil,
                  unique_key: nil,
                  unique_while: nil)
        req = EnqueueRequest.new(
          queue:,
          type:,
          payload:,
          priority:,
          ready_at:,
          retry_limit:,
          backoff:,
          retention:,
          unique_key:,
          unique_while:,
        )
        record(req)
      end

      # @rbs override
      def enqueue_bulk(jobs:)
        @mutex.synchronize do
          jobs.map do |params|
            req = EnqueueRequest.new(
              queue:        params[:queue],
              type:         params[:type],
              payload:      params[:payload],
              priority:     params[:priority],
              ready_at:     params[:ready_at],
              retry_limit:  params[:retry_limit],
              backoff:      params[:backoff],
              retention:    params[:retention],
              unique_key:   params[:unique_key],
              unique_while: params[:unique_while],
            )
            record_unsynchronized(req)
          end
        end
      end

      # All read / mutation / streaming operations are deliberately
      # unimplemented.
      #
      # Raising loudly beats silently returning empty results that
      # hide missing test setup.
      %i[
        get_queues
        list_jobs
        count_jobs
        get_job
        delete_job
        delete_all_jobs
        update_job
        update_all_jobs
        take_jobs
        get_error
        list_errors
        health
        server_version
      ].each do |method_name|
        define_method(method_name) do |*, **, &_|
          Kernel.raise(
            NotSupported,
            "Zizq::Test::Client##{method_name} is not supported in test mode. " \
            "Test mode buffers enqueues only — point at a real server, or stub the call."
          )
        end
      end

      private

      def record(req) #: (EnqueueRequest) -> Resources::Job
        @mutex.synchronize { record_unsynchronized(req) }
      end

      def record_unsynchronized(req) #: (EnqueueRequest) -> Resources::Job
        # Serialized format: ready_at is integer milliseconds. `req.ready_at`
        # (from `to_enqueue_params`) is fractional seconds; convert
        # here so `Resources::Job#ready_at`'s ms -> seconds round-trip
        # produces the same value the caller passed in. When the
        # client omits ready_at the server assigns `now`, so we do
        # the same.
        now_ms = (Time.now.to_f * 1000).to_i
        ready_at_ms = req.ready_at ? (req.ready_at.to_f * 1000).to_i : now_ms

        job = Resources::Job.new(
          self,
          {
            "id" => synthetic_id(@entries.size + 1),
            "queue" => req.queue,
            "type" => req.type,
            "payload" => req.payload,
            "priority" => req.priority,
            "ready_at" => ready_at_ms,
            "retry_limit" => req.retry_limit,
            "status" => ready_at_ms > now_ms ? "scheduled" : "ready",
          },
        )
        @entries << Entry.new(request: req, job: job)
        job
      end

      def synthetic_id(counter) #: (Integer) -> String
        "#{ID_PREFIX}#{counter.to_s.rjust(ID_LENGTH - ID_PREFIX.length, '0')}"
      end
    end
  end
end
