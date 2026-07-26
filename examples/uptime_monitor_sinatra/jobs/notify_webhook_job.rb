# frozen_string_literal: true

require "faraday"
require "json"
require "time"

# Posts a status-transition event to a configurable webhook URL.
#
# Uses Zizq's retry/backoff features:
#   * 5xx and network errors raise, so Zizq retries with backoff.
#   * 4xx logs and returns successfully (job marked complete on the
#     server, no retry) — a permanently-broken receiver shouldn't
#     keep us spinning. Unlike the Rails (ActiveJob) version we
#     don't need `discard_on`: Zizq::Job only retries when `perform`
#     raises, so returning cleanly is the discard.
#   * When WEBHOOK_URL is unset the job no-ops cleanly.
#
# To see the payloads, point WEBHOOK_URL at a webhook.site URL. To
# watch the backoff curve, configure that URL's "Custom Response" to
# return HTTP 503.
class NotifyWebhookJob
  include Zizq::Job

  zizq_queue ZIZQ_QUEUE
  zizq_retry_limit 15
  zizq_backoff exponent: 2.0, base: 3.0, jitter: 1.0

  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 10

  def perform(check_id)
    check = Check[check_id]
    return unless check

    url = ENV["WEBHOOK_URL"].to_s.strip
    return if url.empty?

    response =
      connection.post(url) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(build_payload(check))
      end

    case response.status
    when 200..299
      # delivered
    when 400..499
      # Permanent failure: log and succeed (no retry).
      warn "[NotifyWebhookJob] receiver returned HTTP #{response.status}; giving up"
    else
      raise "Webhook receiver returned HTTP #{response.status}"
    end
  end

  private

  def connection
    Faraday.new do |f|
      f.options.open_timeout = OPEN_TIMEOUT_SECONDS
      f.options.timeout = READ_TIMEOUT_SECONDS
    end
  end

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
end
