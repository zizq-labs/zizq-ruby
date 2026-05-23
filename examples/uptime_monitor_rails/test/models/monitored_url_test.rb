# frozen_string_literal: true

require "test_helper"

class MonitoredUrlTest < ActiveSupport::TestCase
  def result(status:, **overrides)
    UrlProber::Result.new(
      status:           status,
      http_status:      status == "up" ? 200 : 500,
      response_time_ms: 42,
      final_url:        "https://example.com/",
      error_message:    status == "up" ? nil : "HTTP 500",
      checked_at:       Time.current,
      **overrides,
    )
  end

  test "url is required" do
    m = MonitoredUrl.new(url: nil)
    refute m.valid?
    assert_includes m.errors[:url], "can't be blank"
  end

  test "duplicate urls are rejected by the database" do
    MonitoredUrl.create!(url: "https://example.com")
    assert_raises(ActiveRecord::RecordNotUnique) do
      MonitoredUrl.create!(url: "https://example.com")
    end
  end

  test "source must be 'manual' or 'sitemap'" do
    refute MonitoredUrl.new(url: "https://example.com", source: "guess").valid?
    assert MonitoredUrl.new(url: "https://example.com", source: "manual").valid?
    assert MonitoredUrl.new(url: "https://example.com", source: "sitemap").valid?
  end

  test "record_check! on success appends a Check and resets consecutive_failures" do
    m = MonitoredUrl.create!(url: "https://example.com", consecutive_failures: 3)

    assert_difference -> { m.checks.count }, 1 do
      m.record_check!(result(status: "up"))
    end

    m.reload
    assert_equal "up", m.last_status
    assert_equal 0, m.consecutive_failures
    assert_not_nil m.last_checked_at

    check = m.checks.last
    assert_equal "up", check.status
    assert_equal 200, check.http_status
    assert_equal "https://example.com/", check.final_url
    assert_nil check.error_message
  end

  test "record_check! on failure increments consecutive_failures" do
    m = MonitoredUrl.create!(url: "https://example.com", consecutive_failures: 2)

    m.record_check!(result(status: "down", http_status: 503, error_message: "HTTP 503"))

    m.reload
    assert_equal "down", m.last_status
    assert_equal 3, m.consecutive_failures

    check = m.checks.last
    assert_equal "down", check.status
    assert_equal 503, check.http_status
    assert_equal "HTTP 503", check.error_message
  end

  test "enabled scope filters disabled rows" do
    on  = MonitoredUrl.create!(url: "https://a.example.com")
    off = MonitoredUrl.create!(url: "https://b.example.com", enabled: false)

    assert_includes     MonitoredUrl.enabled, on
    refute_includes     MonitoredUrl.enabled, off
  end
end
