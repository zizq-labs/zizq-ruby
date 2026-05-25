# frozen_string_literal: true

require "test_helper"

class NotifyWebhookJobTest < ActiveJob::TestCase
  WEBHOOK = "https://hook.example.com/notify"

  setup do
    @original_webhook = ENV["WEBHOOK_URL"]
    ENV["WEBHOOK_URL"] = WEBHOOK

    @monitored = MonitoredUrl.create!(
      url:                  "https://site.example.com",
      last_status:          "down",
      last_checked_at:      1.minute.ago,
      consecutive_failures: 3,
    )
    @check = @monitored.checks.create!(
      checked_at:       1.minute.ago,
      status:           "down",
      http_status:      500,
      response_time_ms: 120,
      final_url:        "https://site.example.com/",
      error_message:    "HTTP 500",
    )
  end

  teardown do
    if @original_webhook
      ENV["WEBHOOK_URL"] = @original_webhook
    else
      ENV.delete("WEBHOOK_URL")
    end
  end

  test "POSTs JSON payload on success" do
    stub_request(:post, WEBHOOK).to_return(status: 200)

    NotifyWebhookJob.perform_now(@check)

    assert_requested :post, WEBHOOK do |req|
      assert_equal "application/json", req.headers["Content-Type"]
      body = JSON.parse(req.body)
      assert_equal @check.id, body["check_id"]
      assert_equal @monitored.id, body["monitored_url_id"]
      assert_equal @monitored.url, body["url"]
      assert_equal "down", body["status"]
      assert_equal 500, body["http_status"]
      assert_equal 120, body["response_time_ms"]
      assert_equal 3, body["consecutive_failures"]
      assert_equal "HTTP 500", body["error_message"]
      true
    end
  end

  test "no-ops cleanly when WEBHOOK_URL is unset" do
    ENV.delete("WEBHOOK_URL")

    NotifyWebhookJob.perform_now(@check)

    assert_not_requested :any, /.*/
  end

  test "no-ops when WEBHOOK_URL is empty" do
    ENV["WEBHOOK_URL"] = "  "

    NotifyWebhookJob.perform_now(@check)

    assert_not_requested :any, /.*/
  end

  test "4xx response is discarded as a permanent failure (no retry)" do
    stub_request(:post, WEBHOOK).to_return(status: 404)

    # `discard_on PermanentFailure` swallows the exception via
    # ActiveJob's rescue chain — perform_now returns nil, no re-raise.
    assert_nothing_raised do
      NotifyWebhookJob.perform_now(@check)
    end
  end

  test "5xx response re-raises so Zizq retries with backoff" do
    stub_request(:post, WEBHOOK).to_return(status: 503)

    error = assert_raises(RuntimeError) do
      NotifyWebhookJob.perform_now(@check)
    end
    assert_match(/HTTP 503/, error.message)
  end

  test "network error re-raises so Zizq retries with backoff" do
    stub_request(:post, WEBHOOK).to_raise(Errno::ECONNREFUSED)

    assert_raises(Errno::ECONNREFUSED) do
      NotifyWebhookJob.perform_now(@check)
    end
  end
end
