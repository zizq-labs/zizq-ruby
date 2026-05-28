# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:audit_events) do
      primary_key :id

      # When the event actually happened at the source. Set by the
      # producer. Indexed (with id as tie-breaker) for cursor-style
      # pagination of the most-recent-first feed.
      DateTime :occurred_at, null: false

      # The system that produced the event (e.g. "uptime_monitor",
      # "billing_api"). String, not enum — the audit sink stays
      # ignorant of which systems integrate with it.
      String :source, null: false

      # The event type the producer agreed on with… nobody. The audit
      # app doesn't switch on this — it just stores it. Common
      # convention: dot-namespaced ("user.login.succeeded").
      String :event_type, null: false

      String :actor       # who did it (email, user id, "system")
      String :ip          # source IP (string — IPv4 or IPv6)
      String :resource    # what they did it to ("invoice:42")
      String :text        # free-text human summary
      String :data        # JSON-serialised structured payload

      DateTime :created_at, null: false   # when we wrote the row
    end

    # Most-recent-first feed. The (occurred_at, id) tuple gives a
    # total ordering for cursor pagination even when timestamps
    # collide.
    run <<~SQL
      CREATE INDEX idx_audit_events_occurred_at
        ON audit_events (occurred_at DESC, id DESC)
    SQL

    # Filter-by-source feed, for the eventual `?source=...` query.
    run <<~SQL
      CREATE INDEX idx_audit_events_source_occurred_at
        ON audit_events (source, occurred_at DESC, id DESC)
    SQL
  end
end
