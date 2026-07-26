# frozen_string_literal: true

require_relative "test_helper"

class TestCheckUrlJob < Minitest::Test
  def test_enqueueing_buffers_the_job
    m = MonitoredUrl.create(url: "https://example.com")

    Zizq.enqueue(CheckUrlJob, m.id)

    assert Zizq::Test.enqueued?(CheckUrlJob, m.id)
    assert_equal 1, Zizq::Test.enqueued_count(CheckUrlJob)
  end

  def test_dispatching_probes_and_records_a_check
    m = MonitoredUrl.create(url: "https://example.com")
    stub_request(:get, "https://example.com").to_return(status: 200)

    Zizq::Test.dispatch_enqueued_jobs { Zizq.enqueue(CheckUrlJob, m.id) }

    m.refresh
    assert_equal "up", m.last_status
    assert_equal 1, m.checks_dataset.count
    assert_equal 200, m.checks.last.http_status
  end

  def test_skips_disabled_urls
    m = MonitoredUrl.create(url: "https://example.com", enabled: false)

    # No stub: if the prober ran, WebMock would raise on the unstubbed
    # request and fail the test.
    Zizq::Test.dispatch_enqueued_jobs { Zizq.enqueue(CheckUrlJob, m.id) }

    assert_not_requested :any, /.*/
    m.refresh
    assert_nil m.last_status
  end

  def test_enqueues_discover_sitemap_urls_job_when_result_is_a_sitemap
    m = MonitoredUrl.create(url: "https://example.com/sitemap.xml")
    stub_request(:get, "https://example.com/sitemap.xml").to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/xml"
      },
      body:
        %(<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>)
    )

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    assert Zizq::Test.enqueued?(DiscoverSitemapUrlsJob, m.id)
  end

  def test_does_not_enqueue_discover_sitemap_urls_job_for_non_sitemap_responses
    m = MonitoredUrl.create(url: "https://example.com")
    stub_request(:get, "https://example.com").to_return(status: 200)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    refute Zizq::Test.enqueued?(DiscoverSitemapUrlsJob)
  end

  # --- Status transitions ---------------------------------------------

  def test_enqueues_notify_webhook_job_on_an_up_to_down_transition
    m =
      MonitoredUrl.create(
        url: "https://example.com",
        last_status: "up",
        last_checked_at: Time.now - 60
      )
    stub_request(:get, "https://example.com").to_return(status: 500)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    assert Zizq::Test.enqueued?(NotifyWebhookJob)
  end

  def test_enqueues_notify_webhook_job_on_a_down_to_up_transition
    m =
      MonitoredUrl.create(
        url: "https://example.com",
        last_status: "down",
        last_checked_at: Time.now - 60,
        consecutive_failures: 3
      )
    stub_request(:get, "https://example.com").to_return(status: 200)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    assert Zizq::Test.enqueued?(NotifyWebhookJob)
  end

  def test_enqueues_notify_webhook_job_when_first_ever_check_is_down
    m = MonitoredUrl.create(url: "https://example.com") # last_status nil
    stub_request(:get, "https://example.com").to_return(status: 500)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    assert Zizq::Test.enqueued?(NotifyWebhookJob)
  end

  def test_does_not_enqueue_notify_webhook_job_when_first_ever_check_is_up
    m = MonitoredUrl.create(url: "https://example.com") # last_status nil
    stub_request(:get, "https://example.com").to_return(status: 200)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    refute Zizq::Test.enqueued?(NotifyWebhookJob)
  end

  def test_does_not_enqueue_notify_webhook_job_when_status_is_unchanged
    m =
      MonitoredUrl.create(
        url: "https://example.com",
        last_status: "up",
        last_checked_at: Time.now - 60
      )
    stub_request(:get, "https://example.com").to_return(status: 200)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    refute Zizq::Test.enqueued?(NotifyWebhookJob)
  end

  def test_failed_probe_increments_consecutive_failures
    m = MonitoredUrl.create(url: "https://example.com", consecutive_failures: 2)
    stub_request(:get, "https://example.com").to_return(status: 500)

    Zizq::Test.dispatch_enqueued_jobs(only_types: CheckUrlJob) do
      Zizq.enqueue(CheckUrlJob, m.id)
    end

    m.refresh
    assert_equal "down", m.last_status
    assert_equal 3, m.consecutive_failures
  end
end
