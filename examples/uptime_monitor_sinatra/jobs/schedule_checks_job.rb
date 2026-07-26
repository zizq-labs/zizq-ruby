# frozen_string_literal: true

# Periodic sweep that enqueues a CheckUrlJob for every monitored URL
# whose last check is older than STALE_AFTER (or that has never been
# checked). Triggered by a 5-second cron entry registered in
# `app.rb`; the cron fires often, but only stale URLs are re-checked
# so URLs aren't all probed simultaneously.
class ScheduleChecksJob
  include Zizq::Job

  zizq_queue ZIZQ_QUEUE

  STALE_AFTER = 60 # seconds
  BATCH_SIZE = 500

  def perform
    stale_ids =
      MonitoredUrl
        .where(enabled: true)
        .where(
          Sequel.lit(
            "last_checked_at IS NULL OR last_checked_at < ?",
            Time.now - STALE_AFTER
          )
        )
        .select_map(:id)

    # `enqueue_bulk` collapses N jobs into a single Zizq round-trip,
    # so even a backlog of thousands of URLs dispatches in just a
    # handful of requests.
    stale_ids.each_slice(BATCH_SIZE) do |batch|
      Zizq.enqueue_bulk { |b| batch.each { |id| b.enqueue(CheckUrlJob, id) } }
    end
  end
end
