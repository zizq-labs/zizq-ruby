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
    def enqueue(job_class, *args, **kwargs, &block)
      push_entry(Zizq.build_enqueue_request(job_class, *args, **kwargs, &block))
    end

    # Process a raw job enqueue for this entry.
    #
    # This is used for low-level or cross-language support.
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
    # @rbs batch: Zizq::batch?
    # @rbs budgets: Array[Zizq::budget_binding_params]?
    # @rbs return: void
    def enqueue_raw(queue:, type:, payload:, **opts)
      push_entry(EnqueueRequest.new(queue:, type:, payload:, **opts))
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
