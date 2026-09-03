# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class TestTestClient < ZizqTestCase
  # ZizqTestCase#setup resets global state + WebMock and applies the
  # default URL/format. We layer test_mode on top so the bulk of these
  # tests have it enabled. The handful that exercise the disabled
  # branch reconfigure explicitly inside the test.
  def setup
    super
    Zizq.configure { |c| c.test_mode = true }
  end

  # --- enable! / disable! ---

  def test_enable_switches_into_test_mode
    Zizq.reset!
    Zizq.configure { |c| c.url = "http://example:7890" }
    refute Zizq.configuration.test_mode

    Zizq::Test.enable!

    assert Zizq.configuration.test_mode
    assert_kind_of Zizq::Test::Client, Zizq.client
  end

  def test_disable_switches_back_to_the_real_client
    Zizq::Test.disable!

    refute Zizq.configuration.test_mode
    assert_kind_of Zizq::Client, Zizq.client
    refute_kind_of Zizq::Test::Client, Zizq.client
  end

  # --- Configuration plumbing ---

  def test_test_mode_defaults_to_false
    Zizq.reset!
    refute Zizq::Configuration.new.test_mode
  end

  def test_client_resolves_to_test_client_when_test_mode_is_set
    assert_kind_of Zizq::Test::Client, Zizq.client
  end

  def test_client_resolves_to_real_client_when_test_mode_is_disabled
    Zizq.reset!
    Zizq.configure { |c| c.url = "http://example:7890" }
    assert_kind_of Zizq::Client, Zizq.client
    refute_kind_of Zizq::Test::Client, Zizq.client
  end

  # --- Zizq::Test module ---

  def test_zizq_test_client_returns_the_current_test_client
    assert_same Zizq.client, Zizq::Test.client
  end

  def test_zizq_test_client_raises_when_test_mode_disabled
    Zizq.reset!
    Zizq.configure { |c| c.url = "http://example:7890" }

    error =
      assert_raises(Zizq::Test::Client::NotSupported) { Zizq::Test.client }
    assert_match(/test_mode is not enabled/, error.message)
  end

  # --- Enqueue buffering ---

  def test_enqueue_buffers_a_resources_job
    returned = Zizq.enqueue_raw(queue: "q", type: "Email", payload: { user: 1 })

    jobs = Zizq::Test.client.enqueued_jobs
    assert_equal 1, jobs.size
    assert_kind_of Zizq::Resources::Job, jobs.first
    assert_equal "q", jobs.first.queue
    assert_equal "Email", jobs.first.type
    # Payload is normalised via JSON round-trip on enqueue so the
    # in-memory view matches what a consumer sees on the wire —
    # symbol keys become strings.
    assert_equal({ "user" => 1 }, jobs.first.payload)

    # The returned job is the same instance as the buffered one — same
    # id flows through to whatever drain logic the test uses later.
    assert_equal returned.id, jobs.first.id
    assert_equal "ready", returned.status
  end

  def test_status_is_scheduled_when_ready_at_is_in_the_future
    future = Time.now + 60
    Zizq.enqueue_raw(queue: "q", type: "A", payload: {}, ready_at: future)

    job = Zizq::Test.client.enqueued_jobs.first
    assert_equal "scheduled", job.status
    assert_in_delta future.to_f, job.ready_at, 0.01
  end

  def test_status_is_ready_when_ready_at_is_in_the_past
    Zizq.enqueue_raw(
      queue: "q",
      type: "A",
      payload: {
      },
      ready_at: Time.now - 60
    )

    assert_equal "ready", Zizq::Test.client.enqueued_jobs.first.status
  end

  def test_ready_at_defaults_to_now_when_unset
    # `ready_at` defaults to "now" on the server when the client
    # omits it — we mirror that. Timecop freezes time so the assertion
    # is exact (sub-ms precision is lost in ms-storage; freezing
    # makes the test deterministic).
    Timecop.freeze(Time.at(1_780_000_000)) do
      Zizq.enqueue_raw(queue: "q", type: "A", payload: {})

      job = Zizq::Test.client.enqueued_jobs.first
      assert_equal Time.now.to_f, job.ready_at
      assert_equal "ready", job.status
    end
  end

  def test_synthetic_ids_match_scru128_length_and_zero_pad
    Zizq.enqueue_raw(queue: "q", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "q", type: "B", payload: {})

    ids = Zizq::Test.client.enqueued_jobs.map(&:id)
    assert_equal 25, ids.first.length
    assert_equal "test000000000000000000001", ids[0]
    assert_equal "test000000000000000000002", ids[1]
  end

  def test_enqueue_also_preserves_the_original_request
    Zizq.enqueue_raw(
      queue: "q",
      type: "Email",
      payload: {
      },
      unique_key: "user-1"
    )

    requests = Zizq::Test.client.enqueued_requests
    assert_equal 1, requests.size
    assert_kind_of Zizq::EnqueueRequest, requests.first
    # `unique_key` lives on the request, not on Resources::Job —
    # store both so tests can assert on either.
    assert_equal "user-1", requests.first.unique_key
  end

  def test_enqueue_raw_accepts_batch_config
    batch = {
      key: "push:apple",
      when: "($existing.args[0] + $new.args[0]) | length <= 100",
      fold: "$existing | .args[0] += $new.args[0]"
    }

    Zizq.enqueue_raw(
      queue: "push",
      type: "SendPushNotifications",
      payload: {
        "args" => [[{ device: "a" }]],
        "kwargs" => {
          "platform" => "apple"
        }
      },
      batch: batch
    )

    requests = Zizq::Test.client.enqueued_requests
    assert_equal 1, requests.size
    assert_equal batch, requests.first.batch
  end

  # `enqueue` is the low-level primitive and so receives the wire form
  # (`base_ms`, `completed_ms`, ...), but `enqueued_requests` hands back
  # an `EnqueueRequest`, which holds the fractional seconds the caller
  # wrote. Recording the wire form there would make a test assert on
  # keys the application never used.
  def test_enqueue_records_backoff_and_retention_in_seconds
    backoff = { exponent: 2.0, base: 1.5, jitter: 0.25 }
    retention = { completed: 60.0, dead: 3600.0 }

    Zizq.enqueue_raw(
      queue: "q",
      type: "Email",
      payload: {
      },
      backoff: backoff,
      retention: retention
    )

    request = Zizq::Test.client.enqueued_requests.first
    assert_equal backoff, request.backoff
    assert_equal retention, request.retention
  end

  # The bulk path builds its requests separately, so it converts
  # separately too.
  def test_enqueue_bulk_records_backoff_and_retention_in_seconds
    backoff = { exponent: 2.0, base: 1.5, jitter: 0.25 }

    Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "q", type: "A", payload: {}, backoff: backoff)
    end

    assert_equal backoff, Zizq::Test.client.enqueued_requests.first.backoff
  end

  def test_enqueue_bulk_buffers_each_request
    Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "q", type: "A", payload: {})
      b.enqueue_raw(queue: "q", type: "B", payload: {})
    end

    types = Zizq::Test.client.enqueued_jobs.map(&:type)
    assert_equal %w[A B], types
  end

  # --- Reset ---

  def test_reset_clears_the_buffer
    Zizq.enqueue_raw(queue: "q", type: "A", payload: {})
    refute_empty Zizq::Test.client.enqueued_jobs

    Zizq::Test.reset!

    assert_empty Zizq::Test.client.enqueued_jobs
  end

  def test_reset_keeps_test_mode_active
    Zizq.enqueue_raw(queue: "q", type: "A", payload: {})
    Zizq::Test.reset!

    # Same client instance is preserved; test mode remains active.
    assert Zizq.configuration.test_mode
    assert_kind_of Zizq::Test::Client, Zizq.client
  end

  # --- Unsupported operations ---

  def test_read_operations_raise_not_supported
    %i[get_queues count_jobs health server_version].each do |method|
      error =
        assert_raises(Zizq::Test::Client::NotSupported) do
          Zizq.client.public_send(method)
        end
      assert_match(/not supported in test mode/, error.message)
    end
  end

  def test_take_jobs_raises_not_supported
    error =
      assert_raises(Zizq::Test::Client::NotSupported) do
        Zizq.client.take_jobs { |_| }
      end
    assert_match(/take_jobs/, error.message)
  end

  # --- Status filters ---

  def test_pending_jobs_includes_ready_and_scheduled
    Zizq.enqueue_raw(queue: "q", type: "Ready", payload: {})
    Zizq.enqueue_raw(
      queue: "q",
      type: "Scheduled",
      payload: {
      },
      ready_at: Time.now + 60
    )

    pending = Zizq::Test.client.pending_jobs
    assert_equal %w[Ready Scheduled].sort, pending.map(&:type).sort
    assert_empty Zizq::Test.client.in_flight_jobs
    assert_empty Zizq::Test.client.completed_jobs
    assert_empty Zizq::Test.client.dead_jobs
  end

  # --- dispatch_enqueued_jobs ---

  def test_dispatch_enqueued_jobs_drains_pending_and_transitions_to_completed
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    Zizq.enqueue_raw(queue: "q", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "q", type: "B", payload: {})

    performed = Zizq::Test.dispatch_enqueued_jobs

    assert_equal 2, performed
    assert_equal %w[A B], dispatched
    assert_empty Zizq::Test.client.pending_jobs
    assert_equal 2, Zizq::Test.client.completed_jobs.size
  end

  def test_dispatch_enqueued_jobs_block_form_yields_then_drains
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    Zizq::Test.dispatch_enqueued_jobs do
      # During the block: enqueues buffer, nothing has run yet.
      Zizq.enqueue_raw(queue: "q", type: "A", payload: {})
      Zizq.enqueue_raw(queue: "q", type: "B", payload: {})
      assert_empty dispatched
    end

    assert_equal %w[A B], dispatched
  end

  def test_dispatch_enqueued_jobs_skips_scheduled_until_due
    Zizq.configure { |c| c.dispatcher = ->(_) {} }

    Zizq.enqueue_raw(
      queue: "q",
      type: "Future",
      payload: {
      },
      ready_at: Time.now + 60
    )

    assert_equal 0, Zizq::Test.dispatch_enqueued_jobs
    assert_equal 1, Zizq::Test.client.pending_jobs.size
  end

  def test_dispatch_enqueued_jobs_picks_up_scheduled_after_timecop_advances
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    Timecop.freeze(Time.at(1_780_000_000)) do
      Zizq.enqueue_raw(
        queue: "q",
        type: "Future",
        payload: {
        },
        ready_at: Time.now + 60
      )

      Timecop.travel(120) do
        assert_equal 1, Zizq::Test.dispatch_enqueued_jobs
        assert_equal %w[Future], dispatched
      end
    end
  end

  def test_dispatch_enqueued_jobs_drains_handler_reenqueues_recursively
    Zizq.configure do |c|
      c.dispatcher = ->(job) do
        if job.type == "Parent"
          Zizq.enqueue_raw(queue: "q", type: "Child", payload: {})
        end
      end
    end

    Zizq.enqueue_raw(queue: "q", type: "Parent", payload: {})

    # Both the parent and its re-enqueued child should drain in one call.
    assert_equal 2, Zizq::Test.dispatch_enqueued_jobs
    assert_empty Zizq::Test.client.pending_jobs
    assert_equal %w[Parent Child].sort,
                 Zizq::Test.client.completed_jobs.map(&:type).sort
  end

  def test_dispatch_enqueued_jobs_runs_the_full_dequeue_middleware_chain
    # Test mode should mirror the real worker, which dispatches via
    # `Zizq.configuration.dequeue_middleware.call` — so any middleware
    # registered with `c.dequeue_middleware.use(...)` runs in tests too.
    trace = []
    middleware = Object.new
    middleware.define_singleton_method(:call) do |job, chain|
      trace << "before-#{job.type}"
      result = chain.call(job)
      trace << "after-#{job.type}"
      result
    end
    Zizq.configure do |c|
      c.dispatcher = ->(job) { trace << "dispatch-#{job.type}" }
      c.dequeue_middleware.use(middleware)
    end

    Zizq.enqueue_raw(queue: "q", type: "A", payload: {})
    Zizq::Test.dispatch_enqueued_jobs

    assert_equal %w[before-A dispatch-A after-A], trace
  end

  def test_dispatch_enqueued_jobs_marks_handler_failure_as_dead_and_reraises
    boom = Class.new(StandardError)
    Zizq.configure { |c| c.dispatcher = ->(_) { raise boom, "kaboom" } }

    Zizq.enqueue_raw(queue: "q", type: "Failing", payload: {})

    assert_raises(boom) { Zizq::Test.dispatch_enqueued_jobs }

    dead = Zizq::Test.client.dead_jobs
    assert_equal 1, dead.size
    assert_equal "Failing", dead.first.type
    assert_empty Zizq::Test.client.in_flight_jobs
  end

  def test_dispatch_enqueued_jobs_block_exception_skips_drain
    Zizq.configure { |c| c.dispatcher = ->(_) {} }
    Zizq.enqueue_raw(queue: "q", type: "A", payload: {})

    assert_raises(RuntimeError) do
      Zizq::Test.dispatch_enqueued_jobs { raise "block boom" }
    end

    # Block raised before we got to drain; pending stays as-is.
    assert_equal 1, Zizq::Test.client.pending_jobs.size
  end

  # --- Filters ---

  def test_dispatch_enqueued_jobs_filters_by_only_queues
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.queue } }

    Zizq.enqueue_raw(queue: "emails", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "webhooks", type: "B", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(only_queues: "emails")

    assert_equal %w[emails], dispatched
    assert_equal 1, Zizq::Test.client.completed_jobs.size
    assert_equal 1, Zizq::Test.client.pending_jobs.size
    assert_equal "webhooks", Zizq::Test.client.pending_jobs.first.queue
  end

  def test_dispatch_enqueued_jobs_filters_by_except_queues
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.queue } }

    Zizq.enqueue_raw(queue: "emails", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "webhooks", type: "B", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(except_queues: "webhooks")

    assert_equal %w[emails], dispatched
  end

  def test_dispatch_enqueued_jobs_filters_by_only_types
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    Zizq.enqueue_raw(queue: "q", type: "SendEmail", payload: {})
    Zizq.enqueue_raw(queue: "q", type: "PostWebhook", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(only_types: "SendEmail")

    assert_equal %w[SendEmail], dispatched
  end

  def test_dispatch_enqueued_jobs_filters_by_except_types
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    Zizq.enqueue_raw(queue: "q", type: "SendEmail", payload: {})
    Zizq.enqueue_raw(queue: "q", type: "PostWebhook", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(except_types: "SendEmail")

    assert_equal %w[PostWebhook], dispatched
  end

  def test_dispatch_enqueued_jobs_accepts_class_for_type_filter
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    klass = Class.new
    klass.define_singleton_method(:to_s) { "SendEmail" }

    Zizq.enqueue_raw(queue: "q", type: "SendEmail", payload: {})
    Zizq.enqueue_raw(queue: "q", type: "Other", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(only_types: klass)

    assert_equal %w[SendEmail], dispatched
  end

  def test_dispatch_enqueued_jobs_accepts_array_filters
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.queue } }

    Zizq.enqueue_raw(queue: "a", type: "T", payload: {})
    Zizq.enqueue_raw(queue: "b", type: "T", payload: {})
    Zizq.enqueue_raw(queue: "c", type: "T", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(only_queues: %w[a c])

    assert_equal %w[a c], dispatched.sort
    assert_equal 1, Zizq::Test.client.pending_jobs.size
  end

  def test_dispatch_enqueued_jobs_filter_lambda_ANDs_with_named_filters
    dispatched = []
    Zizq.configure { |c| c.dispatcher = ->(job) { dispatched << job.type } }

    Zizq.enqueue_raw(queue: "emails", type: "Urgent", payload: { urgent: true })
    Zizq.enqueue_raw(
      queue: "emails",
      type: "Routine",
      payload: {
        urgent: false
      }
    )
    Zizq.enqueue_raw(queue: "other", type: "Urgent", payload: { urgent: true })

    Zizq::Test.dispatch_enqueued_jobs(
      only_queues: "emails",
      filter: ->(job) { job.payload["urgent"] }
    )

    # `emails` AND `urgent` — only the first job.
    assert_equal %w[Urgent], dispatched
  end

  def test_dispatch_enqueued_jobs_combining_only_and_except_for_same_queue_drains_nothing
    Zizq.configure { |c| c.dispatcher = ->(_) {} }
    Zizq.enqueue_raw(queue: "a", type: "T", payload: {})

    # Logically nonsensical but we don't validate — empty result is
    # the natural consequence.
    assert_equal 0,
                 Zizq::Test.dispatch_enqueued_jobs(
                   only_queues: "a",
                   except_queues: "a"
                 )
    assert_equal 1, Zizq::Test.client.pending_jobs.size
  end

  def test_dispatch_enqueued_jobs_filter_leaves_off_filter_reenqueues_pending
    Zizq.configure do |c|
      c.dispatcher = ->(job) do
        if job.type == "Parent"
          Zizq.enqueue_raw(queue: "webhooks", type: "Child", payload: {})
        end
      end
    end

    Zizq.enqueue_raw(queue: "emails", type: "Parent", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(only_queues: "emails")

    assert_equal 1, Zizq::Test.client.pending_jobs.size
    assert_equal "webhooks", Zizq::Test.client.pending_jobs.first.queue
  end

  # --- Predicate helpers: enqueued_raw? / enqueued_raw_count ---

  def test_enqueued_raw_matches_by_type_only
    Zizq.enqueue_raw(queue: "q", type: "send_email", payload: { user_id: 1 })

    assert Zizq::Test.enqueued_raw?(type: "send_email")
    refute Zizq::Test.enqueued_raw?(type: "post_webhook")
  end

  def test_enqueued_raw_matches_by_type_and_payload
    Zizq.enqueue_raw(queue: "q", type: "send_email", payload: { user_id: 42 })
    Zizq.enqueue_raw(queue: "q", type: "send_email", payload: { user_id: 99 })

    assert Zizq::Test.enqueued_raw?(
             type: "send_email",
             payload: {
               user_id: 42
             }
           )
    refute Zizq::Test.enqueued_raw?(type: "send_email", payload: { user_id: 7 })
  end

  def test_enqueued_raw_matches_by_queue
    Zizq.enqueue_raw(queue: "emails", type: "send_email", payload: {})
    Zizq.enqueue_raw(queue: "webhooks", type: "send_email", payload: {})

    assert Zizq::Test.enqueued_raw?(queue: "emails", type: "send_email")
    refute Zizq::Test.enqueued_raw?(queue: "missing", type: "send_email")
  end

  def test_enqueued_raw_count_counts_matches
    3.times { Zizq.enqueue_raw(queue: "q", type: "x", payload: { n: 1 }) }
    2.times { Zizq.enqueue_raw(queue: "q", type: "x", payload: { n: 2 }) }
    1.times { Zizq.enqueue_raw(queue: "q", type: "y", payload: {}) }

    assert_equal 5, Zizq::Test.enqueued_raw_count(type: "x")
    assert_equal 3, Zizq::Test.enqueued_raw_count(type: "x", payload: { n: 1 })
    assert_equal 1, Zizq::Test.enqueued_raw_count(type: "y")
    assert_equal 0, Zizq::Test.enqueued_raw_count(type: "missing")
  end

  # --- Predicate helpers: enqueued? / enqueued_count (class form) ---

  # An ad-hoc Zizq::Job class for the predicate tests.
  class FakeJob
    include Zizq::Job
    zizq_queue "fake-queue"
    def perform(*)
    end
  end

  def test_enqueued_matches_by_class_only
    Zizq.enqueue(FakeJob, 1)

    assert Zizq::Test.enqueued?(FakeJob)
    refute Zizq::Test.enqueued?(self.class) # arbitrary unrelated class
  end

  def test_enqueued_matches_with_positional_args
    Zizq.enqueue(FakeJob, 42)

    assert Zizq::Test.enqueued?(FakeJob, 42)
    refute Zizq::Test.enqueued?(FakeJob, 99)
  end

  def test_enqueued_matches_with_kwargs
    Zizq.enqueue(FakeJob, 42, template: "welcome")

    assert Zizq::Test.enqueued?(FakeJob, 42, template: "welcome")
    refute Zizq::Test.enqueued?(FakeJob, 42, template: "other")
  end

  def test_enqueued_count_counts_matches
    Zizq.enqueue(FakeJob, 1)
    Zizq.enqueue(FakeJob, 2)
    Zizq.enqueue(FakeJob, 2)

    assert_equal 3, Zizq::Test.enqueued_count(FakeJob)
    assert_equal 2, Zizq::Test.enqueued_count(FakeJob, 2)
    assert_equal 1, Zizq::Test.enqueued_count(FakeJob, 1)
    assert_equal 0, Zizq::Test.enqueued_count(FakeJob, 99)
  end

  def test_enqueued_raises_for_class_without_zizq_serialize
    klass = Class.new # bare Ruby class, no Zizq::Job mixin

    error = assert_raises(ArgumentError) { Zizq::Test.enqueued?(klass, 1, 2) }
    assert_match(/zizq_serialize/, error.message)
  end

  def test_enqueued_with_no_args_uses_type_only_match_even_without_zizq_serialize
    # The no-args path delegates to enqueued_raw?(type:), so it doesn't
    # need the class to be serializable. Handy for "did *something* of
    # this class get enqueued".
    Zizq.enqueue(FakeJob, 1)

    assert Zizq::Test.enqueued?(FakeJob)
  end

  # --- Zizq::Test convenience proxies ---

  def test_zizq_test_module_proxies_accessors_onto_the_client
    Zizq.configure { |c| c.dispatcher = ->(_) {} }

    Zizq.enqueue_raw(queue: "emails", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "webhooks", type: "B", payload: {})

    # Same results as going through client.* directly, but shorter.
    assert_equal Zizq::Test.client.enqueued_jobs.map(&:id),
                 Zizq::Test.enqueued_jobs.map(&:id)
    assert_equal 1, Zizq::Test.pending_jobs(only_queues: "emails").size

    Zizq::Test.dispatch_enqueued_jobs(only_queues: "emails")
    assert_equal 1, Zizq::Test.completed_jobs.size
    assert_equal 1, Zizq::Test.pending_jobs.size
    assert_empty Zizq::Test.in_flight_jobs
    assert_empty Zizq::Test.dead_jobs
  end

  # --- Filters on accessors ---

  def test_filter_kwargs_work_on_pending_jobs
    Zizq.enqueue_raw(queue: "emails", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "webhooks", type: "B", payload: {})

    assert_equal 1, Zizq::Test.client.pending_jobs(only_queues: "emails").size
    assert_equal "emails",
                 Zizq::Test
                   .client
                   .pending_jobs(only_queues: "emails")
                   .first
                   .queue

    assert_equal 1, Zizq::Test.client.pending_jobs(except_queues: "emails").size
    assert_equal "webhooks",
                 Zizq::Test
                   .client
                   .pending_jobs(except_queues: "emails")
                   .first
                   .queue
  end

  def test_filter_kwargs_work_on_enqueued_jobs_across_all_statuses
    Zizq.configure { |c| c.dispatcher = ->(_) {} }

    Zizq.enqueue_raw(queue: "emails", type: "A", payload: {})
    Zizq.enqueue_raw(queue: "webhooks", type: "B", payload: {})

    Zizq::Test.dispatch_enqueued_jobs(only_queues: "emails")

    # `enqueued_jobs` shows everything regardless of status, but the
    # queue filter still narrows the view.
    assert_equal %w[emails],
                 Zizq::Test
                   .client
                   .enqueued_jobs(only_queues: "emails")
                   .map(&:queue)
    assert_equal 2, Zizq::Test.client.enqueued_jobs.size
  end

  def test_filter_lambda_works_on_accessors
    Zizq.enqueue_raw(queue: "q", type: "A", payload: { important: true })
    Zizq.enqueue_raw(queue: "q", type: "B", payload: { important: false })

    important =
      Zizq::Test.client.pending_jobs(
        filter: ->(job) { job.payload["important"] }
      )
    assert_equal %w[A], important.map(&:type)
  end
end
