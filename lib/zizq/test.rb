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
  end
end
