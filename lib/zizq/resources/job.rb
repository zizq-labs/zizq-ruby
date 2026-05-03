# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a job response hash.
    #
    # Inherits template fields (type, queue, priority, payload, backoff,
    # retention, unique_key, unique_while) from JobTemplate and adds
    # lifecycle fields and action methods.
    class Job < JobTemplate
      def id          = @data["id"]          #: () -> String
      def status      = @data["status"]      #: () -> String
      def ready_at    = ms_to_seconds(@data["ready_at"])    #: () -> Float?
      def attempts    = @data["attempts"]    #: () -> Integer
      def dequeued_at = ms_to_seconds(@data["dequeued_at"]) #: () -> Float?
      def failed_at     = ms_to_seconds(@data["failed_at"])     #: () -> Float?
      def completed_at  = ms_to_seconds(@data["completed_at"])  #: () -> Float?
      def duplicate?    = @data["duplicate"] == true #: () -> bool

      # Fetch the error history for this job.
      #
      # @rbs order: Zizq::sort_direction?
      # @rbs limit: Integer?
      # @rbs page_size: Integer?
      # @rbs return: ErrorEnumerator
      def errors(order: nil, limit: nil, page_size: nil)
        ErrorEnumerator.new(id, order:, limit:, page_size:)
      end

      # Mark this job as successfully completed.
      def complete! #: () -> nil
        @client.report_success(id)
      end

      # Report this job as failed.
      #
      # @rbs message: String
      # @rbs error_type: String?
      # @rbs backtrace: String?
      # @rbs retry_at: Float?
      # @rbs kill: bool
      # @rbs return: Job
      def fail!(message:, error_type: nil, backtrace: nil, retry_at: nil, kill: false)
        @client.report_failure(id, message:, error_type:, backtrace:, retry_at:, kill:)
      end

      # Delete this job.
      #
      # @rbs return: void
      def delete
        @client.delete_job(id)
      end

      # Update this job's mutable fields.
      #
      # Returns the updated job.
      #
      # @rbs queue: (String | singleton(Zizq::UNCHANGED))?
      # @rbs priority: (Integer | singleton(Zizq::UNCHANGED))?
      # @rbs ready_at: (Zizq::to_f | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs retry_limit: (Integer | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs backoff: (Zizq::backoff | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs retention: (Zizq::retention | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs return: Job
      def update(queue: Zizq::UNCHANGED,
                 priority: Zizq::UNCHANGED,
                 ready_at: Zizq::UNCHANGED,
                 retry_limit: Zizq::UNCHANGED,
                 backoff: Zizq::UNCHANGED,
                 retention: Zizq::UNCHANGED)
        job = @client.update_job(
          id,
          queue:,
          priority:,
          ready_at:,
          retry_limit:,
          backoff:,
          retention:
        )

        # Make sure this job's fields are updated.
        @data.merge!(job.to_h)

        job
      end
    end
  end
end
