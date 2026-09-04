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

# --- Budget fixtures (pro-only) ---

# Records how many of these ran at once, so a `while_in_flight` budget
# can be checked without measuring time: an allocation of 1 means the
# server must never have two in flight together.
class ConcurrencyProbeJob
  include Zizq::Job

  zizq_queue "budget-concurrency"

  class << self
    attr_accessor :tracker
  end

  def perform = self.class.tracker&.call
end

# Counts dispatches for the rate-limit tests.
class ThrottledProbeJob
  include Zizq::Job

  zizq_queue "budget-throttled"

  class << self
    attr_accessor :tracker
  end

  def perform = self.class.tracker&.call
end

# Declares its budget on the class rather than per enqueue.
class DeclaredBudgetJob
  include Zizq::Job

  zizq_queue "budget-declared"
  zizq_budget "declared-budget",
              cost: 2,
              create_with: {
                allocation: 100,
                strategy: {
                  type: :time_based,
                  duration: 60
                }
              }

  def perform
  end
end

# --- Batched job fixtures (pro-only) ---
#
# The `notifications` positional arg is the batch target. Enqueues
# with the same `platform:` fold into the same job; enqueues with a
# different `platform:` end up in separate batches.
class BatchedIntegrationJob
  include Zizq::Job

  zizq_queue "batched-integration"
  zizq_batched true, limit: 100

  class << self
    attr_accessor :mock_perform
  end

  def perform(notifications, platform:)
    self.class.mock_perform&.call(notifications, platform: platform)
  end
end

# Same shape but with `dedup: true` so overlapping payloads collapse.
class DedupBatchedIntegrationJob
  include Zizq::Job

  zizq_queue "batched-integration"
  zizq_batched true, limit: 100, dedup: true

  def perform(_items) = nil
end

# ActiveJob variant of a batched job.
class BatchedActiveJobIntegrationJob < ActiveJob::Base
  extend Zizq::ActiveJobConfig

  self.queue_adapter = :zizq
  self.queue_name = "batched-activejob-integration"
  zizq_batched true, limit: 100

  class << self
    attr_accessor :mock_perform
  end

  def perform(notifications, platform:)
    self.class.mock_perform&.call(notifications, platform: platform)
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
    ConcurrencyProbeJob.tracker = nil
    ThrottledProbeJob.tracker = nil
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

  # The schedule's timezone is the schedule's, not a copy smeared over every
  # entry, so a refetch still reports it and entries that chose their own
  # keep it.
  def test_crontab_timezone_round_trips
    Zizq.define_crontab(
      "integration-test",
      timezone: "Australia/Melbourne"
    ) do |cron|
      cron.define_entry("inherits", "0 9 * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
      cron.define_entry("scoped", "0 9 * * *", timezone: "UTC").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
    end

    refetched = Zizq.crontab("integration-test")

    assert_equal "Australia/Melbourne", refetched.timezone
    assert_nil refetched.entry("inherits").timezone
    assert_equal "UTC", refetched.entry("scoped").timezone

    # And the schedule's timezone is what the inheriting entry actually runs
    # in: 9am in Melbourne is not 9am in UTC.
    assert_operator refetched.entry("inherits").next_enqueue_at,
                    :!=,
                    refetched.entry("scoped").next_enqueue_at
  rescue Zizq::ClientError => e
    skip "Cron scheduling requires a Pro license" if e.status == 403
  ensure
    begin
      Zizq.crontab("integration-test").delete!
    rescue StandardError
      nil
    end
  end

  # A redefine replaces the schedule whole, so a timezone left out goes.
  def test_crontab_redefine_without_timezone_clears_it
    Zizq.define_crontab(
      "integration-test",
      timezone: "Australia/Melbourne"
    ) do |cron|
      cron.define_entry("a", "0 9 * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
    end

    assert_equal "Australia/Melbourne",
                 Zizq.crontab("integration-test").timezone

    Zizq.define_crontab("integration-test") do |cron|
      cron.define_entry("a", "0 9 * * *").enqueue_raw(
        type: "cron_test",
        queue: "cron-integration",
        payload: {
        }
      )
    end

    assert_nil Zizq.crontab("integration-test").timezone
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

  # --- Batched jobs (pro-only) ---

  def test_batched_first_enqueue_creates_new_job
    r = Zizq.enqueue(BatchedIntegrationJob, [{ id: 1 }], platform: "apple")
    refute r.folded?
    refute_nil r.batch
    assert r.batch[:key].start_with?("BatchedIntegrationJob:")
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_batched_second_enqueue_folds_and_merges
    r1 = Zizq.enqueue(BatchedIntegrationJob, [{ id: 1 }], platform: "apple")
    r2 =
      Zizq.enqueue(
        BatchedIntegrationJob,
        [{ id: 2 }, { id: 3 }],
        platform: "apple"
      )

    refute r1.folded?
    assert r2.folded?
    assert_equal r1.id, r2.id

    fetched = Zizq.client.get_job(r1.id)
    assert_equal(
      {
        "args" => [[{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }]],
        "kwargs" => {
          "platform" => "apple"
        }
      },
      fetched.payload
    )
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_batched_different_non_batch_args_do_not_fold
    r1 = Zizq.enqueue(BatchedIntegrationJob, [{ id: 1 }], platform: "apple")
    r2 = Zizq.enqueue(BatchedIntegrationJob, [{ id: 2 }], platform: "android")

    refute r1.folded?
    refute r2.folded?
    refute_equal r1.id, r2.id
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_batched_bulk_intra_fold
    results =
      Zizq.enqueue_bulk do |b|
        b.enqueue(BatchedIntegrationJob, [{ id: 1 }], platform: "apple")
        b.enqueue(BatchedIntegrationJob, [{ id: 2 }], platform: "apple")
        b.enqueue(BatchedIntegrationJob, [{ id: 3 }], platform: "apple")
      end

    refute results[0].folded?
    assert results[1].folded?
    assert results[2].folded?
    assert_equal results[0].id, results[1].id
    assert_equal results[0].id, results[2].id

    fetched = Zizq.client.get_job(results[0].id)
    assert_equal(
      [{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }],
      fetched.payload["args"][0]
    )
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_batched_dedup_flag_deduplicates
    Zizq.enqueue(DedupBatchedIntegrationJob, [{ "id" => 1 }, { "id" => 2 }])
    r = Zizq.enqueue(DedupBatchedIntegrationJob, [{ "id" => 2 }, { "id" => 3 }])
    assert r.folded?

    fetched = Zizq.client.get_job(r.id)
    merged = fetched.payload["args"][0]
    assert_equal 3, merged.size, "expected duplicates collapsed, got: #{merged}"
    assert_equal [1, 2, 3].sort, merged.map { |h| h["id"] }.sort
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_batched_worker_receives_merged_payload
    Zizq.enqueue(BatchedIntegrationJob, [{ id: 1 }], platform: "apple")
    Zizq.enqueue(BatchedIntegrationJob, [{ id: 2 }], platform: "apple")
    Zizq.enqueue(BatchedIntegrationJob, [{ id: 3 }], platform: "apple")

    worker =
      Zizq::Worker.new(
        thread_count: 1,
        fiber_count: 1,
        queues: ["batched-integration"]
      )

    received = nil
    BatchedIntegrationJob.mock_perform = ->(notifications, platform:) do
      received = { notifications: notifications, platform: platform }
      worker.stop
    end

    worker.run

    refute_nil received, "worker did not receive the batched job"
    assert_equal(
      [{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }],
      received[:notifications]
    )
    assert_equal "apple", received[:platform]
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_activejob_batched_worker_round_trip
    Zizq.configure do |c|
      c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
    end

    BatchedActiveJobIntegrationJob.perform_later([{ id: 1 }], platform: "apple")
    BatchedActiveJobIntegrationJob.perform_later(
      [{ id: 2 }, { id: 3 }],
      platform: "apple"
    )

    worker =
      Zizq::Worker.new(
        thread_count: 1,
        fiber_count: 1,
        queues: ["batched-activejob-integration"]
      )

    received = nil
    BatchedActiveJobIntegrationJob.mock_perform = ->(
      notifications,
      platform:
    ) do
      received = { notifications: notifications, platform: platform }
      worker.stop
    end

    worker.run

    refute_nil received
    # ActiveJob preserves symbol keys through its own
    # serialize/deserialize (via `_aj_symbol_keys` markers), so the
    # worker receives symbol-keyed hashes even though the raw
    # payload on the wire uses string keys.
    assert_equal([{ id: 1 }, { id: 2 }, { id: 3 }], received[:notifications])
    assert_equal "apple", received[:platform]
  rescue Zizq::ClientError => e
    skip "Batched jobs require a Pro license" if e.status == 403
  end

  def test_batched_unique_combination_rejected
    err =
      assert_raises(Zizq::ClientError) do
        Zizq.enqueue_raw(
          queue: "batched-integration",
          type: "BatchedIntegrationJob",
          payload: {
            "args" => [[]],
            "kwargs" => {
              "platform" => "apple"
            }
          },
          unique_key: "some-key",
          batch: {
            key: "b1",
            when: "true",
            fold: "$existing | .args[0] += $new.args[0]"
          }
        )
      end
    skip "Batched jobs require a Pro license" if err.status == 403
    assert_equal 400, err.status
    assert_match(/unique_key.*batch|batch.*unique_key/i, err.message)
  end

  def test_batched_invalid_expression_rejected
    err =
      assert_raises(Zizq::ClientError) do
        Zizq.enqueue_raw(
          queue: "batched-integration",
          type: "BatchedIntegrationJob",
          payload: {
            "args" => [[]],
            "kwargs" => {
              "platform" => "apple"
            }
          },
          batch: {
            key: "bad-expr",
            when: ".[*]", # syntactically invalid
            fold: "$existing | .args[0] += $new.args[0]"
          }
        )
      end
    skip "Batched jobs require a Pro license" if err.status == 403
    assert_equal 422, err.status
  end

  # --- Budgets (pro-only) ---
  #
  # `erase_all_data` wipes budgets too (the server deletes cron groups,
  # then jobs, then budgets — so nothing references a budget by the time
  # it is removed), which is what keeps these isolated from each other.

  TIME_BASED = { type: :time_based, duration: 60 }.freeze

  def test_budget_crud_round_trip
    created =
      Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)
    assert_equal "emails", created.key
    assert_equal 100, created.allocation

    fetched = Zizq.budget("emails")
    assert_equal 100, fetched.allocation
    assert_equal ["emails"], Zizq.budgets.map(&:key)

    Zizq.update_budget("emails", strategy: { burst: 5 })
    assert_equal 5, Zizq.budget("emails").burst

    Zizq.delete_budget("emails")
    assert_raises(Zizq::NotFoundError) { Zizq.budget("emails") }
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # The wire round trip is the point: `duration` goes out as integer
  # milliseconds and has to come back as the seconds it was written in.
  # A unit test with a stubbed response cannot catch a mismatch here.
  def test_budget_durations_round_trip_in_seconds
    Zizq.define_budget(
      "timed",
      allocation: 10,
      strategy: {
        type: :time_based,
        duration: 1.5,
        burst: 3
      }
    )

    b = Zizq.budget("timed")
    assert_equal :time_based, b.strategy_type
    assert b.time_based?
    assert_in_delta 1.5, b.duration
    assert_equal 3, b.burst
    # The burst is the ceiling a cost must fit inside, not the allocation.
    assert_equal 3, b.capacity
    # And it composes straight back into a write.
    assert_equal({ type: :time_based, duration: 1.5, burst: 3 }, b.strategy)
    Zizq.define_budget(
      "timed",
      allocation: 20,
      strategy: b.strategy,
      replace: true
    )
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  def test_while_in_flight_budget_round_trips
    Zizq.define_budget(
      "mutex",
      allocation: 1,
      strategy: {
        type: :while_in_flight
      }
    )

    b = Zizq.budget("mutex")
    assert b.while_in_flight?
    assert_nil b.duration
    assert_nil b.burst
    assert_equal 1, b.capacity
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # `POST` refuses rather than overwriting, which is what lets every
  # replica declare its budgets on boot without coordinating.
  def test_define_budget_conflicts_and_replace_does_not
    Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)

    assert_raises(Zizq::ConflictError) do
      Zizq.define_budget("emails", allocation: 200, strategy: TIME_BASED)
    end
    assert_equal 100, Zizq.budget("emails").allocation

    Zizq.define_budget(
      "emails",
      allocation: 200,
      strategy: TIME_BASED,
      replace: true
    )
    assert_equal 200, Zizq.budget("emails").allocation
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  def test_binding_at_enqueue_reads_back_on_the_job
    Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)

    job =
      Zizq.enqueue_raw(
        queue: "integration",
        type: "BoundJob",
        payload: {
        },
        budgets: [{ key: "emails", cost: 3 }]
      )

    assert_equal [{ key: "emails", cost: 3 }], job.budgets
    assert_equal [{ key: "emails", cost: 3 }],
                 Zizq.client.get_job(job.id).budgets
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # `create_with` binds and creates in one call, so an application can
  # bring its own throttles up without a provisioning step.
  def test_class_declared_budget_creates_and_binds
    job = Zizq.enqueue(DeclaredBudgetJob)

    assert_equal [{ key: "declared-budget", cost: 2 }], job.budgets
    assert_equal 100, Zizq.budget("declared-budget").allocation
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  def test_job_level_binding_methods
    Zizq.define_budget("a", allocation: 100, strategy: TIME_BASED)
    Zizq.define_budget("b", allocation: 100, strategy: TIME_BASED)

    job = Zizq.enqueue_raw(queue: "integration", type: "BindMe", payload: {})
    assert_empty job.budgets

    job.bind_budget("a", cost: 2)
    assert_equal [{ key: "a", cost: 2 }], job.budgets

    assert_raises(Zizq::ConflictError) { job.bind_budget("a") }

    job.set_budget_cost("a", 4)
    assert_equal [{ key: "a", cost: 4 }], job.budgets

    job.rebind_budget("a")
    assert_equal [{ key: "a", cost: 1 }], job.budgets

    job.replace_budgets([{ key: "a", cost: 1 }, { key: "b", cost: 5 }])
    assert_equal %w[a b], job.budgets.map { |x| x[:key] }.sort

    job.unbind_budget("b")
    assert_equal ["a"], job.budgets.map { |x| x[:key] }

    job.unbind_all_budgets
    assert_empty job.budgets
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # A budget cannot be deleted while anything still draws on it, and
  # `by_budgets_key` selects exactly what is in the way.
  def test_drain_a_budget_before_deleting_it
    Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)

    3.times do |i|
      Zizq.enqueue_raw(
        queue: "integration",
        type: "Bound#{i}",
        payload: {
        },
        budgets: [{ key: "emails" }]
      )
    end

    assert_equal 3, Zizq.query.by_budgets_key("emails").count
    assert_raises(Zizq::ConflictError) { Zizq.delete_budget("emails") }

    result = Zizq.query.by_budgets_key("emails").unbind_budget("emails")
    assert_equal 3, result[:changed]
    assert_empty result[:blocked]

    assert_equal 0, Zizq.query.by_budgets_key("emails").count
    Zizq.delete_budget("emails")
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  def test_bulk_binding_over_a_query
    Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)
    3.times do |i|
      Zizq.enqueue_raw(queue: "integration", type: "Q#{i}", payload: {})
    end

    result = Zizq.query.by_queue("integration").bind_budget("emails", cost: 2)
    assert_equal 3, result[:changed]

    assert_equal 3, Zizq.query.by_budgets_key("emails").count

    Zizq.query.by_budgets_key("emails").set_budget_cost("emails", 7)
    costs =
      Zizq.query.by_budgets_key("emails").map { |j| j.budgets.first[:cost] }
    assert_equal [7, 7, 7], costs

    assert_equal 3,
                 Zizq.query.by_queue("integration").unbind_all_budgets[:changed]
    assert_equal 0, Zizq.query.by_budgets_key("emails").count
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # --- Throttling (pro-only) ---
  #
  # Deliberately built so the assertions are about *counts*, not
  # elapsed time. The rate-limit test uses a one-minute period, so the
  # second token cannot arrive inside the few seconds the test runs
  # however loaded the machine is; the concurrency test measures
  # overlap rather than duration and has no timing component at all.

  def test_while_in_flight_budget_never_runs_two_at_once
    Zizq.define_budget(
      "one-at-a-time",
      allocation: 1,
      strategy: {
        type: :while_in_flight
      }
    )

    5.times do |i|
      Zizq.enqueue_raw(
        queue: "budget-concurrency",
        type: "ConcurrencyProbeJob",
        payload: {
          "args" => [],
          "kwargs" => {
          }
        },
        budgets: [{ key: "one-at-a-time" }]
      )
    end

    mutex = Mutex.new
    in_flight = 0
    peak = 0
    done = 0
    worker =
      Zizq::Worker.new(
        thread_count: 4,
        fiber_count: 1,
        queues: ["budget-concurrency"]
      )

    ConcurrencyProbeJob.tracker =
      lambda do
        mutex.synchronize do
          in_flight += 1
          peak = [peak, in_flight].max
        end
        sleep 0.05
        mutex.synchronize do
          in_flight -= 1
          done += 1
          worker.stop if done >= 5
        end
      end

    Timeout.timeout(60) { worker.run }

    assert_equal 5, done
    assert_equal 1, peak, "budget allowed #{peak} jobs in flight at once"
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # One token per minute with a burst of 1, so exactly one job can be
  # afforded and the rest wait for a refill that will not arrive while
  # the test runs. Asserting the count rather than the pacing leaves
  # roughly a minute of slack for a loaded machine.
  def test_time_based_budget_withholds_what_it_cannot_afford
    Zizq.define_budget(
      "one-per-minute",
      allocation: 1,
      strategy: {
        type: :time_based,
        duration: 60,
        burst: 1
      }
    )

    3.times do |i|
      Zizq.enqueue_raw(
        queue: "budget-throttled",
        type: "ThrottledProbeJob",
        payload: {
          "args" => [],
          "kwargs" => {
          }
        },
        budgets: [{ key: "one-per-minute" }]
      )
    end

    mutex = Mutex.new
    performed = 0
    worker =
      Zizq::Worker.new(
        thread_count: 2,
        fiber_count: 1,
        queues: ["budget-throttled"]
      )
    ThrottledProbeJob.tracker = -> { mutex.synchronize { performed += 1 } }

    stopper =
      Thread.new do
        sleep 3
        worker.stop
      end
    Timeout.timeout(60) { worker.run }
    stopper.join

    assert_equal 1,
                 mutex.synchronize { performed },
                 "expected the budget to afford exactly one job"
    assert_equal 2, Zizq.query.by_queue("budget-throttled").count
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end

  # The positive control for the test above: a budget with room to
  # spare must not hold anything back. The bucket starts full, so all
  # three are affordable immediately and no waiting is involved.
  def test_generous_budget_does_not_throttle
    Zizq.define_budget(
      "roomy",
      allocation: 100,
      strategy: {
        type: :time_based,
        duration: 1
      }
    )

    3.times do |i|
      Zizq.enqueue_raw(
        queue: "budget-throttled",
        type: "ThrottledProbeJob",
        payload: {
          "args" => [],
          "kwargs" => {
          }
        },
        budgets: [{ key: "roomy" }]
      )
    end

    mutex = Mutex.new
    performed = 0
    worker =
      Zizq::Worker.new(
        thread_count: 2,
        fiber_count: 1,
        queues: ["budget-throttled"]
      )
    ThrottledProbeJob.tracker =
      lambda do
        mutex.synchronize do
          performed += 1
          worker.stop if performed >= 3
        end
      end

    Timeout.timeout(60) { worker.run }

    assert_equal 3, performed
  rescue Zizq::ClientError => e
    skip "Budgets require a Pro license" if e.status == 403
    raise
  end
end
