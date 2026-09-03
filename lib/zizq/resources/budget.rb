# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a budget response hash.
    #
    # A budget is a named token bucket that jobs draw from. Its strategy
    # decides how tokens are managed: on a clock (`time_based`, a rate
    # limit) or when a job stops running (`while_in_flight`, a
    # concurrency limit, of which a mutex is the allocation = 1 case).
    class Budget < Resource
      # The budget's key, unique across the server.
      def key = @data["key"] #: () -> String

      # Tokens the budget makes available.
      #
      # For a `time_based` budget, how many tokens can be spent over its
      # `duration`. For a `while_in_flight` budgets how many jobs may run
      # at once.
      def allocation = @data["allocation"] #: () -> Integer

      def created_at = ms_to_seconds(@data["created_at"]) #: () -> Float?
      def updated_at = ms_to_seconds(@data["updated_at"]) #: () -> Float?

      # `:time_based` or `:while_in_flight`.
      def strategy_type = strategy[:type] #: () -> Zizq::budget_strategy_type

      def time_based? = strategy_type == :time_based #: () -> bool
      def while_in_flight? = strategy_type == :while_in_flight #: () -> bool

      # Period over which the whole allocation replenishes, in seconds.
      #
      # Tokens accrue using a continuous drip (leaky bucket) such that an
      # empty bucket is full after this duration has elapsed, and is half
      # full after half of the duration has elapsed, etc.
      #
      # `nil` for a `while_in_flight` budget.
      def duration = strategy[:duration] #: () -> Float?

      # Max tokens the bucket may hold at once, or `nil` when it holds
      # a whole allocation.
      #
      # A newly created bucket starts full, so a budget with no burst set
      # hands out an entire allocation the moment work arrives and only
      # then settles to its continuous drip rate — `10` per minute really
      # does permit twenty in the first minute. Setting a burst caps that
      # spike without changing the long-run rate; a burst of `1` paces
      # dispatches evenly at all times. The burst rule also applies to
      # budgets that have not been consumed for an entire duration's worth
      # of time.
      #
      # It is valid for `burst` to be set higher than the `allocation`. In
      # this case the meaning is to continue filling the bucket after the
      # duration has elapsed, so a `burst` of 200 on a 100 token allocation
      # would continue accruing across two consecutive periods, but no more
      # than that.
      #
      # This is designed to allow applications to absorb short-lived
      # spikes.
      #
      # `nil` for a `while_in_flight` budget.
      def burst = strategy[:burst] #: () -> Integer?

      # Most tokens the bucket can hold, which is what a job's cost has
      # to fit inside.
      #
      # The burst where one is set, and the allocation otherwise. Worth
      # distinguishing from `allocation`: with a burst set it is the
      # *smaller* number that decides whether a job can ever be
      # afforded, so a cost well within the allocation may still be
      # refused.
      def capacity #: () -> Integer
        burst || allocation
      end

      # The whole strategy, in the form `create_budget` and `put_budget`
      # take it.
      #
      #     budget = client.get_budget("emails")
      #     client.put_budget(
      #       "emails",
      #       allocation: budget.allocation * 2,
      #       strategy: budget.strategy
      #     )
      #
      # When absent, `burst` is omitted rather than sent as `nil`, since
      # an absent burst and one explicitly cleared mean the same thing.
      def strategy #: () -> Zizq::budget_strategy
        @strategy ||= {
          type: raw_strategy["type"]&.to_sym,
          duration: ms_to_seconds(raw_strategy["duration_ms"]),
          burst: raw_strategy["burst"]
        }.compact #: Zizq::budget_strategy
      end

      private

      # The strategy exactly as the server sent it — string keys, and
      # the period in milliseconds under `duration_ms`.
      def raw_strategy #: () -> Hash[String, untyped]
        @data["strategy"] || {}
      end
    end
  end
end
