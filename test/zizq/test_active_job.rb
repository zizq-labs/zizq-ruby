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
  class << self; attr_accessor :executions; end

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

  @executions = []
  class << self; attr_accessor :executions; end

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
  class << self; attr_accessor :executions; end

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
    resource_job = Zizq::Resources::Job.new(client, {
      "id" => "j1",
      "type" => req.type,
      "queue" => req.queue,
      "payload" => req.payload,
      "attempts" => 0
    })
    ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher.call(resource_job)
    client.close
  end

  # --- Round-trip tests ---

  def test_plain_job_round_trips
    job = PlainActiveJob.new(42, template: "welcome")
    params = adapter_request(job)
    dispatch(params)

    assert_equal 1, PlainActiveJob.executions.size
    assert_equal({ user_id: 42, template: "welcome" }, PlainActiveJob.executions.first)
  end

  def test_extended_job_round_trips
    job = ExtendedActiveJob.new(42, template: "welcome")
    params = adapter_request(job)
    dispatch(params)

    assert_equal 1, ExtendedActiveJob.executions.size
    assert_equal({ user_id: 42, template: "welcome" }, ExtendedActiveJob.executions.first)
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
    assert key.start_with?("ExtendedActiveJob:"), "expected class name prefix, got: #{key}"
  end

  # --- Unique key matches between adapter and class method ---

  def test_adapter_unique_key_matches_class_method
    job = ExtendedActiveJob.new(42, template: "welcome")
    params = adapter_request(job)
    direct_key = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")

    assert_equal direct_key, params.unique_key
  end

  # --- zizq_payload_filter ---

  def test_payload_filter_exact_match
    filter = ExtendedActiveJob.zizq_payload_filter(42, template: "welcome")
    # ActiveJob serializes kwargs with _aj_ruby2_keywords marker.
    expected_payload = ExtendedActiveJob.zizq_serialize(42, template: "welcome")
    assert_equal ".arguments == #{JSON.generate(expected_payload)}", filter
  end

  # --- zizq_payload_subset_filter ---

  def test_payload_subset_filter_args_only
    filter = ExtendedActiveJob.zizq_payload_subset_filter(42)
    assert_equal '(.arguments[0:1] == [42])', filter
  end

  def test_payload_subset_filter_kwargs_only
    filter = ExtendedActiveJob.zizq_payload_subset_filter(template: "welcome")
    assert_equal(
      '(.arguments[0:0] == []) and ' \
      '(.arguments[-1] | has("_aj_ruby2_keywords")) and ' \
      '(.arguments[-1] | contains({"template":"welcome"}))',
      filter
    )
  end

  def test_payload_subset_filter_args_and_kwargs
    filter = ExtendedActiveJob.zizq_payload_subset_filter(42, template: "welcome")
    assert_equal(
      '(.arguments[0:1] == [42]) and ' \
      '(.arguments[-1] | has("_aj_ruby2_keywords")) and ' \
      '(.arguments[-1] | contains({"template":"welcome"}))',
      filter
    )
  end

  def test_payload_subset_filter_no_args
    filter = ExtendedActiveJob.zizq_payload_subset_filter
    assert_equal '(.arguments[0:0] == [])', filter
  end

  # --- enqueue_all (perform_all_later) ---

  def test_enqueue_all_builds_bulk_params
    adapter = ActiveJob::QueueAdapters::ZizqAdapter.new
    jobs = [
      PlainActiveJob.new(1, template: "a"),
      ExtendedActiveJob.new(2, template: "b"),
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
      PlainActiveJob.new(2, template: "b"),
    ]

    requests = jobs.map { |j| adapter.send(:build_enqueue_request, j) }
    requests.each { |req| dispatch(req) }

    assert_equal 2, PlainActiveJob.executions.size
    assert_equal 1, PlainActiveJob.executions[0][:user_id]
    assert_equal 2, PlainActiveJob.executions[1][:user_id]
  end
end
