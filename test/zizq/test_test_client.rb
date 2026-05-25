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

    error = assert_raises(Zizq::Test::Client::NotSupported) { Zizq::Test.client }
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
    assert_equal({ user: 1 }, jobs.first.payload)

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
    Zizq.enqueue_raw(queue: "q", type: "A", payload: {}, ready_at: Time.now - 60)

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
      queue: "q", type: "Email", payload: {},
      unique_key: "user-1",
    )

    requests = Zizq::Test.client.enqueued_requests
    assert_equal 1, requests.size
    assert_kind_of Zizq::EnqueueRequest, requests.first
    # `unique_key` lives on the request, not on Resources::Job —
    # store both so tests can assert on either.
    assert_equal "user-1", requests.first.unique_key
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
      error = assert_raises(Zizq::Test::Client::NotSupported) do
        Zizq.client.public_send(method)
      end
      assert_match(/not supported in test mode/, error.message)
    end
  end

  def test_take_jobs_raises_not_supported
    error = assert_raises(Zizq::Test::Client::NotSupported) do
      Zizq.client.take_jobs { |_| }
    end
    assert_match(/take_jobs/, error.message)
  end
end
