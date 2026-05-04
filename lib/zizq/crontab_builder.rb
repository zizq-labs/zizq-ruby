# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # Builder used to configure a Zizq::Crontab instance.
  #
  # Instances of this class are returned from `Zizq.define_crontab`. See
  # documentation for that method for usage.
  class CrontabBuilder
    # The Crontab instance that this builder configures.
    attr_reader :target #: Zizq::Crontab

    # Optional timezone to be applied to all entries by default.
    attr_accessor :timezone #: String?

    # Initialize the builder with the given Crontab instance.
    #
    # @rbs target: Zizq::Crontab
    # @rbs timezone: String?
    # @rbs paused: bool?
    def initialize(target, timezone: nil, paused: nil)
      @target = target.clear
      @timezone = timezone

      target.paused = paused
    end

    # Add or replace an entry on the schedule
    #
    # If no entry with the given name exists, it is added to schedule. If an
    # entry with the same name exist, this entry replaces that entry. If the
    # entry is the same as the original, the result is idempotent.
    #
    # @rbs name: String
    # @rbs expression: String
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs return: Zizq::CrontabEntryBuilder
    def define_entry(name, expression, timezone: self.timezone, paused: nil)
      CrontabEntryBuilder.new(
        target,
        name,
        expression,
        timezone:,
        paused:,
      )
    end
  end
end
