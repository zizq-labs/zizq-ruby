# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require_relative "job_config"

module Zizq
  # Zizq configuration DSL for ActiveJob classes.
  #
  # Extend this module in an ActiveJob subclass to gain access to Zizq
  # features like unique jobs, backoff, and retention:
  #
  #   class SendEmailJob < ApplicationJob
  #     extend Zizq::ActiveJobConfig
  #
  #     zizq_unique true, scope: :active
  #     zizq_backoff exponent: 4.0, base: 15, jitter: 30
  #
  #     def perform(user_id, template:)
  #       # ...
  #     end
  #   end
  #
  # Serialization uses ActiveJob's own format so that GlobalID, Time, and
  # other ActiveJob-supported types are handled correctly. The Zizq worker
  # must use the ActiveJob dispatcher:
  #
  #   Zizq.configure do |c|
  #     c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
  #   end
  module ActiveJobConfig
    include JobConfig

    # @rbs!
    #   # ActiveJob::Base.new — invisible to steep without this.
    #   def new: (*untyped, **untyped) -> untyped

    # Serialize arguments using ActiveJob's serialization format.
    #
    # Creates a temporary ActiveJob instance to produce the canonical
    # serialized form, including `_aj_ruby2_keywords` markers for kwargs.
    # This ensures unique key generation uses the same format as the
    # enqueued payload.
    #
    # This is needed so that unique job keys can be correctly generated.
    def zizq_serialize(*args, **kwargs) #: (*untyped, **untyped) -> Array[untyped]
      new(*args, **kwargs).serialize["arguments"]
    end

    # Deserialization is handled by ActiveJob::Base.execute on the worker
    # side. This method is not used in the ActiveJob dispatch path.
    def zizq_deserialize(_payload) #: (untyped) -> [Array[untyped], Hash[Symbol, untyped]]
      raise NotImplementedError,
        "ActiveJob handles deserialization via ActiveJob::Base.execute"
    end
  end
end
