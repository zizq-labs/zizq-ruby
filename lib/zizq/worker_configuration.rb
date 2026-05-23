# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Defaults for `Zizq::Worker` instances. Accessed via
  # `Zizq.configuration.worker` and typically populated inside an
  # application's `Zizq.configure` block:
  #
  #   Zizq.configure do |c|
  #     c.url = "https://..."
  #     c.worker.queues = ["emails", "webhooks"]
  #     c.worker.thread_count = 1
  #     c.worker.fiber_count = 25
  #   end
  #
  # Every field defaults to `nil`, meaning "use the Worker's own
  # hardcoded default." Anything explicitly passed to `Worker.new` —
  # or set via CLI flag / env var when launching `zizq-worker` —
  # overrides whatever is set here.
  #
  # See `Zizq::Worker#initialize` for the full resolution order
  # (explicit kwarg → Zizq.configuration.worker → `Worker::DEFAULT_*`).
  #
  # Fields:
  #
  # * `queues` — Queues to consume. `[]` means all queues.
  # * `thread_count` — Number of worker threads.
  # * `fiber_count` — Number of fibers per worker thread.
  # * `prefetch` — Server-side prefetch limit. Defaults to
  #   `2 * threads * fibers`.
  # * `retry_min_wait` — Minimum reconnect backoff in seconds.
  # * `retry_max_wait` — Maximum reconnect backoff in seconds.
  # * `retry_multiplier` — Multiplicative backoff factor between
  #   reconnect attempts.
  WorkerConfiguration = Struct.new(
    :queues,           #: Array[String]?
    :thread_count,     #: Integer?
    :fiber_count,      #: Integer?
    :prefetch,         #: Integer?
    :retry_min_wait,   #: (Float | Integer)?
    :retry_max_wait,   #: (Float | Integer)?
    :retry_multiplier, #: (Float | Integer)?
    keyword_init: true
  )
end
