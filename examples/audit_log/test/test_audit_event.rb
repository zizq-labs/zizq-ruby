# frozen_string_literal: true

require_relative "test_helper"

class TestAuditEvent < Minitest::Test
  def test_required_fields_are_validated
    event = AuditEvent.new

    refute event.valid?
    assert_includes event.errors[:occurred_at], "is required"
    assert_includes event.errors[:source], "is required"
    assert_includes event.errors[:event_type], "is required"
  end

  def test_optional_fields_are_optional
    event =
      AuditEvent.new(
        occurred_at: Time.now,
        source: "billing_api",
        event_type: "invoice.refunded"
      )

    assert event.valid?
  end

  def test_from_payload_with_iso8601_occurred_at
    event =
      AuditEvent.from_payload(
        "occurred_at" => "2026-05-27T10:15:30Z",
        "source" => "billing_api",
        "event_type" => "invoice.refunded"
      )

    assert_equal Time.utc(2026, 5, 27, 10, 15, 30), event.occurred_at.utc
  end

  def test_from_payload_with_epoch_integer_occurred_at
    event =
      AuditEvent.from_payload(
        "occurred_at" => 1_700_000_000,
        "source" => "billing_api",
        "event_type" => "invoice.refunded"
      )

    assert_equal Time.at(1_700_000_000), event.occurred_at
  end

  def test_from_payload_with_time_occurred_at
    now = Time.now
    event =
      AuditEvent.from_payload(
        "occurred_at" => now,
        "source" => "billing_api",
        "event_type" => "invoice.refunded"
      )

    assert_equal now, event.occurred_at
  end

  def test_from_payload_copies_optional_fields
    event =
      AuditEvent.from_payload(
        "occurred_at" => "2026-05-27T10:15:30Z",
        "source" => "billing_api",
        "event_type" => "invoice.refunded",
        "actor" => "alice@example.com",
        "ip" => "203.0.113.7",
        "resource" => "invoice:42",
        "text" => "Refunded $24.00",
        "data" => {
          "amount_cents" => 2400
        }
      )

    assert_equal "alice@example.com", event.actor
    assert_equal "203.0.113.7", event.ip
    assert_equal "invoice:42", event.resource
    assert_equal "Refunded $24.00", event.text
    assert_equal({ "amount_cents" => 2400 }, event.data)
  end

  def test_data_column_round_trips_as_json
    AuditEvent.create(
      occurred_at: Time.now,
      source: "test",
      event_type: "demo",
      data: {
        "k" => "v",
        "nested" => {
          "a" => 1
        }
      }
    )

    reloaded = AuditEvent.first
    assert_equal({ "k" => "v", "nested" => { "a" => 1 } }, reloaded.data)
  end

  def test_unsupported_occurred_at_raises
    assert_raises(ArgumentError) do
      AuditEvent.from_payload(
        "occurred_at" => Object.new,
        "source" => "billing_api",
        "event_type" => "invoice.refunded"
      )
    end
  end
end
