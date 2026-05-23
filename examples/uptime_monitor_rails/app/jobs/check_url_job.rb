# frozen_string_literal: true

class CheckUrlJob < ApplicationJob
  def perform(monitored_url)
    return unless monitored_url.enabled?

    result = UrlProber.call(monitored_url.url)
    monitored_url.record_check!(result)
  end
end
