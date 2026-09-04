# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Represents a Crontab schedule defined on the Zizq server.
  #
  # This requires a Pro license on the Zizq server.
  #
  # The actual data is lazily fetched when first accessed.
  #
  # Crontabs are used to define collections of recurring jobs that run on a
  # specified schedule, such as at 2am on every Monday. Each entry on the
  # Crontab is a single job enqueue, which the Zizq server automatically
  # triggers at the correct point in time. Zizq uses standard Cron expression
  # syntax (with support for seconds via 6-fields) to define entries.
  #
  # Entire schedules, and individual entries on a schedule, can be paused and
  # resumed.
  #
  # By default schedules operate in the system time zone of the Zizq server
  # but an explicit IANA timezone name can be specified when defining the
  # Crontab. It applies to every entry that does not specify one of its own,
  # and is stored on the server as the schedule's own timezone, so it is still
  # there when the schedule is read back.
  #
  # A schedule timezone requires Zizq 0.7.0 or newer on the server.
  class Crontab
    # The name of the cron group that this schedule is backed by.
    attr_reader :name #: String

    # True if this schedule is paused.
    #
    # When paused, the scheduler continues to run but does not enqueue any jobs
    # and only advances the timer.
    attr_writer :paused #: bool?

    # The timezone in which entries without one of their own are processed.
    attr_writer :timezone #: String?

    # Initialize the Crontab with the given group name.
    #
    # @rbs name: String
    def initialize(name)
      @building = false #: bool
      @materialized = false #: bool
      @name = name #: String
      @entries = {} #: Hash[String, Zizq::CrontabEntry]
      @paused = false #: bool?
      @timezone = nil #: String?
      @paused_at = nil #: Float?
      @resumed_at = nil #: Float?
    end

    # Fetch data from the Zizq server if not already fetched.
    #
    # Once fetched, this method becomes a no-op, unless #clear is called to
    # remove the fetched data.
    def materialize #: () -> self
      unless @building || @materialized
        materialize_with(Zizq.client.get_cron_group(name))
      end

      self
    end

    # Clear materialized data that was fetched from the Zizq server.
    #
    # This triggers a refetch when the data is next accessed.
    def clear #: () -> self
      @entries = {}
      @paused = nil
      @timezone = nil
      @paused_at = nil
      @resumed_at = nil
      @materialized = false

      self
    end

    # Delete this entire Crontab schedule and its entries.
    def delete! #: () -> void
      Zizq.client.delete_cron_group(name)
    end

    # Pause this entire Crontab schedule.
    #
    # All entries will stop enqueueing jobs, but the server continues to
    # advance the schedule until it is resumed.
    def pause! #: () -> void
      materialize_with(Zizq.client.update_cron_group(name, paused: true))
    end

    # Resume this Crontab schedule if it is currently paused.
    #
    # Individual entries that are paused will remain paused.
    def resume! #: () -> void
      materialize_with(Zizq.client.update_cron_group(name, paused: false))
    end

    # Check if this schedule is currently paused.
    def paused #: () -> bool?
      materialize
      @paused
    end

    # Check if this schedule is currently paused.
    #
    # Alias of #paused.
    def paused? = paused #: () -> bool?

    # Return the timezone applied to entries that do not specify their own.
    #
    # Nil means entries fall back to the system timezone of the Zizq server.
    def timezone #: () -> String?
      materialize
      @timezone
    end

    # Return the timestamp at which this Crontab schedule was last paused.
    def paused_at #: () -> Float?
      materialize
      @paused_at
    end

    # Return the timestamp at which this Crontab schedule was last resumed.
    def resumed_at #: () -> Float?
      materialize
      @resumed_at
    end

    # Return a Hash of Zizq::CrontabEntry instances keyed by their names.
    #
    # Each entry specifies the cron expression at which it executes,
    # information about when it last/next enqueued a job, and details of the
    # job that the entry enqueues.
    def entries #: () -> Hash[String, Zizq::CrontabEntry]
      materialize
      @entries
    end

    # Redefine (replace) this Crontab schedule with another.
    #
    # This is equivalent to calling `Zizq.define_crontab` and is idempotent
    # when given the same schedule more than once.
    #
    # The timezone is sent as the schedule's own, rather than being copied
    # onto each entry, so it survives a later read of the schedule. Entries
    # that specify their own timezone keep it.
    #
    # @rbs ?timezone: String?
    # @rbs ?paused: bool?
    # @rbs &block: (Zizq::CrontabBuilder) -> void
    # @rbs return: self
    def redefine(timezone: nil, paused: nil, &block)
      @building = true

      builder = CrontabBuilder.new(self, timezone:, paused:)
      yield builder

      materialize_with(
        Zizq.client.replace_cron_group(
          name,
          paused:,
          # Read back off the builder, so assigning `cron.timezone =` inside
          # the block works the same as passing it in.
          timezone: builder.timezone,
          entries: entries.values.map(&:to_params)
        )
      )

      @building = false

      self
    end

    # Return a handle for the specified Zizq::CrontabEntry.
    #
    # The entry can be paused or resumed is isolation, can be deleted entirely
    # or can be redefined (replaced) with another entry.
    #
    # @rbs name: String
    # @rbs return: Zizq::CrontabEntry
    def entry(name)
      materialize
      entries.fetch(name) do
        entry =
          materialize_entry_with(
            Zizq.client.get_cron_group_entry(self.name, name)
          )
        entries[name] = entry
      end
    end

    # Define (or redefine) an entry with this Crontab schedule.
    #
    # Defining the same entry more than once is idempotent. If the entry does
    # not exist, it is added to the schedule. If the entry already exists, it
    # replaces the current entry.
    #
    # The return value is a Zizq::CrontabEntryBuilder instance, on which the
    # caller must call one of the enqueue methods (`enqueue`, `enqueue_raw`,
    # optionally chained onto `enqueue_with`, exactly the same as a regular job
    # enqueue).
    #
    # All enqueue options are supported *except* `delay` and `ready_at` which
    # make no sense for recurring jobs.
    #
    # Bulk enqueues are not supported.
    #
    #   crontab.define_entry(
    #     "refresh_data_warehose",
    #     "*/15 * * * *",
    #   ).enqueue(RefreshDataWarehoseJob, incremental: true)
    #
    # @rbs name: String
    # @rbs expression: String
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs return: Zizq::CrontabEntryBuilder
    def define_entry(name, expression, timezone: nil, paused: nil)
      CrontabEntryBuilder.new(self, name, expression, timezone:, paused:) do |e|
        entry =
          materialize_entry_with(
            Zizq.client.replace_cron_group_entry(
              self.name,
              name,
              expression: e.expression,
              job: e.job.to_enqueue_params,
              timezone: e.timezone,
              paused: e.paused
            )
          )

        materialize # in case this was the first entry operation

        entry
      end
    end

    private

    # @rbs result: Zizq::Resources::CronGroup
    # @rbs return: self
    def materialize_with(result)
      @paused = result.paused?
      @timezone = result.timezone
      @paused_at = result.paused_at
      @resumed_at = result.resumed_at

      @entries =
        result
          .entries
          .map { |entry| [entry.name, materialize_entry_with(entry)] }
          .to_h

      @materialized = true

      self
    end

    # @rbs result: Zizq::Resources::CronEntry
    # @rbs return: Zizq::CrontabEntry
    def materialize_entry_with(result)
      CrontabEntry.new(
        self,
        result.name,
        result.expression,
        timezone: result.timezone,
        job:
          # Every field the template carries has to be listed here.
          # One left out is not only absent from a read: a
          # read-then-redefine writes the entry back without it,
          # silently unbinding a budget or dropping a batch config.
          EnqueueRequest.new(
            type: result.job.type,
            queue: result.job.queue,
            priority: result.job.priority,
            payload: result.job.payload,
            retry_limit: result.job.retry_limit,
            backoff: result.job.backoff,
            retention: result.job.retention,
            unique_key: result.job.unique_key,
            unique_while: result.job.unique_while,
            batch: result.job.batch,
            budgets: result.job.budgets
          ),
        paused: result.paused?,
        paused_at: result.paused_at,
        resumed_at: result.resumed_at,
        last_enqueue_at: result.last_enqueue_at,
        next_enqueue_at: result.next_enqueue_at
      )
    end
  end
end
