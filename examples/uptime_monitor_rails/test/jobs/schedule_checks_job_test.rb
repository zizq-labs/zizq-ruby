# frozen_string_literal: true

require "test_helper"

class ScheduleChecksJobTest < ActiveJob::TestCase
  test "enqueues a check for URLs that have never been checked" do
    m = MonitoredUrl.create!(url: "https://never-checked.example.com")

    assert_enqueued_with(job: CheckUrlJob, args: [m]) do
      ScheduleChecksJob.new.perform
    end
  end

  test "enqueues a check for URLs last checked beyond the stale threshold" do
    stale = MonitoredUrl.create!(
      url: "https://stale.example.com",
      last_checked_at: (ScheduleChecksJob::STALE_AFTER + 1.second).ago,
    )

    assert_enqueued_with(job: CheckUrlJob, args: [stale]) do
      ScheduleChecksJob.new.perform
    end
  end

  test "skips URLs checked within the stale threshold" do
    MonitoredUrl.create!(
      url: "https://fresh.example.com",
      last_checked_at: 10.seconds.ago,
    )

    assert_no_enqueued_jobs(only: CheckUrlJob) do
      ScheduleChecksJob.new.perform
    end
  end

  test "skips disabled URLs even if stale" do
    MonitoredUrl.create!(
      url: "https://disabled.example.com",
      enabled: false,
      last_checked_at: 1.hour.ago,
    )

    assert_no_enqueued_jobs(only: CheckUrlJob) do
      ScheduleChecksJob.new.perform
    end
  end

  test "enqueues one CheckUrlJob per stale URL in a single sweep" do
    3.times { |i| MonitoredUrl.create!(url: "https://stale-#{i}.example.com") }

    assert_enqueued_jobs(3, only: CheckUrlJob) do
      ScheduleChecksJob.new.perform
    end
  end
end
