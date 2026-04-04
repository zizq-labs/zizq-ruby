# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a job response hash.
    #
    # Exposes named accessor methods with Ruby-idiomatic types (fractional
    # seconds instead of milliseconds) and link methods that follow related
    # resources through the Client.
    class Job < Resource
      def id          = @data["id"]          #: () -> String
      def type        = @data["type"]        #: () -> String
      def queue       = @data["queue"]       #: () -> String
      def priority    = @data["priority"]    #: () -> Integer
      def status      = @data["status"]      #: () -> String
      def ready_at    = ms_to_seconds(@data["ready_at"])    #: () -> Float?
      def attempts    = @data["attempts"]    #: () -> Integer
      def payload     = @data["payload"]     #: () -> Hash[String, untyped]?
      def dequeued_at = ms_to_seconds(@data["dequeued_at"]) #: () -> Float?
      def failed_at     = ms_to_seconds(@data["failed_at"])     #: () -> Float?
      def completed_at  = ms_to_seconds(@data["completed_at"])  #: () -> Float?
      def retry_limit   = @data["retry_limit"] #: () -> Integer?
      def unique_key    = @data["unique_key"]  #: () -> String?
      def unique_while  = @data["unique_while"]&.to_sym #: () -> Zizq::unique_scope?
      def duplicate?    = @data["duplicate"] == true #: () -> bool

      # Backoff configuration converted from the wire format (ms) to the
      # Ruby-idiomatic format (seconds), matching the Zizq::backoff type.
      def backoff #: () -> Zizq::backoff?
        raw = @data["backoff"]
        return nil unless raw

        {
          exponent: raw["exponent"].to_f,
          base: raw["base_ms"] / 1000.0,
          jitter: raw["jitter_ms"] / 1000.0
        }
      end

      # Retention configuration converted from the wire format (ms) to the
      # Ruby-idiomatic format (seconds), matching the Zizq::retention type.
      def retention #: () -> Zizq::retention?
        raw = @data["retention"]
        return nil unless raw

        result = {} #: Hash[Symbol, Float]
        result[:completed] = raw["completed_ms"] / 1000.0 if raw["completed_ms"]
        result[:dead] = raw["dead_ms"] / 1000.0 if raw["dead_ms"]
        result
      end

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
