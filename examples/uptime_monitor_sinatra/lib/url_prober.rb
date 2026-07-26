# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
require "nokogiri"

# Performs a single HTTP probe of a URL, following up to MAX_REDIRECTS
# redirects, and returns a Result struct describing the outcome.
#
#   UrlProber.call("https://example.com")
#   # => #<Result status="up" http_status=200 response_time_ms=42
#   #             final_url="https://example.com/" error_message=nil
#   #             is_sitemap=false checked_at=...>
#
# A 2xx final response is "up". Anything else — non-2xx final, network
# error, exceeded redirect cap, timeout — is "down".
#
# When the response advertises XML, we peek at the root element to
# flag whether the body is a sitemap (`urlset` / `sitemapindex`).
# `DiscoverSitemapUrlsJob` does the full URL extraction; we just set
# the flag so it knows to run.
class UrlProber
  MAX_REDIRECTS = 5
  OPEN_TIMEOUT_SECONDS = 5 # connect timeout
  READ_TIMEOUT_SECONDS = 10 # per-read socket timeout (Faraday default unit)

  SITEMAP_ROOT_ELEMENTS = %w[urlset sitemapindex].freeze
  XML_CONTENT_TYPE = %r{\A(application|text)/(.*\+)?xml\b}i

  Result =
    Struct.new(
      :status,
      :http_status,
      :response_time_ms,
      :final_url,
      :error_message,
      :is_sitemap,
      :checked_at,
      keyword_init: true
    )

  def self.call(url)
    new(url).call
  end

  def initialize(url)
    @url = url
  end

  def call
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = connection.get(@url)
    build_result(response, started)
  rescue Faraday::TimeoutError => e
    # Faraday::TimeoutError covers both open and read timeouts; the
    # wrapped exception (e.g. Net::OpenTimeout vs Net::ReadTimeout)
    # has the detail if a finer-grained check is ever useful.
    failure(nil, @url, started, "Timed out: #{e.message}")
  rescue Faraday::ConnectionFailed => e
    failure(nil, @url, started, "Connection failed: #{e.message}")
  rescue Faraday::Error => e
    failure(nil, @url, started, "#{e.class}: #{e.message}")
  end

  private

  # A fresh connection per probe — Faraday's default adapter
  # (Net::HTTP) doesn't pool, and we'd rather be honest about that
  # than fake reuse. For a higher-traffic app, swap in
  # `net_http_persistent`.
  def connection
    Faraday.new do |f|
      f.response :follow_redirects, limit: MAX_REDIRECTS
      f.options.open_timeout = OPEN_TIMEOUT_SECONDS
      f.options.timeout = READ_TIMEOUT_SECONDS
    end
  end

  def build_result(response, started)
    final_url = response.env.url.to_s
    code = response.status

    case code
    when 200..299
      success(response, final_url, started)
    when 300..399
      # `follow_redirects` should have resolved these. If we still
      # see one, the chain bottomed out without reaching 2xx — that
      # usually means we hit the redirect cap.
      failure(code, final_url, started, "Unfollowed redirect: HTTP #{code}")
    else
      failure(code, final_url, started, "HTTP #{code}")
    end
  end

  def success(response, final_url, started)
    is_sitemap, parse_error = inspect_for_sitemap(response)
    build_struct(
      "up",
      response.status,
      final_url,
      started,
      parse_error,
      is_sitemap: is_sitemap
    )
  end

  def failure(http_status, final_url, started, message)
    build_struct("down", http_status, final_url, started, message)
  end

  # Returns `[is_sitemap, parse_error]`. The HTTP probe itself is
  # still "up" regardless — a body that claimed XML but didn't parse
  # is still a 200 from the server's perspective, just not a sitemap.
  # Capturing the parse error on the `Check` row makes the failure
  # visible in history without inventing a third status.
  def inspect_for_sitemap(response)
    content_type = response.headers["content-type"].to_s
    return false, nil unless XML_CONTENT_TYPE.match?(content_type)

    # `strict` so genuinely malformed bodies raise rather than parsing
    # to something weird; `nonet` blocks network fetches during parse
    # (XXE protection).
    doc = Nokogiri.XML(response.body) { |c| c.strict.nonet }
    [SITEMAP_ROOT_ELEMENTS.include?(doc.root&.name), nil]
  rescue Nokogiri::XML::SyntaxError => e
    [false, "Body advertised XML but failed to parse: #{e.message}"]
  end

  def build_struct(
    status,
    http_status,
    final_url,
    started,
    message,
    is_sitemap: false
  )
    Result.new(
      status: status,
      http_status: http_status,
      response_time_ms:
        (
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        ).round,
      final_url: final_url,
      error_message: message,
      is_sitemap: is_sitemap,
      checked_at: Time.now
    )
  end
end
