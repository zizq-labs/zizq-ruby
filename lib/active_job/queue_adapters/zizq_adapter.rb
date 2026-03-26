# frozen_string_literal: true

require "zizq"
require "zizq/active_job_config"

module ActiveJob
  module QueueAdapters
    # ActiveJob adapter for Zizq jobs.
    #
    # To use, set the queue adapter in your Rails configuration:
    #
    #   # config/application.rb
    #   config.active_job.queue_adapter = :zizq
    #
    # And configure the Zizq client to dispatch to ActiveJob:
    #
    #   # config/initializers/zizq.rb
    #   Zizq.configure do |c|
    #     c.url = "http://localhost:7890"
    #     c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
    #   end
    #
    # To use Zizq features (unique jobs, backoff, retention) with ActiveJob
    # classes, you can extend `Zizq::ActiveJobConfig` in your classes:
    #
    #   class SendEmailJob < ApplicationJob
    #     extend Zizq::ActiveJobConfig
    #
    #     zizq_unique true, scope: :active
    #     zizq_backoff exponent: 4.0, base: 15, jitter: 30
    #   end
    #
    class ZizqAdapter
      # Enqueue a job for immediate execution.
      def enqueue(job)
        result = Zizq.enqueue_raw(**enqueue_params(job))
        job.provider_job_id = result.id
        job.successfully_enqueued = true
        result
      end

      # Enqueue a job for execution at a specific time.
      def enqueue_at(job, timestamp)
        job.scheduled_at = timestamp
        result = Zizq.enqueue_raw(**enqueue_params(job))
        job.provider_job_id = result.id
        job.successfully_enqueued = true
        result
      end

      # Enqueue multiple jobs atomically in a single bulk request.
      #
      # Called by `ActiveJob.perform_all_later` (Rails 7.1+).
      # Returns the number of successfully enqueued jobs.
      def enqueue_all(jobs)
        results = Zizq.enqueue_bulk do |b|
          jobs.each do |job|
            b.enqueue_raw(**enqueue_params(job))
          end
        end

        jobs.zip(results).each do |job, result|
          job.provider_job_id = result.id
          job.successfully_enqueued = true
        end

        jobs.size
      rescue => e
        jobs.each { |job| job.successfully_enqueued = false }
        raise e
      end

      # Dispatcher for Zizq workers that executes ActiveJob payloads.
      #
      # ActiveJob handles its own deserialization, callbacks, and error
      # handling. We just pass the serialized payload to `Base.execute`.
      module Dispatcher
        def self.dispatch(job)
          ActiveJob::Base.execute(job.payload)
        end
      end

      private

      def enqueue_params(job)
        params = {
          queue: job.queue_name,
          type: job.class.name,
          payload: job.serialize,
          priority: job.priority,
          ready_at: job.scheduled_at
        }.compact

        klass = job.class

        if klass.respond_to?(:zizq_unique) && klass.zizq_unique
          params[:unique_key] = klass.zizq_unique_key(*job.arguments)
          scope = klass.zizq_unique_scope
          params[:unique_while] = scope if scope
        end

        if klass.respond_to?(:zizq_backoff) && klass.zizq_backoff
          backoff = klass.zizq_backoff
          params[:backoff] = {
            exponent: backoff[:exponent],
            base_ms: (backoff[:base] * 1000).to_f,
            jitter_ms: (backoff[:jitter] * 1000).to_f
          }
        end

        if klass.respond_to?(:zizq_retention) && klass.zizq_retention
          retention = klass.zizq_retention
          wire = {}
          wire[:completed_ms] = (retention[:completed] * 1000).to_i if retention[:completed]
          wire[:dead_ms] = (retention[:dead] * 1000).to_i if retention[:dead]
          params[:retention] = wire
        end

        if klass.respond_to?(:zizq_retry_limit) && klass.zizq_retry_limit
          params[:retry_limit] = klass.zizq_retry_limit
        end

        params
      end
    end
  end
end
