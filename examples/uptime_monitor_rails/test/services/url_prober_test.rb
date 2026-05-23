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

  test "network error is down with the exception captured" do
    stub_request(:get, "https://nonexistent.invalid")
      .to_raise(Socket::ResolutionError.new("getaddrinfo: nope"))

    result = UrlProber.call("https://nonexistent.invalid")

    assert_equal "down", result.status
    assert_includes result.error_message, "Socket::ResolutionError"
    assert_includes result.error_message, "getaddrinfo: nope"
  end
end
