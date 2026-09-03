# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"
require "active_job"
require "active_job/queue_adapters/zizq_adapter"

ActiveJob::Base.logger = Logger.new(File::NULL)

# Plain ActiveJob class — no Zizq extensions.
class PlainActiveJob < ActiveJob::Base
  self.queue_name = "default"

  @executions = []
  class << self
    attr_accessor :executions
  end

  def perform(user_id, template:)
    self.class.executions << { user_id: user_id, template: template }
  end
end

# ActiveJob class with Zizq extensions.
class ExtendedActiveJob < ActiveJob::Base
  extend Zizq::ActiveJobConfig

  self.queue_name = "emails"
  zizq_unique true, scope: :active
  zizq_retry_limit 5
  zizq_backoff exponent: 3.0, base: 10, jitter: 5
  zizq_retention completed: 0, dead: 86_400
  zizq_budget "emails", cost: 2

  @executions = []
  class << self
    attr_accessor :executions
  end

  def perform(user_id, template:)
    self.class.executions << { user_id: user_id, template: template }
  end
end

# ActiveJob class with unique jobs but no explicit scope.
class UniqueNoScopeActiveJob < ActiveJob::Base
  extend Zizq::ActiveJobConfig

  self.queue_name = "default"
  zizq_unique true

  @executions = []
  class << self
    attr_accessor :executions
  end

  def perform(value)
    self.class.executions << { value: value }
  end
end

class TestActiveJob < ZizqTestCase
  def setup
    super
    PlainActiveJob.executions = []
    ExtendedActiveJob.executions = []
    UniqueNoScopeActiveJob.executions = []
  end

  # Build the EnqueueRequest the adapter would produce, without HTTP calls.
  def adapter_request(job)
    ActiveJob::QueueAdapters::ZizqAdapter.new.send(:build_enqueue_request, job)
  end

  # Simulate the dispatch side: build a Resources::Job from a request
  # and run it through the Dispatcher.
  def dispatch(req)
    client = Zizq::Client.new(url: URL, format: :json)
    resource_job =
      Zizq::Resources::Job.new(
        client,
        {
          "id" => "j1",
          "type" => req.type,
          "queue" => req.queue,
          "payload" => req.payload,
          "attempts" => 0
        }
      )
    ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher.call(resource_job)
    client.close
  end

  # --- Round-trip tests ---

  def test_plain_job_round_trips
    job = PlainActiveJob.new(42, template: "welcome")
    params = adapter_request(job)
    dispatch(params)

    assert_equal 1, PlainActiveJob.executions.size
    assert_equal(
      { user_id: 42, template: "welcome" },
      PlainActiveJob.executions.first
    )
  end

  def test_extended_job_round_trips
    job = ExtendedActiveJob.new(42, template: "welcome")
    params = adapter_request(job)
    dispatch(params)

    assert_equal 1, ExtendedActiveJob.executions.size
    assert_equal(
      { user_id: 42, template: "welcome" },
      ExtendedActiveJob.executions.first
    )
  end

  # --- Plain adapter params (no Zizq extensions) ---

  def test_plain_request_include_type_and_queue
    req = adapter_request(PlainActiveJob.new(42, template: "welcome"))

    assert_equal "PlainActiveJob", req.type
    assert_equal "default", req.queue
  end

  def test_plain_request_include_activejob_payload
    req = adapter_request(PlainActiveJob.new(42, template: "welcome"))

    assert_equal "PlainActiveJob", req.payload["job_class"]
    assert req.payload["arguments"].is_a?(Array)
  end

  def test_plain_request_omit_unique_fields
    req = adapter_request(PlainActiveJob.new(42, template: "welcome"))

    assert_nil req.unique_key
    assert_nil req.unique_while
  end

  def test_plain_request_omit_backoff_and_retention
    req = adapter_request(PlainActiveJob.new(42, template: "welcome"))

    assert_nil req.backoff
    assert_nil req.retention
    assert_nil req.retry_limit
  end

  def test_plain_request_omit_budgets
    req = adapter_request(PlainActiveJob.new(42, template: "welcome"))

    assert_nil req.budgets
  end

  # --- Extended adapter request (with Zizq extensions) ---

  def test_extended_request_include_unique_key_and_scope
    req = adapter_request(ExtendedActiveJob.new(42, template: "welcome"))

    assert req.unique_key.start_with?("ExtendedActiveJob:")
    assert_equal :active, req.unique_while
  end

  def test_extended_request_include_backoff
    req = adapter_request(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal({ exponent: 3.0, base: 10.0, jitter: 5.0 }, req.backoff)
  end

  def test_extended_request_include_retention
    req = adapter_request(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal({ completed: 0.0, dead: 86_400.0 }, req.retention)
  end

  # The adapter builds its request field by field rather than through
  # `zizq_enqueue_request`, so anything the DSL gains has to be copied
  # here too or it is silently dropped for ActiveJob callers.
  def test_extended_request_include_budgets
    req = adapter_request(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal [{ key: "emails", cost: 2 }], req.budgets
  end

  def test_extended_request_include_retry_limit
    req = adapter_request(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal 5, req.retry_limit
  end

  def test_extended_request_use_activejob_queue_name
    req = adapter_request(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal "emails", req.queue
  end

  # --- Unique without explicit scope ---

  def test_unique_no_scope_includes_key_but_not_while
    req = adapter_request(UniqueNoScopeActiveJob.new(42))

    assert req.unique_key.is_a?(String)
    assert_nil req.unique_while
  end

  # --- Unique key determinism ---

  def test_unique_key_deterministic_for_same_args
    key1 = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")
    key2 = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")
    assert_equal key1, key2
  end

  def test_unique_key_differs_for_different_args
    key1 = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")
    key2 = ExtendedActiveJob.zizq_unique_key(43, template: "welcome")
    refute_equal key1, key2
  end

  def test_unique_key_includes_class_name
    key = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")
    assert key.start_with?("ExtendedActiveJob:"),
           "expected class name prefix, got: #{key}"
  end

  # --- Unique key matches between adapter and class method ---

  def test_adapter_unique_key_matches_class_method
    job = ExtendedActiveJob.new(42, template: "welcome")
    params = adapter_request(job)
    direct_key = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")

    assert_equal direct_key, params.unique_key
  end

  # --- Batched jobs (positional arg target) ---

  # ActiveJob class batched by the first positional arg.
  class PositionalBatchedActiveJob < ActiveJob::Base
    extend Zizq::ActiveJobConfig

    self.queue_name = "audit"
    zizq_batched true, limit: 100

    def perform(events, tenant_id:) = nil
  end

  def test_positional_batched_reader
    assert PositionalBatchedActiveJob.zizq_batched
    assert_equal 0, PositionalBatchedActiveJob.zizq_batch_arg
    assert_nil PositionalBatchedActiveJob.zizq_batch_kwarg
    assert_equal 100, PositionalBatchedActiveJob.zizq_batch_limit
  end

  def test_positional_batched_expressions
    expr = PositionalBatchedActiveJob.zizq_batch_expressions
    assert_equal(
      "($existing.arguments[0] + $new.arguments[0]) | length <= 100",
      expr[:when]
    )
    assert_equal("$existing | .arguments[0] += $new.arguments[0]", expr[:fold])
  end

  def test_positional_batched_key_ignores_batch_arg
    key1 = PositionalBatchedActiveJob.zizq_batch_key([1, 2], tenant_id: 42)
    key2 = PositionalBatchedActiveJob.zizq_batch_key([99, 100], tenant_id: 42)
    assert_equal key1, key2
  end

  def test_positional_batched_key_differs_by_non_batch_arg
    key1 = PositionalBatchedActiveJob.zizq_batch_key([1], tenant_id: 42)
    key2 = PositionalBatchedActiveJob.zizq_batch_key([1], tenant_id: 43)
    refute_equal key1, key2
  end

  def test_positional_batched_key_prefixed_with_class_name
    key = PositionalBatchedActiveJob.zizq_batch_key([1], tenant_id: 42)
    assert(
      key.start_with?("TestActiveJob::PositionalBatchedActiveJob:"),
      "expected class-name prefix, got: #{key}"
    )
  end

  # --- Batched jobs (kwarg target) ---

  # ActiveJob class batched by a specific kwarg.
  class KwargBatchedActiveJob < ActiveJob::Base
    extend Zizq::ActiveJobConfig

    self.queue_name = "push"
    zizq_batched true, kwarg: :device_ids, limit: 50

    def perform(device_ids:, platform:) = nil
  end

  def test_kwarg_batched_expressions
    expr = KwargBatchedActiveJob.zizq_batch_expressions
    assert_equal(
      "($existing.arguments[-1].device_ids + $new.arguments[-1].device_ids) | length <= 50",
      expr[:when]
    )
    assert_equal(
      "$existing | .arguments[-1].device_ids += $new.arguments[-1].device_ids",
      expr[:fold]
    )
  end

  def test_kwarg_batched_key_ignores_batch_kwarg
    key1 =
      KwargBatchedActiveJob.zizq_batch_key(device_ids: ["a"], platform: "apple")
    key2 =
      KwargBatchedActiveJob.zizq_batch_key(
        device_ids: %w[b c],
        platform: "apple"
      )
    assert_equal key1, key2
  end

  def test_kwarg_batched_key_differs_by_non_batch_kwarg
    key1 =
      KwargBatchedActiveJob.zizq_batch_key(device_ids: ["a"], platform: "apple")
    key2 =
      KwargBatchedActiveJob.zizq_batch_key(
        device_ids: ["a"],
        platform: "android"
      )
    refute_equal key1, key2
  end

  # --- Batched jobs: dedup / sorted ---

  class DedupBatchedActiveJob < ActiveJob::Base
    extend Zizq::ActiveJobConfig
    self.queue_name = "q"
    zizq_batched true, limit: 100, dedup: true
    def perform(items) = nil
  end

  def test_dedup_batched_uses_unique_in_fold
    expr = DedupBatchedActiveJob.zizq_batch_expressions
    assert_equal(
      "$existing | .arguments[0] = " \
        "(.arguments[0] + $new.arguments[0] | unique)",
      expr[:fold]
    )
  end

  # --- Adapter round-trip: batch config on the wire ---

  def test_adapter_populates_batch_config
    job = PositionalBatchedActiveJob.new([1], tenant_id: 42)
    req = adapter_request(job)
    refute_nil req.batch
    assert(
      req.batch[:key].start_with?("TestActiveJob::PositionalBatchedActiveJob:")
    )
    assert_equal(
      "($existing.arguments[0] + $new.arguments[0]) | length <= 100",
      req.batch[:when]
    )
    assert_equal(
      "$existing | .arguments[0] += $new.arguments[0]",
      req.batch[:fold]
    )
  end

  # Direct kwarg targets rely on Ruby's ruby2_keywords marker on
  # `job.arguments` to forward the kwargs hash correctly through
  # `*splat` — no manual reconstitution needed in the adapter.
  def test_adapter_batch_key_stable_for_kwarg_target
    job1 = KwargBatchedActiveJob.new(device_ids: ["a"], platform: "apple")
    job2 = KwargBatchedActiveJob.new(device_ids: %w[b c], platform: "apple")
    key1 = adapter_request(job1).batch[:key]
    key2 = adapter_request(job2).batch[:key]
    assert_equal key1, key2, "batch key should ignore the batched kwarg"

    job3 = KwargBatchedActiveJob.new(device_ids: ["a"], platform: "android")
    key3 = adapter_request(job3).batch[:key]
    refute_equal key1, key3, "different non-batch kwargs → different key"
  end

  # --- Cross-check unique/batch mutual exclusion applies to AJ too ---

  def test_activejob_rejects_batched_after_unique
    assert_raises(ArgumentError) do
      Class.new(ActiveJob::Base) do
        extend Zizq::ActiveJobConfig
        zizq_unique true
        zizq_batched true, limit: 100
      end
    end
  end

  # --- zizq_payload_filter ---

  def test_payload_filter_exact_match
    filter = ExtendedActiveJob.zizq_payload_filter(42, template: "welcome")
    # ActiveJob serializes kwargs with _aj_ruby2_keywords marker.
    # The filter targets .arguments, not the full serialized payload.
    expected_args =
      ExtendedActiveJob.zizq_serialize(42, template: "welcome")["arguments"]
    assert_equal ".arguments == #{JSON.generate(expected_args)}", filter
  end

  # --- zizq_payload_subset_filter ---

  def test_payload_subset_filter_args_only
    filter = ExtendedActiveJob.zizq_payload_subset_filter(42)
    assert_equal "(.arguments[0:1] == [42])", filter
  end

  def test_payload_subset_filter_kwargs_only
    filter = ExtendedActiveJob.zizq_payload_subset_filter(template: "welcome")
    assert_equal(
      "(.arguments[0:0] == []) and " \
        '(.arguments[-1] | has("_aj_ruby2_keywords")) and ' \
        '(.arguments[-1] | contains({"template":"welcome"}))',
      filter
    )
  end

  def test_payload_subset_filter_args_and_kwargs
    filter =
      ExtendedActiveJob.zizq_payload_subset_filter(42, template: "welcome")
    assert_equal(
      "(.arguments[0:1] == [42]) and " \
        '(.arguments[-1] | has("_aj_ruby2_keywords")) and ' \
        '(.arguments[-1] | contains({"template":"welcome"}))',
      filter
    )
  end

  def test_payload_subset_filter_no_args
    filter = ExtendedActiveJob.zizq_payload_subset_filter
    assert_equal "(.arguments[0:0] == [])", filter
  end

  # --- enqueue_all (perform_all_later) ---

  def test_enqueue_all_builds_bulk_params
    adapter = ActiveJob::QueueAdapters::ZizqAdapter.new
    jobs = [
      PlainActiveJob.new(1, template: "a"),
      ExtendedActiveJob.new(2, template: "b")
    ]

    requests = jobs.map { |j| adapter.send(:build_enqueue_request, j) }

    assert_equal "PlainActiveJob", requests[0].type
    assert_equal "default", requests[0].queue

    assert_equal "ExtendedActiveJob", requests[1].type
    assert_equal "emails", requests[1].queue
    assert requests[1].unique_key.start_with?("ExtendedActiveJob:")
  end

  def test_enqueue_all_round_trips_through_dispatcher
    adapter = ActiveJob::QueueAdapters::ZizqAdapter.new
    jobs = [
      PlainActiveJob.new(1, template: "a"),
      PlainActiveJob.new(2, template: "b")
    ]

    requests = jobs.map { |j| adapter.send(:build_enqueue_request, j) }
    requests.each { |req| dispatch(req) }

    assert_equal 2, PlainActiveJob.executions.size
    assert_equal 1, PlainActiveJob.executions[0][:user_id]
    assert_equal 2, PlainActiveJob.executions[1][:user_id]
  end

  # --- Zizq.enqueue with ActiveJob classes ---

  def test_enqueue_active_job_class
    stub_request(:post, "#{URL}/jobs")
      .with do |req|
        body = JSON.parse(req.body)
        body["type"] == "ExtendedActiveJob" && body["queue"] == "emails" &&
          body["payload"].is_a?(Hash) &&
          body["payload"]["job_class"] == "ExtendedActiveJob" &&
          body["payload"]["arguments"] ==
            [
              42,
              { "template" => "welcome", "_aj_ruby2_keywords" => ["template"] }
            ]
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    result = Zizq.enqueue(ExtendedActiveJob, 42, template: "welcome")
    assert_equal "x", result.id
  end

  def test_enqueue_active_job_uses_class_queue
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["queue"] == "emails" }
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    Zizq.enqueue(ExtendedActiveJob, 42, template: "welcome")
  end

  def test_enqueue_active_job_includes_unique_key
    stub_request(:post, "#{URL}/jobs")
      .with do |req|
        body = JSON.parse(req.body)
        body["unique_key"].is_a?(String) && body["unique_while"] == "active"
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    Zizq.enqueue(ExtendedActiveJob, 42, template: "welcome")
  end

  def test_enqueue_active_job_with_block_override
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["priority"] == 0 }
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    Zizq.enqueue(ExtendedActiveJob, 42, template: "welcome") do |o|
      o.priority = 0
    end
  end

  def test_enqueue_rejects_non_job_config_class
    assert_raises(ArgumentError) { Zizq.enqueue(String) }
  end
end
