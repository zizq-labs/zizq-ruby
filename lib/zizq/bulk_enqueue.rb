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
    attr_reader :requests #: Array[EnqueueRequest]

    def initialize #: () -> void
      @requests = [] #: Array[EnqueueRequest]
    end

    # Collect a job class enqueue. Accepts the same arguments as
    # `Zizq.enqueue`.
    #
    # @rbs job_class: Class & Zizq::job_class
    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[Symbol, untyped]
    # @rbs &block: ?(EnqueueRequest) -> void
    # @rbs return: void
    def enqueue(job_class, *args, **kwargs, &block)
      @requests << Zizq.build_enqueue_request(job_class, *args, **kwargs, &block)
    end

    # Collect a raw enqueue. Accepts the same arguments as
    # `Zizq.enqueue_raw`.
    #
    # @rbs queue: String
    # @rbs type: String
    # @rbs payload: untyped
    # @rbs priority: Integer?
    # @rbs ready_at: Zizq::to_f?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs return: void
    def enqueue_raw(queue:, type:, payload:, **opts)
      @requests << EnqueueRequest.new(queue:, type:, payload:, **opts)
    end
  end
end
