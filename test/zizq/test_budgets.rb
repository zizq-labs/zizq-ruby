# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

# The module-level budget surface. `Zizq::Client` is the low-level API
# these delegate to and is covered separately in test_client.rb; what
# matters here is that an application never has to reach for it.
class TestBudgets < ZizqTestCase
  BUDGET = {
    "key" => "emails",
    "allocation" => 100,
    "strategy" => {
      "type" => "time_based",
      "duration_ms" => 60_000
    }
  }.freeze

  TIME_BASED = { type: :time_based, duration: 60 }.freeze

  def test_budgets_lists_every_budget
    stub_request(:get, "#{URL}/budgets").to_return(
      json_response({ "budgets" => [BUDGET] })
    )

    result = Zizq.budgets
    assert_equal 1, result.size
    assert_equal "emails", result.first.key
  end

  def test_budget_fetches_one
    stub_request(:get, "#{URL}/budgets/emails").to_return(json_response(BUDGET))

    assert_equal 100, Zizq.budget("emails").allocation
  end

  def test_budget_raises_when_missing
    stub_request(:get, "#{URL}/budgets/nope").to_return(
      status: 404,
      body: JSON.generate({ "error" => "budget not found" }),
      headers: {
        "Content-Type" => "application/json"
      }
    )

    assert_raises(Zizq::NotFoundError) { Zizq.budget("nope") }
  end

  # Defaults to `POST`, so a second definition conflicts rather than
  # overwriting whatever an operator has since tuned.
  def test_define_budget_creates
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
    ).to_return(status: 201, body: JSON.generate(BUDGET), headers: json_headers)

    result = Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)
    assert_instance_of Zizq::Resources::Budget, result
  end

  def test_define_budget_conflicts_when_it_exists
    stub_request(:post, "#{URL}/budgets/emails").to_return(
      status: 409,
      body: JSON.generate({ "error" => "budget 'emails' already exists" }),
      headers: json_headers
    )

    assert_raises(Zizq::ConflictError) do
      Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)
    end
  end

  # The declare-on-boot shape: every replica calls it, and the one that
  # loses the race treats the conflict as success.
  def test_define_budget_conflict_is_rescuable_per_replica
    stub_request(:post, "#{URL}/budgets/emails").to_return(
      status: 409,
      body: JSON.generate({ "error" => "budget 'emails' already exists" }),
      headers: json_headers
    )

    declared =
      begin
        Zizq.define_budget("emails", allocation: 100, strategy: TIME_BASED)
        true
      rescue Zizq::ConflictError
        false
      end

    refute declared
  end

  # `replace: true` switches to `PUT`, which never conflicts.
  def test_define_budget_with_replace_overwrites
    stub_request(:put, "#{URL}/budgets/emails").with(
      body:
        JSON.generate(
          { allocation: 200, strategy: { type: "while_in_flight" } }
        )
    ).to_return(status: 200, body: JSON.generate(BUDGET), headers: json_headers)

    Zizq.define_budget(
      "emails",
      allocation: 200,
      strategy: {
        type: :while_in_flight
      },
      replace: true
    )
  end

  # Merge patch recurses into the strategy, so one field changes without
  # restating the others.
  def test_update_budget_sends_only_what_was_named
    stub_request(:patch, "#{URL}/budgets/emails").with(
      body: JSON.generate({ strategy: { burst: 5 } })
    ).to_return(status: 200, body: JSON.generate(BUDGET), headers: json_headers)

    Zizq.update_budget("emails", strategy: { burst: 5 })
  end

  def test_update_budget_converts_duration_to_ms
    stub_request(:patch, "#{URL}/budgets/emails").with(
      body: JSON.generate({ strategy: { duration_ms: 30_000 } })
    ).to_return(status: 200, body: JSON.generate(BUDGET), headers: json_headers)

    Zizq.update_budget("emails", strategy: { duration: 30 })
  end

  def test_delete_budget
    stub_request(:delete, "#{URL}/budgets/emails").to_return(status: 204)

    assert_nil Zizq.delete_budget("emails")
  end

  # Refused while anything still draws on it, which is what
  # `unbind_budget` over a query is for.
  def test_delete_budget_conflicts_while_referenced
    stub_request(:delete, "#{URL}/budgets/emails").to_return(
      status: 409,
      body:
        JSON.generate(
          { "error" => "budget 'emails' is referenced by 3 unfinished jobs." }
        ),
      headers: json_headers
    )

    assert_raises(Zizq::ConflictError) { Zizq.delete_budget("emails") }
  end

  # The drain-then-delete flow, entirely at module level — no reaching
  # for `Zizq.client`.
  def test_drain_then_delete_without_touching_the_client
    stub_request(:delete, "#{URL}/jobs/budgets/emails").with(
      query: {
        "budgets.key" => "emails"
      }
    ).to_return(json_response({ "changed" => 12, "blocked" => [] }))
    stub_request(:delete, "#{URL}/budgets/emails").to_return(status: 204)

    result = Zizq.query.by_budgets_key("emails").unbind_budget("emails")

    assert_equal({ changed: 12, blocked: [] }, result)
    assert_nil Zizq.delete_budget("emails")
  end

  # --- bindings on a single job ---

  BOUND_JOB = {
    "id" => "j1",
    "type" => "SendEmail",
    "queue" => "emails",
    "status" => "ready",
    "attempts" => 0,
    "budgets" => [{ "key" => "emails", "cost" => 2 }]
  }.freeze

  UNBOUND_JOB = BOUND_JOB.reject { |k, _| k == "budgets" }.freeze

  def job(data = UNBOUND_JOB)
    Zizq::Resources::Job.new(Zizq.client, data.dup)
  end

  def test_bind_budget
    stub_request(:post, "#{URL}/jobs/j1/budgets/emails").with(
      body: JSON.generate({ cost: 2 })
    ).to_return(json_response(BOUND_JOB))

    result = job.bind_budget("emails", cost: 2)

    assert_equal [{ key: "emails", cost: 2 }], result.budgets
  end

  def test_bind_budget_conflicts_when_already_bound
    stub_request(:post, "#{URL}/jobs/j1/budgets/emails").to_return(
      status: 409,
      body:
        JSON.generate(
          { "error" => "job 'j1' already draws on budget 'emails'" }
        ),
      headers: json_headers
    )

    assert_raises(Zizq::ConflictError) { job.bind_budget("emails") }
  end

  def test_rebind_budget
    stub_request(:put, "#{URL}/jobs/j1/budgets/emails").with(
      body: JSON.generate({ cost: 3 })
    ).to_return(json_response(BOUND_JOB))

    assert_instance_of Zizq::Resources::Job,
                       job.rebind_budget("emails", cost: 3)
  end

  def test_set_budget_cost
    stub_request(:patch, "#{URL}/jobs/j1/budgets/emails").with(
      body: JSON.generate({ cost: 5 })
    ).to_return(json_response(BOUND_JOB))

    assert_instance_of Zizq::Resources::Job, job.set_budget_cost("emails", 5)
  end

  def test_set_budget_cost_raises_when_not_bound
    stub_request(:patch, "#{URL}/jobs/j1/budgets/emails").to_return(
      status: 404,
      body:
        JSON.generate(
          { "error" => "job 'j1' does not draw on budget 'emails'" }
        ),
      headers: json_headers
    )

    assert_raises(Zizq::NotFoundError) { job.set_budget_cost("emails", 5) }
  end

  def test_replace_budgets
    stub_request(:put, "#{URL}/jobs/j1/budgets").with(
      body: JSON.generate({ budgets: [{ key: "emails", cost: 2 }] })
    ).to_return(json_response(BOUND_JOB))

    job.replace_budgets([{ key: "emails", cost: 2 }])
  end

  # The server omits `budgets` for an unthrottled job rather than
  # sending an empty array, so refreshing has to replace the wrapped
  # data rather than merge into it — a merge would leave the binding
  # that was just removed.
  def test_unbind_budget_clears_the_stale_binding_on_the_receiver
    stub_request(:delete, "#{URL}/jobs/j1/budgets/emails").to_return(
      json_response(UNBOUND_JOB)
    )

    bound = job(BOUND_JOB)
    assert_equal [{ key: "emails", cost: 2 }], bound.budgets

    returned = bound.unbind_budget("emails")

    assert_empty returned.budgets
    assert_empty bound.budgets
  end

  def test_unbind_all_budgets
    stub_request(:delete, "#{URL}/jobs/j1/budgets").to_return(
      json_response(UNBOUND_JOB)
    )

    bound = job(BOUND_JOB)
    assert_empty bound.unbind_all_budgets.budgets
    assert_empty bound.budgets
  end

  # Only queued jobs can be rebound — an in-flight one already holds
  # tokens against its budgets.
  def test_binding_refuses_a_job_that_is_not_queued
    stub_request(:post, "#{URL}/jobs/j1/budgets/emails").to_return(
      status: 422,
      body:
        JSON.generate(
          {
            "error" =>
              "job 'j1' is InFlight — only queued jobs may have " \
                "their budgets changed"
          }
        ),
      headers: json_headers
    )

    error = assert_raises(Zizq::ClientError) { job.bind_budget("emails") }
    assert_equal 422, error.status
  end

  private

  def json_headers
    { "Content-Type" => "application/json" }
  end

  def json_response(body)
    { status: 200, body: JSON.generate(body), headers: json_headers }
  end
end
