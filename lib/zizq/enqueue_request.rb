# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Represents a job enqueue request.
  #
  # Contains all the information needed to enqueue a job. Built by
  # `Job::ClassMethods#zizq_enqueue_options` or directly for raw enqueues.
  # Mutable — callers can override values via the block form of
  # `Zizq.enqueue`.
  #
  #   Zizq.enqueue(MyJob, 42) { |req| req.priority = 0 }
  #
  class EnqueueRequest
    # Job type string (e.g. class name).
    attr_accessor :type #: String

    # Target queue name.
    attr_accessor :queue #: String

    # Job payload (serialized arguments).
    attr_accessor :payload #: untyped

    # Job priority (lower = higher priority).
    attr_accessor :priority #: Integer?

    # Delay before the job becomes ready (seconds).
    attr_accessor :delay #: Zizq::to_f?

    # Absolute time when the job becomes ready (fractional seconds since epoch).
    attr_accessor :ready_at #: Zizq::to_f?

    # Maximum number of retries before the job is killed.
    attr_accessor :retry_limit #: Integer?

    # Backoff configuration (in seconds).
    attr_accessor :backoff #: Zizq::backoff?

    # Retention configuration (in seconds).
    attr_accessor :retention #: Zizq::retention?

    # Unique key for deduplication.
    attr_accessor :unique_key #: String?

    # Uniqueness scope.
    attr_accessor :unique_while #: Zizq::unique_scope?

    # @rbs type: String
    # @rbs queue: String
    # @rbs payload: untyped
    # @rbs priority: Integer?
    # @rbs delay: Zizq::to_f?
    # @rbs ready_at: Zizq::to_f?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs return: void
    def initialize(type:,
                   queue:,
                   payload:,
                   priority: nil,
                   delay: nil,
                   ready_at: nil,
                   retry_limit: nil,
                   backoff: nil,
                   retention: nil,
                   unique_key: nil,
                   unique_while: nil)
      update(
        type:,
        queue:,
        payload:,
        priority:,
        delay:,
        ready_at:,
        retry_limit:,
        backoff:,
        retention:,
        unique_key:,
        unique_while:,
      )
    end

    # Update one or more fields in place.
    #
    # Each keyword argument defaults to the current field value, so
    # callers only need to name the fields they want to change. Returns
    # `self` for chaining. Unknown keys raise `ArgumentError` — this is
    # the signal that prevents typos like `:retries` from silently
    # doing nothing.
    #
    #   req.update(priority: 0, ready_at: Time.now + 60)
    #
    # Used by `Zizq::EnqueueWith` to apply scoped overrides, and can be
    # called directly from enqueue blocks as an alternative to assigning
    # individual attributes.
    #
    # @rbs type: String
    # @rbs queue: String
    # @rbs payload: untyped
    # @rbs priority: Integer?
    # @rbs delay: Zizq::to_f?
    # @rbs ready_at: Zizq::to_f?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs return: self
    def update(type: @type,
               queue: @queue,
               payload: @payload,
               priority: @priority,
               delay: @delay,
               ready_at: @ready_at,
               retry_limit: @retry_limit,
               backoff: @backoff,
               retention: @retention,
               unique_key: @unique_key,
               unique_while: @unique_while)
      @type         = type
      @queue        = queue
      @payload      = payload
      @priority     = priority
      @delay        = delay
      @ready_at     = ready_at
      @retry_limit  = retry_limit
      @backoff      = backoff
      @retention    = retention
      @unique_key   = unique_key
      @unique_while = unique_while
      self
    end

    # Convert to the params expected by `Client#enqueue`.
    #
    # Handles seconds -> milliseconds conversion for time-based fields,
    # delay -> ready_at resolution, and nil omission.
    def to_enqueue_params #: () -> Hash[Symbol, untyped]
      params = { queue:, type:, payload: } #: Hash[Symbol, untyped]
      params[:priority] = priority if priority

      effective_ready_at = if delay
        Time.now.to_f + delay.to_f
      else
        ready_at
      end
      params[:ready_at] = effective_ready_at if effective_ready_at

      params[:retry_limit] = retry_limit if retry_limit

      if backoff
        params[:backoff] = {
          exponent: backoff[:exponent].to_f,
          base_ms: (backoff[:base].to_f * 1000).to_f,
          jitter_ms: (backoff[:jitter].to_f * 1000).to_f
        }
      end

      if retention
        ret = {} #: Hash[Symbol, Integer]
        ret[:completed_ms] = (retention[:completed].to_f * 1000).to_i if retention[:completed]
        ret[:dead_ms] = (retention[:dead].to_f * 1000).to_i if retention[:dead]
        params[:retention] = ret
      end

      params[:unique_key] = unique_key if unique_key
      params[:unique_while] = unique_while.to_s if unique_while

      params
    end
  end
end
