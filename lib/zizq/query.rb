# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Composable query builder for jobs in Zizq.
  #
  # Provides a chainable, immutable API for filtering, iterating, updating,
  # and deleting jobs. Each filter method returns a new `Query` instance,
  # leaving the original unchanged.
  #
  # `Query` is `Enumerable`— it lazily paginates through results, so
  # standard Ruby methods like `count`, `map`, `select`, `first`, etc.
  # work out of the box.
  #
  # Examples:
  #
  #   # Count ready jobs on a queue
  #   Zizq::Query.new.by_queue("emails").by_status("ready").count
  #
  #   # Move all jobs from one queue to another
  #   Zizq::Query.new.by_queue("old").update_all(queue: "new")
  #
  #   # Delete dead jobs matching a payload filter
  #   Zizq::Query.new.by_status("dead").add_jq_filter(".user_id == 42").delete_all
  #
  #   # Iterate in batches
  #   Zizq::Query.new.in_pages_of(100).each { |job| puts job.id }
  #
  #   # Move all jobs from one queue to another in batches.
  #   Zizq::Query.new.by_queue("old").in_pages_of(100).update_all(queue: "new")
  #
  #   # Find jobs by class and arguments
  #   Zizq::Query.new.by_job_class_and_args(SendEmailJob, 42, template: "welcome")
  #
  #   # Find jobs by class and arguments (subset)
  #   Zizq::Query.new.by_job_class_and_args_subset(SendEmailJob, 42)
  #
  class Query
    # Maximum page size the server can handle.
    MAX_PAGE_SIZE = 2000 #: Integer

    # @rbs skip
    include Enumerable

    # @rbs!
    #   include ::Enumerable[Zizq::Resources::Job]

    # Initialize the query with some initial parameters.
    #
    # @rbs id: (String | Array[String])?
    # @rbs queue: (String | Array[String])?
    # @rbs type: (String | Array[String])?
    # @rbs status: (String | Array[String])?
    # @rbs jq_filter: String?
    # @rbs order: Zizq::sort_direction?
    # @rbs limit: Integer?
    # @rbs page_size: Integer?
    # @rbs return: void
    def initialize(id: nil,
                   queue: nil,
                   type: nil,
                   status: nil,
                   jq_filter: nil,
                   order: nil,
                   limit: nil,
                   page_size: nil)
      @id = id
      @queue = queue
      @type = type
      @status = status
      @jq_filter = jq_filter
      @order = order
      @limit = limit
      @page_size = page_size
    end

    # Set the page size for paginated iteration.
    #
    # When set, `each_page` fetches pages of this size, and `each` fetches jobs
    # in pages of this size. Also used by `update_all` and `delete_all` to
    # batch operations by page.
    #
    # @rbs page_size: Integer?
    # @rbs return: Query
    def in_pages_of(page_size)
      rebuild(page_size:)
    end

    # Filter by job ID (replaces any existing ID filter).
    #
    # @rbs id: (String | Array[String])?
    # @rbs return: Query
    def by_id(id)
      rebuild(id:)
    end

    # Add a job ID to the existing ID filter.
    #
    # @rbs id: String | Array[String]
    # @rbs return: Query
    def add_id(id)
      rebuild(id: Array(@id) + Array(id))
    end

    # Filter by queue name (replaces any existing queue filter).
    #
    # @rbs queue: (String | Array[String])?
    # @rbs return: Query
    def by_queue(queue)
      rebuild(queue:)
    end

    # Add a queue to the existing queue filter.
    #
    # @rbs queue: String | Array[String]
    # @rbs return: Query
    def add_queue(queue)
      rebuild(queue: Array(@queue) + Array(queue))
    end

    # Filter by job type (replaces any existing type filter).
    #
    # @rbs type: (String | Array[String])?
    # @rbs return: Query
    def by_type(type)
      rebuild(type:)
    end

    # Add a type to the existing type filter.
    #
    # @rbs type: String | Array[String]
    # @rbs return: Query
    def add_type(type)
      rebuild(type: Array(@type) + Array(type))
    end

    # Filter by status (replaces any existing status filter).
    #
    # @rbs status: (String | Array[String])
    # @rbs return: Query
    def by_status(status)
      rebuild(status:)
    end

    # Add a status to the existing status filter.
    #
    # @rbs status: String | Array[String]
    # @rbs return: Query
    def add_status(status)
      rebuild(status: Array(@status) + Array(status))
    end

    # Filter by job class and exact arguments.
    #
    # The job class must include `Zizq::Job` or for Active Job classes must
    # extend `Zizq::ActiveJobConfig`.
    #
    # Sets the type filter to the class name and adds a jq payload filter
    # for an exact match of the serialized arguments.
    #
    # @rbs job_class: Zizq::job_class
    # @rbs *args: untyped
    # @rbs **kwargs: untyped
    # @rbs return: Query
    def by_job_class_and_args(job_class, *args, **kwargs)
      validate_job_class!(job_class)
      name = job_class.name or raise ArgumentError, "anonymous classes are not supported"
      by_type(name).add_jq_filter(job_class.zizq_payload_filter(*args, **kwargs))
    end

    # Filter by job class and a subset of arguments.
    #
    # Matches jobs whose positional args start with the given values and
    # whose kwargs contain (at minimum) the given key/value pairs.
    #
    # The job class must include `Zizq::Job` or for Active Job classes must
    # extend `Zizq::ActiveJobConfig`.
    #
    # @rbs job_class: Zizq::job_class
    # @rbs *args: untyped
    # @rbs **kwargs: untyped
    # @rbs return: Query
    def by_job_class_and_args_subset(job_class, *args, **kwargs)
      validate_job_class!(job_class)
      name = job_class.name or raise ArgumentError, "anonymous classes are not supported"
      by_type(name).add_jq_filter(job_class.zizq_payload_subset_filter(*args, **kwargs))
    end

    # Replace the jq payload filter expression.
    #
    # @rbs jq_filter: String?
    # @rbs return: Query
    def by_jq_filter(jq_filter)
      rebuild(jq_filter:)
    end

    # Add a jq payload filter, logically combines with any existing filter via
    # "and".
    #
    # @rbs jq_filter: String
    # @rbs return: Query
    def add_jq_filter(jq_filter)
      rebuild(jq_filter: [@jq_filter, "(#{jq_filter})"].compact.join(" and "))
    end

    # Set the sort order for iteration.
    #
    # @rbs order: Zizq::sort_direction?
    # @rbs return: Query
    def order(order)
      rebuild(order:)
    end

    # Limit the total number of jobs returned.
    #
    # This is a total limit, imposed across potentially multiple page fetches.
    # This limit also applies to `update_all` and `delete_all` operations.
    #
    # @rbs limit: Integer?
    # @rbs return: Query
    def limit(limit)
      rebuild(limit:)
    end

    # Reverse the sort order.
    #
    # Returns a new query with the opposite order. If no order was set,
    # defaults to descending (the server default is ascending).
    #
    # @rbs return: Query
    def reverse_order
      rebuild(order: @order == :desc ? :asc : :desc)
    end

    # Returns true if there are no matching jobs.
    #
    # Optimised: fetches a single job to check.
    #
    # @rbs return: bool
    def empty?
      first.nil?
    end

    # Returns true if there are any matching jobs.
    #
    # Without a block, optimised to fetch a single job. With a block,
    # falls back to Enumerable (tests each job against the block).
    #
    # @rbs &block: ?(Resources::Job) -> bool
    # @rbs return: bool
    def any?
      return super if block_given?

      !first.nil?
    end

    # Returns true if there are no matching jobs.
    #
    # Without a block, optimised to fetch a single job. With a block,
    # falls back to Enumerable (tests each job against the block).
    #
    # @rbs &block: ?(Resources::Job) -> bool
    # @rbs return: bool
    def none?
      return super if block_given?

      first.nil?
    end

    # Returns true if there is exactly one matching job.
    #
    # Without a block, optimised to fetch at most two jobs. With a block,
    # falls back to Enumerable.
    #
    # @rbs &block: ?(Resources::Job) -> bool
    # @rbs return: bool
    def one?
      return super if block_given?

      limit(2).to_a.size == 1
    end

    # Count matching jobs via the server-side count endpoint.
    #
    # Without a block or argument, uses `GET /jobs/count` for an efficient
    # server-side count. When a limit is set, caps the result locally with
    # `[total, limit].min`.
    #
    # With a block or argument, falls back to Enumerable (iterates and counts
    # matching jobs).
    #
    # @rbs *args: untyped
    # @rbs &block: ?(Resources::Job) -> bool
    # @rbs return: Integer
    def count(*args, &block)
      return super if block || !args.empty?

      total = Zizq.client.count_jobs(
        id: @id,
        queue: @queue,
        type: @type,
        status: @status,
        filter: @jq_filter,
      )

      @limit ? [total, @limit].min : total
    end

    # Iterate over matching jobs in reverse order.
    #
    # Optimised: pushes the reverse ordering to the server instead of
    # fetching all jobs into memory and reversing.
    #
    # @rbs &block: ?(Resources::Job) -> void
    # @rbs return: ::Enumerator[Zizq::Resources::Job, void]
    def reverse_each(&block)
      reverse_order.each(&block)
    end

    # Return the first matching job, or nil if none match.
    #
    # Optimised: fetches a single job from the server (`?limit=1`).
    #
    # @rbs return: Resources::Job?
    def first
      limit(1).each.first
    end

    # Return the last matching job, or nil if none match.
    #
    # Optimised: reverses the order and fetches a single job.
    #
    # @rbs return: Resources::Job?
    def last
      reverse_order.first
    end

    # Return the first `n` matching jobs.
    #
    # Optimised: sets the limit to `n` so the server only returns what's
    # needed.
    #
    # @rbs n: Integer
    # @rbs return: Array[Resources::Job]
    def take(n)
      limit(n).to_a
    end

    # Update the first matching job.
    #
    # Returns 1 if a job was updated, 0 if no jobs matched.
    #
    # @rbs queue: (String | singleton(Zizq::UNCHANGED))?
    # @rbs priority: (Integer | singleton(Zizq::UNCHANGED))?
    # @rbs ready_at: (Zizq::to_f | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retry_limit: (Integer | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs backoff: (Zizq::backoff | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retention: (Zizq::retention | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs return: Integer
    def update_one(...)
      limit(1).update_all(...)
    end

    # Delete the first matching job.
    #
    # Returns 1 if a job was deleted, 0 if no jobs matched.
    #
    # @rbs return: Integer
    def delete_one
      limit(1).delete_all
    end

    # Iterate over matching jobs, lazily paginating through results.
    #
    # Respects `limit` if set. Without a block, returns an `Enumerator`.
    #
    # @rbs &block: ?(Resources::Job) -> void
    # @rbs return: ::Enumerator[Zizq::Resources::Job, void]
    def each(&block)
      enumerator = enum_for(:each)

      if block_given?
        remaining = @limit

        each_page do |page|
          page.jobs.each do |job|
            if remaining
              break if remaining <= 0
            end

            yield job

            remaining -= 1 if remaining
          end
        end
      end

      enumerator
    end

    # Iterate over pages of matching jobs.
    #
    # Each page is a `Resources::JobPage`. Without a block, returns an
    # `Enumerator`.
    #
    # If `limit` is set, terminates after the last page is reached that exceeds
    # the limit, but does not truncate the page.
    #
    # @rbs &block: ?(Resources::JobPage) -> void
    # @rbs return: ::Enumerator[Zizq::Resources::JobPage, void]
    def each_page(&block)
      enumerator = enum_for(:each_page)

      if block_given?
        page = Zizq.client.list_jobs(
          id: @id,
          queue: @queue,
          type: @type,
          status: @status,
          filter: @jq_filter,
          limit: [@page_size, @limit, (@page_size || @limit) && MAX_PAGE_SIZE].compact.min,
          order: @order,
        )

        remaining = @limit

        while page
          yield page

          if remaining
            remaining -= page.jobs.size
            break if remaining <= 0
          end

          page = page.next_page
        end
      end

      enumerator
    end

    # Update all matching jobs with the given field values.
    #
    # When `page_size` or `limit` is set, iterates page by page and
    # issues a bulk update per page using the job IDs on that page. For safety
    # query parameters are included in the scope along with all IDs. Otherwise,
    # issues a single bulk update with the query parameters.
    #
    # Returns the total number of updated jobs.
    #
    # @rbs queue: (String | singleton(Zizq::UNCHANGED))?
    # @rbs priority: (Integer | singleton(Zizq::UNCHANGED))?
    # @rbs ready_at: (Zizq::to_f | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retry_limit: (Integer | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs backoff: (Zizq::backoff | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retention: (Zizq::retention | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs return: Integer
    def update_all(queue: Zizq::UNCHANGED,
                   priority: Zizq::UNCHANGED,
                   ready_at: Zizq::UNCHANGED,
                   retry_limit: Zizq::UNCHANGED,
                   backoff: Zizq::UNCHANGED,
                   retention: Zizq::UNCHANGED)
      where = {
        id: @id,
        queue: @queue,
        type: @type,
        status: @status,
        filter: @jq_filter,
      }

      apply = {
        queue:,
        priority:,
        ready_at:,
        retry_limit:,
        backoff:,
        retention:,
      }

      if @limit || @page_size
        remaining = @limit
        updated = 0

        each_page do |page|
          if remaining
            break if remaining <= 0
          end

          ids_on_page = page.jobs.map(&:id)
          ids_on_page = ids_on_page.take(remaining) if remaining

          updated += Zizq.client.update_all_jobs(
            where: where.merge(id: ids_on_page),
            apply:,
          )

          remaining -= ids_on_page.size if remaining
        end

        updated
      else
        Zizq.client.update_all_jobs(where:, apply:)
      end
    end

    # Delete all matching jobs.
    #
    # When `page_size` or `limit` is set, iterates page by page and
    # issues a bulk delete per page using the job IDs on that page. For safety
    # query parameters are included in the scope along with all IDs. Otherwise,
    # issues a single bulk delete with the query filters.
    #
    # When called in a bare query, this deletes *all* jobs from the server,
    # which is useful in tests.
    #
    # Returns the total number of deleted jobs.
    #
    # @rbs return: Integer
    def delete_all
      where = {
        id: @id,
        queue: @queue,
        type: @type,
        status: @status,
        filter: @jq_filter,
      }

      if @limit || @page_size
        remaining = @limit
        deleted = 0

        each_page do |page|
          if remaining
            break if remaining <= 0
          end

          ids_on_page = page.jobs.map(&:id)
          ids_on_page = ids_on_page.take(remaining) if remaining

          deleted += Zizq.client.delete_all_jobs(
            where: where.merge(id: ids_on_page),
          )

          remaining -= ids_on_page.size if remaining
        end

        deleted
      else
        Zizq.client.delete_all_jobs(where:)
      end
    end

    private

    # Build a new Query with the given overrides, preserving all other fields.
    #
    # @rbs return: Query
    def rebuild(id: @id,
                queue: @queue,
                type: @type,
                status: @status,
                jq_filter: @jq_filter,
                order: @order,
                limit: @limit,
                page_size: @page_size)
      self.class.new(
        id:,
        queue:,
        type:,
        status:,
        jq_filter:,
        limit:,
        order:,
        page_size:,
      )
    end

    # @rbs job_class: untyped
    # @rbs return: void
    def validate_job_class!(job_class)
      unless job_class.is_a?(JobConfig)
        raise ArgumentError,
          "#{job_class} does not include Zizq::JobConfig " \
          "(include Zizq::Job or extend Zizq::ActiveJobConfig)"
      end
    end
  end
end
