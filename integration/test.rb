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

ZIZQ_URL = ENV.fetch("ZIZQ_URL") do
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

class IntegrationTest < Minitest::Test
  def setup
    Zizq.configure do |c|
      c.url = ZIZQ_URL
      c.format = :json
      c.logger = Logger.new(File::NULL)
    end

    Zizq.client.delete_all_jobs
    IntegrationTestJob.mock_perform = nil
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

  def test_enqueue_raw
    job = Zizq.enqueue_raw(
      queue: "integration",
      type: "raw_test",
      payload: { hello: "world" },
    )

    assert job.id
    assert_equal "raw_test", job.type

    fetched = Zizq.client.get_job(job.id)
    assert_equal({ "hello" => "world" }, fetched.payload)
  end

  def test_enqueue_bulk
    jobs = Zizq.enqueue_bulk do |b|
      b.enqueue(IntegrationTestJob, 1)
      b.enqueue(IntegrationTestJob, 2)
      b.enqueue(IntegrationTestJob, 3)
    end

    assert_equal 3, jobs.length
    assert_equal IntegrationTestJob.name, jobs[0].type
  end

  def test_enqueue_bulk_raw
    jobs = Zizq.enqueue_bulk do |b|
      b.enqueue_raw(queue: "integration", type: "bulk_raw_a", payload: { n: 1 })
      b.enqueue_raw(queue: "integration", type: "bulk_raw_b", payload: { n: 2 })
    end

    assert_equal 2, jobs.length
    assert_equal "bulk_raw_a", jobs[0].type
    assert_equal "bulk_raw_b", jobs[1].type
  end

  def test_worker_round_trip
    count = 10

    Zizq.enqueue_bulk do |b|
      count.times { |i| b.enqueue(IntegrationTestJob, i+1) }
    end

    worker = Zizq::Worker.new(
      thread_count: 1,
      fiber_count: 1,
      queues: ["worker-integration"],
    )

    received = []

    IntegrationTestJob.mock_perform = ->(n) do
      received << n
      worker.stop if n >= count
    end

    worker.run

    assert_equal count, received.length
    assert_equal (1..count).to_a, received.sort
  end

  def test_query_jobs
    job = Zizq.enqueue_raw(
      queue: "query-integration",
      type: "query_test",
      payload: { marker: "findme" },
    )

    found = Zizq.query
      .by_queue("query-integration")
      .by_type("query_test")
      .first

    assert found
    assert_equal job.id, found.id
  end

  def test_delete_job
    job = Zizq.enqueue_raw(
      queue: "delete-integration",
      type: "delete_test",
      payload: {},
    )

    Zizq.client.delete_job(job.id)

    assert_raises(Zizq::NotFoundError) do
      Zizq.client.get_job(job.id)
    end
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

  def test_delete_all_jobs
    Zizq.enqueue_bulk do |b|
      3.times { b.enqueue_raw(queue: "integration", type: "x", payload: {}) }
    end

    assert_equal 3, Zizq.query.count

    deleted = Zizq.client.delete_all_jobs(where: { queue: "integration" })
    assert_equal 3, deleted
    assert_equal 0, Zizq.query.count
  end
end
