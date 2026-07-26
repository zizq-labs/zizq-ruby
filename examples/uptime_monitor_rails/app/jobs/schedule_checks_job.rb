# frozen_string_literal: true

# Periodic sweep that enqueues a CheckUrlJob for every monitored URL
# whose last check is older than STALE_AFTER (or that has never been
# checked). Triggered by a 5-second cron entry defined in
# `config/initializers/zizq_crontab.rb`; the cron fires often, but only
# stale URLs are re-checked, so URLs aren't all probed simultaneously.
class ScheduleChecksJob < ApplicationJob
  STALE_AFTER = 60.seconds
  BATCH_SIZE = 500

  def perform
    stale =
      MonitoredUrl.enabled.where(
        "last_checked_at IS NULL OR last_checked_at < ?",
        STALE_AFTER.ago
      )

    # `in_batches` paginates the DB read; `perform_all_later` collapses
    # each batch into a single Zizq bulk enqueue, so even a backlog of
    # thousands of URLs is dispatched in just a handful of round trips.
    stale.in_batches(of: BATCH_SIZE) do |batch|
      jobs = batch.map { |monitored| CheckUrlJob.new(monitored) }
      ActiveJob.perform_all_later(jobs)
    end
  end
end
