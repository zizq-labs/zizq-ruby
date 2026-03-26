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

class TestActiveJob < Minitest::Test
  URL = "http://localhost:7890"

  def setup
    PlainActiveJob.executions = []
    ExtendedActiveJob.executions = []
    UniqueNoScopeActiveJob.executions = []
  end

  # Build the params hash that the adapter would send to enqueue_raw,
  # without making any HTTP calls.
  def adapter_params(job)
    ActiveJob::QueueAdapters::ZizqAdapter.new.send(:enqueue_params, job)
  end

  # Simulate the dispatch side: build a Resources::Job from adapter
  # params and run it through the Dispatcher.
  def dispatch(params)
    client = Zizq::Client.new(url: URL, format: :json)
    resource_job = Zizq::Resources::Job.new(client, {
      "id" => "j1",
      "type" => params[:type],
      "queue" => params[:queue],
      "payload" => params[:payload],
      "attempts" => 0
    })
    ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher.dispatch(resource_job)
  end

  # --- Round-trip tests ---

  def test_plain_job_round_trips
    job = PlainActiveJob.new(42, template: "welcome")
    params = adapter_params(job)
    dispatch(params)

    assert_equal 1, PlainActiveJob.executions.size
    assert_equal({ user_id: 42, template: "welcome" }, PlainActiveJob.executions.first)
  end

  def test_extended_job_round_trips
    job = ExtendedActiveJob.new(42, template: "welcome")
    params = adapter_params(job)
    dispatch(params)

    assert_equal 1, ExtendedActiveJob.executions.size
    assert_equal({ user_id: 42, template: "welcome" }, ExtendedActiveJob.executions.first)
  end

  # --- Plain adapter params (no Zizq extensions) ---

  def test_plain_params_include_type_and_queue
    params = adapter_params(PlainActiveJob.new(42, template: "welcome"))

    assert_equal "PlainActiveJob", params[:type]
    assert_equal "default", params[:queue]
  end

  def test_plain_params_include_activejob_payload
    params = adapter_params(PlainActiveJob.new(42, template: "welcome"))

    assert_equal "PlainActiveJob", params[:payload]["job_class"]
    assert params[:payload]["arguments"].is_a?(Array)
  end

  def test_plain_params_omit_unique_fields
    params = adapter_params(PlainActiveJob.new(42, template: "welcome"))

    refute params.key?(:unique_key)
    refute params.key?(:unique_while)
  end

  def test_plain_params_omit_backoff_and_retention
    params = adapter_params(PlainActiveJob.new(42, template: "welcome"))

    refute params.key?(:backoff)
    refute params.key?(:retention)
    refute params.key?(:retry_limit)
  end

  # --- Extended adapter params (with Zizq extensions) ---

  def test_extended_params_include_unique_key_and_scope
    params = adapter_params(ExtendedActiveJob.new(42, template: "welcome"))

    assert params[:unique_key].start_with?("ExtendedActiveJob:")
    assert_equal :active, params[:unique_while]
  end

  def test_extended_params_include_backoff
    params = adapter_params(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal({
      exponent: 3.0,
      base_ms: 10_000.0,
      jitter_ms: 5_000.0
    }, params[:backoff])
  end

  def test_extended_params_include_retention
    params = adapter_params(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal({ completed_ms: 0, dead_ms: 86_400_000 }, params[:retention])
  end

  def test_extended_params_include_retry_limit
    params = adapter_params(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal 5, params[:retry_limit]
  end

  def test_extended_params_use_activejob_queue_name
    params = adapter_params(ExtendedActiveJob.new(42, template: "welcome"))

    assert_equal "emails", params[:queue]
  end

  # --- Unique without explicit scope ---

  def test_unique_no_scope_includes_key_but_not_while
    params = adapter_params(UniqueNoScopeActiveJob.new(42))

    assert params[:unique_key].is_a?(String)
    refute params.key?(:unique_while)
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
    params = adapter_params(job)
    direct_key = ExtendedActiveJob.zizq_unique_key(42, template: "welcome")

    assert_equal direct_key, params[:unique_key]
  end

  # --- enqueue_all (perform_all_later) ---

  def test_enqueue_all_builds_bulk_params
    adapter = ActiveJob::QueueAdapters::ZizqAdapter.new
    jobs = [
      PlainActiveJob.new(1, template: "a"),
      ExtendedActiveJob.new(2, template: "b"),
    ]

    # Collect the params that would be sent to enqueue_bulk.
    all_params = jobs.map { |j| adapter.send(:enqueue_params, j) }

    assert_equal "PlainActiveJob", all_params[0][:type]
    assert_equal "default", all_params[0][:queue]

    assert_equal "ExtendedActiveJob", all_params[1][:type]
    assert_equal "emails", all_params[1][:queue]
    assert all_params[1][:unique_key].start_with?("ExtendedActiveJob:")
  end

  def test_enqueue_all_round_trips_through_dispatcher
    adapter = ActiveJob::QueueAdapters::ZizqAdapter.new
    jobs = [
      PlainActiveJob.new(1, template: "a"),
      PlainActiveJob.new(2, template: "b"),
    ]

    all_params = jobs.map { |j| adapter.send(:enqueue_params, j) }

    all_params.each { |params| dispatch(params) }

    assert_equal 2, PlainActiveJob.executions.size
    assert_equal 1, PlainActiveJob.executions[0][:user_id]
    assert_equal 2, PlainActiveJob.executions[1][:user_id]
  end
end
