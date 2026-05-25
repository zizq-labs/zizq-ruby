# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

# This enqueues a largely no-op ActiveJob job a given number of times (default
# 10,000). The worker then starts with those jobs on the queue and processes
# them until it performs the Nth job which is at the back of the queue and then
# exits the process.
#
# Change the environment variable JOB_COUNT to control how many jobs are
# enqueued.

require 'active_job'
require 'active_job/queue_adapters/zizq_adapter'
require_relative './setup'

require 'zizq'
require 'async'

# --- Setup ----

JOB_COUNT = Integer(ENV.fetch("JOB_COUNT", 10_000))
THREADS = Integer(ENV.fetch("THREADS", "5"))
FIBERS = Integer(ENV.fetch("FIBERS", "1"))

Zizq.configure do |c|
  c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
end

# As close to a no-op as possible.
class TestJob < ActiveJob::Base
  self.queue_adapter = :zizq

  def perform(n)
    if n == JOB_COUNT
      Process.kill("TERM", Process.pid)
    end
  end
end

# --- Dequeue Phase ----

enqueue_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

Sync do
  (1..JOB_COUNT).each_slice(1_000) do |nums|
    ActiveJob.perform_all_later(nums.map {|n| TestJob.new(n)})
  end
end

enqueue_finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
enqueue_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - enqueue_started_at

puts format(
  "Enqueued %d jobs in %.3fs (%.3f jobs/sec).",
  JOB_COUNT,
  enqueue_elapsed,
  JOB_COUNT/enqueue_elapsed
)

# --- Dequeue Phase ----

worker = Zizq::Worker.new(
  thread_count: THREADS,
  fiber_count: FIBERS,
)

Signal.trap("TERM") { worker.stop }

dequeue_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

worker.run

dequeue_finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
dequeue_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - dequeue_started_at

puts format(
  "Dequeued %d jobs in %.3fs (%.3f jobs/sec).",
  JOB_COUNT,
  dequeue_elapsed,
  JOB_COUNT/dequeue_elapsed
)
