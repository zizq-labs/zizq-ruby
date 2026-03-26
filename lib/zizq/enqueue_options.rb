# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Mutable options object for enqueue-time configuration.
  #
  # Built by `Job::ClassMethods#zizq_enqueue_options` with the class-level
  # defaults already populated. Callers can override values via the block
  # form of `Zizq.enqueue`, and job classes can override the factory method
  # for dynamic logic (e.g. priority based on arguments).
  #
  #   Zizq.enqueue(MyJob, "urgent") { |o| o.priority = 0 }
  #
  class EnqueueOptions
    attr_accessor :queue #: String
    attr_accessor :priority #: Integer?
    attr_accessor :delay #: Zizq::to_f?
    attr_accessor :ready_at #: Zizq::to_f?
    attr_accessor :retry_limit #: Integer?
    attr_accessor :backoff #: Zizq::backoff?
    attr_accessor :retention #: Zizq::retention?
    attr_accessor :unique_key #: String?
    attr_accessor :unique_while #: Zizq::unique_scope?

    # @rbs queue: String
    # @rbs priority: Integer?
    # @rbs delay: Zizq::to_f?
    # @rbs ready_at: Zizq::to_f?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs return: void
    def initialize(queue:,
                   priority: nil,
                   delay: nil,
                   ready_at: nil,
                   retry_limit: nil,
                   backoff: nil,
                   retention: nil,
                   unique_key: nil,
                   unique_while: nil)
      @queue        = queue
      @priority     = priority
      @delay        = delay
      @ready_at     = ready_at
      @retry_limit  = retry_limit
      @backoff      = backoff
      @retention    = retention
      @unique_key   = unique_key
      @unique_while = unique_while
    end
  end
end
