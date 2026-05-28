# frozen_string_literal: true

require_relative "test_helper"

class TestAuditRouter < Minitest::Test
  def test_audit_create_inserts_a_row
    job = build_job("audit.create",
      "occurred_at" => "2026-05-27T10:15:30Z",
      "source"      => "billing_api",
      "event_type"  => "invoice.refunded",
      "actor"       => "alice@example.com",
      "ip"          => "203.0.113.7",
      "resource"    => "invoice:42",
      "text"        => "Refunded $24.00",
      "data"        => { "amount_cents" => 2400 },
    )

    AUDIT_ROUTER.call(job)

    row = AuditEvent.first
    assert_equal "billing_api",      row.source
    assert_equal "invoice.refunded", row.event_type
    assert_equal "alice@example.com", row.actor
    assert_equal({ "amount_cents" => 2400 }, row.data)
  end

  def test_unknown_type_raises
    job = build_job("audit.unknown",
      "occurred_at" => Time.now.utc.iso8601,
      "source"      => "x",
      "event_type"  => "y",
    )

    assert_raises(Zizq::Router::UnknownJobType) { AUDIT_ROUTER.call(job) }
  end

  private

  def build_job(type, payload)
    Zizq::Resources::Job.new(nil, {
      "id"      => "test-1",
      "queue"   => ZIZQ_QUEUE,
      "type"    => type,
      "payload" => payload,
    })
  end
end
