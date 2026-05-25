# frozen_string_literal: true

class CheckUrlJob < ApplicationJob
  def perform(monitored_url)
    return unless monitored_url.enabled?

    previous_status = monitored_url.last_status
    result = UrlProber.call(monitored_url.url)
    check = monitored_url.record_check!(result)

    NotifyWebhookJob.perform_later(check) if status_transitioned?(previous_status, result.status)
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
