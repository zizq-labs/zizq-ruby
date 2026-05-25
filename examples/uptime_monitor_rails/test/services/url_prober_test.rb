# frozen_string_literal: true

require "test_helper"

class UrlProberTest < ActiveSupport::TestCase
  test "2xx is up with the requested URL as final" do
    stub_request(:get, "https://example.com").to_return(status: 200)

    result = UrlProber.call("https://example.com")

    assert_equal "up", result.status
    assert_equal 200, result.http_status
    assert_equal "https://example.com", result.final_url
    assert_nil result.error_message
    assert_kind_of Integer, result.response_time_ms
    assert_operator result.response_time_ms, :>=, 0
  end

  test "non-2xx is down with status code captured" do
    stub_request(:get, "https://example.com").to_return(status: 404)

    result = UrlProber.call("https://example.com")

    assert_equal "down", result.status
    assert_equal 404, result.http_status
    assert_equal "HTTP 404", result.error_message
  end

  test "follows a redirect and reports the final URL" do
    stub_request(:get, "https://example.com")
      .to_return(status: 301, headers: { "Location" => "https://final.example.com/" })
    stub_request(:get, "https://final.example.com/").to_return(status: 200)

    result = UrlProber.call("https://example.com")

    assert_equal "up", result.status
    assert_equal 200, result.http_status
    assert_equal "https://final.example.com/", result.final_url
  end

  test "resolves relative Location headers against the previous URL" do
    stub_request(:get, "https://example.com/start")
      .to_return(status: 302, headers: { "Location" => "/landing" })
    stub_request(:get, "https://example.com/landing").to_return(status: 200)

    result = UrlProber.call("https://example.com/start")

    assert_equal "up", result.status
    assert_equal "https://example.com/landing", result.final_url
  end

  test "too many redirects is down" do
    (0..UrlProber::MAX_REDIRECTS).each do |i|
      stub_request(:get, "https://example.com/#{i}")
        .to_return(status: 302, headers: { "Location" => "https://example.com/#{i + 1}" })
    end

    result = UrlProber.call("https://example.com/0")

    assert_equal "down", result.status
    assert_match(/Too many redirects/, result.error_message)
  end

  test "redirect without a Location header is down" do
    stub_request(:get, "https://example.com").to_return(status: 302)

    result = UrlProber.call("https://example.com")

    assert_equal "down", result.status
    assert_equal 302, result.http_status
    assert_equal "Redirect without Location header", result.error_message
  end

  test "timeout is down with a friendly message" do
    stub_request(:get, "https://slow.example.com").to_timeout

    result = UrlProber.call("https://slow.example.com")

    assert_equal "down", result.status
    assert_equal "Timed out after #{UrlProber::TIMEOUT_SECONDS}s", result.error_message
  end

  test "network error is down with the exception captured" do
    stub_request(:get, "https://nonexistent.invalid")
      .to_raise(Socket::ResolutionError.new("getaddrinfo: nope"))

    result = UrlProber.call("https://nonexistent.invalid")

    assert_equal "down", result.status
    assert_includes result.error_message, "Socket::ResolutionError"
    assert_includes result.error_message, "getaddrinfo: nope"
  end

  test "XML urlset is flagged as a sitemap" do
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://example.com/page</loc></url>
      </urlset>
    XML
    stub_request(:get, "https://example.com/sitemap.xml")
      .to_return(status: 200, headers: { "Content-Type" => "application/xml" }, body: body)

    result = UrlProber.call("https://example.com/sitemap.xml")

    assert_equal "up", result.status
    assert result.is_sitemap
    assert_nil result.error_message
  end

  test "XML sitemapindex is flagged as a sitemap" do
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://example.com/sitemap-1.xml</loc></sitemap>
      </sitemapindex>
    XML
    stub_request(:get, "https://example.com/sitemap.xml")
      .to_return(status: 200, headers: { "Content-Type" => "text/xml" }, body: body)

    result = UrlProber.call("https://example.com/sitemap.xml")

    assert result.is_sitemap
  end

  test "non-sitemap XML (e.g. RSS) is not flagged" do
    stub_request(:get, "https://example.com/feed.xml").to_return(
      status: 200,
      headers: { "Content-Type" => "application/rss+xml" },
      body: %(<?xml version="1.0"?><rss><channel></channel></rss>),
    )

    result = UrlProber.call("https://example.com/feed.xml")

    refute result.is_sitemap
    assert_nil result.error_message
  end

  test "non-XML response is not inspected for sitemap content" do
    stub_request(:get, "https://example.com").to_return(
      status: 200,
      headers: { "Content-Type" => "text/html" },
      body: "<html></html>",
    )

    result = UrlProber.call("https://example.com")

    refute result.is_sitemap
    assert_nil result.error_message
  end

  test "malformed XML with an XML content-type captures the parse error" do
    stub_request(:get, "https://example.com/sitemap.xml").to_return(
      status: 200,
      headers: { "Content-Type" => "application/xml" },
      body: "<unclosed",
    )

    result = UrlProber.call("https://example.com/sitemap.xml")

    assert_equal "up", result.status # HTTP succeeded, parse problem is application-level
    refute result.is_sitemap
    assert_match(/Body advertised XML but failed to parse/, result.error_message)
  end
end
