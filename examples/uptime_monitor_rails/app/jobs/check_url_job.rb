# frozen_string_literal: true

class CheckUrlJob < ApplicationJob
  def perform(monitored_url)
    return unless monitored_url.enabled?

    previous_status = monitored_url.last_status
    result = UrlProber.call(monitored_url.url)
    check = monitored_url.record_check!(result)

    if status_transitioned?(previous_status, result.status)
      Audit.emit(
        event_type: "url.status.changed",
        actor:      "system",
        resource:   "monitored_url:#{monitored_url.id}",
        text:       "#{monitored_url.url} went #{result.status}",
        data:       {
          "url"  => monitored_url.url,
          "from" => previous_status,
          "to"   => result.status,
        },
      )
      NotifyWebhookJob.perform_later(check)
    end

    DiscoverSitemapUrlsJob.perform_later(monitored_url) if result.is_sitemap
  end

  private

  # Notify on any change between recorded statuses, plus the
  # first-ever check if it's "down" (so an alarm fires immediately).
  # The first "up" check is uninteresting and stays silent.
  def status_transitioned?(previous, current)
    return false if previous == current
    return true if previous

    current == "down"
  end
end
