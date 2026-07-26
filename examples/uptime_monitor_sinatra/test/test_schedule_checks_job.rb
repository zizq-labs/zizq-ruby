# frozen_string_literal: true

require_relative "test_helper"

class TestScheduleChecksJob < Minitest::Test
  def test_schedules_check_for_never_checked_urls
    m = MonitoredUrl.create(url: "https://example.com")

    ScheduleChecksJob.new.perform

    assert Zizq::Test.enqueued?(CheckUrlJob, m.id)
  end

  def test_schedules_check_for_stale_urls
    stale =
      MonitoredUrl.create(
        url: "https://stale.example.com",
        last_checked_at: Time.now - ScheduleChecksJob::STALE_AFTER - 1
      )

    ScheduleChecksJob.new.perform

    assert Zizq::Test.enqueued?(CheckUrlJob, stale.id)
  end

  def test_skips_urls_checked_within_the_stale_threshold
    fresh =
      MonitoredUrl.create(
        url: "https://fresh.example.com",
        last_checked_at: Time.now - 10
      )

    ScheduleChecksJob.new.perform

    refute Zizq::Test.enqueued?(CheckUrlJob, fresh.id)
  end

  def test_skips_disabled_urls
    disabled =
      MonitoredUrl.create(
        url: "https://disabled.example.com",
        enabled: false,
        last_checked_at: Time.now - 3600
      )

    ScheduleChecksJob.new.perform

    refute Zizq::Test.enqueued?(CheckUrlJob, disabled.id)
  end

  def test_enqueues_one_check_per_stale_url_in_a_single_sweep
    3.times { |i| MonitoredUrl.create(url: "https://stale-#{i}.example.com") }

    ScheduleChecksJob.new.perform

    assert_equal 3, Zizq::Test.enqueued_count(CheckUrlJob)
  end
end
