# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class TestClient < ZizqTestCase
  def setup
    super
    @json_client = Zizq::Client.new(url: URL, format: :json)
    @msgpack_client = Zizq::Client.new(url: URL, format: :msgpack)
  end

  def teardown
    @json_client.close
    @msgpack_client.close
  end

  # --- enqueue ---

  def test_enqueue_json
    job_response = {
      "id" => "abc123",
      "type" => "SendEmail",
      "queue" => "emails",
      "priority" => 32_768,
      "status" => "ready",
      "ready_at" => 1000,
      "attempts" => 0
    }

    stub_request(:post, "#{URL}/jobs").with(
      body:
        JSON.generate(
          { queue: "emails", type: "SendEmail", payload: { user_id: 42 } }
        ),
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    ).to_return(
      status: 201,
      body: JSON.generate(job_response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.enqueue(
        queue: "emails",
        type: "SendEmail",
        payload: {
          user_id: 42
        }
      )
    assert_instance_of Zizq::Resources::Job, result
    assert_equal "abc123", result.id
    assert_equal "SendEmail", result.type
  end

  # Durations are fractional seconds at every public entry point; the
  # conversion to the integer milliseconds the server wants happens
  # here, at the wire boundary.
  def test_enqueue_converts_backoff_and_retention_to_ms
    stub_request(:post, "#{URL}/jobs")
      .with do |req|
        body = JSON.parse(req.body)
        # exponent stays a float — it's a ratio, not a duration.
        body["backoff"] ==
          { "exponent" => 2.0, "base_ms" => 1500, "jitter_ms" => 250 } &&
          body["retention"] ==
            { "completed_ms" => 60_000, "dead_ms" => 3_600_000 }
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "abc123" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue(
      queue: "emails",
      type: "SendEmail",
      payload: {
      },
      backoff: {
        exponent: 2.0,
        base: 1.5,
        jitter: 0.25
      },
      retention: {
        completed: 60.0,
        dead: 3600.0
      }
    )
  end

  # An absent retention field stays absent rather than being sent as
  # zero, which would tell the server to discard immediately.
  def test_enqueue_omits_unset_retention_fields
    stub_request(:post, "#{URL}/jobs")
      .with do |req|
        JSON.parse(req.body)["retention"] == { "dead_ms" => 90_000 }
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "abc123" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue(
      queue: "emails",
      type: "SendEmail",
      payload: {
      },
      retention: {
        dead: 90.0
      }
    )
  end

  # The bulk path builds each job's body separately, so it converts
  # separately too.
  def test_enqueue_bulk_converts_backoff_and_retention_to_ms
    stub_request(:post, "#{URL}/jobs/bulk")
      .with do |req|
        job = JSON.parse(req.body)["jobs"].first
        job["backoff"] ==
          { "exponent" => 2.0, "base_ms" => 1500, "jitter_ms" => 250 } &&
          job["retention"] == { "completed_ms" => 60_000 }
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "jobs" => [{ "id" => "abc123" }] }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue_bulk(
      jobs: [
        {
          queue: "emails",
          type: "SendEmail",
          payload: {
          },
          backoff: {
            exponent: 2.0,
            base: 1.5,
            jitter: 0.25
          },
          retention: {
            completed: 60.0
          }
        }
      ]
    )
  end

  # A cron entry's job template goes through the same boundary.
  def test_put_cron_group_converts_backoff_in_the_job_template
    stub_request(:put, "#{URL}/crons/nightly")
      .with do |req|
        job = JSON.parse(req.body)["entries"].first["job"]
        job["backoff"] ==
          { "exponent" => 2.0, "base_ms" => 1500, "jitter_ms" => 250 }
      end
      .to_return(
        status: 200,
        body: JSON.generate({ "name" => "nightly", "entries" => [] }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.replace_cron_group(
      "nightly",
      entries: [
        {
          name: "digest",
          expression: "0 9 * * *",
          job: {
            queue: "emails",
            type: "Digest",
            payload: {
            },
            backoff: {
              exponent: 2.0,
              base: 1.5,
              jitter: 0.25
            }
          }
        }
      ]
    )
  end

  def test_enqueue_msgpack
    job_response = {
      "id" => "abc123",
      "type" => "SendEmail",
      "queue" => "emails",
      "priority" => 32_768,
      "status" => "ready",
      "ready_at" => 1000,
      "attempts" => 0
    }

    stub_request(:post, "#{URL}/jobs").with(
      body:
        MessagePack.pack(
          { queue: "emails", type: "SendEmail", payload: { user_id: 42 } }
        ),
      headers: {
        "Content-Type" => "application/msgpack",
        "Accept" => "application/msgpack"
      }
    ).to_return(
      status: 201,
      body: MessagePack.pack(job_response),
      headers: {
        "Content-Type" => "application/msgpack"
      }
    )

    result =
      @msgpack_client.enqueue(
        queue: "emails",
        type: "SendEmail",
        payload: {
          user_id: 42
        }
      )
    assert_instance_of Zizq::Resources::Job, result
    assert_equal "abc123", result.id
  end

  def test_enqueue_with_priority
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["priority"] == 100 }
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue(type: "Job", queue: "q", payload: {}, priority: 100)
  end

  def test_enqueue_with_ready_at
    stub_request(:post, "#{URL}/jobs")
      .with { |req| JSON.parse(req.body)["ready_at"] == 9_999_000 }
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    # 9999.0 seconds → 9_999_000 ms on the wire
    @json_client.enqueue(type: "Job", queue: "q", payload: {}, ready_at: 9999.0)
  end

  def test_enqueue_with_time_ready_at
    now = Time.now
    ready_at = now + 60

    stub_request(:post, "#{URL}/jobs")
      .with do |req|
        JSON.parse(req.body)["ready_at"] == (ready_at.to_f * 1000).to_i
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue(
      type: "Job",
      queue: "q",
      payload: {
      },
      ready_at: ready_at
    )
  end

  def test_enqueue_400_raises_client_error
    stub_request(:post, "#{URL}/jobs").to_return(
      status: 400,
      body: JSON.generate({ "error" => "queue is required" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    err =
      assert_raises(Zizq::ClientError) do
        @json_client.enqueue(type: "", queue: "", payload: {})
      end
    assert_equal 400, err.status
    assert_equal "queue is required", err.message
  end

  # --- enqueue_bulk ---

  def test_enqueue_bulk_json
    jobs_response = {
      "jobs" => [
        {
          "id" => "j1",
          "type" => "SendEmail",
          "queue" => "emails",
          "status" => "ready"
        },
        {
          "id" => "j2",
          "type" => "ProcessOrder",
          "queue" => "orders",
          "status" => "ready"
        }
      ]
    }

    stub_request(:post, "#{URL}/jobs/bulk").with(
      body:
        JSON.generate(
          {
            jobs: [
              { type: "SendEmail", queue: "emails", payload: { user_id: 42 } },
              {
                type: "ProcessOrder",
                queue: "orders",
                payload: {
                  order_id: 7
                }
              }
            ]
          }
        ),
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    ).to_return(
      status: 201,
      body: JSON.generate(jobs_response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.enqueue_bulk(
        jobs: [
          { type: "SendEmail", queue: "emails", payload: { user_id: 42 } },
          { type: "ProcessOrder", queue: "orders", payload: { order_id: 7 } }
        ]
      )
    assert_instance_of Array, result
    assert_equal 2, result.size
    assert_instance_of Zizq::Resources::Job, result[0]
    assert_equal "j1", result[0].id
    assert_equal "j2", result[1].id
  end

  def test_enqueue_bulk_msgpack
    jobs_response = {
      "jobs" => [
        {
          "id" => "j1",
          "type" => "SendEmail",
          "queue" => "emails",
          "status" => "ready"
        }
      ]
    }

    stub_request(:post, "#{URL}/jobs/bulk").with(
      body:
        MessagePack.pack(
          {
            jobs: [
              { type: "SendEmail", queue: "emails", payload: { user_id: 42 } }
            ]
          }
        ),
      headers: {
        "Content-Type" => "application/msgpack",
        "Accept" => "application/msgpack"
      }
    ).to_return(
      status: 201,
      body: MessagePack.pack(jobs_response),
      headers: {
        "Content-Type" => "application/msgpack"
      }
    )

    result =
      @msgpack_client.enqueue_bulk(
        jobs: [{ type: "SendEmail", queue: "emails", payload: { user_id: 42 } }]
      )
    assert_instance_of Array, result
    assert_equal 1, result.size
    assert_instance_of Zizq::Resources::Job, result[0]
    assert_equal "j1", result[0].id
  end

  def test_enqueue_bulk_400_raises_client_error
    stub_request(:post, "#{URL}/jobs/bulk").to_return(
      status: 400,
      body: JSON.generate({ "error" => "invalid job type" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    err =
      assert_raises(Zizq::ClientError) do
        @json_client.enqueue_bulk(jobs: [{ type: "", queue: "", payload: {} }])
      end
    assert_equal 400, err.status
    assert_equal "invalid job type", err.message
  end

  def test_enqueue_bulk_converts_ready_at_to_ms
    stub_request(:post, "#{URL}/jobs/bulk")
      .with do |req|
        body = JSON.parse(req.body)
        body["jobs"][0]["ready_at"] == 9_999_000
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "jobs" => [{ "id" => "x" }] }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue_bulk(
      jobs: [{ type: "Job", queue: "q", payload: {}, ready_at: 9999.0 }]
    )
  end

  # --- batch (folded jobs) ---

  def test_enqueue_with_batch_sends_batch_field
    stub_request(:post, "#{URL}/jobs")
      .with do |req|
        body = JSON.parse(req.body)
        body["batch"] ==
          { "key" => "audit", "when" => "true", "fold" => "$existing + $new" }
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "id" => "x", "folded" => false }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    result =
      @json_client.enqueue(
        type: "Audit",
        queue: "q",
        payload: [1],
        batch: {
          key: "audit",
          when: "true",
          fold: "$existing + $new"
        }
      )
    refute result.folded?
  end

  def test_enqueue_folded_response_sets_folded_flag
    stub_request(:post, "#{URL}/jobs").to_return(
      status: 200,
      body: JSON.generate({ "id" => "x", "folded" => true }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.enqueue(type: "Audit", queue: "q", payload: [1])
    assert result.folded?
  end

  def test_enqueue_response_batch_config_exposed_via_resource
    stub_request(:post, "#{URL}/jobs").to_return(
      status: 200,
      body:
        JSON.generate(
          {
            "id" => "x",
            "batch" => {
              "key" => "audit",
              "when" => "true",
              "fold" => "$existing + $new"
            }
          }
        ),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.enqueue(type: "Audit", queue: "q", payload: [1])
    assert_equal(
      { key: "audit", when: "true", fold: "$existing + $new" },
      result.batch
    )
  end

  def test_enqueue_bulk_with_batch_sends_batch_per_job
    stub_request(:post, "#{URL}/jobs/bulk")
      .with do |req|
        body = JSON.parse(req.body)
        body["jobs"][0]["batch"] ==
          { "key" => "audit", "when" => "true", "fold" => "$existing + $new" }
      end
      .to_return(
        status: 201,
        body: JSON.generate({ "jobs" => [{ "id" => "x" }] }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.enqueue_bulk(
      jobs: [
        {
          type: "Audit",
          queue: "q",
          payload: [1],
          batch: {
            key: "audit",
            when: "true",
            fold: "$existing + $new"
          }
        }
      ]
    )
  end

  # --- get_job ---

  def test_get_job
    job = {
      "id" => "job1",
      "type" => "Foo",
      "queue" => "default",
      "priority" => 32_768,
      "status" => "ready",
      "ready_at" => 1000,
      "attempts" => 0,
      "payload" => {
        "key" => "value"
      }
    }

    stub_request(:get, "#{URL}/jobs/job1").with(
      headers: {
        "Accept" => "application/json"
      }
    ).to_return(
      status: 200,
      body: JSON.generate(job),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_job("job1")
    assert_instance_of Zizq::Resources::Job, result
    assert_equal "job1", result.id
    assert_equal({ "key" => "value" }, result.payload)
  end

  def test_get_job_not_found
    stub_request(:get, "#{URL}/jobs/missing").to_return(
      status: 404,
      body: JSON.generate({ "error" => "not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) { @json_client.get_job("missing") }
  end

  # --- list_jobs ---

  def test_list_jobs_no_filters
    response = { "jobs" => [], "pages" => { "self" => "/jobs" } }

    stub_request(:get, "#{URL}/jobs").with(
      headers: {
        "Accept" => "application/json"
      }
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.list_jobs
    assert_instance_of Zizq::Resources::JobPage, result
    assert_equal [], result.jobs
  end

  def test_list_jobs_with_filters
    response = {
      "jobs" => [{ "id" => "j1" }],
      "pages" => {
        "self" => "/jobs"
      }
    }

    stub_request(
      :get,
      "#{URL}/jobs?status=ready,in_flight&queue=emails&limit=10"
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.list_jobs(
        status: %w[ready in_flight],
        queue: "emails",
        limit: 10
      )
    assert_equal 1, result.jobs.size
  end

  def test_list_jobs_with_id_filter
    response = {
      "jobs" => [{ "id" => "j1" }],
      "pages" => {
        "self" => "/jobs"
      }
    }

    stub_request(:get, "#{URL}/jobs?id=j1,j2").to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.list_jobs(id: %w[j1 j2])
    assert_equal 1, result.jobs.size
  end

  def test_list_jobs_with_payload_filter
    response = {
      "jobs" => [{ "id" => "j1" }],
      "pages" => {
        "self" => "/jobs"
      }
    }

    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "filter" => ".user_id == 42"
      }
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.list_jobs(filter: ".user_id == 42")
    assert_equal 1, result.jobs.size
  end

  def test_list_jobs_with_empty_array_short_circuits
    # No HTTP request should be made.
    result = @json_client.list_jobs(id: [])
    assert_instance_of Zizq::Resources::JobPage, result
    assert_equal [], result.jobs
    assert_equal false, result.has_next?
  end

  # --- range filters ---

  def test_list_jobs_with_priority_integer
    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "priority" => "50"
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "jobs" => [], "pages" => { "self" => "/jobs" } }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    @json_client.list_jobs(priority: 50)
  end

  def test_list_jobs_with_priority_inclusive_range
    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "priority" => "0..100"
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "jobs" => [], "pages" => { "self" => "/jobs" } }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    @json_client.list_jobs(priority: 0..100)
  end

  def test_list_jobs_with_priority_endless_range
    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "priority" => "100.."
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "jobs" => [], "pages" => { "self" => "/jobs" } }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    @json_client.list_jobs(priority: 100..)
  end

  def test_list_jobs_with_priority_beginless_range
    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "priority" => "..100"
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "jobs" => [], "pages" => { "self" => "/jobs" } }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    @json_client.list_jobs(priority: ..100)
  end

  def test_list_jobs_with_attempts_range
    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "attempts" => "1.."
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "jobs" => [], "pages" => { "self" => "/jobs" } }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    @json_client.list_jobs(attempts: 1..)
  end

  def test_list_jobs_with_ready_at_range_in_seconds_converts_to_ms
    # Times in Ruby are fractional seconds; the wire format is ms.
    t1 = Time.at(1_700_000_000)
    t2 = Time.at(1_800_000_000)
    stub_request(:get, "#{URL}/jobs").with(
      query: {
        "ready_at" => "1700000000000..1800000000000"
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "jobs" => [], "pages" => { "self" => "/jobs" } }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    @json_client.list_jobs(ready_at: t1..t2)
  end

  def test_list_jobs_rejects_exclusive_range
    assert_raises(ArgumentError) { @json_client.list_jobs(priority: 0...100) }
    assert_raises(ArgumentError) { @json_client.list_jobs(priority: 0...) }
    assert_raises(ArgumentError) { @json_client.list_jobs(priority: ...100) }
  end

  def test_count_jobs_with_range
    stub_request(:get, "#{URL}/jobs/count").with(
      query: {
        "priority" => "0..100"
      }
    ).to_return(
      status: 200,
      body: JSON.generate({ "count" => 3 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    assert_equal 3, @json_client.count_jobs(priority: 0..100)
  end

  def test_delete_all_jobs_with_range
    stub_request(:delete, "#{URL}/jobs?attempts=1..").to_return(
      status: 200,
      body: JSON.generate({ "deleted" => 5 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    assert_equal 5, @json_client.delete_all_jobs(where: { attempts: 1.. })
  end

  def test_update_all_jobs_with_range
    stub_request(:patch, "#{URL}/jobs?priority=200..").with(
      body: JSON.generate({ priority: 100 })
    ).to_return(
      status: 200,
      body: JSON.generate({ "patched" => 3 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    assert_equal 3,
                 @json_client.update_all_jobs(
                   where: {
                     priority: 200..
                   },
                   apply: {
                     priority: 100
                   }
                 )
  end

  # --- count_jobs ---

  def test_count_jobs_no_filters
    stub_request(:get, "#{URL}/jobs/count").to_return(
      status: 200,
      body: JSON.generate({ "count" => 42 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_equal 42, @json_client.count_jobs
  end

  def test_count_jobs_with_filters
    stub_request(:get, "#{URL}/jobs/count?queue=emails&status=ready").to_return(
      status: 200,
      body: JSON.generate({ "count" => 7 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_equal 7, @json_client.count_jobs(queue: "emails", status: "ready")
  end

  def test_count_jobs_empty_array_short_circuits
    count = @json_client.count_jobs(queue: [])
    assert_equal 0, count
  end

  # --- delete_job ---

  def test_delete_job
    stub_request(:delete, "#{URL}/jobs/j1").to_return(
      status: 204,
      body: "",
      headers: {
      }
    )

    assert_nil @json_client.delete_job("j1")
  end

  def test_delete_job_not_found
    stub_request(:delete, "#{URL}/jobs/j1").to_return(
      status: 404,
      body: JSON.generate({ "error" => "job not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) { @json_client.delete_job("j1") }
  end

  # --- delete_all_jobs ---

  def test_delete_all_jobs_with_filters
    stub_request(:delete, "#{URL}/jobs?queue=emails&status=dead").to_return(
      status: 200,
      body: JSON.generate({ "deleted" => 5 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    count =
      @json_client.delete_all_jobs(where: { queue: "emails", status: "dead" })
    assert_equal 5, count
  end

  def test_delete_all_jobs_no_filters
    stub_request(:delete, "#{URL}/jobs").to_return(
      status: 200,
      body: JSON.generate({ "deleted" => 10 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    count = @json_client.delete_all_jobs
    assert_equal 10, count
  end

  def test_delete_all_jobs_empty_array_short_circuits
    count = @json_client.delete_all_jobs(where: { id: [] })
    assert_equal 0, count
  end

  def test_erase_all_data
    stub_request(:post, "#{URL}/reset").to_return(
      status: 204,
      body: "",
      headers: {
      }
    )

    assert_nil @json_client.erase_all_data
  end

  def test_erase_all_data_raises_on_non_204
    stub_request(:post, "#{URL}/reset").to_return(
      status: 500,
      body: JSON.generate({ "error" => "boom" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::ServerError) { @json_client.erase_all_data }
  end

  def test_delete_all_jobs_rejects_unknown_filter
    assert_raises(ArgumentError) do
      @json_client.delete_all_jobs(where: { typo: "x" })
    end
  end

  # --- update_job ---

  def test_update_job
    response = { "id" => "j1", "queue" => "q2", "priority" => 10 }

    stub_request(:patch, "#{URL}/jobs/j1").with(
      body: JSON.generate({ queue: "q2", priority: 10 }),
      headers: {
        "Content-Type" => "application/json"
      }
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.update_job("j1", queue: "q2", priority: 10)
    assert_instance_of Zizq::Resources::Job, result
    assert_equal "q2", result.queue
  end

  def test_update_job_with_reset
    response = { "id" => "j1" }

    stub_request(:patch, "#{URL}/jobs/j1").with(
      body: JSON.generate({ retry_limit: nil })
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.update_job("j1", retry_limit: Zizq::RESET)
  end

  def test_update_job_omits_unchanged_fields
    response = { "id" => "j1", "priority" => 99 }

    stub_request(:patch, "#{URL}/jobs/j1").with(
      body: JSON.generate({ priority: 99 })
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.update_job("j1", priority: 99)
  end

  def test_update_job_rejects_nil_queue
    assert_raises(ArgumentError) { @json_client.update_job("j1", queue: nil) }
  end

  def test_update_job_rejects_nil_priority
    assert_raises(ArgumentError) do
      @json_client.update_job("j1", priority: nil)
    end
  end

  def test_update_job_converts_ready_at_to_ms
    response = { "id" => "j1" }

    stub_request(:patch, "#{URL}/jobs/j1").with(
      body: JSON.generate({ ready_at: 1_500_000_000_000 })
    ).to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.update_job("j1", ready_at: 1_500_000_000.0)
  end

  # --- update_all_jobs ---

  def test_update_all_jobs_with_filters
    stub_request(:patch, "#{URL}/jobs?queue=q1").with(
      body: JSON.generate({ queue: "q2" })
    ).to_return(
      status: 200,
      body: JSON.generate({ "patched" => 5 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    count =
      @json_client.update_all_jobs(
        where: {
          queue: "q1"
        },
        apply: {
          queue: "q2"
        }
      )
    assert_equal 5, count
  end

  def test_update_all_jobs_empty_id_short_circuits
    count =
      @json_client.update_all_jobs(where: { id: [] }, apply: { priority: 1 })
    assert_equal 0, count
  end

  def test_update_all_jobs_rejects_unknown_where_key
    assert_raises(ArgumentError) do
      @json_client.update_all_jobs(where: { typo: "x" }, apply: { priority: 1 })
    end
  end

  def test_update_all_jobs_rejects_unknown_set_key
    assert_raises(ArgumentError) do
      @json_client.update_all_jobs(where: {}, apply: { typo: 1 })
    end
  end

  # --- get_error ---

  def test_get_error
    response = {
      "attempt" => 2,
      "message" => "timeout",
      "error_type" => "Timeout::Error",
      "backtrace" => nil,
      "dequeued_at" => 1000,
      "failed_at" => 2000
    }

    stub_request(:get, "#{URL}/jobs/j1/errors/2").to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_error("j1", attempt: 2)
    assert_instance_of Zizq::Resources::ErrorRecord, result
    assert_equal 2, result.attempt
    assert_equal "timeout", result.message
    assert_equal "Timeout::Error", result.error_type
  end

  # --- list_errors ---

  def test_list_errors
    response = {
      "errors" => [
        { "attempt" => 1, "message" => "boom", "failed_at" => 2000 }
      ],
      "pages" => {
        "self" => "/jobs/j1/errors"
      }
    }

    stub_request(:get, "#{URL}/jobs/j1/errors").to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.list_errors("j1")
    assert_instance_of Zizq::Resources::ErrorPage, result
    assert_equal 1, result.errors.size
    assert_equal "boom", result.errors[0].message
  end

  def test_list_errors_with_options
    response = { "errors" => [], "pages" => { "self" => "/jobs/j1/errors" } }

    stub_request(:get, "#{URL}/jobs/j1/errors?order=desc&limit=5").to_return(
      status: 200,
      body: JSON.generate(response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.list_errors("j1", order: :desc, limit: 5)
  end

  # --- health ---

  def test_health
    stub_request(:get, "#{URL}/health").to_return(
      status: 200,
      body: JSON.generate({ "status" => "ok" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.health
    assert_equal "ok", result["status"]
  end

  # --- server_version ---

  def test_server_version
    stub_request(:get, "#{URL}/version").to_return(
      status: 200,
      body: JSON.generate({ "version" => "0.1.0" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_equal "0.1.0", @json_client.server_version
  end

  # --- get_queues ---

  def test_get_queues
    stub_request(:get, "#{URL}/queues").to_return(
      status: 200,
      body: JSON.generate({ "queues" => %w[emails payments] }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_queues
    assert_equal %w[emails payments], result
  end

  def test_get_queues_empty
    stub_request(:get, "#{URL}/queues").to_return(
      status: 200,
      body: JSON.generate({ "queues" => [] }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_queues
    assert_equal [], result
  end

  # --- report_success (ack) ---

  def test_report_success
    stub_request(:post, "#{URL}/jobs/job1/success").with(
      headers: {
        "Accept" => "application/json"
      }
    ).to_return(status: 204, body: "")

    result = @json_client.report_success("job1")
    assert_nil result
  end

  def test_ack_alias
    stub_request(:post, "#{URL}/jobs/job1/success").to_return(
      status: 204,
      body: ""
    )

    @json_client.ack("job1")
  end

  def test_report_success_404
    stub_request(:post, "#{URL}/jobs/missing/success").to_return(
      status: 404,
      body: JSON.generate({ "error" => "not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) do
      @json_client.report_success("missing")
    end
  end

  # --- report_success_bulk (bulk ack) ---

  def test_report_success_bulk
    stub_request(:post, "#{URL}/jobs/success").with(
      body: JSON.generate({ ids: %w[j1 j2] }),
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    ).to_return(status: 204, body: "")

    result = @json_client.report_success_bulk(%w[j1 j2])
    assert_nil result
  end

  def test_report_success_bulk_422_accepted
    stub_request(:post, "#{URL}/jobs/success").to_return(
      status: 422,
      body: JSON.generate({ "not_found" => ["j2"] }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.report_success_bulk(%w[j1 j2])
    assert_nil result
  end

  def test_report_success_bulk_500_raises
    stub_request(:post, "#{URL}/jobs/success").to_return(
      status: 500,
      body: JSON.generate({ "error" => "internal" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::ServerError) do
      @json_client.report_success_bulk(["j1"])
    end
  end

  def test_ack_bulk_alias
    stub_request(:post, "#{URL}/jobs/success").to_return(status: 204, body: "")

    result = @json_client.ack_bulk(["j1"])
    assert_nil result
  end

  def test_report_success_bulk_msgpack
    stub_request(:post, "#{URL}/jobs/success").with(
      body: MessagePack.pack({ ids: %w[j1 j2] }),
      headers: {
        "Content-Type" => "application/msgpack",
        "Accept" => "application/msgpack"
      }
    ).to_return(status: 204, body: "")

    result = @msgpack_client.report_success_bulk(%w[j1 j2])
    assert_nil result
  end

  # --- report_failure (nack) ---

  def test_report_failure
    updated_job = { "id" => "job1", "status" => "scheduled", "attempts" => 1 }

    stub_request(:post, "#{URL}/jobs/job1/failure")
      .with do |req|
        body = JSON.parse(req.body)
        body["message"] == "RuntimeError: boom" &&
          body["error_type"] == "RuntimeError" &&
          body["backtrace"] == "line1\nline2"
      end
      .to_return(
        status: 200,
        body: JSON.generate(updated_job),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    result =
      @json_client.report_failure(
        "job1",
        message: "RuntimeError: boom",
        error_type: "RuntimeError",
        backtrace: "line1\nline2"
      )
    assert_instance_of Zizq::Resources::Job, result
    assert_equal "scheduled", result.status
    assert_equal 1, result.attempts
  end

  def test_report_failure_with_kill
    stub_request(:post, "#{URL}/jobs/job1/failure")
      .with { |req| JSON.parse(req.body)["kill"] == true }
      .to_return(
        status: 200,
        body: JSON.generate({ "id" => "job1", "status" => "dead" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    result = @json_client.report_failure("job1", message: "fatal", kill: true)
    assert_equal "dead", result.status
  end

  def test_nack_alias
    stub_request(:post, "#{URL}/jobs/job1/failure").to_return(
      status: 200,
      body: JSON.generate({ "id" => "job1" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.nack("job1", message: "oops")
  end

  # --- error handling ---

  def test_500_raises_server_error
    stub_request(:get, "#{URL}/health").to_return(
      status: 500,
      body: JSON.generate({ "error" => "internal" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    err = assert_raises(Zizq::ServerError) { @json_client.health }
    assert_equal 500, err.status
  end

  # --- take (NDJSON streaming) ---

  def test_take_ndjson_yields_jobs
    job1 = { "id" => "j1", "type" => "Foo", "queue" => "default" }
    job2 = { "id" => "j2", "type" => "Bar", "queue" => "default" }
    body = "#{JSON.generate(job1)}\n\n#{JSON.generate(job2)}\n"

    stub_request(:get, "#{URL}/jobs/take?prefetch=5").with(
      headers: {
        "Accept" => "application/x-ndjson"
      }
    ).to_return(
      status: 200,
      body: body,
      headers: {
        "Content-Type" => "application/x-ndjson"
      }
    )

    jobs = []
    @json_client.take_jobs(prefetch: 5) { |job| jobs << job }
    assert_equal 2, jobs.size
    assert_instance_of Zizq::Resources::Job, jobs[0]
    assert_equal "j1", jobs[0].id
    assert_equal "j2", jobs[1].id
  end

  def test_take_ndjson_skips_heartbeats
    job1 = { "id" => "j1" }
    # Heartbeat lines are empty
    body = "\n\n#{JSON.generate(job1)}\n\n\n"

    stub_request(:get, "#{URL}/jobs/take?prefetch=1").to_return(
      status: 200,
      body: body,
      headers: {
        "Content-Type" => "application/x-ndjson"
      }
    )

    jobs = []
    @json_client.take_jobs(prefetch: 1) { |job| jobs << job }
    assert_equal 1, jobs.size
  end

  def test_take_with_queues
    stub_request(
      :get,
      "#{URL}/jobs/take?prefetch=1&queue=emails,webhooks"
    ).to_return(
      status: 200,
      body: "",
      headers: {
        "Content-Type" => "application/x-ndjson"
      }
    )

    @json_client.take_jobs(prefetch: 1, queues: %w[emails webhooks]) { |_| }
  end

  def test_take_with_worker_id
    stub_request(:get, "#{URL}/jobs/take?prefetch=1").with(
      headers: {
        "Worker-Id" => "myworker-1"
      }
    ).to_return(
      status: 200,
      body: "",
      headers: {
        "Content-Type" => "application/x-ndjson"
      }
    )

    @json_client.take_jobs(prefetch: 1, worker_id: "myworker-1") { |_| }
  end

  def test_take_requires_block
    assert_raises(ArgumentError) { @json_client.take_jobs(prefetch: 1) }
  end

  def test_take_on_connect_called_when_stream_opens
    body = "#{JSON.generate({ "id" => "j1" })}\n"

    stub_request(:get, "#{URL}/jobs/take?prefetch=1").to_return(
      status: 200,
      body: body,
      headers: {
        "Content-Type" => "application/x-ndjson"
      }
    )

    connected = false
    @json_client.take_jobs(
      prefetch: 1,
      on_connect: -> { connected = true }
    ) { |_| }
    assert connected, "on_connect should have been called"
  end

  def test_take_on_connect_called_for_empty_stream
    stub_request(:get, "#{URL}/jobs/take?prefetch=1").to_return(
      status: 200,
      body: "",
      headers: {
        "Content-Type" => "application/x-ndjson"
      }
    )

    connected = false
    @json_client.take_jobs(
      prefetch: 1,
      on_connect: -> { connected = true }
    ) { |_| }
    assert connected,
           "on_connect should fire when a 200 is received (server was reachable)"
  end

  # --- take (MsgPack streaming) ---

  def test_take_msgpack_yields_jobs
    job1 = { "id" => "j1", "type" => "Foo" }
    job2 = { "id" => "j2", "type" => "Bar" }
    packed1 = MessagePack.pack(job1)
    packed2 = MessagePack.pack(job2)

    body = +""
    body << [packed1.bytesize].pack("N") << packed1
    # Heartbeat (zero-length frame)
    body << [0].pack("N")
    body << [packed2.bytesize].pack("N") << packed2

    stub_request(:get, "#{URL}/jobs/take?prefetch=2").with(
      headers: {
        "Accept" => "application/vnd.zizq.msgpack-stream"
      }
    ).to_return(
      status: 200,
      body: body,
      headers: {
        "Content-Type" => "application/vnd.zizq.msgpack-stream"
      }
    )

    jobs = []
    @msgpack_client.take_jobs(prefetch: 2) { |job| jobs << job }
    assert_equal 2, jobs.size
    assert_instance_of Zizq::Resources::Job, jobs[0]
    assert_equal "j1", jobs[0].id
    assert_equal "j2", jobs[1].id
  end

  def test_take_msgpack_skips_heartbeats
    body = +""
    # Two heartbeats, no jobs
    body << [0].pack("N")
    body << [0].pack("N")

    stub_request(:get, "#{URL}/jobs/take?prefetch=1").to_return(
      status: 200,
      body: body,
      headers: {
        "Content-Type" => "application/vnd.zizq.msgpack-stream"
      }
    )

    jobs = []
    @msgpack_client.take_jobs(prefetch: 1) { |job| jobs << job }
    assert_equal 0, jobs.size
  end

  # --- parser unit tests (class methods) ---

  def test_parse_ndjson_single_chunk
    job1 = { "id" => "j1" }
    job2 = { "id" => "j2" }
    chunks = ["#{JSON.generate(job1)}\n\n#{JSON.generate(job2)}\n"]

    jobs = []
    Zizq::Client.parse_ndjson(chunks) { |job| jobs << job }
    assert_equal 2, jobs.size
    assert_equal "j1", jobs[0]["id"]
    assert_equal "j2", jobs[1]["id"]
  end

  def test_parse_ndjson_split_across_chunks
    # Simulate a line split mid-JSON across two chunks
    full_line = JSON.generate({ "id" => "j1" })
    chunk1 = full_line[0, 5]
    chunk2 = "#{full_line[5..]}\n"

    jobs = []
    Zizq::Client.parse_ndjson([chunk1, chunk2]) { |job| jobs << job }
    assert_equal 1, jobs.size
    assert_equal "j1", jobs[0]["id"]
  end

  def test_parse_ndjson_skips_blank_lines
    jobs = []
    Zizq::Client.parse_ndjson(["\n\n\n"]) { |job| jobs << job }
    assert_equal 0, jobs.size
  end

  def test_parse_msgpack_stream_single_chunk
    job1 = { "id" => "j1" }
    job2 = { "id" => "j2" }
    packed1 = MessagePack.pack(job1)
    packed2 = MessagePack.pack(job2)

    data = +""
    data << [packed1.bytesize].pack("N") << packed1
    data << [0].pack("N") # heartbeat
    data << [packed2.bytesize].pack("N") << packed2

    jobs = []
    Zizq::Client.parse_msgpack_stream([data]) { |job| jobs << job }
    assert_equal 2, jobs.size
    assert_equal "j1", jobs[0]["id"]
    assert_equal "j2", jobs[1]["id"]
  end

  def test_parse_msgpack_stream_split_across_chunks
    packed = MessagePack.pack({ "id" => "j1" })
    header = [packed.bytesize].pack("N")

    # Split the frame across two chunks: header in first, payload in second
    jobs = []
    Zizq::Client.parse_msgpack_stream([header, packed]) { |job| jobs << job }
    assert_equal 1, jobs.size
    assert_equal "j1", jobs[0]["id"]
  end

  def test_parse_msgpack_stream_heartbeats_only
    data = +""
    data << [0].pack("N")
    data << [0].pack("N")

    jobs = []
    Zizq::Client.parse_msgpack_stream([data]) { |job| jobs << job }
    assert_equal 0, jobs.size
  end

  # --- url normalization ---

  def test_trailing_slash_stripped
    client = Zizq::Client.new(url: "http://localhost:7890/", format: :json)
    assert_equal "http://localhost:7890", client.url
  ensure
    client&.close
  end

  # --- close ---

  def test_close
    # Do this a lot to make sure we're not leaking anything.
    200.times do
      client = Zizq::Client.new(url: URL, format: :json)
      stub_request(:get, "#{URL}/health").to_return(
        status: 200,
        body: JSON.generate({ "status" => "ok" }),
        headers: {
          "Content-Type" => "application/json"
        }
      )

      client.health
      client.close
    end
  end

  # --- Cron scheduling ---

  CRON_GROUP_RESPONSE = {
    "name" => "default",
    "paused" => false,
    "entries" => [
      {
        "name" => "e1",
        "expression" => "* * * * *",
        "paused" => false,
        "job" => {
          "type" => "test",
          "queue" => "q",
          "payload" => {
          }
        },
        "next_enqueue_at" => 1_700_000_060_000
      }
    ]
  }.freeze

  CRON_ENTRY_RESPONSE = CRON_GROUP_RESPONSE["entries"][0].freeze

  BUDGET_RESPONSE = {
    "key" => "emails",
    "allocation" => 100,
    "strategy" => {
      "type" => "time_based",
      "duration_ms" => 60_000,
      "burst" => 5
    },
    "created_at" => 1_700_000_000_000,
    "updated_at" => 1_700_000_060_000
  }.freeze

  def test_list_budgets
    stub_request(:get, "#{URL}/budgets").to_return(
      status: 200,
      body: JSON.generate({ "budgets" => [BUDGET_RESPONSE] }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.list_budgets
    assert_equal 1, result.size
    assert_instance_of Zizq::Resources::Budget, result[0]
    assert_equal "emails", result[0].key
  end

  def test_list_budgets_when_empty
    stub_request(:get, "#{URL}/budgets").to_return(
      status: 200,
      body: JSON.generate({ "budgets" => [] }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_empty @json_client.list_budgets
  end

  def test_get_budget
    stub_request(:get, "#{URL}/budgets/emails").to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_budget("emails")
    assert_instance_of Zizq::Resources::Budget, result
    assert_equal "emails", result.key
    assert_equal 100, result.allocation
    assert result.time_based?
    assert_equal :time_based, result.strategy_type
    assert_in_delta 60.0, result.duration
    assert_equal 5, result.burst
    # The burst is the ceiling a cost has to fit inside, not the
    # allocation.
    assert_equal 5, result.capacity
  end

  # A budget that has been read composes straight back into the shape
  # `put_budget` takes, which is the point of `strategy_type` and
  # `duration` reading back in the form they were written.
  def test_get_budget_strategy_round_trips_into_put_budget
    stub_request(:get, "#{URL}/budgets/emails").to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )
    stub_request(:put, "#{URL}/budgets/emails").with(
      body:
        JSON.generate(
          {
            allocation: 200,
            strategy: {
              type: "time_based",
              duration_ms: 60_000,
              burst: 5
            }
          }
        )
    ).to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    budget = @json_client.get_budget("emails")
    assert_equal(
      { type: :time_based, duration: 60.0, burst: 5 },
      budget.strategy
    )

    @json_client.put_budget(
      "emails",
      allocation: budget.allocation * 2,
      strategy: budget.strategy
    )
  end

  # An unset burst is left out rather than sent as nil, since absent and
  # explicitly cleared mean the same thing on the way in.
  def test_budget_strategy_omits_an_unset_burst
    budget =
      Zizq::Resources::Budget.new(
        @json_client,
        {
          "key" => "emails",
          "allocation" => 100,
          "strategy" => {
            "type" => "time_based",
            "duration_ms" => 60_000
          }
        }
      )

    assert_equal({ type: :time_based, duration: 60.0 }, budget.strategy)
  end

  # `while_in_flight` has no clock, so its strategy carries the kind
  # alone.
  def test_budget_strategy_for_while_in_flight
    budget =
      Zizq::Resources::Budget.new(
        @json_client,
        {
          "key" => "mutex",
          "allocation" => 1,
          "strategy" => {
            "type" => "while_in_flight"
          }
        }
      )

    assert_equal({ type: :while_in_flight }, budget.strategy)
  end

  def test_get_budget_raises_when_missing
    stub_request(:get, "#{URL}/budgets/nope").to_return(
      status: 404,
      body: JSON.generate({ "error" => "budget not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) { @json_client.get_budget("nope") }
  end

  def test_create_budget
    stub_request(:post, "#{URL}/budgets/emails").with(
      body:
        JSON.generate(
          {
            allocation: 100,
            strategy: {
              type: "time_based",
              duration_ms: 60_000
            }
          }
        )
    ).to_return(
      status: 201,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.create_budget(
        "emails",
        allocation: 100,
        strategy: {
          type: :time_based,
          duration: 60
        }
      )
    assert_instance_of Zizq::Resources::Budget, result
  end

  # A fractional period is fine — it converts to whole milliseconds,
  # and a burst rides alongside it.
  def test_create_budget_converts_a_fractional_duration
    stub_request(:post, "#{URL}/budgets/emails")
      .with do |req|
        JSON.parse(req.body)["strategy"] ==
          { "type" => "time_based", "duration_ms" => 1500, "burst" => 5 }
      end
      .to_return(
        status: 201,
        body: JSON.generate(BUDGET_RESPONSE),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.create_budget(
      "emails",
      allocation: 100,
      strategy: {
        type: :time_based,
        duration: 1.5,
        burst: 5
      }
    )
  end

  # `while_in_flight` has no clock, so it sends neither field.
  def test_create_budget_omits_duration_for_while_in_flight
    stub_request(:post, "#{URL}/budgets/mutex")
      .with do |req|
        JSON.parse(req.body)["strategy"] == { "type" => "while_in_flight" }
      end
      .to_return(
        status: 201,
        body: JSON.generate(BUDGET_RESPONSE),
        headers: {
          "Content-Type" => "application/json"
        }
      )

    @json_client.create_budget(
      "mutex",
      allocation: 1,
      strategy: {
        type: :while_in_flight
      }
    )
  end

  # `POST` refuses rather than overwriting, so an application declaring
  # its budgets on boot cannot clobber an operator's adjustment.
  def test_create_budget_conflicts_when_it_exists
    stub_request(:post, "#{URL}/budgets/emails").to_return(
      status: 409,
      body: JSON.generate({ "error" => "budget 'emails' already exists" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    error =
      assert_raises(Zizq::ConflictError) do
        @json_client.create_budget(
          "emails",
          allocation: 100,
          strategy: {
            type: :while_in_flight
          }
        )
      end
    assert_equal 409, error.status
    assert_match(/already exists/, error.message)
  end

  # A conflict stays rescuable as the general 4xx class, so existing
  # `rescue Zizq::ClientError` keeps catching it.
  def test_conflict_error_is_a_client_error
    assert_operator Zizq::ConflictError, :<, Zizq::ClientError
  end

  def test_put_budget
    stub_request(:put, "#{URL}/budgets/emails").with(
      body:
        JSON.generate(
          { allocation: 100, strategy: { type: "while_in_flight" } }
        )
    ).to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.put_budget(
        "emails",
        allocation: 100,
        strategy: {
          type: :while_in_flight
        }
      )
    assert_instance_of Zizq::Resources::Budget, result
  end

  # Merge patch recurses into the strategy, so the burst is changeable
  # without restating the kind and period.
  def test_update_budget_sends_only_what_was_named
    stub_request(:patch, "#{URL}/budgets/emails").with(
      body: JSON.generate({ strategy: { burst: 5 } })
    ).to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.update_budget("emails", strategy: { burst: 5 })
    assert_instance_of Zizq::Resources::Budget, result
  end

  # A patch has nothing to merge into when the budget is absent, so it
  # raises rather than creating one the way `put_budget` would.
  # `burst` is the one field with a meaningful unset, so an explicit
  # `nil` has to survive as JSON null rather than being dropped the way
  # an absent key is.
  def test_update_budget_sends_an_explicit_nil_burst_as_null
    stub_request(:patch, "#{URL}/budgets/emails").with(
      body: JSON.generate({ strategy: { burst: nil } })
    ).to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.update_budget("emails", strategy: { burst: nil })
  end

  # The period converts on a patch too.
  def test_update_budget_converts_duration_to_ms
    stub_request(:patch, "#{URL}/budgets/emails").with(
      body: JSON.generate({ strategy: { duration_ms: 30_000 } })
    ).to_return(
      status: 200,
      body: JSON.generate(BUDGET_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    @json_client.update_budget("emails", strategy: { duration: 30 })
  end

  def test_update_budget_raises_when_missing
    stub_request(:patch, "#{URL}/budgets/nope").to_return(
      status: 404,
      body: JSON.generate({ "error" => "budget not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) do
      @json_client.update_budget("nope", allocation: 5)
    end
  end

  def test_delete_budget
    stub_request(:delete, "#{URL}/budgets/emails").to_return(status: 204)

    assert_nil @json_client.delete_budget("emails")
  end

  def test_delete_budget_raises_when_missing
    stub_request(:delete, "#{URL}/budgets/nope").to_return(
      status: 404,
      body: JSON.generate({ "error" => "budget not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) { @json_client.delete_budget("nope") }
  end

  # Refused while anything still draws on it, so the caller learns which
  # of the two remedies applies.
  def test_delete_budget_conflicts_while_referenced
    stub_request(:delete, "#{URL}/budgets/emails").to_return(
      status: 409,
      body:
        JSON.generate(
          {
            "error" =>
              "budget 'emails' is referenced by 3 unfinished jobs. " \
                "Delete them or wait for them to finish before deleting it."
          }
        ),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    error =
      assert_raises(Zizq::ConflictError) do
        @json_client.delete_budget("emails")
      end
    assert_equal 409, error.status
    assert_match(/unfinished jobs/, error.message)
  end

  # Budgets are Pro-gated, so a licence failure is a routine outcome and
  # the server's message is what tells the caller why.
  def test_budget_calls_surface_the_licence_message
    stub_request(:get, "#{URL}/budgets").to_return(
      status: 403,
      body: JSON.generate({ "error" => "budgets require a Pro license" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    error = assert_raises(Zizq::ClientError) { @json_client.list_budgets }
    assert_equal 403, error.status
    assert_match(/Pro license/, error.message)
  end

  # A `while_in_flight` budget has no clock, so there is no period to
  # report and the allocation is the ceiling.
  def test_budget_resource_for_a_concurrency_limit
    stub_request(:get, "#{URL}/budgets/mutex").to_return(
      status: 200,
      body:
        JSON.generate(
          {
            "key" => "mutex",
            "allocation" => 1,
            "strategy" => {
              "type" => "while_in_flight"
            },
            "created_at" => 1_700_000_000_000,
            "updated_at" => 1_700_000_000_000
          }
        ),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_budget("mutex")
    assert result.while_in_flight?
    refute result.time_based?
    assert_equal :while_in_flight, result.strategy_type
    assert_nil result.duration
    assert_nil result.burst
    assert_equal 1, result.capacity
  end

  def test_list_cron_groups
    stub_request(:get, "#{URL}/crons").to_return(
      status: 200,
      body: JSON.generate({ "crons" => %w[default billing] }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.list_cron_groups
    assert_equal %w[default billing], result
  end

  def test_get_cron_group
    stub_request(:get, "#{URL}/crons/default").to_return(
      status: 200,
      body: JSON.generate(CRON_GROUP_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_cron_group("default")
    assert_instance_of Zizq::Resources::CronGroup, result
    assert_equal "default", result.name
    assert_equal false, result.paused?
    assert_equal 1, result.entries.size
    assert_equal "e1", result.entries[0].name
  end

  def test_replace_cron_group
    stub_request(:put, "#{URL}/crons/default").with(
      body:
        JSON.generate(
          {
            entries: [
              {
                name: "e1",
                expression: "* * * * *",
                job: {
                  type: "test",
                  queue: "q",
                  payload: {
                  }
                }
              }
            ]
          }
        ),
      headers: {
        "Content-Type" => "application/json"
      }
    ).to_return(
      status: 200,
      body: JSON.generate(CRON_GROUP_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.replace_cron_group(
        "default",
        entries: [
          {
            name: "e1",
            expression: "* * * * *",
            job: {
              type: "test",
              queue: "q",
              payload: {
              }
            }
          }
        ]
      )
    assert_instance_of Zizq::Resources::CronGroup, result
    assert_equal "default", result.name
  end

  def test_update_cron_group
    paused_response =
      CRON_GROUP_RESPONSE.merge(
        "paused" => true,
        "paused_at" => 1_700_000_000_000
      )
    stub_request(:patch, "#{URL}/crons/default").with(
      body: JSON.generate({ paused: true })
    ).to_return(
      status: 200,
      body: JSON.generate(paused_response),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.update_cron_group("default", paused: true)
    assert_instance_of Zizq::Resources::CronGroup, result
    assert result.paused?
  end

  def test_delete_cron_group
    stub_request(:delete, "#{URL}/crons/default").to_return(
      status: 204,
      body: "",
      headers: {
      }
    )

    assert_nil @json_client.delete_cron_group("default")
  end

  def test_delete_all_crons
    stub_request(:delete, "#{URL}/crons").to_return(
      status: 200,
      body: JSON.generate({ "deleted" => 3 }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    count = @json_client.delete_all_crons
    assert_equal 3, count
  end

  def test_get_cron_group_entry
    stub_request(:get, "#{URL}/crons/default/entries/e1").to_return(
      status: 200,
      body: JSON.generate(CRON_ENTRY_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.get_cron_group_entry("default", "e1")
    assert_instance_of Zizq::Resources::CronEntry, result
    assert_equal "e1", result.name
    assert_equal "* * * * *", result.expression
  end

  def test_add_cron_group_entry
    stub_request(:post, "#{URL}/crons/default/entries").with(
      body:
        JSON.generate(
          {
            name: "e1",
            expression: "* * * * *",
            job: {
              type: "test",
              queue: "q",
              payload: {
              }
            }
          }
        )
    ).to_return(
      status: 201,
      body: JSON.generate(CRON_ENTRY_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.add_cron_group_entry(
        "default",
        name: "e1",
        expression: "* * * * *",
        job: {
          type: "test",
          queue: "q",
          payload: {
          }
        }
      )
    assert_instance_of Zizq::Resources::CronEntry, result
    assert_equal "e1", result.name
  end

  def test_replace_cron_group_entry
    stub_request(:put, "#{URL}/crons/default/entries/e1").to_return(
      status: 200,
      body: JSON.generate(CRON_ENTRY_RESPONSE),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result =
      @json_client.replace_cron_group_entry(
        "default",
        "e1",
        expression: "* * * * *",
        job: {
          type: "test",
          queue: "q",
          payload: {
          }
        }
      )
    assert_instance_of Zizq::Resources::CronEntry, result
    assert_equal "e1", result.name
  end

  def test_update_cron_group_entry
    paused_entry =
      CRON_ENTRY_RESPONSE.merge(
        "paused" => true,
        "paused_at" => 1_700_000_000_000
      )
    stub_request(:patch, "#{URL}/crons/default/entries/e1").with(
      body: JSON.generate({ paused: true })
    ).to_return(
      status: 200,
      body: JSON.generate(paused_entry),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    result = @json_client.update_cron_group_entry("default", "e1", paused: true)
    assert_instance_of Zizq::Resources::CronEntry, result
    assert result.paused?
  end

  def test_delete_cron_group_entry
    stub_request(:delete, "#{URL}/crons/default/entries/e1").to_return(
      status: 204,
      body: "",
      headers: {
      }
    )

    assert_nil @json_client.delete_cron_group_entry("default", "e1")
  end
end
