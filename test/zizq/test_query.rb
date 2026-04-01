# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class SendJob
  include Zizq::Job
  zizq_queue "emails"
  def perform(user_id, template: "default") = nil
end

class TestQuery < ZizqTestCase

  # --- Immutability ---

  def test_filter_methods_return_new_instance
    q1 = Zizq::Query.new
    q2 = q1.by_queue("emails")
    refute_same q1, q2
  end

  # --- Filter composition ---

  def test_by_id_sets_id_filter
    stub_list(query: { "id" => "j1" })
    Zizq::Query.new.by_id("j1").to_a
  end

  def test_add_id_appends
    stub_list(query: { "id" => "j1,j2" })
    Zizq::Query.new.by_id("j1").add_id("j2").to_a
  end

  def test_by_queue_sets_queue_filter
    stub_list(query: { "queue" => "emails" })
    Zizq::Query.new.by_queue("emails").to_a
  end

  def test_add_queue_appends
    stub_list(query: { "queue" => "emails,webhooks" })
    Zizq::Query.new.by_queue("emails").add_queue("webhooks").to_a
  end

  def test_by_type_sets_type_filter
    stub_list(query: { "type" => "SendEmail" })
    Zizq::Query.new.by_type("SendEmail").to_a
  end

  def test_add_type_appends
    stub_list(query: { "type" => "SendEmail,ProcessOrder" })
    Zizq::Query.new.by_type("SendEmail").add_type("ProcessOrder").to_a
  end

  def test_by_status_sets_status_filter
    stub_list(query: { "status" => "ready" })
    Zizq::Query.new.by_status("ready").to_a
  end

  def test_add_status_appends
    stub_list(query: { "status" => "ready,in_flight" })
    Zizq::Query.new.by_status("ready").add_status("in_flight").to_a
  end

  def test_by_jq_filter_sets_filter
    stub_list(query: { "filter" => ".user_id == 42" })
    Zizq::Query.new.by_jq_filter(".user_id == 42").to_a
  end

  def test_add_jq_filter_combines_with_and
    stub_list(query: { "filter" => "(.x > 1) and (.x < 10)" })
    Zizq::Query.new.add_jq_filter(".x > 1").add_jq_filter(".x < 10").to_a
  end

  def test_order_sets_order
    stub_list(query: { "order" => "desc" })
    Zizq::Query.new.order(:desc).to_a
  end

  def test_in_pages_of_sets_limit_param
    stub_list(query: { "limit" => "100" })
    Zizq::Query.new.in_pages_of(100).to_a
  end

  # --- by_job_class_and_args ---

  def test_by_job_class_and_args_sets_type_and_filter
    # add_jq_filter wraps in parens: "(. == {...})"
    inner = SendJob.zizq_payload_filter(42, template: "welcome")
    expected_filter = "(#{inner})"
    stub_request(:get, "#{URL}/jobs")
      .with(query: { "type" => "SendJob", "filter" => expected_filter })
      .to_return(json_response(page_body([])))
    Zizq::Query.new.by_job_class_and_args(SendJob, 42, template: "welcome").to_a
  end

  def test_by_job_class_and_args_subset_sets_type_and_filter
    inner = SendJob.zizq_payload_subset_filter(42)
    expected_filter = "(#{inner})"
    stub_request(:get, "#{URL}/jobs")
      .with(query: { "type" => "SendJob", "filter" => expected_filter })
      .to_return(json_response(page_body([])))
    Zizq::Query.new.by_job_class_and_args_subset(SendJob, 42).to_a
  end

  def test_by_job_class_rejects_non_job_class
    assert_raises(ArgumentError) do
      Zizq::Query.new.by_job_class_and_args(String, "hello")
    end
  end

  # --- each ---

  def test_each_yields_jobs
    stub_list(body: page_body(["j1", "j2"]))
    ids = Zizq::Query.new.map(&:id)
    assert_equal %w[j1 j2], ids
  end

  def test_each_paginates
    stub_list(body: page_body(["j1"], next_path: "/jobs?from=j1"))
    stub_request(:get, "#{URL}/jobs?from=j1")
      .to_return(json_response(page_body(["j2"])))

    ids = Zizq::Query.new.map(&:id)
    assert_equal %w[j1 j2], ids
  end

  def test_each_respects_limit
    stub_list(query: { "limit" => "2" }, body: page_body(["j1", "j2", "j3"]))
    ids = Zizq::Query.new.limit(2).map(&:id)
    assert_equal %w[j1 j2], ids
  end

  def test_each_returns_enumerator
    stub_list(body: page_body(["j1"]))
    enum = Zizq::Query.new.each
    assert_kind_of Enumerator, enum
  end

  # --- each_page ---

  def test_each_page_yields_pages
    stub_list(body: page_body(["j1", "j2"]))
    pages = Zizq::Query.new.each_page.to_a
    assert_equal 1, pages.size
    assert_equal %w[j1 j2], pages[0].jobs.map(&:id)
  end

  def test_each_page_follows_pagination
    stub_list(body: page_body(["j1"], next_path: "/jobs?from=j1"))
    stub_request(:get, "#{URL}/jobs?from=j1")
      .to_return(json_response(page_body(["j2"])))

    pages = Zizq::Query.new.each_page.to_a
    assert_equal 2, pages.size
  end

  def test_each_page_respects_limit
    stub_list(query: { "limit" => "2" }, body: page_body(["j1", "j2"], next_path: "/jobs?from=j2&limit=2"))
    pages = []
    Zizq::Query.new.limit(2).each_page { |p| pages << p }
    assert_equal 1, pages.size
  end

  # --- count ---

  def test_count_enumerates_all_pages
    stub_list(body: page_body(["j1", "j2"], next_path: "/jobs?from=j2"))
    stub_request(:get, "#{URL}/jobs?from=j2")
      .to_return(json_response(page_body(["j3"])))

    assert_equal 3, Zizq::Query.new.count
  end

  # --- delete_all ---

  def test_delete_all_one_shot
    stub_request(:delete, "#{URL}/jobs?queue=emails")
      .to_return(json_response({ "deleted" => 5 }))

    count = Zizq::Query.new.by_queue("emails").delete_all
    assert_equal 5, count
  end

  def test_delete_all_paginated
    stub_list(
      query: { "queue" => "emails", "limit" => "2" },
      body: page_body(["j1", "j2"], next_path: "/jobs?queue=emails&from=j2&limit=2"),
    )
    stub_request(:get, "#{URL}/jobs?queue=emails&from=j2&limit=2")
      .to_return(json_response(page_body(["j3"])))

    stub_request(:delete, "#{URL}/jobs?queue=emails&id=j1,j2")
      .to_return(json_response({ "deleted" => 2 }))
    stub_request(:delete, "#{URL}/jobs?queue=emails&id=j3")
      .to_return(json_response({ "deleted" => 1 }))

    count = Zizq::Query.new.by_queue("emails").in_pages_of(2).delete_all
    assert_equal 3, count
  end

  def test_delete_all_paginated_with_limit
    stub_list(
      query: { "queue" => "emails", "limit" => "2" },
      body: page_body(["j1", "j2", "j3"]),
    )

    stub_request(:delete, "#{URL}/jobs?queue=emails&id=j1,j2")
      .to_return(json_response({ "deleted" => 2 }))

    count = Zizq::Query.new.by_queue("emails").in_pages_of(3).limit(2).delete_all
    assert_equal 2, count
  end

  # --- update_all ---

  def test_update_all_one_shot
    stub_request(:patch, "#{URL}/jobs?queue=old")
      .with(body: JSON.generate({ queue: "new" }))
      .to_return(json_response({ "patched" => 5 }))

    count = Zizq::Query.new.by_queue("old").update_all(queue: "new")
    assert_equal 5, count
  end

  def test_update_all_paginated
    stub_list(
      query: { "queue" => "old", "limit" => "2" },
      body: page_body(["j1", "j2"], next_path: "/jobs?queue=old&from=j2&limit=2"),
    )
    stub_request(:get, "#{URL}/jobs?queue=old&from=j2&limit=2")
      .to_return(json_response(page_body(["j3"])))

    stub_request(:patch, "#{URL}/jobs?queue=old&id=j1,j2")
      .with(body: JSON.generate({ queue: "new" }))
      .to_return(json_response({ "patched" => 2 }))
    stub_request(:patch, "#{URL}/jobs?queue=old&id=j3")
      .with(body: JSON.generate({ queue: "new" }))
      .to_return(json_response({ "patched" => 1 }))

    count = Zizq::Query.new.by_queue("old").in_pages_of(2).update_all(queue: "new")
    assert_equal 3, count
  end

  def test_update_all_with_reset
    stub_request(:patch, "#{URL}/jobs?queue=emails")
      .with(body: JSON.generate({ retry_limit: nil }))
      .to_return(json_response({ "patched" => 3 }))

    count = Zizq::Query.new.by_queue("emails").update_all(retry_limit: Zizq::RESET)
    assert_equal 3, count
  end

  private

  # Stub a GET /jobs request with optional query params.
  def stub_list(query: {}, body: page_body([]))
    stub = stub_request(:get, "#{URL}/jobs")
    stub = stub.with(query:) unless query.empty?
    stub.to_return(json_response(body))
  end

  # Build a page response body with the given job IDs.
  def page_body(ids, next_path: nil)
    pages = { "self" => "/jobs" }
    pages["next"] = next_path if next_path
    { "jobs" => ids.map { |id| { "id" => id, "type" => "Test", "queue" => "default" } }, "pages" => pages }
  end

  def json_response(body)
    { status: 200, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
  end
end
