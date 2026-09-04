# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a job response hash.
    #
    # Inherits template fields (type, queue, priority, payload, backoff,
    # retention, unique_key, unique_while) from JobTemplate and adds
    # lifecycle fields and action methods.
    class Job < JobTemplate
      def id = @data["id"] #: () -> String
      def status = @data["status"] #: () -> String
      def ready_at = ms_to_seconds(@data["ready_at"]) #: () -> Float?
      def attempts = @data["attempts"] #: () -> Integer
      def dequeued_at = ms_to_seconds(@data["dequeued_at"]) #: () -> Float?
      def failed_at = ms_to_seconds(@data["failed_at"]) #: () -> Float?
      def completed_at = ms_to_seconds(@data["completed_at"]) #: () -> Float?
      def duplicate? = @data["duplicate"] == true #: () -> bool
      def folded? = @data["folded"] == true #: () -> bool

      # Fetch the error history for this job.
      #
      # @rbs order: Zizq::sort_direction?
      # @rbs limit: Integer?
      # @rbs page_size: Integer?
      # @rbs return: ErrorEnumerator
      def errors(order: nil, limit: nil, page_size: nil)
        ErrorEnumerator.new(id, order:, limit:, page_size:)
      end

      # Mark this job as successfully completed.
      def complete! #: () -> nil
        @client.report_success(id)
      end

      # Report this job as failed.
      #
      # @rbs message: String
      # @rbs error_type: String?
      # @rbs backtrace: String?
      # @rbs retry_at: Float?
      # @rbs kill: bool
      # @rbs return: Job
      def fail!(
        message:,
        error_type: nil,
        backtrace: nil,
        retry_at: nil,
        kill: false
      )
        @client.report_failure(
          id,
          message:,
          error_type:,
          backtrace:,
          retry_at:,
          kill:
        )
      end

      # Delete this job.
      #
      # @rbs return: void
      def delete
        @client.delete_job(id)
      end

      # Update this job's mutable fields.
      #
      # Returns the updated job.
      #
      # @rbs queue: (String | singleton(Zizq::UNCHANGED))?
      # @rbs priority: (Integer | singleton(Zizq::UNCHANGED))?
      # @rbs ready_at: (Zizq::to_f | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs retry_limit: (Integer | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs backoff: (Zizq::backoff | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs retention: (Zizq::retention | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
      # @rbs return: Job
      def update(
        queue: Zizq::UNCHANGED,
        priority: Zizq::UNCHANGED,
        ready_at: Zizq::UNCHANGED,
        retry_limit: Zizq::UNCHANGED,
        backoff: Zizq::UNCHANGED,
        retention: Zizq::UNCHANGED
      )
        job =
          @client.update_job(
            id,
            queue:,
            priority:,
            ready_at:,
            retry_limit:,
            backoff:,
            retention:
          )

        refresh_from(job)
      end

      # Bind this job to a budget it is not already bound to.
      #
      # Requires a Pro license on the server, else raise `Zizq::ClientError`
      # for the server's 403 response.
      #
      # Raises a `Zizq::ConflictError` (409) if it is already bound to this
      # budget, leaving the existing binding untouched — use
      # `rebind_budget` to replace it, or `set_budget_cost` to change
      # only what it costs.
      #
      # `create_with` declares the budget's policy should it not exist
      # yet, binding and creating in one atomic call. It is ignored when
      # the budget already exists.
      #
      # Only queued (`scheduled`, `ready`) jobs may be rebound. Anything
      # else raises `Zizq::ClientError` (422).
      #
      # Returns the updated job, and refreshes this one.
      #
      # @rbs key: String
      # @rbs cost: Integer?
      # @rbs create_with: Zizq::budget_policy?
      # @rbs return: Job
      def bind_budget(key, cost: nil, create_with: nil)
        refresh_from(@client.add_job_budget(id, key, cost:, create_with:))
      end

      # Bind this job to a budget, replacing any existing binding to it.
      #
      # Requires a Pro license on the server, else raise `Zizq::ClientError`
      # for the server's 403 response.
      #
      # Unlike `bind_budget` this never conflicts. The binding is
      # replaced whole, so a `cost` left unset returns to the default of
      # 1 rather than keeping what was there.
      #
      # @rbs key: String
      # @rbs cost: Integer?
      # @rbs create_with: Zizq::budget_policy?
      # @rbs return: Job
      def rebind_budget(key, cost: nil, create_with: nil)
        refresh_from(@client.put_job_budget(id, key, cost:, create_with:))
      end

      # Change what an existing binding costs, leaving the binding
      # itself alone.
      #
      # Raises `Zizq::NotFoundError` if this job is not bound to the
      # budget. Raises a `Zizq::ClientError` (422) if the new cost exceeds
      # the budget's capacity.
      #
      # @rbs key: String
      # @rbs cost: Integer
      # @rbs return: Job
      def set_budget_cost(key, cost)
        refresh_from(@client.update_job_budget(id, key, cost:))
      end

      # Unbind one budget, leaving this job's other budgets alone.
      #
      # Raises `Zizq::NotFoundError` if it is not bound to it.
      #
      # @rbs key: String
      # @rbs return: Job
      def unbind_budget(key)
        refresh_from(@client.delete_job_budget(id, key))
      end

      # Unbind every budget.
      #
      # The job will be dispatched the moment it reaches the front of
      # the queue.
      #
      # @rbs return: Job
      def unbind_all_budgets
        refresh_from(@client.clear_job_budgets(id))
      end

      # Replace the whole set of budgets this job is bound to.
      #
      # Budgets omitted from `budgets` are unbound, so this describes the
      # job's throttling outright rather than amending it. Passing `[]`
      # is the same as `unbind_all_budgets`.
      #
      # @rbs budgets: Array[Zizq::budget_binding_params]
      # @rbs return: Job
      def replace_budgets(budgets)
        refresh_from(@client.replace_job_budgets(id, budgets:))
      end

      private

      # Refresh this job from a response carrying the whole job, and
      # hand that response back.
      #
      # Replaces rather than merges. Every one of these endpoints
      # responds with the complete job, and the fields that can be
      # cleared are omitted from it rather than sent as null — `budgets`
      # for an unthrottled job, `backoff` and `retention` once reset. A
      # merge leaves exactly those behind, so the receiver would go on
      # reporting what was just removed.
      #
      # @rbs job: Job
      # @rbs return: Job
      def refresh_from(job)
        @data.replace(job.to_h)
        job
      end
    end
  end
end
