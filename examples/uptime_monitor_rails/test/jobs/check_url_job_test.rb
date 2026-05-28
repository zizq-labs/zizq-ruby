# frozen_string_literal: true

require "test_helper"

class CheckUrlJobTest < ActiveJob::TestCase
  test "perform_later enqueues the job with the monitored_url" do
    m = MonitoredUrl.create!(url: "https://example.com")

    assert_enqueued_with(job: CheckUrlJob, args: [m]) do
      CheckUrlJob.perform_later(m)
    end
  end

  test "running the enqueued job probes the URL and records a check" do
    m = MonitoredUrl.create!(url: "https://example.com")
    stub_request(:get, "https://example.com").to_return(status: 200)

    perform_enqueued_jobs do
      CheckUrlJob.perform_later(m)
    end

    m.reload
    assert_equal "up", m.last_status
    assert_equal 1, m.checks.count
    assert_equal 200, m.checks.last.http_status
  end

  test "skips disabled URLs without recording a check" do
    m = MonitoredUrl.create!(url: "https://example.com", enabled: false)

    # No stub_request — if the job tried to probe, WebMock would raise.
    perform_enqueued_jobs do
      CheckUrlJob.perform_later(m)
    end

    assert_not_requested :any, /.*/
    m.reload
    assert_nil m.last_status
    assert_equal 0, m.checks.count
  end

  test "enqueues DiscoverSitemapUrlsJob when the response is a sitemap" do
    m = MonitoredUrl.create!(url: "https://example.com/sitemap.xml")
    stub_request(:get, "https://example.com/sitemap.xml").to_return(
      status: 200,
      headers: { "Content-Type" => "application/xml" },
      body: %(<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>),
    )

    assert_enqueued_with(job: DiscoverSitemapUrlsJob, args: [m]) do
      perform_enqueued_jobs(only: CheckUrlJob) do
        CheckUrlJob.perform_later(m)
      end
    end
  end

  test "does not enqueue DiscoverSitemapUrlsJob for non-sitemap responses" do
    m = MonitoredUrl.create!(url: "https://example.com")
    stub_request(:get, "https://example.com").to_return(status: 200)

    perform_enqueued_jobs(only: CheckUrlJob) do
      CheckUrlJob.perform_later(m)
    end

    assert_no_enqueued_jobs(only: DiscoverSitemapUrlsJob)
  end

  test "enqueues NotifyWebhookJob on an up -> down transition" do
    m = MonitoredUrl.create!(url: "https://example.com", last_status: "up", last_checked_at: 1.minute.ago)
    stub_request(:get, "https://example.com").to_return(status: 500)

    assert_enqueued_jobs(1, only: NotifyWebhookJob) do
      perform_enqueued_jobs(only: CheckUrlJob) do
        CheckUrlJob.perform_later(m)
      end
    end
  end

  test "emits a url.status.changed audit event on a status transition" do
    m = MonitoredUrl.create!(url: "https://example.com", last_status: "up", last_checked_at: 1.minute.ago)
    stub_request(:get, "https://example.com").to_return(status: 500)

    perform_enqueued_jobs(only: CheckUrlJob) do
      CheckUrlJob.perform_later(m)
    end

    event = Zizq::Test.enqueued_jobs(only_types: "audit.create").first
    refute_nil event
    assert_equal "url.status.changed", event.payload["event_type"]
    assert_equal "system",             event.payload["actor"]
    assert_equal "monitored_url:#{m.id}", event.payload["resource"]
    assert_equal "up",   event.payload["data"]["from"]
    assert_equal "down", event.payload["data"]["to"]
  end

  test "does not emit a url.status.changed audit event when status is unchanged" do
    m = MonitoredUrl.create!(url: "https://example.com", last_status: "up", last_checked_at: 1.minute.ago)
    stub_request(:get, "https://example.com").to_return(status: 200)

    perform_enqueued_jobs(only: CheckUrlJob) do
      CheckUrlJob.perform_later(m)
    end

    assert_empty Zizq::Test.enqueued_jobs(only_types: "audit.create")
  end

  test "enqueues NotifyWebhookJob on a down -> up transition" do
    m = MonitoredUrl.create!(url: "https://example.com", last_status: "down", last_checked_at: 1.minute.ago, consecutive_failures: 3)
    stub_request(:get, "https://example.com").to_return(status: 200)

    assert_enqueued_jobs(1, only: NotifyWebhookJob) do
      perform_enqueued_jobs(only: CheckUrlJob) do
        CheckUrlJob.perform_later(m)
      end
    end
  end

  test "enqueues NotifyWebhookJob when the first ever check is down" do
    m = MonitoredUrl.create!(url: "https://example.com") # last_status nil
    stub_request(:get, "https://example.com").to_return(status: 500)

    assert_enqueued_jobs(1, only: NotifyWebhookJob) do
      perform_enqueued_jobs(only: CheckUrlJob) do
        CheckUrlJob.perform_later(m)
      end
    end
  end

  test "does not enqueue NotifyWebhookJob when the first ever check is up" do
    m = MonitoredUrl.create!(url: "https://example.com") # last_status nil
    stub_request(:get, "https://example.com").to_return(status: 200)

    perform_enqueued_jobs(only: CheckUrlJob) do
      CheckUrlJob.perform_later(m)
    end

    assert_no_enqueued_jobs(only: NotifyWebhookJob)
  end

  test "does not enqueue NotifyWebhookJob when status is unchanged" do
    m = MonitoredUrl.create!(url: "https://example.com", last_status: "up", last_checked_at: 1.minute.ago)
    stub_request(:get, "https://example.com").to_return(status: 200)

    perform_enqueued_jobs(only: CheckUrlJob) do
      CheckUrlJob.perform_later(m)
    end

    assert_no_enqueued_jobs(only: NotifyWebhookJob)
  end
end
