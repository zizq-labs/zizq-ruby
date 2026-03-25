# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Builder for collecting multiple job params to be sent as a single bulk
  # request via `Zizq.enqueue_bulk`.
  #
  #   Zizq.enqueue_bulk do |b|
  #     b.enqueue(MyApp::FooJob, 42)
  #     b.enqueue(MyApp::OtherJob, 42, x: 7)
  #   end
  class BulkEnqueue
    attr_reader :jobs #: Array[Hash[Symbol, untyped]]

    def initialize #: () -> void
      @jobs = [] #: Array[Hash[Symbol, untyped]]
    end

    # Collect params for a single job. Accepts the same arguments as
    # `Zizq.enqueue`.
    #
    # @rbs job_class: Class & Zizq::job_class
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueOptions) -> void
    # @rbs return: void
    def enqueue(job_class, *args, **kwargs, &block)
      @jobs << Zizq.build_enqueue_params(job_class, *args, **kwargs, &block)
    end

    # Collect params for a single raw enqueue. Accepts the same arguments as
    # `Zizq.enqueue_raw`.
    #
    # @rbs queue: String
    # @rbs type: String
    # @rbs payload: Hash[String | Symbol, untyped]
    # @rbs priority: Integer?
    # @rbs ready_at: Float?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs return: void
    def enqueue_raw(queue:,
                    type:,
                    payload:,
                    priority: nil,
                    ready_at: nil,
                    retry_limit: nil,
                    backoff: nil,
                    retention: nil,
                    unique_key: nil,
                    unique_while: nil)
      @jobs << {
        queue:,
        type:,
        payload:,
        priority:,
        ready_at:,
        retry_limit:,
        backoff:,
        retention:,
        unique_key:,
        unique_while:
      }
    end
  end
end
