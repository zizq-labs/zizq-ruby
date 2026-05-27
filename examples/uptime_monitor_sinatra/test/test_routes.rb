# frozen_string_literal: true

require_relative "test_helper"

class TestRoutes < Minitest::Test
  def test_get_index_renders_form
    get "/"

    assert last_response.ok?
    assert_match(/Uptime Monitor/, last_response.body)
    assert_match(/<form/, last_response.body)
    assert_match(%r{<div id="urls">}, last_response.body)
  end

  def test_xhr_returns_just_the_urls_partial
    get "/", {}, "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest"

    assert last_response.ok?
    refute_match(/<html/, last_response.body)
    assert_match(%r{<div id="urls">}, last_response.body)
  end

  def test_post_creates_a_monitored_url_and_enqueues_a_check
    post "/monitored_urls", url: "https://example.com"

    assert last_response.redirect?
    created = MonitoredUrl.first
    assert_equal "https://example.com", created.url
    assert_equal "manual",               created.source
    assert Zizq::Test.enqueued?(CheckUrlJob, created.id)
  end

  def test_post_strips_whitespace
    post "/monitored_urls", url: "  https://example.com  "

    assert_equal "https://example.com", MonitoredUrl.first.url
  end

  def test_post_prepends_https_when_no_scheme
    post "/monitored_urls", url: "example.com"

    assert_equal "https://example.com", MonitoredUrl.first.url
  end

  def test_post_existing_url_does_not_duplicate
    MonitoredUrl.create(url: "https://example.com")

    post "/monitored_urls", url: "https://example.com"

    assert_equal 1, MonitoredUrl.count
    assert Zizq::Test.enqueued?(CheckUrlJob)
  end

  def test_post_existing_url_re_enqueues_for_re_check
    existing = MonitoredUrl.create(url: "https://example.com")

    post "/monitored_urls", url: "https://example.com"

    assert Zizq::Test.enqueued?(CheckUrlJob, existing.id)
    follow_redirect!
    assert_match(/Re-checking/, last_response.body)
  end

  def test_post_new_url_shows_now_monitoring_flash
    post "/monitored_urls", url: "https://example.com"

    follow_redirect!
    assert_match(/Now monitoring/, last_response.body)
  end

  def test_post_invalid_url_shows_alert_and_does_not_enqueue
    post "/monitored_urls", url: "ftp://example.com"

    assert_equal 0, MonitoredUrl.count
    assert_equal 0, Zizq::Test.enqueued_count(CheckUrlJob)
    follow_redirect!
    assert_match(/must be an http/, last_response.body)
  end

  def test_index_lists_existing_urls_with_their_status
    MonitoredUrl.create(url: "https://up.example.com",      last_status: "up",   last_checked_at: Time.now - 60)
    MonitoredUrl.create(url: "https://down.example.com",    last_status: "down", last_checked_at: Time.now - 120)
    MonitoredUrl.create(url: "https://pending.example.com")

    get "/"

    assert last_response.ok?
    assert_match(/status-up.*UP/m,           last_response.body)
    assert_match(/status-down.*DOWN/m,       last_response.body)
    assert_match(/status-pending.*PENDING/m, last_response.body)
  end
end
