# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a cron group response hash.
    class CronGroup < Resource
      def name        = @data["name"]        #: () -> String
      def paused      = @data["paused"]      #: () -> bool
      def paused?     = paused               #: () -> bool
      def paused_at   = ms_to_seconds(@data["paused_at"])   #: () -> Float?
      def resumed_at  = ms_to_seconds(@data["resumed_at"])  #: () -> Float?

      # Returns the entries in this group as typed resources.
      def entries #: () -> Array[CronEntry]
        (@data["entries"] || []).map { |e| CronEntry.new(client, e) }
      end
    end
  end
end
