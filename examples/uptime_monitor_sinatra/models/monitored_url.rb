# frozen_string_literal: true

require "uri"

class MonitoredUrl < Sequel::Model
  SOURCES = %w[manual sitemap].freeze
  STATUSES = %w[up down].freeze

  plugin :timestamps, update_on_create: true
  plugin :defaults_setter # apply schema defaults to new instances

  one_to_many :checks

  dataset_module { def enabled = where(enabled: true) }

  def validate
    super
    errors.add(:url, "is required") if url.to_s.strip.empty?
    unless SOURCES.include?(source)
      errors.add(:source, "must be one of #{SOURCES.inspect}")
    end
    if last_status && !STATUSES.include?(last_status)
      errors.add(:last_status, "must be one of #{STATUSES.inspect}")
    end

    validate_url_scheme if url && !url.to_s.empty?
  end

  # Apply the outcome of a single probe: append a Check row, update
  # the denormalised summary columns on this record, and return the
  # newly-created Check.
  def record_check!(result)
    db.transaction do
      check =
        add_check(
          checked_at: result.checked_at,
          status: result.status,
          http_status: result.http_status,
          response_time_ms: result.response_time_ms,
          final_url: result.final_url,
          error_message: result.error_message,
          created_at: Time.now
        )

      update(
        last_checked_at: result.checked_at,
        last_status: result.status,
        consecutive_failures:
          result.status == "up" ? 0 : consecutive_failures + 1
      )

      check
    end
  end

  private

  def validate_url_scheme
    uri = URI.parse(url)
    unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
      errors.add(:url, "must be an http:// or https:// URL")
    end
  rescue URI::InvalidURIError
    errors.add(:url, "is not a valid URL")
  end
end
