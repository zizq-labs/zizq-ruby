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
end
