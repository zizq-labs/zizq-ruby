# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Paginated list of jobs.
    # @rbs inherits Page[Job]
    class JobPage < Page
      def items #: () -> Array[Job]
        @items ||= (@data["jobs"] || []).map { |j| Job.new(client, j) }
      end

      alias jobs items

      # Delete all jobs on this page.
      #
      # Returns the number of deleted jobs.
      #
      # @rbs return: Integer
      def delete_all
        ids = jobs.map(&:id)
        return 0 if ids.empty?

        client.delete_all_jobs(where: { id: ids })
      end

      # Update all jobs on this page with the given field values.
      #
      # Returns the number of updated jobs.
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
        ids = jobs.map(&:id)
        return 0 if ids.empty?

        client.update_all_jobs(
          where: { id: ids },
          apply: { queue:, priority:, ready_at:, retry_limit:, backoff:, retention: },
        )
      end
    end
  end
end
