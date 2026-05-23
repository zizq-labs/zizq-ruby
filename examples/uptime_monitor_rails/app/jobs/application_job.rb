# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  extend Zizq::ActiveJobConfig
  queue_as "uptime_monitor/active_job"
end
