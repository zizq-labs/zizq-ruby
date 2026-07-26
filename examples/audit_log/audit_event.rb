# frozen_string_literal: true

require "json"

class AuditEvent < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :serialization, :json, :data

  # All fields except `occurred_at`, `source`, `event_type` are
  # optional — the schema is fixed, but most events don't fill every
  # column. The audit app doesn't validate event_type against a
  # whitelist; that's the producer's concern.
  REQUIRED = %i[occurred_at source event_type].freeze

  def validate
    super
    REQUIRED.each do |field|
      errors.add(field, "is required") if send(field).to_s.strip.empty?
    end
  end

  # Build (don't save) an AuditEvent from the JSON payload of an
  # `audit.create` job. The payload is plain hash-shaped JSON — every
  # key is a String. `occurred_at` accepts an ISO8601 string or an
  # epoch integer.
  def self.from_payload(payload)
    new(
      occurred_at: parse_time(payload["occurred_at"]),
      source: payload["source"],
      event_type: payload["event_type"],
      actor: payload["actor"],
      ip: payload["ip"],
      resource: payload["resource"],
      text: payload["text"],
      data: payload["data"]
    )
  end

  def self.parse_time(value)
    case value
    when nil
      nil
    when Integer
      Time.at(value)
    when Float
      Time.at(value)
    when String
      Time.parse(value)
    when Time
      value
    else
      raise ArgumentError, "unsupported occurred_at: #{value.inspect}"
    end
  end
end
