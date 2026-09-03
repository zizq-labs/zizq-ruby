# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a job template — the fields shared between
    # live jobs and cron entry job definitions.
    class JobTemplate < Resource
      def type = @data["type"] #: () -> String
      def queue = @data["queue"] #: () -> String
      def priority = @data["priority"] #: () -> Integer?
      def payload = @data["payload"] #: () -> Hash[String, untyped]?
      def retry_limit = @data["retry_limit"] #: () -> Integer?
      def unique_key = @data["unique_key"] #: () -> String?
      def unique_while = @data["unique_while"]&.to_sym #: () -> Zizq::unique_scope?

      # Batching configuration for this job. Retutns `nil` for non-batched jobs.
      def batch #: () -> Zizq::batch?
        raw = @data["batch"]
        return nil unless raw

        { key: raw["key"], when: raw["when"], fold: raw["fold"] }
      end

      # Backoff configuration converted from the API format (ms) to the
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

      # Budgets this job must satisfy on when it dispatches, each with the cost
      # it consumes.
      #
      # Not present for a normal job that dispatches as soon as it reaches the
      # front of the queue.
      #
      # `cost` is the number of tokens the job takes from the budget. Any
      # `create_with` the enqueue specified is not stored on the job and is
      # only used during the enqueue operation.
      def budgets #: () -> Array[Zizq::budget_binding]
        (@data["budgets"] || []).map do |b|
          { key: b["key"], cost: b["cost"] } #: Zizq::budget_binding
        end
      end

      # Retention configuration converted from the API format (ms) to the
      # Ruby-idiomatic format (seconds), matching the Zizq::retention type.
      def retention #: () -> Zizq::retention?
        raw = @data["retention"]
        return nil unless raw

        result = {} #: Hash[Symbol, Float]
        result[:completed] = raw["completed_ms"] / 1000.0 if raw["completed_ms"]
        result[:dead] = raw["dead_ms"] / 1000.0 if raw["dead_ms"]
        result
      end
    end
  end
end
