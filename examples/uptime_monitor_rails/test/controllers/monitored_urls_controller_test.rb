# frozen_string_literal: true

require "test_helper"

class MonitoredUrlsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "index renders with the form when there are no URLs" do
    get root_path

    assert_response :success
    assert_select "form.url-form"
    assert_select "p.empty"
  end

  test "index returns just the urls partial on XHR for AJAX polling" do
    MonitoredUrl.create!(url: "https://up.example.com", last_status: "up", last_checked_at: 1.minute.ago)

    get root_path, headers: { "X-Requested-With" => "XMLHttpRequest" }

    assert_response :success
    refute_match(/<html/, @response.body) # no layout
    assert_match(/<div id="urls">/, @response.body)
    assert_select "span.status-up", text: "UP"
  end

  test "index lists existing monitored URLs with their status" do
    MonitoredUrl.create!(url: "https://up.example.com",   last_status: "up",   last_checked_at: 1.minute.ago)
    MonitoredUrl.create!(url: "https://down.example.com", last_status: "down", last_checked_at: 2.minutes.ago)
    MonitoredUrl.create!(url: "https://pending.example.com")

    get root_path

    assert_response :success
    assert_select "table.urls tbody tr", 3
    assert_select "span.status-up",      text: "UP"
    assert_select "span.status-down",    text: "DOWN"
    assert_select "span.status-pending", text: "PENDING"
  end

  test "create persists the URL and enqueues a check job" do
    assert_difference -> { MonitoredUrl.count }, 1 do
      assert_enqueued_with(job: CheckUrlJob) do
        post monitored_urls_path, params: { monitored_url: { url: "https://example.com" } }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_match(/Now monitoring/, flash[:notice] || @response.body)

    created = MonitoredUrl.last
    assert_equal "https://example.com", created.url
    assert_equal "manual", created.source
  end

  test "create strips surrounding whitespace from the URL" do
    post monitored_urls_path, params: { monitored_url: { url: "  https://example.com  " } }

    assert_equal "https://example.com", MonitoredUrl.last.url
  end

  test "create prepends https:// when no scheme is given" do
    post monitored_urls_path, params: { monitored_url: { url: "example.com" } }

    assert_equal "https://example.com", MonitoredUrl.last.url
  end

  test "create rejects URLs with unsupported schemes" do
    assert_no_difference -> { MonitoredUrl.count } do
      post monitored_urls_path, params: { monitored_url: { url: "ftp://example.com" } }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_match(/http:\/\/ or https:\/\//, flash[:alert] || @response.body)
  end

  test "submitting an existing URL re-checks it without duplicating the row" do
    existing = MonitoredUrl.create!(url: "https://example.com")

    assert_no_difference -> { MonitoredUrl.count } do
      assert_enqueued_with(job: CheckUrlJob, args: [existing]) do
        post monitored_urls_path, params: { monitored_url: { url: "https://example.com" } }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_match(/Re-checking/, flash[:notice] || @response.body)
  end
end
