# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  module Resources
    # Typed wrapper around a cron entry response hash.
    class CronEntry < Resource
      def name            = @data["name"]            #: () -> String
      def expression      = @data["expression"]      #: () -> String
      def timezone        = @data["timezone"]        #: () -> String?
      def paused          = @data["paused"]          #: () -> bool
      def paused?         = paused                   #: () -> bool
      def paused_at       = ms_to_seconds(@data["paused_at"])   #: () -> Float?
      def resumed_at      = ms_to_seconds(@data["resumed_at"])  #: () -> Float?
      def next_enqueue_at = ms_to_seconds(@data["next_enqueue_at"]) #: () -> Float?
      def last_enqueue_at = ms_to_seconds(@data["last_enqueue_at"]) #: () -> Float?

      # Returns the job template for this entry.
      def job #: () -> JobTemplate
        JobTemplate.new(client, @data["job"])
      end
    end
  end
end
