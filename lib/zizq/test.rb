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
  #     setup    { Zizq::Test.reset! }
  #   end
  #
  # Inspect what was enqueued via `Zizq::Test.client.enqueued_jobs`.
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
    # `test_mode` flag so the next `Zizq.client` access still resolves
    # to the test client.
    def self.reset! #: () -> void
      client.clear!
    end
  end
end
