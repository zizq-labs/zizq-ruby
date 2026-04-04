# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Provides a lazy Enumerator across all errors on a job following the
    # cursor-based pagination.
    class ErrorEnumerator
      # Maximum page size the server can handle.
      MAX_PAGE_SIZE = 2000 #: Integer

      # @rbs skip
      include Enumerable

      # @rbs!
      #   include ::Enumerable[Zizq::Resources::ErrorRecord]

      # Initialize the enumerator.
      #
      # @rbs id: String
      # @rbs order: Zizq::sort_direction?
      # @rbs limit: Integer?
      # @rbs page_size: Integer?
      # @rbs return: void
      def initialize(id,
                     order: nil,
                     limit: nil,
                     page_size: nil)
        @id = id
        @order = order
        @limit = limit
        @page_size = page_size
      end

      # Set the page size for paginated iteration.
      #
      # When set, `each_page` fetches pages of this size, and `each` fetches
      # errors in pages of this size.
      #
      # @rbs page_size: Integer?
      # @rbs return: ErrorEnumerator
      def in_pages_of(page_size)
        rebuild(page_size:)
      end

      # Set the sort order for iteration.
      #
      # @rbs order: Zizq::sort_direction?
      # @rbs return: ErrorEnumerator
      def order(order)
        rebuild(order:)
      end

      # Limit the total number of errors returned.
      #
      # This is a total limit, imposed across potentially multiple page fetches.
      #
      # @rbs limit: Integer?
      # @rbs return: ErrorEnumerator
      def limit(limit)
        rebuild(limit:)
      end

      # Reverse the sort order.
      #
      # Returns a new query with the opposite order. If no order was set,
      # defaults to descending (the server default is ascending).
      #
      # @rbs return: ErrorEnumerator
      def reverse_order
        rebuild(order: @order == :desc ? :asc : :desc)
      end

      # Returns true if there are no errors.
      #
      # Optimised: fetches a single error to check.
      #
      # @rbs return: bool
      def empty?
        first.nil?
      end

      # Returns true if there are any errors.
      #
      # Without a block, optimised to fetch a single error. With a block,
      # falls back to Enumerable (tests each error against the block).
      #
      # @rbs &block: ?(Resources::ErrorRecord) -> bool
      # @rbs return: bool
      def any?
        return super if block_given?

        !first.nil?
      end

      # Returns true if there are no errors.
      #
      # Without a block, optimised to fetch a single error. With a block,
      # falls back to Enumerable (tests each error against the block).
      #
      # @rbs &block: ?(Resources::ErrorRecord) -> bool
      # @rbs return: bool
      def none?
        return super if block_given?

        first.nil?
      end

      # Returns true if there is exactly one error.
      #
      # Without a block, optimised to fetch at most two errors. With a block,
      # falls back to Enumerable.
      #
      # @rbs &block: ?(Resources::ErrorRecord) -> bool
      # @rbs return: bool
      def one?
        return super if block_given?

        limit(2).to_a.size == 1
      end

      # Iterate over errors in reverse order.
      #
      # Optimised: pushes the reverse ordering to the server instead of
      # fetching all errors into memory and reversing.
      #
      # @rbs &block: ?(Resources::ErrorRecord) -> void
      # @rbs return: ::Enumerator[Zizq::Resources::ErrorRecord, void]
      def reverse_each(&block)
        reverse_order.each(&block)
      end

      # Return the first error, or nil if no errors.
      #
      # Optimised: fetches a single error from the server (`?limit=1`).
      #
      # @rbs return: Resources::ErrorRecord?
      def first
        limit(1).each.first
      end

      # Return the last error, or nil if no errors.
      #
      # Optimised: reverses the order and fetches a single error.
      #
      # @rbs return: Resources::ErrorRecord?
      def last
        reverse_order.first
      end

      # Return the first `n` errors.
      #
      # Optimised: sets the limit to `n` so the server only returns what's
      # needed.
      #
      # @rbs n: Integer
      # @rbs return: Array[Resources::ErrorRecord]
      def take(n)
        limit(n).to_a
      end

      # Iterate over errors, lazily paginating through results.
      #
      # Respects `limit` if set. Without a block, returns an `Enumerator`.
      #
      # @rbs &block: ?(Resources::ErrorRecord) -> void
      # @rbs return: ::Enumerator[Zizq::Resources::ErrorRecord, void]
      def each(&block)
        enumerator = enum_for(:each)

        if block_given?
          remaining = @limit

          each_page do |page|
            page.errors.each do |error|
              if remaining
                break if remaining <= 0
              end

              yield error

              remaining -= 1 if remaining
            end
          end
        end

        enumerator
      end

      # Iterate over pages of errors.
      #
      # Each page is a `Resources::ErrorPage`. Without a block, returns an
      # `Enumerator`.
      #
      # If `limit` is set, terminates after the last page is reached that
      # exceeds the limit, but does not truncate the page.
      #
      # @rbs &block: ?(Resources::ErrorPage) -> void
      # @rbs return: ::Enumerator[Zizq::Resources::ErrorPage, void]
      def each_page(&block)
        enumerator = enum_for(:each_page)

        if block_given?
          page = Zizq.client.list_errors(
            @id,
            limit: [@page_size, @limit, (@page_size || @limit) && MAX_PAGE_SIZE].compact.min,
            order: @order,
          )

          remaining = @limit

          while page
            yield page

            if remaining
              remaining -= page.errors.size
              break if remaining <= 0
            end

            page = page.next_page
          end
        end

        enumerator
      end

      private

      # Build a new ErrorEnumerator with the given overrides, preserving all
      # other fields.
      #
      # @rbs return: ErrorEnumerator
      def rebuild(id = @id, order: @order, limit: @limit, page_size: @page_size)
        self.class.new(id, limit:, order:, page_size:)
      end
    end
  end
end
