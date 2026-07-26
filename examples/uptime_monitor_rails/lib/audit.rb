# frozen_string_literal: true

module Audit
  AUDIT_QUEUE = ENV.fetch("AUDIT_QUEUE", "audit")

  # Emit an audit event to the centralised audit_log system.
  #
  # See the "audit_log" example, which if running ingests the emitted event
  # and for record keeping across various systems.
  #
  # This uses `Zizq.enqueue_raw` for cross-language dispatch.
  #
  # Example:
  #
  #     Audit.emit(
  #       event_type:"url.status.changed",
  #       actor: "system",
  #       resource: "monitored_url:42",
  #       text: "https://example.com went down",
  #       data: { "from": "up", "to": "down" }
  #     )
  def self.emit(
    event_type:,
    actor:,
    text:,
    resource: nil,
    data: nil,
    ip: nil,
    occurred_at: Time.current
  )
    Zizq.enqueue_raw(
      queue: AUDIT_QUEUE,
      type: "audit.create",
      payload: {
        occurred_at: occurred_at.iso8601,
        source: Rails.application.name,
        event_type:,
        actor:,
        ip:,
        resource:,
        text:,
        data:
      }
    )
  end
end
