# frozen_string_literal: true

require_relative "test_helper"
require "json"

class TestNotifyWebhookJob < Minitest::Test
  WEBHOOK = "https://hook.example.com/notify"

  def setup
    super
    @original_webhook = ENV["WEBHOOK_URL"]
    ENV["WEBHOOK_URL"] = WEBHOOK

    @monitored =
      MonitoredUrl.create(
        url: "https://site.example.com",
        last_status: "down",
        last_checked_at: Time.now - 60,
        consecutive_failures: 3
      )
    @check =
      Check.create(
        monitored_url: @monitored,
        checked_at: Time.now - 60,
        status: "down",
        http_status: 500,
        response_time_ms: 120,
        final_url: "https://site.example.com/",
        error_message: "HTTP 500",
        created_at: Time.now - 60
      )
  end

  def teardown
    if @original_webhook
      ENV["WEBHOOK_URL"] = @original_webhook
    else
      ENV.delete("WEBHOOK_URL")
    end
  end

  def test_posts_json_payload_on_success
    stub_request(:post, WEBHOOK).to_return(status: 200)

    NotifyWebhookJob.new.perform(@check.id)

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

  def test_no_ops_cleanly_when_webhook_url_is_unset
    ENV.delete("WEBHOOK_URL")

    NotifyWebhookJob.new.perform(@check.id)

    assert_not_requested :any, /.*/
  end

  def test_no_ops_when_webhook_url_is_empty_or_whitespace
    ENV["WEBHOOK_URL"] = "  "

    NotifyWebhookJob.new.perform(@check.id)

    assert_not_requested :any, /.*/
  end

  def test_4xx_is_treated_as_permanent_no_raise
    stub_request(:post, WEBHOOK).to_return(status: 404)

    # No raise — the worker sees the job as successful, Zizq won't
    # retry. We still warn on stderr for visibility.
    assert_silent_or_warned { NotifyWebhookJob.new.perform(@check.id) }
  end

  def test_5xx_raises_so_zizq_retries
    stub_request(:post, WEBHOOK).to_return(status: 503)

    error =
      assert_raises(RuntimeError) { NotifyWebhookJob.new.perform(@check.id) }
    assert_match(/HTTP 503/, error.message)
  end

  def test_network_error_raises_so_zizq_retries
    stub_request(:post, WEBHOOK).to_raise(Errno::ECONNREFUSED)

    assert_raises(Faraday::ConnectionFailed) do
      NotifyWebhookJob.new.perform(@check.id)
    end
  end

  private

  # Capture stderr so the "giving up" warning doesn't pollute output;
  # we don't need to assert on it, just absorb it.
  def assert_silent_or_warned
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original_stderr
  end
end
