# frozen_string_literal: true

require_relative "test_helper"

class TestRoutes < Minitest::Test
  def test_get_index_empty
    get "/"

    assert last_response.ok?
    assert_match(/Audit Log/, last_response.body)
    assert_match(/No audit events yet/, last_response.body)
  end

  def test_get_index_lists_events_most_recent_first
    older = create_event(occurred_at: Time.utc(2026, 5, 27, 10, 0, 0), source: "older_system")
    newer = create_event(occurred_at: Time.utc(2026, 5, 27, 11, 0, 0), source: "newer_system")
    refute_nil older
    refute_nil newer

    get "/"

    assert last_response.ok?
    newer_pos = last_response.body.index("newer_system")
    older_pos = last_response.body.index("older_system")
    assert newer_pos && older_pos, "both rows should render"
    assert newer_pos < older_pos, "newer should appear before older"
  end

  def test_pagination_appears_when_more_than_page_size_rows
    (AuditLogApp::PAGE_SIZE + 5).times do |i|
      create_event(
        occurred_at: Time.utc(2026, 5, 27, 0, 0, 0) + i,
        source:      "src_#{i}",
      )
    end

    get "/"

    assert last_response.ok?
    assert_match(/\?cursor=/, last_response.body)
    assert_match(/Older/,     last_response.body)

    # First page should hold exactly PAGE_SIZE rows.
    assert_equal AuditLogApp::PAGE_SIZE,
      last_response.body.scan(/<tr>/).size - 1  # minus the thead row
  end

  def test_pagination_following_cursor_returns_next_page
    rows = (AuditLogApp::PAGE_SIZE + 3).times.map do |i|
      create_event(
        occurred_at: Time.utc(2026, 5, 27, 0, 0, 0) + i,
        source:      "src_#{i}",
      )
    end

    get "/"
    refute_match(/Newest/, last_response.body) # not on page 1
    cursor = last_response.body[/\?cursor=([^"]+)/, 1]
    refute_nil cursor

    get "/?cursor=#{cursor}"

    assert last_response.ok?
    # Newest 50 are on page 1; oldest 3 are on page 2.
    rows.first(3).each do |row|
      assert_match(/#{row.source}/, last_response.body)
    end
    refute_match(/src_#{AuditLogApp::PAGE_SIZE}/, last_response.body)
    # End of feed — no "Older" link.
    refute_match(/Older/, last_response.body)
    # "Newest" link back to page 1 is visible.
    assert_match(/Newest/, last_response.body)
    assert_match(%r{<a href="/">}, last_response.body)
  end

  def test_garbage_cursor_falls_back_to_first_page
    create_event

    get "/?cursor=not-a-cursor"

    assert last_response.ok?
    refute_match(/No audit events yet/, last_response.body)
  end

  private

  def create_event(**overrides)
    AuditEvent.create({
      occurred_at: Time.now,
      source:      "test_system",
      event_type:  "test.event",
      text:        "demo",
    }.merge(overrides))
  end
end
