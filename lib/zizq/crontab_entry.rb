# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Represents a single entry within a Crontab schedule.
  #
  # Each entry specifies the cron expression at which it executes,
  # information about when it last/next enqueued a job, and details of the
  # job that the entry enqueues.
  #
  # Entries can be paused or resumed, and can be deleted or redefined in place.
  class CrontabEntry
    # The Crontab schedule to which this entry belongs.
    attr_reader :crontab #: Zizq::Crontab

    # The name of this entry within the schedule.
    attr_reader :name #: String

    # The cron expression used to define the schedule for the entry.
    #
    # Both standard 5-field and enhanced 6-field cron (with seconds) are
    # supported, along with @daily, @weekly etc.
    attr_reader :expression #: String

    # The timezone in which the schedule entry is processed.
    #
    # Defaults to the Zizq server timezone unless specified.
    attr_reader :timezone #: String?

    # Parameters that will be used to enqueue jobs each time the schedule fires.
    #
    # These are the same parameters as those used to enqueue jobs normally.
    attr_reader :job #: EnqueueRequest

    # True if this entry is currrently paused.
    attr_reader :paused #: bool?

    # The timestamp at which this entry was last paused.
    attr_reader :paused_at #: Float?

    # The timestamp at which this entry was last resumed.
    attr_reader :resumed_at #: Float?

    # The timestamp at which a job was last enqueued for this entry.
    attr_reader :last_enqueue_at #: Float?
    #
    # The timestamp at which the next job will be enqueued for this entry.
    attr_reader :next_enqueue_at #: Float?

    # Initialize the entry with all configured parameters.
    #
    # @rbs crontab: Zizq::Crontab
    # @rbs name: String
    # @rbs expression: String
    # @rbs timezone: String?
    # @rbs job: EnqueueRequest
    # @rbs paused: bool?
    # @rbs paused_at: Float?
    # @rbs resumed_at: Float?
    # @rbs last_enqueue_at: Float?
    # @rbs next_enqueue_at: Float?
    def initialize(crontab,
                   name,
                   expression,
                   job:,
                   timezone: nil,
                   paused: nil,
                   paused_at: nil,
                   resumed_at: nil,
                   last_enqueue_at: nil,
                   next_enqueue_at: nil)
      @crontab = crontab
      @name = name
      @expression = expression
      @timezone = timezone
      @job = job
      @paused = paused
      @paused_at = paused_at
      @resumed_at = resumed_at
      @last_enqueue_at = last_enqueue_at
      @next_enqueue_at = next_enqueue_at
    end

    # Replace this entry with another.
    #
    # This is equivalent to calling `crontab.define_entry` with the same name.
    #
    # @rbs expression: String
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs return: Zizq::CrontabEntryBuilder
    def redefine(expression, timezone: nil, paused: nil)
      CrontabEntryBuilder.new(crontab, name, expression, timezone:, paused:) do |e|
        materialize_with(
          Zizq.client.replace_cron_group_entry(
            crontab.name,
            name,
            expression: e.expression,
            job: e.job.to_enqueue_params,
            timezone: e.timezone,
            paused: e.paused,
          ),
        )
      end
    end

    # Delete the entry from the schedule.
    def delete! #: () -> void
      Zizq.client.delete_cron_group_entry(crontab.name, name)
      crontab.entries.delete(name)
    end

    # Pause the entry within the schedule.
    #
    # This is independent of the paused state of the Crontab itself.
    def pause! #: () -> void
      materialize_with(
        Zizq.client.update_cron_group_entry(
          crontab.name,
          name,
          paused: true,
        ),
      )
    end

    # Resume this entry if it is currently paused.
    #
    # If the parent Crontab itself is paused, the entry will still not enqueue
    # jobs until the Crontab is resumed.
    def resume! #: () -> void
      materialize_with(
        Zizq.client.update_cron_group_entry(
          crontab.name,
          name,
          paused: false,
        ),
      )
    end

    # @private
    # @rbs return: Zizq::cron_entry_params
    def to_params
      {
        name:,
        expression:,
        timezone:,
        job: job.to_enqueue_params,
        paused:,
      }.compact #: Zizq::cron_entry_params
    end

    private

    # @rbs result: Zizq::Resources::CronEntry
    # @rbs return: self
    def materialize_with(result)
      @expression = result.expression
      @timezone = result.timezone
      @paused = result.paused?
      @paused_at = result.paused_at
      @resumed_at = result.resumed_at
      @last_enqueue_at = result.last_enqueue_at
      @next_enqueue_at = result.next_enqueue_at
      @job = EnqueueRequest.new(
        type: result.job.type,
        queue: result.job.queue,
        priority: result.job.priority,
        payload: result.job.payload,
        retry_limit: result.job.retry_limit,
        backoff: result.job.backoff,
        retention: result.job.retention,
        unique_key: result.job.unique_key,
        unique_while: result.job.unique_while,
      )

      self
    end
  end
end
