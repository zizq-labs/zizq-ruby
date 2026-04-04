# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class TestResources < ZizqTestCase
  def setup
    super
    @client = Zizq::Client.new(url: URL, format: :json)
  end

  # --- Resource base ---

  def test_to_h_returns_raw_data
    data = { "id" => "j1", "type" => "Foo" }
    resource = Zizq::Resources::Resource.new(@client, data)
    assert_equal data, resource.to_h
  end

  # --- Job accessors ---

  def test_job_simple_accessors
    data = {
      "id" => "j1", "type" => "SendEmail", "queue" => "emails",
      "priority" => 100, "status" => "ready", "attempts" => 2,
      "retry_limit" => 5
    }
    job = Zizq::Resources::Job.new(@client, data)

    assert_equal "j1", job.id
    assert_equal "SendEmail", job.type
    assert_equal "emails", job.queue
    assert_equal 100, job.priority
    assert_equal "ready", job.status
    assert_equal 2, job.attempts
    assert_equal 5, job.retry_limit
  end

  def test_job_ms_to_seconds_conversion
    data = {
      "id" => "j1", "type" => "Foo", "queue" => "default",
      "ready_at" => 1_700_000_000_000,
      "dequeued_at" => 1_700_000_001_500,
      "failed_at" => 1_700_000_002_750
    }
    job = Zizq::Resources::Job.new(@client, data)

    assert_in_delta 1_700_000_000.0, job.ready_at, 0.001
    assert_in_delta 1_700_000_001.5, job.dequeued_at, 0.001
    assert_in_delta 1_700_000_002.75, job.failed_at, 0.001
  end

  def test_job_nil_optional_fields
    data = { "id" => "j1", "type" => "Foo", "queue" => "default" }
    job = Zizq::Resources::Job.new(@client, data)

    assert_nil job.payload
    assert_nil job.dequeued_at
    assert_nil job.failed_at
    assert_nil job.retry_limit
    assert_nil job.backoff
  end

  def test_job_payload_present
    data = { "id" => "j1", "type" => "Foo", "queue" => "default",
             "payload" => { "user_id" => 42 } }
    job = Zizq::Resources::Job.new(@client, data)

    assert_equal({ "user_id" => 42 }, job.payload)
  end

  def test_job_backoff_converts_from_wire_format
    data = { "id" => "j1", "type" => "Foo", "queue" => "default",
             "backoff" => { "exponent" => 4.0, "base_ms" => 15_000, "jitter_ms" => 30_000 } }
    job = Zizq::Resources::Job.new(@client, data)

    # Wire format ms values are converted to seconds matching Zizq::backoff
    assert_equal({ exponent: 4.0, base: 15.0, jitter: 30.0 }, job.backoff)
  end

  def test_job_to_h
    data = { "id" => "j1", "type" => "Foo", "queue" => "default" }
    job = Zizq::Resources::Job.new(@client, data)

    assert_equal data, job.to_h
  end

  # --- Job link methods ---

  def test_job_errors_returns_error_enumerator
    job = Zizq::Resources::Job.new(@client, { "id" => "j1" })
    result = job.errors

    assert_instance_of Zizq::Resources::ErrorEnumerator, result
  end

  def test_job_complete_delegates_to_client
    stub_request(:post, "#{URL}/jobs/j1/success")
      .to_return(status: 204, body: "")

    job = Zizq::Resources::Job.new(@client, { "id" => "j1" })
    result = job.complete!

    assert_nil result
  end

  def test_job_fail_delegates_to_client
    updated = { "id" => "j1", "status" => "scheduled", "attempts" => 1 }
    stub_request(:post, "#{URL}/jobs/j1/failure")
      .to_return(status: 200, body: JSON.generate(updated),
                 headers: { "Content-Type" => "application/json" })

    job = Zizq::Resources::Job.new(@client, { "id" => "j1" })
    result = job.fail!(message: "oops")

    assert_instance_of Zizq::Resources::Job, result
    assert_equal "scheduled", result.status
  end

  def test_job_delete_delegates_to_client
    stub_request(:delete, "#{URL}/jobs/j1")
      .to_return(status: 204, body: "")

    job = Zizq::Resources::Job.new(@client, { "id" => "j1" })
    result = job.delete

    assert_nil result
  end

  def test_job_update_delegates_to_client
    updated = { "id" => "j1", "queue" => "emails", "priority" => 10 }
    stub_request(:patch, "#{URL}/jobs/j1")
      .with { |req| JSON.parse(req.body)["priority"] == 10 }
      .to_return(status: 200, body: JSON.generate(updated),
                 headers: { "Content-Type" => "application/json" })

    job = Zizq::Resources::Job.new(@client, { "id" => "j1" })
    result = job.update(priority: 10)

    assert_instance_of Zizq::Resources::Job, result
    assert_equal 10, result.priority
  end

  # --- ErrorRecord ---

  def test_error_record_accessors
    data = {
      "attempt" => 3, "message" => "connection timeout",
      "error_type" => "Timeout::Error", "backtrace" => "line1\nline2",
      "dequeued_at" => 1_700_000_000_000, "failed_at" => 1_700_000_001_500
    }
    record = Zizq::Resources::ErrorRecord.new(@client, data)

    assert_equal 3, record.attempt
    assert_equal "connection timeout", record.message
    assert_equal "Timeout::Error", record.error_type
    assert_equal "line1\nline2", record.backtrace
    assert_in_delta 1_700_000_000.0, record.dequeued_at, 0.001
    assert_in_delta 1_700_000_001.5, record.failed_at, 0.001
  end

  def test_error_record_nil_optional_fields
    data = { "attempt" => 1, "message" => "boom",
             "dequeued_at" => 1000, "failed_at" => 2000 }
    record = Zizq::Resources::ErrorRecord.new(@client, data)

    assert_nil record.error_type
    assert_nil record.backtrace
  end

  # --- ErrorEnumerator ---

  def test_error_enumerator_iterates_errors
    stub_request(:get, "#{URL}/jobs/j1/errors")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 1, "message" => "boom", "dequeued_at" => 1000, "failed_at" => 2000 },
          { "attempt" => 2, "message" => "bang", "dequeued_at" => 3000, "failed_at" => 4000 },
        ],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    errors = Zizq::Resources::ErrorEnumerator.new("j1").to_a

    assert_equal 2, errors.size
    assert_equal "boom", errors[0].message
    assert_equal "bang", errors[1].message
  end

  def test_error_enumerator_paginates
    stub_request(:get, "#{URL}/jobs/j1/errors?limit=1")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 1, "message" => "first", "dequeued_at" => 1000, "failed_at" => 2000 },
        ],
        "pages" => { "next" => "/jobs/j1/errors?from=1&limit=1" }
      }), headers: { "Content-Type" => "application/json" })

    stub_request(:get, "#{URL}/jobs/j1/errors?from=1&limit=1")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 2, "message" => "second", "dequeued_at" => 3000, "failed_at" => 4000 },
        ],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    errors = Zizq::Resources::ErrorEnumerator.new("j1").in_pages_of(1).to_a

    assert_equal 2, errors.size
    assert_equal "first", errors[0].message
    assert_equal "second", errors[1].message
  end

  def test_error_enumerator_respects_limit
    stub_request(:get, "#{URL}/jobs/j1/errors?limit=1")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 1, "message" => "only", "dequeued_at" => 1000, "failed_at" => 2000 },
        ],
        "pages" => { "next" => "/jobs/j1/errors?from=1&limit=1" }
      }), headers: { "Content-Type" => "application/json" })

    errors = Zizq::Resources::ErrorEnumerator.new("j1").limit(1).to_a

    assert_equal 1, errors.size
    assert_equal "only", errors[0].message
  end

  def test_error_enumerator_passes_order
    stub_request(:get, "#{URL}/jobs/j1/errors?order=desc")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 2, "message" => "latest", "dequeued_at" => 3000, "failed_at" => 4000 },
        ],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    errors = Zizq::Resources::ErrorEnumerator.new("j1").order(:desc).to_a

    assert_equal 1, errors.size
    assert_equal "latest", errors[0].message
  end

  def test_error_enumerator_empty
    stub_request(:get, "#{URL}/jobs/j1/errors")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    stub_request(:get, "#{URL}/jobs/j1/errors?limit=1")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    enum = Zizq::Resources::ErrorEnumerator.new("j1")

    assert_equal [], enum.to_a
    assert enum.empty?
    assert enum.none?
  end

  def test_error_enumerator_first_and_last
    stub_request(:get, "#{URL}/jobs/j1/errors?limit=1")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 1, "message" => "first", "dequeued_at" => 1000, "failed_at" => 2000 },
        ],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    stub_request(:get, "#{URL}/jobs/j1/errors?order=desc&limit=1")
      .to_return(status: 200, body: JSON.generate({
        "errors" => [
          { "attempt" => 3, "message" => "last", "dequeued_at" => 5000, "failed_at" => 6000 },
        ],
        "pages" => {}
      }), headers: { "Content-Type" => "application/json" })

    enum = Zizq::Resources::ErrorEnumerator.new("j1")

    assert_equal "first", enum.first.message
    assert_equal "last", enum.last.message
  end

  # --- JobPage ---

  def test_job_page_wraps_jobs
    data = {
      "jobs" => [
        { "id" => "j1", "type" => "Foo", "queue" => "default" },
        { "id" => "j2", "type" => "Bar", "queue" => "default" }
      ],
      "pages" => { "self" => "/jobs" }
    }
    page = Zizq::Resources::JobPage.new(@client, data)

    assert_equal 2, page.jobs.size
    assert_instance_of Zizq::Resources::Job, page.jobs[0]
    assert_equal "j1", page.jobs[0].id
    assert_equal "j2", page.jobs[1].id
  end

  def test_job_page_items_alias
    data = { "jobs" => [{ "id" => "j1" }], "pages" => {} }
    page = Zizq::Resources::JobPage.new(@client, data)

    assert_equal page.jobs, page.items
  end

  def test_job_page_to_h
    data = { "jobs" => [], "pages" => {} }
    page = Zizq::Resources::JobPage.new(@client, data)
    assert_equal data, page.to_h
  end

  # --- ErrorPage ---

  def test_error_page_wraps_errors
    data = {
      "errors" => [
        { "attempt" => 1, "message" => "boom", "dequeued_at" => 1000, "failed_at" => 2000 }
      ],
      "pages" => { "self" => "/jobs/j1/errors" }
    }
    page = Zizq::Resources::ErrorPage.new(@client, data)

    assert_equal 1, page.errors.size
    assert_instance_of Zizq::Resources::ErrorRecord, page.errors[0]
    assert_equal "boom", page.errors[0].message
  end

  def test_error_page_items_alias
    data = { "errors" => [{ "attempt" => 1, "message" => "x", "dequeued_at" => 1, "failed_at" => 2 }], "pages" => {} }
    page = Zizq::Resources::ErrorPage.new(@client, data)

    assert_equal page.errors, page.items
  end

  # --- Page navigation ---

  def test_page_next_and_prev_predicates
    page_with = Zizq::Resources::JobPage.new(@client, {
      "jobs" => [],
      "pages" => { "self" => "/jobs", "next" => "/jobs?from=abc", "prev" => "/jobs?from=xyz&order=desc" }
    })

    assert page_with.has_next?
    assert page_with.has_prev?

    page_without = Zizq::Resources::JobPage.new(@client, {
      "jobs" => [],
      "pages" => { "self" => "/jobs" }
    })

    refute page_without.has_next?
    refute page_without.has_prev?
  end

  def test_page_next_page_follows_link
    page1_data = {
      "jobs" => [{ "id" => "j1" }],
      "pages" => { "self" => "/jobs", "next" => "/jobs?from=j1" }
    }
    page2_data = {
      "jobs" => [{ "id" => "j2" }],
      "pages" => { "self" => "/jobs?from=j1" }
    }

    stub_request(:get, "#{URL}/jobs?from=j1")
      .with(headers: { "Accept" => "application/json" })
      .to_return(status: 200, body: JSON.generate(page2_data),
                 headers: { "Content-Type" => "application/json" })

    page1 = Zizq::Resources::JobPage.new(@client, page1_data)
    page2 = page1.next_page

    assert_instance_of Zizq::Resources::JobPage, page2
    assert_equal 1, page2.jobs.size
    assert_equal "j2", page2.jobs[0].id
  end

  def test_page_prev_page_follows_link
    page2_data = {
      "jobs" => [{ "id" => "j2" }],
      "pages" => { "self" => "/jobs?from=j1", "prev" => "/jobs?from=j2&order=desc" }
    }
    page1_data = {
      "jobs" => [{ "id" => "j1" }],
      "pages" => { "self" => "/jobs" }
    }

    stub_request(:get, "#{URL}/jobs?from=j2&order=desc")
      .to_return(status: 200, body: JSON.generate(page1_data),
                 headers: { "Content-Type" => "application/json" })

    page2 = Zizq::Resources::JobPage.new(@client, page2_data)
    page1 = page2.prev_page

    assert_instance_of Zizq::Resources::JobPage, page1
    assert_equal "j1", page1.jobs[0].id
  end

  def test_page_next_page_returns_nil_when_absent
    page = Zizq::Resources::JobPage.new(@client, {
      "jobs" => [], "pages" => { "self" => "/jobs" }
    })

    assert_nil page.next_page
  end

  def test_page_prev_page_returns_nil_when_absent
    page = Zizq::Resources::JobPage.new(@client, {
      "jobs" => [], "pages" => { "self" => "/jobs" }
    })

    assert_nil page.prev_page
  end

  def test_error_page_next_page_returns_error_page
    page1_data = {
      "errors" => [{ "attempt" => 1, "message" => "boom", "dequeued_at" => 1000, "failed_at" => 2000 }],
      "pages" => { "self" => "/jobs/j1/errors", "next" => "/jobs/j1/errors?from=abc" }
    }
    page2_data = {
      "errors" => [{ "attempt" => 2, "message" => "bang", "dequeued_at" => 3000, "failed_at" => 4000 }],
      "pages" => { "self" => "/jobs/j1/errors?from=abc" }
    }

    stub_request(:get, "#{URL}/jobs/j1/errors?from=abc")
      .to_return(status: 200, body: JSON.generate(page2_data),
                 headers: { "Content-Type" => "application/json" })

    page1 = Zizq::Resources::ErrorPage.new(@client, page1_data)
    page2 = page1.next_page

    assert_instance_of Zizq::Resources::ErrorPage, page2
    assert_equal "bang", page2.errors[0].message
  end

  # --- Page Enumerable ---

  def test_page_is_enumerable
    data = {
      "jobs" => [
        { "id" => "j1", "type" => "Foo", "queue" => "q" },
        { "id" => "j2", "type" => "Bar", "queue" => "q" },
      ],
      "pages" => {}
    }
    page = Zizq::Resources::JobPage.new(@client, data)

    assert_kind_of Enumerable, page
    assert_equal ["j1", "j2"], page.map(&:id)
    assert_equal 2, page.count
  end

  # --- JobPage#delete_all ---

  def test_job_page_delete_all
    data = {
      "jobs" => [
        { "id" => "j1", "type" => "Foo", "queue" => "q" },
        { "id" => "j2", "type" => "Bar", "queue" => "q" },
      ],
      "pages" => {}
    }

    stub_request(:delete, "#{URL}/jobs?id=j1,j2")
      .to_return(status: 200, body: JSON.generate({ "deleted" => 2 }),
                 headers: { "Content-Type" => "application/json" })

    page = Zizq::Resources::JobPage.new(@client, data)
    assert_equal 2, page.delete_all
  end

  def test_job_page_delete_all_empty_page
    data = { "jobs" => [], "pages" => {} }
    page = Zizq::Resources::JobPage.new(@client, data)

    assert_equal 0, page.delete_all
  end

  # --- JobPage#update_all ---

  def test_job_page_update_all
    data = {
      "jobs" => [
        { "id" => "j1", "type" => "Foo", "queue" => "q" },
        { "id" => "j2", "type" => "Bar", "queue" => "q" },
      ],
      "pages" => {}
    }

    stub_request(:patch, "#{URL}/jobs?id=j1,j2")
      .with { |req| JSON.parse(req.body)["priority"] == 10 }
      .to_return(status: 200, body: JSON.generate({ "patched" => 2 }),
                 headers: { "Content-Type" => "application/json" })

    page = Zizq::Resources::JobPage.new(@client, data)
    assert_equal 2, page.update_all(priority: 10)
  end

  def test_job_page_update_all_empty_page
    data = { "jobs" => [], "pages" => {} }
    page = Zizq::Resources::JobPage.new(@client, data)

    assert_equal 0, page.update_all(priority: 10)
  end
end
