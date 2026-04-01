# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

# Test job class with a custom queue.
class SendEmailJob
  include Zizq::Job

  zizq_queue "emails"
  zizq_priority 20

  attr_reader :received_user_id, :received_template

  def perform(user_id, template: "default")
    @received_user_id = user_id
    @received_template = template
  end
end

# Test job class using the default queue.
class DefaultQueueJob
  include Zizq::Job

  attr_reader :received_args, :received_kwargs

  def perform(*args, **kwargs)
    @received_args = args
    @received_kwargs = kwargs
  end
end

# Test job class with retry/backoff configuration.
class RetryConfiguredJob
  include Zizq::Job

  zizq_queue "retries"
  zizq_retry_limit 5
  zizq_backoff exponent: 2.0, base: 1.5, jitter: 0.5

  def perform(*) = nil
end

# Test job class that doesn't implement perform.
class UnimplementedJob
  include Zizq::Job
end

# Test job class with a custom zizq_enqueue_request override.
class PriorityOverrideJob
  include Zizq::Job

  zizq_queue "priority"

  def self.zizq_enqueue_request(*args, **kwargs)
    req = super
    req.priority = 0 if args.first == "urgent"
    req
  end

  def perform(level) = nil
end

class TestJob < ZizqTestCase

  # --- zizq_queue class method ---

  def test_custom_queue
    assert_equal "emails", SendEmailJob.zizq_queue
  end

  def test_default_queue
    assert_equal "default", DefaultQueueJob.zizq_queue
  end

  # --- zizq_retry_limit class method ---

  def test_retry_limit_configured
    assert_equal 5, RetryConfiguredJob.zizq_retry_limit
  end

  def test_retry_limit_nil_by_default
    assert_nil DefaultQueueJob.zizq_retry_limit
  end

  # --- zizq_backoff class method ---

  def test_backoff_configured
    expected = { exponent: 2.0, base: 1.5, jitter: 0.5 }
    assert_equal expected, RetryConfiguredJob.zizq_backoff
  end

  def test_backoff_nil_by_default
    assert_nil DefaultQueueJob.zizq_backoff
  end

  def test_backoff_requires_all_args
    klass = Class.new { include Zizq::Job }
    assert_raises(ArgumentError) { klass.zizq_backoff(exponent: 2.0) }
    assert_raises(ArgumentError) { klass.zizq_backoff(base: 1.0) }
  end

  # --- zizq_serialize / zizq_deserialize ---

  def test_serialize_args_and_kwargs
    payload = SendEmailJob.zizq_serialize(42, template: "welcome")
    assert_equal({ "args" => [42], "kwargs" => { "template" => "welcome" } }, payload)
  end

  def test_serialize_no_args
    payload = DefaultQueueJob.zizq_serialize
    assert_equal({ "args" => [], "kwargs" => {} }, payload)
  end

  def test_deserialize_round_trips
    original_args = [1, "two"]
    original_kwargs = { key: "val" }
    payload = DefaultQueueJob.zizq_serialize(*original_args, **original_kwargs)
    args, kwargs = DefaultQueueJob.zizq_deserialize(payload)
    assert_equal original_args, args
    assert_equal original_kwargs, kwargs
  end

  # --- zizq_payload_filter ---

  def test_payload_filter_exact_match
    filter = SendEmailJob.zizq_payload_filter(42, template: "welcome")
    assert_equal '. == {"args":[42],"kwargs":{"template":"welcome"}}', filter
  end

  def test_payload_filter_no_args
    filter = DefaultQueueJob.zizq_payload_filter
    assert_equal '. == {"args":[],"kwargs":{}}', filter
  end

  # --- zizq_payload_subset_filter ---

  def test_payload_subset_filter_args_only
    filter = SendEmailJob.zizq_payload_subset_filter(42)
    assert_equal(
      '(.args[0:1] == [42]) and (.kwargs | contains({}))',
      filter
    )
  end

  def test_payload_subset_filter_kwargs_only
    filter = SendEmailJob.zizq_payload_subset_filter(template: "welcome")
    assert_equal(
      '(.args[0:0] == []) and (.kwargs | contains({"template":"welcome"}))',
      filter
    )
  end

  def test_payload_subset_filter_args_and_kwargs
    filter = SendEmailJob.zizq_payload_subset_filter(42, template: "welcome")
    assert_equal(
      '(.args[0:1] == [42]) and (.kwargs | contains({"template":"welcome"}))',
      filter
    )
  end

  def test_payload_subset_filter_no_args
    filter = DefaultQueueJob.zizq_payload_subset_filter
    assert_equal(
      '(.args[0:0] == []) and (.kwargs | contains({}))',
      filter
    )
  end

  # --- zizq_enqueue_request ---

  def test_enqueue_options_defaults
    opts = SendEmailJob.zizq_enqueue_request(42)
    assert_equal "emails", opts.queue
    assert_equal 20, opts.priority
    assert_nil opts.delay
    assert_nil opts.retry_limit
  end

  def test_enqueue_options_includes_class_config
    opts = RetryConfiguredJob.zizq_enqueue_request
    assert_equal "retries", opts.queue
    assert_equal 5, opts.retry_limit
    assert_equal({ exponent: 2.0, base: 1.5, jitter: 0.5 }, opts.backoff)
  end

  def test_enqueue_options_custom_override
    opts = PriorityOverrideJob.zizq_enqueue_request("urgent")
    assert_equal 0, opts.priority

    opts2 = PriorityOverrideJob.zizq_enqueue_request("normal")
    assert_nil opts2.priority
  end

  # --- perform ---

  def test_perform_receives_args_and_kwargs
    job = SendEmailJob.new
    job.perform(42, template: "welcome")
    assert_equal 42, job.received_user_id
    assert_equal "welcome", job.received_template
  end

  def test_perform_with_defaults
    job = SendEmailJob.new
    job.perform(42)
    assert_equal 42, job.received_user_id
    assert_equal "default", job.received_template
  end

  def test_unimplemented_perform_raises
    job = UnimplementedJob.new
    assert_raises(NotImplementedError) { job.perform }
  end

  # --- metadata helpers ---

  def test_metadata_helpers
    client = Zizq::Client.new(url: URL, format: :json)
    resource_job = Zizq::Resources::Job.new(client, {
      "id" => "job-123",
      "attempts" => 3,
      "queue" => "emails",
      "priority" => 100,
      "dequeued_at" => 1_700_000_000_000
    })

    job = SendEmailJob.new
    job.set_zizq_job(resource_job)

    assert_equal "job-123", job.zizq_id
    assert_equal 3, job.zizq_attempts
    assert_equal "emails", job.zizq_queue
    assert_equal 100, job.zizq_priority
    assert_in_delta 1_700_000_000.0, job.zizq_dequeued_at, 0.001
  end

  def test_metadata_nil_before_set
    job = SendEmailJob.new
    assert_nil job.zizq_id
    assert_nil job.zizq_attempts
  end

  # --- Zizq.enqueue ---

  def test_enqueue_with_args_and_kwargs
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["type"] == "SendEmailJob" &&
          body["queue"] == "emails" &&
          body["payload"] == { "args" => [42], "kwargs" => { "template" => "welcome" } }
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    result = Zizq.enqueue(SendEmailJob, 42, template: "welcome")
    assert_equal "x", result.id
  end

  def test_enqueue_uses_class_queue_by_default
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["queue"] == "emails" }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(SendEmailJob, 42)
  end

  def test_enqueue_default_queue_fallback
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["queue"] == "default" }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(DefaultQueueJob)
  end

  def test_enqueue_queue_override_via_block
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["queue"] == "priority" }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(SendEmailJob, 42) { |o| o.queue = "priority" }
  end

  def test_enqueue_with_priority_via_block
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["priority"] == 100 }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(SendEmailJob, 42) { |o| o.priority = 100 }
  end

  def test_enqueue_with_ready_at_via_block
    now = Time.now
    expected_ready_at = ((now.to_f + 60) * 1000).to_i

    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["ready_at"] == expected_ready_at
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(SendEmailJob, 42) { |o| o.ready_at = now + 60 }
  end

  def test_enqueue_with_delay_via_block
    now = Time.now.to_f
    expected_ready_at = ((now + 60) * 1000).to_i

    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        # Allow 1 second of drift for test execution time
        (body["ready_at"] - expected_ready_at).abs < 1000
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(SendEmailJob, 42) { |o| o.delay = 60 }
  end

  def test_enqueue_uses_class_retry_limit
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["retry_limit"] == 5
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(RetryConfiguredJob)
  end

  def test_enqueue_uses_class_backoff_converted_to_ms
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        # 1.5s -> 1500ms, 0.5s -> 500ms
        body["backoff"] == { "exponent" => 2.0, "base_ms" => 1500.0, "jitter_ms" => 500.0 }
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(RetryConfiguredJob)
  end

  def test_enqueue_block_overrides_class_retry_limit
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["retry_limit"] == 10 }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(RetryConfiguredJob) { |o| o.retry_limit = 10 }
  end

  def test_enqueue_with_custom_enqueue_options_override
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["priority"] == 0 && body["queue"] == "priority"
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(PriorityOverrideJob, "urgent")
  end

  def test_enqueue_rejects_class_without_job_mixin
    assert_raises(ArgumentError) { Zizq.enqueue(String) }
  end

  def test_enqueue_anonymous_class_raises
    klass = Class.new { include Zizq::Job }
    assert_raises(ArgumentError) { Zizq.enqueue(klass) }
  end

  # --- Zizq.enqueue_bulk ---

  def test_enqueue_bulk_collects_and_sends_single_request
    jobs_response = { "jobs" => [
      { "id" => "j1", "type" => "SendEmailJob", "queue" => "emails", "status" => "ready" },
      { "id" => "j2", "type" => "DefaultQueueJob", "queue" => "default", "status" => "ready" }
    ] }

    stub_request(:post, "#{URL}/jobs/bulk")
      .with { |req|
        body = JSON.parse(req.body)
        body["jobs"].size == 2 &&
          body["jobs"][0]["type"] == "SendEmailJob" &&
          body["jobs"][0]["queue"] == "emails" &&
          body["jobs"][0]["payload"] == { "args" => [42], "kwargs" => { "template" => "welcome" } } &&
          body["jobs"][1]["type"] == "DefaultQueueJob" &&
          body["jobs"][1]["queue"] == "default"
      }
      .to_return(status: 201, body: JSON.generate(jobs_response),
                 headers: { "Content-Type" => "application/json" })

    result = Zizq.enqueue_bulk do |b|
      b.enqueue(SendEmailJob, 42, template: "welcome")
      b.enqueue(DefaultQueueJob)
    end

    assert_instance_of Array, result
    assert_equal 2, result.size
    assert_equal "j1", result[0].id
    assert_equal "j2", result[1].id
  end

  def test_enqueue_bulk_supports_option_overrides
    stub_request(:post, "#{URL}/jobs/bulk")
      .with { |req|
        body = JSON.parse(req.body)
        body["jobs"][0]["queue"] == "priority" &&
          body["jobs"][0]["priority"] == 100
      }
      .to_return(status: 201, body: JSON.generate({ "jobs" => [{ "id" => "j1" }] }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue_bulk do |b|
      b.enqueue(SendEmailJob, 42) { |o| o.queue = "priority"; o.priority = 100 }
    end
  end

  def test_enqueue_bulk_empty_returns_empty_array
    result = Zizq.enqueue_bulk { |_b| }
    assert_equal [], result
  end

  def test_enqueue_bulk_rejects_non_job_class
    assert_raises(ArgumentError) do
      Zizq.enqueue_bulk { |b| b.enqueue(String) }
    end
  end

  # --- zizq_unique ---

  def test_unique_is_false_by_default
    refute DefaultQueueJob.zizq_unique
  end

  def test_unique_can_be_enabled
    klass = Class.new { include Zizq::Job; zizq_unique true }
    assert klass.zizq_unique
  end

  def test_unique_with_scope
    klass = Class.new { include Zizq::Job; zizq_unique true, scope: :active }
    assert klass.zizq_unique
    assert_equal :active, klass.zizq_unique_scope
  end

  def test_unique_without_scope_has_nil_scope
    klass = Class.new { include Zizq::Job; zizq_unique true }
    assert_nil klass.zizq_unique_scope
  end

  def test_unique_can_be_disabled_with_false
    klass = Class.new { include Zizq::Job; zizq_unique true, scope: :active }
    klass.zizq_unique false
    refute klass.zizq_unique
  end

  # --- zizq_unique_key ---

  def test_unique_key_is_deterministic
    key1 = SendEmailJob.zizq_unique_key(42, template: "welcome")
    key2 = SendEmailJob.zizq_unique_key(42, template: "welcome")
    assert_equal key1, key2
  end

  def test_unique_key_differs_for_different_args
    key1 = SendEmailJob.zizq_unique_key(42, template: "welcome")
    key2 = SendEmailJob.zizq_unique_key(43, template: "welcome")
    refute_equal key1, key2
  end

  def test_unique_key_differs_for_different_kwargs
    key1 = SendEmailJob.zizq_unique_key(42, template: "welcome")
    key2 = SendEmailJob.zizq_unique_key(42, template: "farewell")
    refute_equal key1, key2
  end

  def test_unique_key_includes_class_name
    key = SendEmailJob.zizq_unique_key(42)
    assert key.start_with?("SendEmailJob:"), "expected key to start with class name, got: #{key}"
  end

  def test_unique_key_different_classes_do_not_collide
    key1 = SendEmailJob.zizq_unique_key(42)
    key2 = DefaultQueueJob.zizq_unique_key(42)
    refute_equal key1, key2
  end

  def test_unique_key_is_deterministic_regardless_of_kwarg_order
    key1 = DefaultQueueJob.zizq_unique_key(a: 1, b: 2)
    key2 = DefaultQueueJob.zizq_unique_key(b: 2, a: 1)
    assert_equal key1, key2
  end

  def test_unique_key_normalizes_nested_hashes
    key1 = DefaultQueueJob.zizq_unique_key(data: { z: 1, a: 2 })
    key2 = DefaultQueueJob.zizq_unique_key(data: { a: 2, z: 1 })
    assert_equal key1, key2
  end

  def test_unique_key_super_with_fewer_args
    klass = Class.new do
      include Zizq::Job
      def self.name = "CustomJob"
      def self.zizq_unique_key(user_id, template:)
        super(user_id) # ignore template
      end
    end

    key1 = klass.zizq_unique_key(42, template: "welcome")
    key2 = klass.zizq_unique_key(42, template: "farewell")
    assert_equal key1, key2
  end

  # --- Zizq.enqueue with unique jobs ---

  def test_enqueue_sends_unique_key_and_while
    klass = Class.new do
      include Zizq::Job
      def self.name = "UniqueTestJob"
      zizq_queue "default"
      zizq_unique true, scope: :active
    end

    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["unique_key"]&.start_with?("UniqueTestJob:") &&
          body["unique_while"] == "active"
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(klass)
  end

  def test_enqueue_sends_unique_key_without_scope_when_no_scope_set
    klass = Class.new do
      include Zizq::Job
      def self.name = "UniqueNoScopeJob"
      zizq_unique true
    end

    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["unique_key"]&.start_with?("UniqueNoScopeJob:") &&
          !body.key?("unique_while")
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(klass)
  end

  def test_enqueue_does_not_send_unique_fields_without_dsl
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        !body.key?("unique_key") && !body.key?("unique_while")
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(DefaultQueueJob)
  end

  def test_enqueue_duplicate_returns_job_with_duplicate_flag
    stub_request(:post, "#{URL}/jobs")
      .to_return(status: 200,
                 body: JSON.generate({ "id" => "existing", "duplicate" => true }),
                 headers: { "Content-Type" => "application/json" })

    klass = Class.new do
      include Zizq::Job
      def self.name = "DupJob"
      zizq_unique true
    end

    result = Zizq.enqueue(klass)
    assert_equal "existing", result.id
    assert result.duplicate?
  end

  def test_enqueue_unique_key_override_via_block
    klass = Class.new do
      include Zizq::Job
      def self.name = "OverrideKeyJob"
      zizq_unique true
    end

    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["unique_key"] == "custom-key"
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue(klass) { |o| o.unique_key = "custom-key" }
  end

  # --- Zizq.enqueue_raw ---

  def test_enqueue_raw_sends_type_queue_and_payload
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["queue"] == "emails" &&
          body["type"] == "send_email" &&
          body["payload"] == { "user_id" => 42 }
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    result = Zizq.enqueue_raw(queue: "emails", type: "send_email", payload: { user_id: 42 })
    assert_equal "x", result.id
  end

  def test_enqueue_raw_passes_optional_fields
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body["priority"] == 10 &&
          body["retry_limit"] == 3 &&
          body["unique_key"] == "my-key" &&
          body["unique_while"] == "active"
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue_raw(
      queue: "q",
      type: "task",
      payload: {},
      priority: 10,
      retry_limit: 3,
      unique_key: "my-key",
      unique_while: :active
    )
  end

  def test_enqueue_raw_does_not_send_nil_fields
    stub_request(:post, "#{URL}/jobs")
      .with { |req|
        body = JSON.parse(req.body)
        body.keys.sort == %w[payload queue type]
      }
      .to_return(status: 201, body: JSON.generate({ "id" => "x" }),
                 headers: { "Content-Type" => "application/json" })

    Zizq.enqueue_raw(queue: "q", type: "task", payload: {})
  end

  def test_enqueue_raw_handles_duplicate_response
    stub_request(:post, "#{URL}/jobs")
      .to_return(status: 200,
                 body: JSON.generate({ "id" => "existing", "duplicate" => true }),
                 headers: { "Content-Type" => "application/json" })

    result = Zizq.enqueue_raw(queue: "q", type: "task", payload: {}, unique_key: "k")
    assert_equal "existing", result.id
    assert result.duplicate?
  end

  # --- Zizq.enqueue_bulk with enqueue_raw ---

  def test_enqueue_bulk_with_raw_jobs
    jobs_response = { "jobs" => [
      { "id" => "j1", "type" => "send_email", "queue" => "emails", "status" => "ready" },
      { "id" => "j2", "type" => "generate_report", "queue" => "reports", "status" => "ready" }
    ] }

    stub_request(:post, "#{URL}/jobs/bulk")
      .with { |req|
        body = JSON.parse(req.body)
        body["jobs"].size == 2 &&
          body["jobs"][0]["type"] == "send_email" &&
          body["jobs"][0]["queue"] == "emails" &&
          body["jobs"][0]["payload"] == { "user_id" => 42 } &&
          body["jobs"][1]["type"] == "generate_report" &&
          body["jobs"][1]["queue"] == "reports"
      }
      .to_return(status: 201, body: JSON.generate(jobs_response),
                 headers: { "Content-Type" => "application/json" })

    result = Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "emails", type: "send_email", payload: { user_id: 42 })
      b.enqueue_raw(queue: "reports", type: "generate_report", payload: { id: 7 })
    end

    assert_equal 2, result.size
    assert_equal "j1", result[0].id
    assert_equal "j2", result[1].id
  end

  def test_enqueue_bulk_mixed_raw_and_job_class
    jobs_response = { "jobs" => [
      { "id" => "j1", "type" => "SendEmailJob", "queue" => "emails", "status" => "ready" },
      { "id" => "j2", "type" => "process_payment", "queue" => "payments", "status" => "ready" }
    ] }

    stub_request(:post, "#{URL}/jobs/bulk")
      .with { |req|
        body = JSON.parse(req.body)
        body["jobs"].size == 2 &&
          body["jobs"][0]["type"] == "SendEmailJob" &&
          body["jobs"][0]["queue"] == "emails" &&
          body["jobs"][1]["type"] == "process_payment" &&
          body["jobs"][1]["queue"] == "payments"
      }
      .to_return(status: 201, body: JSON.generate(jobs_response),
                 headers: { "Content-Type" => "application/json" })

    result = Zizq.enqueue_bulk do |b|
      b.enqueue(SendEmailJob, 42, template: "welcome")
      b.enqueue_raw(queue: "payments", type: "process_payment", payload: { amount: 99 })
    end

    assert_equal 2, result.size
    assert_equal "j1", result[0].id
    assert_equal "j2", result[1].id
  end
end
