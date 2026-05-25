# frozen_string_literal: true

require "zizq"
require "active_job/queue_adapters/zizq_adapter"

Zizq.configure do |c|
  c.url = ENV.fetch("ZIZQ_URL", "http://127.0.0.1:7890")
  c.tls.ca = ENV["ZIZQ_CA"].presence
  c.tls.client_cert = ENV["ZIZQ_CLIENT_CERT"].presence
  c.tls.client_key = ENV["ZIZQ_CLIENT_KEY"].presence
  c.worker.thread_count = Integer(ENV.fetch("ZIZQ_WORKER_THREADS", "4"), 10)
  c.worker.fiber_count = Integer(ENV.fetch("ZIZQ_WORKER_FIBERS", "10"), 10)
  c.worker.queues = ["uptime_monitor/active_job"]
  c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
end
