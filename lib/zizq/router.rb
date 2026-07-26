# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Dispatch jobs by `type` string, mapping each to a handler block.
  #
  # Designed for cross-language workflows: payloads are plain JSON
  # values (Hashes / Arrays / strings / numbers), `type` is a String
  # the producer agrees on with the consumer, and routes are
  # registered explicitly — no `Zizq::Job` mixin involved.
  #
  #   Zizq.configure do |c|
  #     c.dispatcher = Zizq::Router.new do
  #       route("send_email") do |payload|
  #         Mailer.deliver(payload["user_id"], payload["template"])
  #       end
  #
  #       route("expire_tokens") do
  #         TokenSweeper.run
  #       end
  #
  #       route("generate_report") do |payload, job|
  #         Reports.generate(payload["id"], attempts: job.attempts)
  #       end
  #
  #       # `def` inside the block defines singleton methods on the
  #       # router. Route blocks captured *inside* the constructor
  #       # have lexical `self == router`, so they can call these
  #       # helpers; routes added outside (`router.route("…") { … }`)
  #       # keep their own lexical `self` and would need to go through
  #       # the router explicitly (`router.logger`).
  #       def logger
  #         Zizq.configuration.logger
  #       end
  #
  #       # Anything else falls back. A common pattern is delegating
  #       # to `Zizq::Job` for the apps that mix the two styles.
  #       fallback { |job| Zizq::Job.call(job) }
  #     end
  #   end
  #
  # Routes can also be registered outside the constructor block:
  #
  #   router = Zizq::Router.new
  #   router.route("send_email") { |payload| ... }
  #
  # Handlers are called as `handler.call(payload, job)`. Block-arity
  # rules let `{ |payload| }` or `{ }` ignore either argument.
  # Strict-arity lambdas need to declare both.
  class Router
    # Raised when a job arrives with a type that has no registered
    # route and no fallback. Caught by Zizq's normal worker error
    # path, which nacks the job for retry (or dead-letters it once
    # the retry limit is hit).
    class UnknownJobType < Zizq::Error
    end

    # @rbs &block: ?(self) [self: Router] -> void
    def initialize(&block)
      @routes = {} #: Hash[String, ^(untyped, Resources::Job) -> void]
      @fallback = nil #: (^(Resources::Job) -> void)?
      instance_eval(&block) if block
    end

    # Register `handler` for jobs whose `type` matches.
    #
    # @rbs type: String | Symbol
    # @rbs &handler: (untyped, Resources::Job) -> void
    def route(type, &handler)
      @routes[type.to_s] = handler
    end

    # Register a fallback handler invoked when no route matches.
    # Receives the full `Resources::Job` (not split into payload /
    # job pair), since the canonical use is delegation to another
    # dispatcher:
    #
    #   fallback { |job| Zizq::Job.call(job) }
    #
    # @rbs &handler: (Resources::Job) -> void
    def fallback(&handler)
      @fallback = handler
    end

    # Dispatch a single job. Looks up the handler by `job.type`,
    # falls back to the registered fallback if any, otherwise
    # raises `UnknownJobType`.
    def call(job) #: (Resources::Job) -> void
      handler = @routes[job.type]

      return handler.call(job.payload, job) if handler
      return @fallback.call(job) if @fallback

      raise UnknownJobType,
            "no handler registered for job type #{job.type.inspect}"
    end
  end
end
