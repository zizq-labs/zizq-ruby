# frozen_string_literal: true

require_relative "test_helper"

class TestUrlProber < Minitest::Test
  def test_2xx_is_up
    stub_request(:get, "https://example.com").to_return(status: 200)

    result = UrlProber.call("https://example.com")

    assert_equal "up", result.status
    assert_equal 200, result.http_status
    assert_kind_of Integer, result.response_time_ms
  end

  def test_non_2xx_is_down_with_status_code_captured
    stub_request(:get, "https://example.com").to_return(status: 404)

    result = UrlProber.call("https://example.com")

    assert_equal "down", result.status
    assert_equal 404, result.http_status
    assert_equal "HTTP 404", result.error_message
  end

  def test_follows_a_redirect_and_reports_the_final_url
    stub_request(:get, "https://example.com").to_return(
      status: 301,
      headers: {
        "Location" => "https://final.example.com/"
      }
    )
    stub_request(:get, "https://final.example.com/").to_return(status: 200)

    result = UrlProber.call("https://example.com")

    assert_equal "up", result.status
    assert_equal "https://final.example.com/", result.final_url
  end

  def test_network_error_is_down_with_friendly_message
    stub_request(:get, "https://nonexistent.invalid").to_raise(
      Errno::ECONNREFUSED
    )

    result = UrlProber.call("https://nonexistent.invalid")

    assert_equal "down", result.status
    assert_match(/\AConnection failed:/, result.error_message)
    assert_includes result.error_message, "Connection refused"
  end

  # --- Sitemap detection ---------------------------------------------

  def test_xml_urlset_is_flagged_as_a_sitemap
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://example.com/page</loc></url>
      </urlset>
    XML
    stub_request(:get, "https://example.com/sitemap.xml").to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/xml"
      },
      body: body
    )

    result = UrlProber.call("https://example.com/sitemap.xml")

    assert_equal "up", result.status
    assert result.is_sitemap
    assert_nil result.error_message
  end

  def test_xml_sitemapindex_is_flagged_as_a_sitemap
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://example.com/sitemap-1.xml</loc></sitemap>
      </sitemapindex>
    XML
    stub_request(:get, "https://example.com/sitemap.xml").to_return(
      status: 200,
      headers: {
        "Content-Type" => "text/xml"
      },
      body: body
    )

    result = UrlProber.call("https://example.com/sitemap.xml")

    assert result.is_sitemap
  end

  def test_non_sitemap_xml_is_not_flagged
    stub_request(:get, "https://example.com/feed.xml").to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/rss+xml"
      },
      body: %(<?xml version="1.0"?><rss><channel></channel></rss>)
    )

    result = UrlProber.call("https://example.com/feed.xml")

    refute result.is_sitemap
    assert_nil result.error_message
  end

  def test_non_xml_response_is_not_inspected_for_sitemap_content
    stub_request(:get, "https://example.com").to_return(
      status: 200,
      headers: {
        "Content-Type" => "text/html"
      },
      body: "<html></html>"
    )

    result = UrlProber.call("https://example.com")

    refute result.is_sitemap
    assert_nil result.error_message
  end

  def test_malformed_xml_with_xml_content_type_captures_the_parse_error
    stub_request(:get, "https://example.com/sitemap.xml").to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/xml"
      },
      body: "<unclosed"
    )

    result = UrlProber.call("https://example.com/sitemap.xml")

    # HTTP succeeded so the probe is still "up"; the parse problem is
    # application-level and surfaces on `error_message` for the
    # Check row's history.
    assert_equal "up", result.status
    refute result.is_sitemap
    assert_match(
      /Body advertised XML but failed to parse/,
      result.error_message
    )
  end
end
