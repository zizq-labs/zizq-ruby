# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Test-mode helpers. Activated by setting `c.test_mode = true` in a
  # `Zizq.configure` block; `Zizq.client` then lazily resolves to a
  # `Zizq::Test::Client` that buffers enqueues instead of dispatching.
  #
  # Typical use in a test helper:
  #
  #   Zizq.configure do |c|
  #     c.test_mode = true
  #   end
  #
  #   class MyTestCase
  #     setup { Zizq::Test.reset! }
  #   end
  #
  # In a test:
  #
  #   def test_signup_fans_out
  #     # Default buffered mode — assert what was enqueued.
  #     SignupService.new.run
  #     assert_equal 2, Zizq::Test.client.pending_jobs.size
  #
  #     # Drain whatever's pending (handler re-enqueues fall through
  #     # naturally — drain loops until pending is empty).
  #     Zizq::Test.dispatch_enqueued_jobs
  #
  #     # Block form: run the work, then drain. Matches ActiveJob's
  #     # `perform_enqueued_jobs do ... end`.
  #     Zizq::Test.dispatch_enqueued_jobs { SignupService.new.run }
  #
  #     # Filter by queue and/or type when only a subset should fire.
  #     Zizq::Test.dispatch_enqueued_jobs(queue: "emails")
  #     Zizq::Test.dispatch_enqueued_jobs(type: SendEmailJob)
  #   end
  module Test
    autoload :Client, "zizq/test/client"

    # Switch Zizq into test mode. After this, `Zizq.client` resolves
    # to a `Zizq::Test::Client` that buffers enqueues in memory.
    # Typically called once in a test helper.
    def self.enable! #: () -> void
      Zizq.configure { |c| c.test_mode = true }
    end

    # Switch back to the real client. The buffered state is dropped
    # along with the test client (the next `Zizq.client` access
    # builds a fresh `Zizq::Client`).
    def self.disable! #: () -> void
      Zizq.configure { |c| c.test_mode = false }
    end

    # The active test client. Raises if test mode is not enabled —
    # better to fail loudly than return a stale or wrong client.
    def self.client #: () -> Client
      unless Zizq.configuration.test_mode
        raise Client::NotSupported,
          "Zizq.configuration.test_mode is not enabled; Zizq::Test.client has nothing to manage."
      end
      Zizq.client #: Client
    end

    # Reset buffered state between tests. Keeps the configured
    # `test_mode` flag.
    def self.reset! #: () -> void
      client.clear!
    end

    # Dispatch pending jobs through the configured dequeue middleware
    # chain (`Zizq.configuration.dequeue_middleware` — same path the
    # real worker uses, so any registered middlewares run in tests
    # too), looping until no more pending entries match the filters.
    #
    # * No block: drain whatever's pending now.
    # * With block: yield first (test code enqueues), then drain.
    # * `only_queues:` / `except_queues:` — String or Array of Strings.
    # * `only_types:`  / `except_types:`  — String, Class, or Array of
    #   those (Class names match the serialized-format `type` via `.to_s`,
    #   so passing an ActiveJob class works directly).
    # * `filter:` — a lambda `->(job)` returning truthy to keep an
    #   entry. Defaults to "pass all". Combines with the named
    #   filters via AND.
    #
    # Returns the number of jobs dispatched. A block exception
    # propagates without draining; a handler exception during drain
    # transitions that entry to `dead` and re-raises.
    def self.dispatch_enqueued_jobs(**filters, &block) #: (**untyped) ?{ () -> void } -> Integer
      yield if block
      client.drain(**filters)
    end

    # Convenience proxies onto the active test client, so test code
    # can read `Zizq::Test.pending_jobs(only_queues: "emails")`
    # instead of routing through `Zizq::Test.client.pending_jobs(...)`.
    # Each forwards `**filters` to the corresponding Client accessor;
    # see `Test::Client` for the supported filter kwargs.
    #
    # All accept the same filter kwargs as `#dispatch_enqueued_jobs`.
    %i[
      enqueued_jobs
      enqueued_requests
      pending_jobs
      in_flight_jobs
      completed_jobs
      dead_jobs
    ].each do |name|
      define_singleton_method(name) do |**filters|
        client.public_send(name, **filters)
      end
    end

    # Was a job of `job_class` enqueued (optionally with matching
    # args)?
    #
    #   Zizq::Test.enqueued?(SendEmailJob)                            # any args
    #   Zizq::Test.enqueued?(SendEmailJob, 42, template: "welcome")   # exact args
    #
    # With no args, matches by class/type only. With args/kwargs,
    # uses the class's own `zizq_serialize` to compute the expected
    # payload — so it works for both `Zizq::Job` and AJ classes
    # (AJ's volatile fields like `job_id` are ignored, only the
    # `arguments` subset is compared).
    #
    # For anything fuzzier (matchers, subset matching, custom
    # predicates), drop down to
    # `client.enqueued_jobs(only_types: ..., filter: ->(job) { ... })`.
    def self.enqueued?(job_class, *args, **kwargs) #: (Class, *untyped, **untyped) -> bool
      enqueued_count(job_class, *args, **kwargs) > 0
    end

    # How many times was a job of `job_class` enqueued (optionally
    # with matching args)? Same argument semantics as `#enqueued?`.
    def self.enqueued_count(job_class, *args, **kwargs) #: (Class, *untyped, **untyped) -> Integer
      type = job_class.to_s
      return enqueued_raw_count(type: type) if args.empty? && kwargs.empty?

      unless job_class.respond_to?(:zizq_serialize)
        raise ArgumentError,
          "#{job_class} doesn't implement zizq_serialize — " \
          "include Zizq::Job or extend Zizq::ActiveJobConfig, " \
          "or use Zizq::Test.enqueued_raw? for raw enqueues."
      end

      expected = job_class.zizq_serialize(*args, **kwargs)
      client.enqueued_jobs(only_types: type).count do |job|
        payloads_equivalent?(expected, job.payload)
      end
    end

    # Was a raw job (queue + type + payload) enqueued? Each kwarg is
    # optional; unspecified means "don't filter on this axis."
    #
    #   Zizq::Test.enqueued_raw?(type: "send_email")
    #   Zizq::Test.enqueued_raw?(type: "send_email", payload: { user_id: 42 })
    #   Zizq::Test.enqueued_raw?(queue: "emails", type: "send_email")
    def self.enqueued_raw?(queue: nil, type: nil, payload: nil) #: (?queue: String?, ?type: String?, ?payload: untyped) -> bool
      enqueued_raw_count(queue: queue, type: type, payload: payload) > 0
    end

    # How many raw jobs match (queue + type + payload)? Same
    # argument semantics as `#enqueued_raw?`.
    def self.enqueued_raw_count(queue: nil, type: nil, payload: nil) #: (?queue: String?, ?type: String?, ?payload: untyped) -> Integer
      filters = {}
      filters[:only_queues] = queue if queue
      filters[:only_types]  = type  if type
      filters[:filter]      = ->(job) { job.payload == payload } unless payload.nil?
      client.enqueued_jobs(**filters).size
    end

    # Heuristic payload comparison that handles both `Zizq::Job`'s
    # serialized format (`{"args" => [...], "kwargs" => {...}}`) and
    # ActiveJob's (`{"job_class" => ..., "arguments" => [...],
    # "job_id" => ..., "enqueued_at" => ..., ...}`). The AJ shape
    # always has an `"arguments"` key while `Zizq::Job`'s doesn't, so
    # we use that to pick whether to compare the full hash or only the
    # `arguments` subset (dropping AJ's volatile per-enqueue fields).
    def self.payloads_equivalent?(expected, actual) #: (untyped, untyped) -> bool
      if expected.is_a?(Hash) && expected.key?("arguments")
        actual.is_a?(Hash) && actual["arguments"] == expected["arguments"]
      else
        actual == expected
      end
    end
  end
end
