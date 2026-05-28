# frozen_string_literal: true

# The audit app's dispatcher. Cross-language by design — payloads
# are plain JSON, types are strings the producer agrees on with the
# consumer. The audit sink itself only cares about the *envelope*,
# not the event_type inside it.
AUDIT_ROUTER = Zizq::Router.new do
  # The one route: "record this audit event."
  #
  # Payload shape (all keys strings):
  #   {
  #     "occurred_at": "2026-05-27T10:15:00Z",  # ISO8601 or epoch int
  #     "source":      "uptime_monitor",
  #     "event_type":  "url.status.changed",
  #     "actor":       "system",
  #     "ip":          null,
  #     "resource":    "monitored_url:42",
  #     "text":        "https://example.com went down",
  #     "data":        { "from": "up", "to": "down", ... }
  #   }
  route "audit.create" do |payload|
    AuditEvent.from_payload(payload).save
  end
end
