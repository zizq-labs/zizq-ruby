# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Builder class used to define individual entries within a Crontab schedule.
  #
  # This is used internally by `Zizq.define_crontab`. See documentation for
  # that method for full details.
  #
  # Callers *must* call one of the enqueue methods to complete the build
  # process.
  class CrontabEntryBuilder
    # The Crontab instance onto which entries are applied.
    attr_reader :target #: Zizq::Crontab

    # The name of the entry being built.
    attr_reader :name #: String

    # The cron expression for the entry.
    attr_reader :expression #: String

    # Optional timezone for the entry.
    #
    # Defaults to the Zizq server timezone when not specified.
    attr_reader :timezone #: String?

    # True if this entry will be paused.
    attr_reader :paused #: bool?

    # Callback through which the built entry is passed before being added to
    # the Crontab schedule.
    #
    # The callback receives the Zizq::CrontabEntry instance and may return an
    # alternative instance to be used after it has done any processing on the
    # entry.
    attr_reader :callback #: ^(Zizq::CrontabEntry) -> Zizq::CrontabEntry

    # Initialize the builder with the given inputs.
    #
    # @rbs target: Zizq::Crontab
    # @rbs name: String
    # @rbs expression: String
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs ?&block: (Zizq::CrontabEntry) -> Zizq::CrontabEntry
    def initialize(target, name, expression, timezone: nil, paused: nil, &block)
      @target = target
      @name = name
      @expression = expression
      @timezone = timezone
      @paused = paused
      @callback = block || :itself.to_proc
    end

    # Enqueue a Zizq::Job or ActiveJob class using Zizq::ActiveJobConfig via
    # this entry.
    #
    # @rbs job_class: Class & Zizq::JobConfig
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueRequest) -> void
    # @rbs return: void
    def enqueue_job_class(job_class, *args, **kwargs, &block)
      push_entry(Zizq.build_enqueue_request(job_class, *args, **kwargs, &block))
    end

    # Enqueue via this entry, by class or by raw inputs.
    #
    #   cron.define_entry("d", "0 9 * * *").enqueue(DigestJob)
    #   cron.define_entry("d", "0 9 * * *")
    #       .enqueue(queue: "emails", type: "digest", payload: {})
    #
    # A cron entry fires on its schedule, so the raw form here omits
    # `ready_at` and `delay` — passing either does not typecheck. Both
    # still bind at runtime and raise an `ArgumentError`, which is what
    # untyped callers get.
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

    # Process a raw job enqueue for this entry.
    #
    # This is used for low-level or cross-language support.
    #
    # `ready_at` and `delay` are absent from the signature: a cron entry
    # fires on its schedule and cannot also be scheduled. They still
    # bind at runtime and raise an `ArgumentError`, since the method
    # takes `**opts` and cannot refuse a keyword by itself.
    #
    # @rbs skip
    # @rbs!
    #   def enqueue_raw: (
    #     queue: String,
    #     type: String,
    #     payload: untyped,
    #     ?priority: Integer?,
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
      push_entry(req)
    end

    # Bulk enqueues are not supported via cron.
    #
    # @rbs &block: (BulkEnqueue) -> void
    # @rbs return: self
    def enqueue_bulk(&block)
      raise NotImplementedError, "bulk enqueues are not supported via cron"
    end

    # Provide common fields to be used when enqueueing a job.
    #
    # @rbs overrides: Hash[Symbol, untyped]
    # @rbs return: EnqueueWith
    def enqueue_with(**overrides)
      EnqueueWith.new(self, overrides)
    end

    private

    # @rbs job: EnqueueRequest
    # @rbs return: untyped
    def push_entry(req)
      if req.ready_at || req.delay
        raise ArgumentError, "delayed job are not permitted via cron"
      end

      entry =
        callback.call(
          CrontabEntry.new(
            target,
            name,
            expression,
            job: req,
            timezone:,
            paused:
          )
        )

      target.entries[entry.name] = entry
    end
  end
end
