# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Middleware
    # A linked chain of middleware ending with a terminal.
    #
    # Each middleware must implement `#call(arg, chain)` where `chain` is
    # the next link. The terminal implements `#call(arg)`.
    #
    # When no middleware is registered, `#call` delegates directly to the
    # terminal with zero overhead.
    #
    #   chain = Zizq::Middleware::Chain.new(dispatcher)
    #   chain.use(LoggingMiddleware.new)
    #   chain.use(MetricsMiddleware.new)
    #   chain.call(job)
    #   # MetricsMiddleware -> LoggingMiddleware -> dispatcher
    #
    # @rbs generic Arg -- the type flowing through the chain
    # @rbs generic Ret -- the return type of the terminal
    class Chain
      # The terminal callable at the end of the chain.
      attr_reader :terminal #: untyped

      def initialize(terminal) #: (untyped) -> void
        @terminal = terminal
        @entries = [] #: Array[untyped]
        @built = nil #: untyped?
      end

      # Replace the terminal, invalidating any built chain.
      def terminal=(terminal) #: (untyped) -> void
        @terminal = terminal
        @built = nil
      end

      # Append a middleware to the chain.
      def use(middleware) #: (untyped) -> void
        @entries << middleware
        @built = nil
      end

      # Execute the chain with the given argument.
      def call(arg) #: (Arg) -> Ret
        build.call(arg)
      end

      private

      def build #: () -> untyped
        @built ||= if @entries.empty?
          @terminal
        else
          @entries.reverse.reduce(@terminal) do |next_link, mw|
            Link.new(mw, next_link)
          end
        end
      end
    end

    # A single link in the middleware chain, connecting a middleware to
    # the next link (or terminal).
    class Link
      def initialize(middleware, next_link) #: (untyped, untyped) -> void
        @middleware = middleware
        @next_link = next_link
      end

      # Invoke this middleware, passing the next link for continuation.
      def call(arg) #: (untyped) -> untyped
        @middleware.call(arg, @next_link)
      end
    end
  end
end
