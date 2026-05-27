# frozen_string_literal: true

# Probes one `MonitoredUrl` and records the result.
#
# Arguments here are plain JSON-serialisable values — Zizq::Job
# uses its own `zizq_serialize` / `zizq_deserialize` pair, no
# GlobalID magic. We pass the row's integer id and re-fetch.
class CheckUrlJob
  include Zizq::Job

  zizq_queue ZIZQ_QUEUE
  zizq_retry_limit 3

  def perform(monitored_url_id)
    monitored = MonitoredUrl[monitored_url_id]
    return unless monitored&.enabled

    previous_status = monitored.last_status
    result = UrlProber.call(monitored.url)
    check  = monitored.record_check!(result)

    Zizq.enqueue(NotifyWebhookJob, check.id) if status_transitioned?(previous_status, result.status)
    Zizq.enqueue(DiscoverSitemapUrlsJob, monitored.id) if result.is_sitemap
  end

  private

  # Fire on any change between recorded statuses, plus the first-ever
  # check if it's "down" (so an alarm fires immediately). The first
  # "up" check is uninteresting and stays silent.
  def status_transitioned?(previous, current)
    return false if previous == current
    return true if previous

    current == "down"
  end
end
