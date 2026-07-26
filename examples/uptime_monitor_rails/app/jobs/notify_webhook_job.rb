# frozen_string_literal: true

require "async"
require "async/http/internet/instance"
require "json"

# Posts a status-transition event to a configurable webhook URL.
#
# Uses Zizq's retry/backoff features:
#   * 5xx and network errors raise, so Zizq retries with backoff.
#   * 4xx raises PermanentFailure, which `discard_on` swallows so
#     Zizq sees the job as successful and doesn't retry a hopeless
#     receiver.
#   * When WEBHOOK_URL is unset the job no-ops cleanly.
#
# To see the payloads, point WEBHOOK_URL at a webhook.site URL. Set the
# "Custom Response" to 503 to see retries in action.
class NotifyWebhookJob < ApplicationJob
  zizq_retry_limit 15
  zizq_backoff exponent: 3.0, base: 3.0, jitter: 10.0

  TIMEOUT_SECONDS = 15

  class PermanentFailure < StandardError
  end

  discard_on PermanentFailure

  def perform(check)
    url = ENV["WEBHOOK_URL"].to_s.strip
    if url.empty?
      return logger.warn("NotifyWebhookJob: WEBHOOK_URL not set; skipping")
    end

    deliver(url, build_payload(check))
  end

  private

  def build_payload(check)
    monitored = check.monitored_url
    {
      check_id: check.id,
      monitored_url_id: monitored.id,
      url: monitored.url,
      status: check.status,
      http_status: check.http_status,
      response_time_ms: check.response_time_ms,
      final_url: check.final_url,
      error_message: check.error_message,
      consecutive_failures: monitored.consecutive_failures,
      checked_at: check.checked_at.iso8601
    }
  end

  def deliver(url, payload)
    status_code =
      Sync do
        Async::Task
          .current
          .with_timeout(TIMEOUT_SECONDS) do
            response =
              Async::HTTP::Internet.post(
                url,
                { "content-type" => "application/json" },
                JSON.generate(payload)
              )
            begin
              response.status
            ensure
              response&.finish
              response&.close
            end
          end
      end

    case status_code
    when 200..299
      logger.info do
        "NotifyWebhookJob: delivered to #{url} (HTTP #{status_code})"
      end
    when 400..499
      raise PermanentFailure,
            "Webhook receiver returned #{status_code}; giving up"
    else
      # 3xx (unexpected redirect on POST), 5xx, anything else — let Zizq retry.
      raise "Webhook receiver returned HTTP #{status_code}"
    end
  end
end
