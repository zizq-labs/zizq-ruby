# frozen_string_literal: true

require "zizq"
require "active_job/queue_adapters/zizq_adapter"

Zizq.configure do |c|
  c.url = ENV.fetch("ZIZQ_URL", "http://127.0.0.1:7890")
  c.worker.thread_count = 4
  c.worker.fiber_count = 25
  c.worker.queues = ["uptime_monitor/active_job"]
  c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
end
