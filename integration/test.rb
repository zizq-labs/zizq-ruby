# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# Integration tests for the Zizq Ruby client.
#
# These tests exercise the installed gem (not the source) against a real
# Zizq server whose URL is provided via the ZIZQ_URL environment
# variable. The server lifecycle is managed by run.sh.
#
# Run via: ZIZQ_URL=http://... ruby test.rb

require "minitest/autorun"
require "timeout"
require "zizq"
require "active_job"
require "active_job/queue_adapters/zizq_adapter"

ZIZQ_URL =
  ENV.fetch("ZIZQ_URL") do
    abort "Error: ZIZQ_URL environment variable must be set."
  end

# A minimal job class for the worker round-trip test.
class IntegrationTestJob
  include Zizq::Job

  zizq_queue "worker-integration"

  class << self
    attr_accessor :mock_perform # e.g. ->(*args, **kwargs) { ... }
  end

  def perform(*args, **kwargs)
    self.class.mock_perform&.call(*args, **kwargs)
  end
end

# Jobs with backoff/retention configured. These exercise the wire
# format used for those fields, which has bitten us before (floats
# being sent where the server expects integer milliseconds).
class BackoffConfiguredJob
  include Zizq::Job

  zizq_queue "integration"
  zizq_retry_limit 3
  zizq_backoff exponent: 2.0, base: 1.5, jitter: 0.5

  def perform
  end
end

class RetentionConfiguredJob
  include Zizq::Job

  zizq_queue "integration"
  zizq_retention completed: 3600, dead: 86_400

  def perform
  end
end

# An ActiveJob class for testing ActiveJob-specific query methods.
ActiveJob::Base.logger = Logger.new(File::NULL)

class ActiveJobTestJob < ActiveJob::Base
  extend Zizq::ActiveJobConfig

  self.queue_adapter = :zizq
  self.queue_name = "activejob-integration"

  class << self
    attr_accessor :mock_perform # e.g. ->(*args, **kwargs) { ... }
  end

  def perform(*args, **kwargs)
    self.class.mock_perform&.call(*args, **kwargs)
  end
end

class IntegrationTest < Minitest::Test
  def setup
    Zizq.configure do |c|
      c.url = ZIZQ_URL
      c.format = :json
      c.logger = Logger.new(File::NULL)
    end

    # Wipe both jobs and cron groups so each scenario starts clean.
    # Note: `Zizq.reset!` (in `teardown`) is the unrelated module-level
    # call that releases the shared client and configuration —
    # `Zizq.client.erase_all_data` is the server-side wipe.
    Zizq.client.erase_all_data
    IntegrationTestJob.mock_perform = nil
  end

  def teardown
    Zizq.reset!
  end

  def test_health_check
    health = Zizq.client.health
    assert_equal "ok", health["status"]
  end

  def test_enqueue_and_get
    job = Zizq.enqueue(IntegrationTestJob, 42)

    assert job.id
    assert_equal IntegrationTestJob.name, job.type
    assert_equal "worker-integration", job.queue

    fetched = Zizq.client.get_job(job.id)
    assert_equal job.id, fetched.id
  end

  def test_enqueue_with_backoff_round_trips_correctly
    # Regression: `base_ms` and `jitter_ms` were being sent as floats,
    # which the server rejected with "invalid MessagePack: invalid
    # type: floating point, expected u32". This asserts the wire
    # format is accepted AND the values round-trip back as the
    # configured seconds.
    job = Zizq.enqueue(BackoffConfiguredJob)

    fetched = Zizq.client.get_job(job.id)
    assert_equal 3, fetched.retry_limit
    assert_equal({ exponent: 2.0, base: 1.5, jitter: 0.5 }, fetched.backoff)
  end

  def test_enqueue_with_retention_round_trips_correctly
    job = Zizq.enqueue(RetentionConfiguredJob)

    fetched = Zizq.client.get_job(job.id)
    assert_equal({ completed: 3600.0, dead: 86_400.0 }, fetched.retention)
  end

  def test_enqueue_raw
    job =
      Zizq.enqueue_raw(
        queue: "integration",
        type: "raw_test",
        payload: {
          hello: "world"
        }
      )

    assert job.id
    assert_equal "raw_test", job.type

    fetched = Zizq.client.get_job(job.id)
    assert_equal({ "hello" => "world" }, fetched.payload)
  end

  def test_enqueue_bulk
    jobs =
      Zizq.enqueue_bulk do |b|
        b.enqueue(IntegrationTestJob, 1)
        b.enqueue(IntegrationTestJob, 2)
        b.enqueue(IntegrationTestJob, 3)
      end

    assert_equal 3, jobs.length
    assert_equal IntegrationTestJob.name, jobs[0].type
  end

  def test_enqueue_bulk_raw
    jobs =
      Zizq.enqueue_bulk do |b|
        b.enqueue_raw(
          queue: "integration",
          type: "bulk_raw_a",
          payload: {
            n: 1
          }
        )
        b.enqueue_raw(
          queue: "integration",
          type: "bulk_raw_b",
          payload: {
            n: 2
          }
        )
      end

    assert_equal 2, jobs.length
    assert_equal "bulk_raw_a", jobs[0].type
    assert_equal "bulk_raw_b", jobs[1].type
  end

  def test_worker_round_trip
    count = 10

    Zizq.enqueue_bulk do |b|
      count.times { |i| b.enqueue(IntegrationTestJob, i + 1, label: "test") }
    end

    worker =
      Zizq::Worker.new(
        thread_count: 1,
        fiber_count: 1,
        queues: ["worker-integration"]
      )

    received = []

    IntegrationTestJob.mock_perform = ->(n, label:) do
      received << n
      worker.stop if n >= count
    end

    worker.run

    assert_equal count, received.length
    assert_equal (1..count).to_a, received.sort
  end

  def test_activejob_worker_round_trip
    Zizq.configure do |c|
      c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
    end

    count = 10

    ActiveJob.perform_all_later(
      count.times.map { |i| ActiveJobTestJob.new(i + 1, label: "test") }
    )

    worker =
      Zizq::Worker.new(
        thread_count: 1,
        fiber_count: 1,
        queues: ["activejob-integration"]
      )

    received = []

    ActiveJobTestJob.mock_perform = ->(n, label:) do
      received << n
      worker.stop if n >= count
    end

    worker.run

    assert_equal count, received.length
    assert_equal (1..count).to_a, received.sort
  end

  def test_activejob_worker_round_trip_via_enqueue
    Zizq.configure do |c|
      c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
    end

    count = 10

    Zizq.enqueue_bulk do |b|
      count.times { |i| b.enqueue(ActiveJobTestJob, i + 1, label: "test") }
    end

    worker =
      Zizq::Worker.new(
        thread_count: 1,
        fiber_count: 1,
        queues: ["activejob-integration"]
      )

    received = []

    ActiveJobTestJob.mock_perform = ->(n, label:) do
      received << n
      worker.stop if n >= count
    end

    worker.run

    assert_equal count, received.length
    assert_equal (1..count).to_a, received.sort
  end

  def test_query_jobs
    job =
      Zizq.enqueue_raw(
        queue: "query-integration",
        type: "query_test",
        payload: {
          marker: "findme"
        }
      )

    found = Zizq.query.by_queue("query-integration").by_type("query_test").first

    assert found
    assert_equal job.id, found.id
  end

  def test_delete_job
    job =
      Zizq.enqueue_raw(
        queue: "delete-integration",
        type: "delete_test",
        payload: {
        }
      )

    Zizq.client.delete_job(job.id)

    assert_raises(Zizq::NotFoundError) { Zizq.client.get_job(job.id) }
  end

  def test_count_and_empty
    assert Zizq.query.empty?
    assert_equal 0, Zizq.query.count

    Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "integration", type: "count_a", payload: {})
      b.enqueue_raw(queue: "integration", type: "count_b", payload: {})
      b.enqueue_raw(queue: "integration", type: "count_c", payload: {})
    end

    refute Zizq.query.empty?
    assert_equal 3, Zizq.query.count
    assert_equal 1, Zizq.query.by_type("count_b").count
  end

  def test_count_jobs
    assert_equal 0, Zizq.client.count_jobs

    Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "q1", type: "count_a", payload: {})
      b.enqueue_raw(queue: "q1", type: "count_b", payload: {})
      b.enqueue_raw(queue: "q2", type: "count_c", payload: {})
    end

    assert_equal 3, Zizq.client.count_jobs
    assert_equal 2, Zizq.client.count_jobs(queue: "q1")
    assert_equal 1, Zizq.client.count_jobs(queue: "q2")
    assert_equal 1, Zizq.client.count_jobs(type: "count_a")
    assert_equal 1, Zizq.client.count_jobs(queue: "q1", type: "count_b")
    assert_equal 0, Zizq.client.count_jobs(queue: "nonexistent")
  end

  def test_update_job
    job =
      Zizq.enqueue_raw(
        queue: "integration",
        type: "update_test",
        payload: {
        },
        priority: 100
      )

    updated = Zizq.client.update_job(job.id, priority: 50)
    assert_equal job.id, updated.id
    assert_equal 50, updated.priority

    fetched = Zizq.client.get_job(job.id)
    assert_equal 50, fetched.priority
  end

  def test_update_all_jobs
    Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "q1", type: "upd_a", payload: {}, priority: 100)
      b.enqueue_raw(queue: "q1", type: "upd_b", payload: {}, priority: 100)
      b.enqueue_raw(queue: "q2", type: "upd_c", payload: {}, priority: 100)
    end

    patched =
      Zizq.client.update_all_jobs(
        where: {
          queue: "q1"
        },
        apply: {
          priority: 1
        }
      )
    assert_equal 2, patched

    q1_job = Zizq.query.by_queue("q1").first
    assert_equal 1, q1_job.priority

    q2_job = Zizq.query.by_queue("q2").first
    assert_equal 100, q2_job.priority
  end

  def test_query_by_jq_filter
    Zizq.enqueue_bulk do |b|
      b.enqueue_raw(
        queue: "integration",
        type: "jq_test",
        payload: {
          priority: "high",
          region: "eu"
        }
      )
      b.enqueue_raw(
        queue: "integration",
        type: "jq_test",
        payload: {
          priority: "low",
          region: "eu"
        }
      )
      b.enqueue_raw(
        queue: "integration",
        type: "jq_test",
        payload: {
          priority: "high",
          region: "us"
        }
      )
    end

    high_priority = Zizq.query.add_jq_filter('.priority == "high"').to_a
    assert_equal 2, high_priority.length

    high_eu =
      Zizq
        .query
        .add_jq_filter('.priority == "high"')
        .add_jq_filter('.region == "eu"')
        .first
    assert high_eu
    assert_equal({ "priority" => "high", "region" => "eu" }, high_eu.payload)
  end

  def test_query_by_job_class_and_args
    Zizq.enqueue(IntegrationTestJob, 1, x: "a")
    Zizq.enqueue(IntegrationTestJob, 1, x: "b")
    Zizq.enqueue(IntegrationTestJob, 2, x: "a")

    matches =
      Zizq.query.by_job_class_and_args(IntegrationTestJob, 1, x: "a").to_a
    assert_equal 1, matches.length
  end

  def test_query_by_job_class_and_args_subset
    Zizq.enqueue(IntegrationTestJob, 1, x: "a", y: true)
    Zizq.enqueue(IntegrationTestJob, 1, x: "b", y: false)
    Zizq.enqueue(IntegrationTestJob, 2, x: "a", y: true)

    # Subset match on positional arg only.
    by_first_arg =
      Zizq.query.by_job_class_and_args_subset(IntegrationTestJob, 1).to_a
    assert_equal 2, by_first_arg.length

    # Subset match on kwargs only.
    by_kwarg =
      Zizq.query.by_job_class_and_args_subset(IntegrationTestJob, x: "a").to_a
    assert_equal 2, by_kwarg.length

    # Subset match combining positional arg + kwarg.
    combined =
      Zizq
        .query
        .by_job_class_and_args_subset(IntegrationTestJob, 1, x: "a")
        .to_a
    assert_equal 1, combined.length
  end

  def test_activejob_query_by_job_class_and_args
    ActiveJobTestJob.perform_later(1, label: "a")
    ActiveJobTestJob.perform_later(1, label: "b")
    ActiveJobTestJob.perform_later(2, label: "a")

    matches =
      Zizq.query.by_job_class_and_args(ActiveJobTestJob, 1, label: "a").to_a
    assert_equal 1, matches.length
  end

  def test_activejob_query_by_job_class_and_args_subset
    ActiveJobTestJob.perform_later(1, label: "a")
    ActiveJobTestJob.perform_later(1, label: "b")
    ActiveJobTestJob.perform_later(2, label: "a")

    # Subset match on positional arg only.
    by_first_arg =
      Zizq.query.by_job_class_and_args_subset(ActiveJobTestJob, 1).to_a
    assert_equal 2, by_first_arg.length

    # Subset match on kwarg only.
    by_label =
      Zizq.query.by_job_class_and_args_subset(ActiveJobTestJob, label: "a").to_a
    assert_equal 2, by_label.length

    # Combined.
    combined =
      Zizq
        .query
        .by_job_class_and_args_subset(ActiveJobTestJob, 1, label: "a")
        .to_a
    assert_equal 1, combined.length
  end

  def test_delete_all_jobs
    Zizq.enqueue_bulk do |b|
      3.times { b.enqueue_raw(queue: "integration", type: "x", payload: {}) }
    end

    assert_equal 3, Zizq.query.count

    deleted = Zizq.client.delete_all_jobs(where: { queue: "integration" })
    assert_equal 3, deleted
    assert_equal 0, Zizq.query.count
  end

  # --- Crontab CRUD ---
  #
  # These tests require a Pro license on the server. They are skipped if
  # the server returns 403 Forbidden.

  def test_crontab_define_and_refetch
    tab =
      Zizq.define_crontab("integration-test") do |cron|
        cron.define_entry("entry-a", "* * * * *").enqueue(
          IntegrationTestJob,
          1,
          label: "a"
        )
        cron.define_entry("entry-b", "*/5 * * * *").enqueue(
          ActiveJobTestJob,
          2,
          label: "b"
        )
        cron.define_entry("entry-c", "0 0 * * *").enqueue_raw(
          type: "cron_test_c",
          queue: "cron-integration",
          payload: {
          }
        )
      end

    assert_equal 3, tab.entries.size

    # Re-fetch from the server and verify.
    refetched = Zizq.crontab("integration-test")
    assert_equal 3, refetched.entries.size
    assert refetched.entries.key?("entry-a")
    assert refetched.entries.key?("entry-b")
    assert refetched.entries.key?("entry-c")
    assert_equal "* * * * *", refetched.entry("entry-a").expression
    assert_equal "*/5 * * * *", refetched.entry("entry-b").expression
    assert_equal "0 0 * * *", refetched.entry("entry-c").expression

    # Verify job types were serialised correctly.
    assert_equal "IntegrationTestJob", refetched.entry("entry-a").job.type
    assert_equal "worker-integration", refetched.entry("entry-a").job.queue
    assert_equal "ActiveJobTestJob", refetched.entry("entry-b").job.type
    assert_equal "activejob-integration", refetched.entry("entry-b").job.queue
  rescue Zizq::ClientError => e
    skip "Cron scheduling requires a Pro license" if e.status == 403
  ensure
    begin
      Zizq.crontab("integration-test").delete!
    rescue StandardError
      nil
    end
  end

  def test_crontab_redefine_removes_absent_entries
    # Define with three entries.
    Zizq.define_crontab("integration-test") do |cron|
      cron.define_entry("keep-a", "* * * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
      cron.define_entry("keep-b", "* * * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
      cron.define_entry("remove-c", "* * * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
    end

    # Redefine with only two entries.
    Zizq.define_crontab("integration-test") do |cron|
      cron.define_entry("keep-a", "* * * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
      cron.define_entry("keep-b", "* * * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
    end

    # Re-fetch and verify remove-c is gone.
    refetched = Zizq.crontab("integration-test")
    assert_equal 2, refetched.entries.size
    assert refetched.entries.key?("keep-a")
    assert refetched.entries.key?("keep-b")
    refute refetched.entries.key?("remove-c")
  rescue Zizq::ClientError => e
    skip "Cron scheduling requires a Pro license" if e.status == 403
  ensure
    begin
      Zizq.crontab("integration-test").delete!
    rescue StandardError
      nil
    end
  end

  def test_delete_all_crons_wipes_every_group
    %w[wipe-a wipe-b].each do |name|
      Zizq.define_crontab(name) do |cron|
        cron.define_entry("e", "* * * * *").enqueue(IntegrationTestJob, 1)
      end
    end

    deleted = Zizq.client.delete_all_crons
    assert_equal 2, deleted
    assert_empty Zizq.crontabs
  rescue Zizq::ClientError => e
    skip "Cron scheduling requires a Pro license" if e.status == 403
  end

  def test_crontab_entry_pause
    Zizq.define_crontab("integration-test") do |cron|
      cron.define_entry("pausable", "* * * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
    end

    tab = Zizq.crontab("integration-test")
    refute tab.entry("pausable").paused

    tab.entry("pausable").pause!
    assert tab.entry("pausable").paused

    # Re-fetch to confirm it persisted.
    refetched = Zizq.crontab("integration-test")
    assert refetched.entry("pausable").paused
    assert_kind_of Float, refetched.entry("pausable").paused_at
  rescue Zizq::ClientError => e
    skip "Cron scheduling requires a Pro license" if e.status == 403
  ensure
    begin
      Zizq.crontab("integration-test").delete!
    rescue StandardError
      nil
    end
  end
end
