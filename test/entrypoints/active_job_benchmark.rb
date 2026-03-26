# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

# Entrypoint for the profiler script ./bin/profile-worker. Should also
# work with the standard worker too for benchmarking.
#
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

Zizq.configure do |c|
  c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
end

# As close to a no-op as possible.
class TestJob < ActiveJob::Base
  self.queue_adapter = :zizq

  @@started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def perform(n, total)
    if n == total
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @@started_at
      warn format(
        "Processed %d jobs in %.3fs (%.3f jobs/s). Terminating.",
        total,
        elapsed,
        total/elapsed
      )
      Process.kill("TERM", Process.pid)
    end
  end
end

job_count = Integer(ENV.fetch("JOB_COUNT", 10_000))

warn "Enqueueing #{job_count} jobs"

Sync do
  (1..job_count).each_slice(1_000) do |nums|
    ActiveJob.perform_all_later(nums.map {|n| TestJob.new(n, job_count)})
  end
end
