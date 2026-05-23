# frozen_string_literal: true

class MonitoredUrl < ApplicationRecord
  SOURCES  = %w[manual sitemap].freeze
  STATUSES = %w[up down].freeze

  has_many :checks

  validates :url,    presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :last_status, inclusion: { in: STATUSES }, allow_nil: true

  scope :enabled, -> { where(enabled: true) }

  # Apply the outcome of a single probe: append a Check row and update
  # the denormalised summary columns on this record.
  def record_check!(result)
    transaction do
      checks.create!(
        checked_at:       result.checked_at,
        status:           result.status,
        http_status:      result.http_status,
        response_time_ms: result.response_time_ms,
        final_url:        result.final_url,
        error_message:    result.error_message,
      )

      update!(
        last_checked_at:      result.checked_at,
        last_status:          result.status,
        consecutive_failures: result.status == "up" ? 0 : consecutive_failures + 1,
      )
    end
  end
end
