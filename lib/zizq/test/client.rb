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

      # The canonical Zizq lifecycle states. We mirror these so the
      # `status` on a buffered job reflects what the real server would
      # report. Test mode never retries — `in_flight` only ever
      # transitions to `completed` or `dead`.
      STATUS_SCHEDULED = "scheduled"
      STATUS_READY     = "ready"
      STATUS_IN_FLIGHT = "in_flight"
      STATUS_COMPLETED = "completed"
      STATUS_DEAD      = "dead"

      # Default `filter:` lambda — passes every job. Named so the
      # filter pipeline is always callable without nil-checking.
      PASS_ALL_FILTER = ->(_job) { true } #: ^(Resources::Job) -> bool

      # Paired view of a single enqueue: the original `EnqueueRequest`
      # (with full submission metadata — `unique_key`, `unique_while`,
      # retry config, etc.), the synthetic `Resources::Job` returned
      # to callers, and the data hash that backs the job (so we can
      # mutate its status through the lifecycle).
      Entry = Struct.new(:request, :job, :data, keyword_init: true)

      def initialize #: () -> void
        # Skip the parent's HTTP setup — we don't open connections in
        # test mode. The parent's @http and friends stay nil; methods
        # that would touch them are overridden below.

        @entries = [] #: Array[Entry]
        @mutex = Mutex.new
      end

      # All buffered jobs, in submission order, optionally filtered.
      # See `apply_filters` for the filter kwargs.
      def enqueued_jobs(**filters) #: (**untyped) -> Array[Resources::Job]
        @mutex.synchronize { apply_filters(@entries, **filters).map(&:job) }
      end

      # Original `EnqueueRequest`s in submission order. Useful when a
      # test needs metadata that doesn't survive onto `Resources::Job`
      # (`unique_key`, `unique_while`, `delay` before `ready_at`
      # resolution, etc.). Same filter kwargs as `enqueued_jobs`.
      def enqueued_requests(**filters) #: (**untyped) -> Array[EnqueueRequest]
        @mutex.synchronize { apply_filters(@entries, **filters).map(&:request) }
      end

      # Jobs awaiting dispatch — `ready` and `scheduled` entries.
      # `pending_jobs` is the set `drain` would attempt to run on its
      # next call (modulo `ready_at` for `scheduled` entries).
      def pending_jobs(**filters) #: (**untyped) -> Array[Resources::Job]
        filter_by_status([STATUS_READY, STATUS_SCHEDULED], **filters)
      end

      def in_flight_jobs(**filters) #: (**untyped) -> Array[Resources::Job]
        filter_by_status([STATUS_IN_FLIGHT], **filters)
      end

      def completed_jobs(**filters) #: (**untyped) -> Array[Resources::Job]
        filter_by_status([STATUS_COMPLETED], **filters)
      end

      def dead_jobs(**filters) #: (**untyped) -> Array[Resources::Job]
        filter_by_status([STATUS_DEAD], **filters)
      end

      # Reset the buffer. Called between tests via `Zizq::Test.reset!`.
      def clear! #: () -> void
        @mutex.synchronize { @entries.clear }
      end

      def close #: () -> void
      end

      # Dispatch every runnable entry (status `ready`, or `scheduled`
      # with `ready_at` already elapsed) through the configured
      # dequeue middleware chain (same path the real worker uses, so
      # any registered middlewares run in tests too), looping until no
      # more match the filters. Re-enqueues during dispatch fall
      # through the loop naturally — they get drained too unless they
      # fall outside the filter set.
      #
      # The per-iteration snapshot is taken under the mutex and marked
      # `in_flight` atomically. Dispatch happens outside the mutex so
      # handlers can re-enter the client without deadlocking. On
      # success the entry moves to `completed`; on a raised exception
      # it moves to `dead` and the exception re-raises (matching
      # ActiveJob's `perform_enqueued_jobs` + Sidekiq's `drain`).
      def drain(**filters) #: (**untyped) -> Integer
        total = 0
        loop do
          snapshot = take_runnable_snapshot(**filters)
          break if snapshot.empty?

          snapshot.each { |entry| dispatch_entry(entry) }
          total += snapshot.size
        end
        total
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
        @mutex.synchronize { record_unsynchronized(req) }.job
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
            record_unsynchronized(req).job
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

      def record_unsynchronized(req) #: (EnqueueRequest) -> Entry
        # Serialized format: ready_at is integer milliseconds.
        # `req.ready_at` (from `to_enqueue_params`) is fractional
        # seconds; convert here so `Resources::Job#ready_at`'s
        # ms -> seconds round-trip produces the same value the
        # caller passed in. When the client omits ready_at the server
        # assigns `now`, so we do the same.
        now_ms = (Time.now.to_f * 1000).to_i
        ready_at_ms = req.ready_at ? (req.ready_at.to_f * 1000).to_i : now_ms

        data = {
          "id" => synthetic_id(@entries.size + 1),
          "queue" => req.queue,
          "type" => req.type,
          "payload" => req.payload,
          "priority" => req.priority,
          "ready_at" => ready_at_ms,
          "retry_limit" => req.retry_limit,
          "status" => ready_at_ms > now_ms ? STATUS_SCHEDULED : STATUS_READY,
        }
        entry = Entry.new(request: req, job: Resources::Job.new(self, data), data: data)
        @entries << entry
        entry
      end

      def synthetic_id(counter) #: (Integer) -> String
        "#{ID_PREFIX}#{counter.to_s.rjust(ID_LENGTH - ID_PREFIX.length, '0')}"
      end

      # Returns entries matching every named filter AND the predicate.
      # All filter kwargs are optional; unset means "don't filter on
      # this axis." Callers must hold `@mutex` — public accessors do
      # so via `synchronize` before calling.
      #
      # * `only_queues:`  / `except_queues:` — String, Array of Strings.
      # * `only_types:`   / `except_types:`  — String, Class, or Array
      #   of those. Class names are matched against the wire-format
      #   `type` string via `.to_s`.
      # * `filter:` — a lambda receiving a `Resources::Job`, returning
      #   truthy to keep. Defaults to `PASS_ALL_FILTER`.
      #
      # `only_*` and `except_*` AND together with the predicate.
      def apply_filters(entries,
                        only_queues: nil,
                        except_queues: nil,
                        only_types: nil,
                        except_types: nil,
                        filter: PASS_ALL_FILTER) #: (Array[Entry], **untyped) -> Array[Entry]
        only_queues   = normalize_filter(only_queues)
        except_queues = normalize_filter(except_queues)
        only_types    = normalize_filter(only_types)
        except_types  = normalize_filter(except_types)

        entries.select do |entry|
          queue = entry.data["queue"] #: String
          type  = entry.data["type"]  #: String

          (only_queues.empty? || only_queues.include?(queue)) &&
            (except_queues.empty? || !except_queues.include?(queue)) &&
            (only_types.empty? || only_types.include?(type)) &&
            (except_types.empty? || !except_types.include?(type)) &&
            filter.call(entry.job)
        end
      end

      def filter_by_status(statuses, **filters) #: (Array[String], **untyped) -> Array[Resources::Job]
        @mutex.synchronize do
          apply_filters(@entries, **filters)
            .select { |e| statuses.include?(e.data["status"]) }
            .map(&:job)
        end
      end

      # Lock, find runnable entries matching the filters, flip each
      # to in_flight, return the snapshot. Holding the mutex through
      # this is fine because we don't call user code — dispatch
      # happens outside.
      def take_runnable_snapshot(**filters) #: (**untyped) -> Array[Entry]
        now_ms = (Time.now.to_f * 1000).to_i
        @mutex.synchronize do
          apply_filters(@entries, **filters)
            .select { |e| runnable?(e, now_ms) }
            .each { |entry| entry.data["status"] = STATUS_IN_FLIGHT }
        end
      end

      def runnable?(entry, now_ms) #: (Entry, Integer) -> bool
        case entry.data["status"]
        when STATUS_READY     then true
        when STATUS_SCHEDULED then entry.data["ready_at"] <= now_ms
        else false
        end
      end

      # Accept a Class, String, or Array of those; emit an Array of
      # Strings. Class names match the API's `type` string.
      def normalize_filter(value) #: ((String | Class | Array[String | Class])?) -> Array[String]
        case value
        when nil then []
        when Array then value.map { |x| x.to_s }
        else [value.to_s]
        end
      end

      # Mark the entry in_flight, dispatch through the full dequeue
      # middleware chain (same path the real worker uses, so any
      # registered middlewares run in tests too), settle to
      # completed or dead. A raised exception re-raises after
      # recording — same observable behaviour as Rails'
      # `perform_enqueued_jobs`.
      def dispatch_entry(entry) #: (Entry) -> void
        entry.data["status"] = STATUS_IN_FLIGHT
        begin
          Zizq.configuration.dequeue_middleware.call(entry.job)
          entry.data["status"] = STATUS_COMPLETED
        rescue
          entry.data["status"] = STATUS_DEAD
          raise
        end
      end
    end
  end
end
