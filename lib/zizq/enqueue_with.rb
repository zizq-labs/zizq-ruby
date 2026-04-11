# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # A scoped enqueue helper that applies a set of option overrides to every
  # enqueue routed through it.
  #
  # This is sugar for the block form of `Zizq.enqueue`. The two forms below
  # are equivalent:
  #
  #   Zizq.enqueue(SendEmailJob, 42) { |req| req.ready_at = Time.now + 3600 }
  #   Zizq.enqueue_with(ready_at: Time.now + 3600).enqueue(SendEmailJob, 42)
  #
  # Chainable: successive `enqueue_with` calls merge, with later keys
  # winning:
  #
  #   Zizq.enqueue_with(queue: "hi").enqueue_with(priority: 0).enqueue(MyJob)
  #
  # This works inside a bulk block too, applying the overrides to just that one
  # enqueue:
  #
  #   Zizq.enqueue_bulk do |b|
  #     b.enqueue(MyJob, 1)
  #     b.enqueue_with(ready_at: Time.now + 3600).enqueue(OtherJob, 42)
  #   end
  #
  # Also wraps a whole bulk block when used at the top level, applying the
  # overrides to every job in the batch:
  #
  #   Zizq.enqueue_with(priority: 0).enqueue_bulk do |b|
  #     b.enqueue(MyJob, 1)
  #     b.enqueue(MyJob, 2)
  #   end
  #
  # A user block is still allowed and runs *after* the overrides, so it can
  # override them further for that one call:
  #
  #   Zizq.enqueue_with(priority: 100).enqueue(MyJob) { |req| req.priority = 0 }
  #
  # Instances are immutable — `enqueue_with` returns a new instance. Safe
  # to stash and reuse:
  #
  #   high_priority = Zizq.enqueue_with(queue: "hi", priority: 0)
  #   high_priority.enqueue(MyJob, 1)
  #   high_priority.enqueue(OtherJob, 2)
  #
  class EnqueueWith
    # @rbs target: Zizq::enqueue_target
    # @rbs overrides: Hash[Symbol, untyped]
    # @rbs return: void
    def initialize(target, overrides)
      @target = target
      @overrides = overrides.freeze
    end

    # Merge additional overrides into this scope, returning a new instance.
    # Later keys win.
    #
    # @rbs overrides: Hash[Symbol, untyped]
    # @rbs return: EnqueueWith
    def enqueue_with(**overrides)
      self.class.new(@target, @overrides.merge(overrides))
    end

    # Enqueue a job class via the underlying target, applying the scoped
    # overrides before invoking any caller-supplied block.
    #
    # @rbs job_class: Class & Zizq::job_class
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueRequest) -> void
    # @rbs return: untyped
    def enqueue(job_class, *args, **kwargs, &block)
      @target.enqueue(job_class, *args, **kwargs) do |req|
        req.update(**@overrides)
        block&.call(req)
      end
    end

    # Enqueue a raw request via the underlying target, with overrides
    # merged into the kwargs (explicit kwargs take precedence).
    #
    # @rbs queue: String
    # @rbs type: String
    # @rbs payload: untyped
    # @rbs opts: Hash[Symbol, untyped]
    # @rbs return: untyped
    def enqueue_raw(queue:, type:, payload:, **opts)
      @target.enqueue_raw(queue:, type:, payload:, **@overrides.merge(opts))
    end

    # Wrap a bulk block so that every enqueue inside it inherits the
    # scoped overrides. Works uniformly against both the top-level
    # `Zizq` module (starts a new bulk batch) and a `BulkEnqueue`
    # instance (appends to the existing batch), because `BulkEnqueue`
    # implements `enqueue_bulk` as a no-op that yields itself.
    #
    # @rbs &block: (EnqueueWith) -> void
    # @rbs return: untyped
    def enqueue_bulk(&block)
      @target.enqueue_bulk do |b|
        block.call(self.class.new(b, @overrides))
      end
    end
  end
end
