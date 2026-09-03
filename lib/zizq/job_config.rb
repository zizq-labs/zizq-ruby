# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require "digest"
require "json"

module Zizq
  # Shared class-level configuration DSL for Zizq job classes.
  #
  # This module provides the queue, priority, retry, backoff, retention,
  # and uniqueness configuration methods. It is extended onto job classes
  # by `Zizq::Job` and can also be used with ActiveJob via
  # `Zizq::ActiveJobConfig`.
  #
  # Modules including this module must implement `zizq_serialize` and
  # `zizq_deserialize` to define how job arguments are serialized for the API.
  module JobConfig
    # @rbs!
    #   # The class name where this is included (invisible to steep without this).
    #   def name: () -> String?

    # Serialize positional and keyword arguments into a JSON-serializable
    # payload.
    #
    # Implemented by the including module.
    def zizq_serialize(*args, **kwargs) #: (*untyped, **untyped) -> untyped
      raise NotImplementedError, "#{self} must implement zizq_serialize"
    end

    # Deserialize positional and keyword arguments from the serialized payload.
    #
    # Implemented by the including module.
    def zizq_deserialize(payload) #: untyped -> [Array[untyped], Hash[Symbol, untyped]]
      raise NotImplementedError, "#{self} must implement zizq_deserialize"
    end

    # Generate a jq expression that exactly matches payloads with the given
    # arguments.
    #
    # Implemented by the including module.
    def zizq_payload_filter(*args, **kwargs) #: (*untyped, **untyped) -> String
      raise NotImplementedError, "#{self} must implement zizq_payload_filter"
    end

    # Generate a jq expression that matches a subset of the given arguments.
    #
    # Implemented by the including module.
    def zizq_payload_subset_filter(*args, **kwargs) #: (*untyped, **untyped) -> String
      raise NotImplementedError,
            "#{self} must implement zizq_payload_subset_filter"
    end

    # Declare the default queue for this job class.
    #
    # If not called, defaults to "default". Jobs enqueued for this class will
    # use the specified queue unless explicitly overridden during
    # [`Zizq::enqueue`] or by overriding `::zizq_enqueue_options` on the job
    # class.
    def zizq_queue(name = nil) #: (?String?) -> String
      if name
        @zizq_queue = name
      else
        @zizq_queue || "default"
      end
    end

    # Declare the default priority for this job class.
    #
    # If not called, defaults to the default priority on the Zizq server.
    # Jobs enqueued for this class will use the specified priority unless
    # explicitly overridden during [`Zizq::enqueue`] or by overriding
    # `::zizq_enqueue_options` on the job class.
    def zizq_priority(priority = nil) #: (?Integer?) -> Integer?
      if priority
        @zizq_priority = priority
      else
        @zizq_priority
      end
    end

    # Declare the default retry limit for this job class.
    #
    # The job may fail up to the number of times specified by the retry limit
    # and will exponentially backoff. Once the retry limit is reached, the
    # job is killed and becomes part of the dead set.
    #
    # If not configured, the server's default is used.
    def zizq_retry_limit(limit = nil) #: (?Integer?) -> Integer?
      if limit
        @zizq_retry_limit = limit
      else
        @zizq_retry_limit
      end
    end

    # Declare the default backoff configuration for this job class.
    #
    # Times are specified in seconds (optionally fractional).
    # In a Rails app `ActiveSupport::Duration` is supported too.
    #
    # All three parameters must be specified together and are used in the
    # following exponential backoff formula:
    #
    #   delay = base + attempts**exponent + rand(0.0..jitter)*attempts
    #
    # Example:
    #
    #   zizq_backoff exponent: 4.0, base: 15, jitter: 30
    #
    # If not configured, the server's default backoff policy is used.
    def zizq_backoff(exponent: nil, base: nil, jitter: nil) #: (?exponent: Numeric?, ?base: Numeric?, ?jitter: Numeric?) -> Zizq::backoff?
      if exponent || base || jitter
        unless exponent && base && jitter
          raise ArgumentError, "all of exponent:, base:, jitter: are required"
        end

        @zizq_backoff = {
          exponent: exponent.to_f,
          base: base.to_f,
          jitter: jitter.to_f
        }
      else
        @zizq_backoff
      end
    end

    # Declare the default retention configuration for this job class.
    #
    # Times are specified in seconds (optionally fractional).
    # In a Rails app `ActiveSupport::Duration` is supported too.
    #
    # Both parameters are optional — only the ones provided will be sent
    # to the server. Omitted values use the server's defaults.
    #
    # Example:
    #
    #   zizq_retention completed: 0, dead: 7 * 86_400
    #
    # If not configured, the server's default is used.
    def zizq_retention(completed: nil, dead: nil) #: (?completed: Numeric?, ?dead: Numeric?) -> Zizq::retention?
      if completed || dead
        result = {} #: Hash[Symbol, Float]

        result[:completed] = completed.to_f if completed
        result[:dead] = dead.to_f if dead

        @zizq_retention = result
      else
        @zizq_retention
      end
    end

    # Declare a budget this job is bound to.
    #
    # Budgets are used for concurrency control and rate limiting, and
    # require a Pro license on the server.
    #
    # This method is additive, called once per budget:
    #
    #   zizq_budget "emails", cost: 2
    #   zizq_budget "stripe"
    #
    # The `cost` is how many tokens one job of this class consumes when
    # it dispatches, defaulting to 1. `create_with` declares the
    # budget's policy should it not exist yet, so jobs can be enqueued
    # without first creating the budget in a separate step:
    #
    #   zizq_budget "emails",
    #               create_with: {
    #                 allocation: 100,
    #                 strategy: { type: :time_based, duration: 60 }
    #               }
    #
    # It is ignored when the budget already exists, so this cannot
    # accidentally overwrite an already configured budget.
    #
    # Declaring the same key twice raises `ArgumentError' — the server
    # would reject a duplicate key outright.
    #
    # A per-enqueue `budgets` replaces these rather than adding to
    # them, the same way a block-assigned `queue` or `priority` does:
    #
    #   Zizq.enqueue(SendEmailJob) { |req| req.budgets = [...] }
    #   Zizq.enqueue(SendEmailJob) { |req| req.budgets << {key: "x"} }
    #
    # @rbs key: String
    # @rbs cost: Integer?
    # @rbs create_with: Zizq::budget_policy?
    # @rbs return: Zizq::budget_binding_params
    def zizq_budget(key, cost: nil, create_with: nil)
      if zizq_budgets.any? { |b| b[:key] == key }
        raise ArgumentError, "#{self}: budget '#{key}' is already declared"
      end

      binding = { key: } #: Zizq::budget_binding_params
      binding[:cost] = cost if cost
      binding[:create_with] = create_with if create_with

      @zizq_budgets = zizq_budgets << binding.freeze
      binding
    end

    # Budgets declared on this class, in declaration order.
    #
    # A fresh array each call, so mutating it cannot corrupt the
    # class-level declaration. The bindings themselves are frozen.
    def zizq_budgets #: () -> Array[Zizq::budget_binding_params]
      (@zizq_budgets || []).dup
    end

    # Declare uniqueness for this job class.
    #
    # Requires a pro license.
    #
    # When enabled, duplicate jobs with the same unique key are rejected
    # at enqueue time. The optional scope controls how long the
    # uniqueness guard lasts:
    #
    #   :queued  — unique while "scheduled" or "ready" (server default)
    #   :active  — unique while "scheduled", "ready", or "in_flight"
    #   :exists  — unique until the job is reaped by the server
    #
    # Examples:
    #
    #   zizq_unique true                   # unique, server default scope
    #   zizq_unique true, scope: :active   # unique while active
    #   zizq_unique false                  # disable (e.g. in a subclass)
    #
    def zizq_unique(unique = nil, scope: nil) #: (?bool?, ?scope: Zizq::unique_scope?) -> bool
      if unique.nil?
        @zizq_unique || false
      else
        if unique && zizq_batched
          raise ArgumentError,
                "#{self}: zizq_unique cannot be combined with zizq_batched"
        end
        @zizq_unique = !!unique
        @zizq_unique_scope = scope
        @zizq_unique
      end
    end

    # Declare or read the uniqueness scope for this job class.
    #
    # Usually set via `zizq_unique true, scope: :active` but can also
    # be set independently.
    def zizq_unique_scope(scope = nil) #: (?Zizq::unique_scope?) -> Zizq::unique_scope?
      if scope
        @zizq_unique_scope = scope
      else
        @zizq_unique_scope
      end
    end

    # Declare or read batched-job configuration for this class.
    #
    # When enabled, subsequent enqueues that share the batch key are
    # folded into the pending job's payload rather than creating a new
    # job. The batch target is a specific positional arg (`arg:`) or
    # keyword arg (`kwarg:`) whose value must be an array; other args
    # participate in the batch key.
    #
    #   zizq_batched true, limit: 100                     # arg: 0 by default
    #   zizq_batched true, kwarg: :notifications, limit: 100
    #   zizq_batched true, limit: 50, dedup: true         # + `| unique`
    #   zizq_batched true, limit: 50, sorted: true        # + `| sort`
    #   zizq_batched false                                # disable in a subclass
    #
    # Cannot be combined with `zizq_unique` — the server rejects the
    # combination and the client raises at declaration time.
    #
    # @rbs enabled: bool?
    # @rbs arg: Integer?
    # @rbs kwarg: Symbol?
    # @rbs limit: Integer?
    # @rbs dedup: bool
    # @rbs sorted: bool
    # @rbs return: bool
    def zizq_batched(
      enabled = nil,
      arg: nil,
      kwarg: nil,
      limit: nil,
      dedup: false,
      sorted: false
    )
      return @zizq_batched || false if enabled.nil?

      if enabled
        if zizq_unique
          raise ArgumentError,
                "#{self}: zizq_batched cannot be combined with zizq_unique"
        end
        if arg && kwarg
          raise ArgumentError,
                "#{self}: zizq_batched cannot specify both arg: and kwarg:"
        end
        if limit.nil?
          raise ArgumentError, "#{self}: zizq_batched requires limit:"
        end
        unless limit.is_a?(Integer) && limit.positive?
          raise ArgumentError,
                "#{self}: zizq_batched limit: must be a positive Integer"
        end

        @zizq_batched = true
        @zizq_batch_arg = kwarg.nil? ? (arg || 0) : nil
        @zizq_batch_kwarg = kwarg
        @zizq_batch_limit = limit
        @zizq_batch_dedup = dedup
        @zizq_batch_sorted = sorted
      else
        @zizq_batched = false
        @zizq_batch_arg = nil
        @zizq_batch_kwarg = nil
        @zizq_batch_limit = nil
        @zizq_batch_dedup = false
        @zizq_batch_sorted = false
      end

      @zizq_batched
    end

    # Positional arg index that participates in the batch payload, or
    # `nil` if `kwarg:` was chosen instead.
    def zizq_batch_arg #: () -> Integer?
      @zizq_batch_arg
    end

    # Keyword arg name that participates in the batch payload, or `nil`
    # if `arg:` was chosen instead.
    def zizq_batch_kwarg #: () -> Symbol?
      @zizq_batch_kwarg
    end

    # Maximum combined length of the batch payload before the current
    # batch is sealed and a fresh one starts.
    def zizq_batch_limit #: () -> Integer?
      @zizq_batch_limit
    end

    # Whether the fold expression appends `| unique` to dedup entries
    # within a batch.
    def zizq_batch_dedup? #: () -> bool
      @zizq_batch_dedup || false
    end

    # Whether the fold expression appends `| sort` to sort entries
    # within a batch.
    def zizq_batch_sorted? #: () -> bool
      @zizq_batch_sorted || false
    end

    # Compute the unique key for a job with the given arguments.
    #
    # The default implementation uses the class name and hashes the
    # normalized serialized payload. Override this method to customize
    # uniqueness — for example, to ignore certain arguments:
    #
    #   def self.zizq_unique_key(user_id, template:)
    #     super(user_id)  # unique per user, ignoring template
    #   end
    def zizq_unique_key(*args, **kwargs) #: (*untyped, **untyped) -> String
      hash_args(*args, **kwargs)
    end

    # Compute the batch key for a job with the given arguments.
    #
    # The default implementation drops the configured batch target
    # (positional `arg:` or `kwarg:`) from the arguments and hashes
    # everything else. Two enqueues with the same non-batch arguments
    # therefore produce the same batch key, so they fold into the same
    # pending job; different non-batch arguments produce different keys
    # and end up in separate batches.
    #
    # Override this method to customize batching — for example, to
    # batch by tenant regardless of what else is passed:
    #
    #   def self.zizq_batch_key(_notifications, tenant_id:, **_)
    #     "#{name}:tenant-#{tenant_id}"
    #   end
    def zizq_batch_key(*args, **kwargs) #: (*untyped, **untyped) -> String
      filtered_args =
        args.dup.tap { |a| a.delete_at(zizq_batch_arg) if zizq_batch_arg }
      filtered_kwargs = kwargs.except(zizq_batch_kwarg)

      hash_args(*filtered_args, **filtered_kwargs)
    end

    # Build the static jq expressions (`when` predicate, `fold`
    # reducer) for this class's batch configuration.
    #
    # Implemented by the including module — `Zizq::Job` and
    # `Zizq::ActiveJobConfig` know how to target the right JSON path
    # for their respective payload shapes. Returns `nil` when the
    # class is not batched.
    #
    # Override to supply completely custom `when`/`fold` expressions
    # that the DSL flags don't cover.
    def zizq_batch_expressions #: () -> Zizq::batch_expressions?
      return nil unless zizq_batched

      raise NotImplementedError, "#{self} must implement zizq_batch_expressions"
    end

    # Build a `Zizq::EnqueueRequest` from the class-level job config.
    #
    # Subclasses can override this to implement dynamic logic such as
    # priority based on arguments:
    #
    #   def self.zizq_enqueue_request(user_id, template:)
    #     req = super
    #     req.priority = 0 if template == "urgent"
    #     req
    #   end
    def zizq_enqueue_request(*args, **kwargs) #: (*untyped, **untyped) -> EnqueueRequest
      EnqueueRequest.new(
        type: name || raise(ArgumentError, "Cannot enqueue anonymous class"),
        queue: zizq_queue,
        payload: zizq_serialize(*args, **kwargs),
        priority: zizq_priority,
        retry_limit: zizq_retry_limit,
        backoff: zizq_backoff,
        retention: zizq_retention,
        unique_while: zizq_unique ? zizq_unique_scope : nil,
        unique_key: zizq_unique ? zizq_unique_key(*args, **kwargs) : nil,
        batch: zizq_batched ? batch_for_enqueue(*args, **kwargs) : nil,
        budgets: zizq_budgets
      )
    end

    private

    # Class-name-prefixed SHA256 of the normalized hashable payload.
    # Shared primitive powering both `zizq_unique_key` and
    # `zizq_batch_key` — the two features hash arguments the same way,
    # they just choose *which* arguments to hash.
    def hash_args(*args, **kwargs) #: (*untyped, **untyped) -> String
      payload = normalize_payload(hashable_args(*args, **kwargs))
      "#{name}:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    # The subset of the serialized payload that participates in key
    # hashing. Defaults to the full serialized payload; overridden by
    # `ActiveJobConfig` to hash only the ActiveJob `arguments` array
    # (skipping volatile envelope fields like `job_id` and
    # `enqueued_at` that vary per enqueue).
    def hashable_args(*args, **kwargs) #: (*untyped, **untyped) -> untyped
      zizq_serialize(*args, **kwargs)
    end

    # Compose `zizq_batch_expressions` (static) with `zizq_batch_key`
    # (dynamic, arg-dependent) into a full API serialized `Zizq::batch`.
    def batch_for_enqueue(*args, **kwargs) #: (*untyped, **untyped) -> Zizq::batch?
      expr = zizq_batch_expressions
      return nil unless expr

      {
        key: zizq_batch_key(*args, **kwargs),
        when: expr[:when],
        fold: expr[:fold]
      }
    end

    # Compile `when`/`fold` expressions targeting a jq path (e.g.
    # `.args[0]` for `Zizq::Job` or `.arguments[-1].notifications`
    # for `ActiveJobConfig`). Applies dedup/sorted flags. Shared
    # across payload shapes because only the target path differs.
    def build_batch_expressions(target) #: (String) -> Zizq::batch_expressions
      limit = zizq_batch_limit
      when_expr = "($existing#{target} + $new#{target}) | length <= #{limit}"

      fold_expr =
        if zizq_batch_dedup?
          # `unique` in jq also sorts, so it subsumes `sorted:` too.
          "$existing | #{target} = " \
            "(#{target} + $new#{target} | unique)"
        elsif zizq_batch_sorted?
          "$existing | #{target} = " \
            "(#{target} + $new#{target} | sort)"
        else
          "$existing | #{target} += $new#{target}"
        end

      { when: when_expr, fold: fold_expr }
    end

    # Deep-sort all Hash keys so that serialization is deterministic
    # regardless of insertion order or JSON library.
    def normalize_payload(obj) #: (untyped) -> untyped
      case obj
      when Hash
        obj
          .sort_by { |k, _| k.to_s }
          .map { |k, v| [k, normalize_payload(v)] }
          .to_h
      when Array
        obj.map { |v| normalize_payload(v) }
      else
        obj
      end
    end
  end
end
