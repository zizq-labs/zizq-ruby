# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class TestRouter < ZizqTestCase
  # Stand-in for a `Resources::Job` — the router only ever touches
  # `#type` and `#payload`, plus whatever a fallback chooses to use.
  JobStub = Struct.new(:type, :payload, :attempts)

  # --- Constructor + DSL --------------------------------------------

  def test_route_registered_via_constructor_block_dispatches
    received = nil
    router =
      Zizq::Router.new { route("send_email") { |payload| received = payload } }

    router.call(JobStub.new("send_email", { "user_id" => 42 }))

    assert_equal({ "user_id" => 42 }, received)
  end

  def test_route_can_also_be_added_outside_the_constructor_block
    received = nil
    router = Zizq::Router.new
    router.route("send_email") { |payload| received = payload }

    router.call(JobStub.new("send_email", { "user_id" => 42 }))

    assert_equal({ "user_id" => 42 }, received)
  end

  def test_symbol_types_are_normalised_to_strings
    received = nil
    router =
      Zizq::Router.new { route(:send_email) { |payload| received = payload } }

    # Wire format is String; lookup uses String. Symbol registration
    # would otherwise miss.
    router.call(JobStub.new("send_email", {}))

    assert_equal({}, received)
  end

  # --- Handler arity ------------------------------------------------

  def test_handler_with_arity_zero_is_called_with_no_args
    fired = false
    router = Zizq::Router.new { route("expire_tokens") { fired = true } }

    router.call(JobStub.new("expire_tokens", {}))

    assert fired
  end

  def test_handler_with_arity_one_receives_only_the_payload
    received = nil
    router =
      Zizq::Router.new { route("send_email") { |payload| received = payload } }

    router.call(JobStub.new("send_email", { "to" => "alice" }))

    assert_equal({ "to" => "alice" }, received)
  end

  def test_handler_with_arity_two_receives_payload_and_job
    captured = nil
    router =
      Zizq::Router.new do
        route("generate_report") do |payload, job|
          captured = [payload, job.type]
        end
      end

    router.call(JobStub.new("generate_report", { "id" => 1 }))

    assert_equal [{ "id" => 1 }, "generate_report"], captured
  end

  def test_strict_arity_lambda_handlers_must_declare_both_args
    # Handlers are always invoked as `handler.call(payload, job)`.
    # Block-form procs are lax and tolerate extras; strict lambdas
    # need both parameters declared.
    one_arg_lambda = ->(payload) { payload }
    two_arg_lambda = ->(payload, _job) { payload }
    router = Zizq::Router.new
    router.route("strict_one", &one_arg_lambda)
    router.route("strict_two", &two_arg_lambda)

    assert_raises(ArgumentError) do
      router.call(JobStub.new("strict_one", { "x" => 1 }))
    end

    assert_equal(
      { "x" => 1 },
      router.call(JobStub.new("strict_two", { "x" => 1 }))
    )
  end

  # --- Self / helper methods inside the DSL --------------------------

  def test_routes_can_call_helpers_defined_in_the_constructor_block
    received = nil
    router =
      Zizq::Router.new do
        route("send_email") { |payload| received = decorate(payload) }

        def decorate(payload)
          payload.merge("decorated" => true)
        end
      end

    router.call(JobStub.new("send_email", { "user_id" => 1 }))

    assert_equal({ "user_id" => 1, "decorated" => true }, received)
  end

  # --- Unknown types -------------------------------------------------

  def test_unknown_type_raises_when_no_fallback_is_registered
    router = Zizq::Router.new
    error =
      assert_raises(Zizq::Router::UnknownJobType) do
        router.call(JobStub.new("missing", {}))
      end
    assert_match(/"missing"/, error.message)
  end

  def test_fallback_is_invoked_when_no_route_matches
    captured = nil
    router =
      Zizq::Router.new do
        route("known") {}
        fallback { |job| captured = job.type }
      end

    router.call(JobStub.new("unknown", {}))

    assert_equal "unknown", captured
  end

  def test_fallback_receives_the_full_job_not_a_payload_pair
    captured = nil
    router = Zizq::Router.new { fallback { |job| captured = job } }

    job = JobStub.new("anything", { "k" => "v" })
    router.call(job)

    assert_same job, captured
  end

  def test_routes_win_over_fallback_when_both_are_registered
    route_fired = false
    fallback_fired = false
    router =
      Zizq::Router.new do
        route("send_email") { route_fired = true }
        fallback { |_| fallback_fired = true }
      end

    router.call(JobStub.new("send_email", {}))

    assert route_fired
    refute fallback_fired
  end

  def test_fallback_can_compose_another_dispatcher
    captured_jobs = []
    other_dispatcher = ->(job) { captured_jobs << job }

    router = Zizq::Router.new { fallback { |job| other_dispatcher.call(job) } }

    job = JobStub.new("unhandled", {})
    router.call(job)

    assert_equal [job], captured_jobs
  end
end
