# frozen_string_literal: true

require "async"
require "async/http/internet/instance"
require "nokogiri"
require "uri"

# Performs a single HTTP probe of a URL, following up to MAX_REDIRECTS
# redirects, and returns a Result struct describing the outcome.
#
#   UrlProber.call("https://example.com")
#   # => #<Result status="up" http_status=200 response_time_ms=42
#   #             final_url="https://example.com/" error_message=nil
#   #             is_sitemap=false checked_at=...>
#
# A 2xx final response is "up". Anything else — non-2xx final, network
# error, missing Location header on a redirect, exceeded redirect cap —
# is "down".
#
# When the final response is XML, the prober peeks at the root element
# to flag whether the URL is a sitemap (urlset/sitemapindex). It
# doesn't extract the URLs — DiscoverSitemapUrlsJob re-fetches and
# parses in full.
class UrlProber
  MAX_REDIRECTS = 5
  TIMEOUT_SECONDS = 10

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
    # `with_timeout` bounds the whole probe — DNS, TCP/TLS, all redirect
    # hops, and reading the response — not each step individually. If
    # the site is slow enough that the total exceeds TIMEOUT_SECONDS,
    # that's effectively "down" from a user-experience perspective.
    Sync { Async::Task.current.with_timeout(TIMEOUT_SECONDS) { probe } }
  end

  private

  def probe
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    current_url = @url
    hops = 0

    loop do
      response = Async::HTTP::Internet.get(current_url)

      begin
        status_code = response.status

        case status_code
        when 200..299
          return(
            success_with_sitemap_check(
              response,
              status_code,
              current_url,
              started
            )
          )
        when 300..399
          location = response.headers["location"]
          unless location
            return(
              failure(
                status_code,
                current_url,
                started,
                "Redirect without Location header"
              )
            )
          end

          hops += 1
          if hops > MAX_REDIRECTS
            return(
              failure(
                status_code,
                current_url,
                started,
                "Too many redirects (> #{MAX_REDIRECTS})"
              )
            )
          end

          current_url = URI.join(current_url, location).to_s
        else
          return(
            failure(status_code, current_url, started, "HTTP #{status_code}")
          )
        end
      ensure
        response&.finish
        response&.close
      end
    end
  rescue Async::TimeoutError
    failure(
      nil,
      current_url || @url,
      started,
      "Timed out after #{TIMEOUT_SECONDS}s"
    )
  rescue => e
    failure(nil, current_url || @url, started, "#{e.class}: #{e.message}")
  end

  # Build the "up" result, peeking at the body for sitemap detection
  # when the content-type advertises XML. Body is discarded after —
  # DiscoverSitemapUrlsJob re-fetches for actual URL extraction.
  def success_with_sitemap_check(response, http_status, final_url, started)
    is_sitemap = false
    parse_error = nil

    if XML_CONTENT_TYPE.match?(response.headers["content-type"])
      body = response.read.to_s
      begin
        # `strict` so genuinely malformed bodies raise rather than
        # silently parsing to something weird; `nonet` blocks
        # network fetches during parse (XXE protection).
        doc = Nokogiri.XML(body) { |c| c.strict.nonet }
        is_sitemap = SITEMAP_ROOT_ELEMENTS.include?(doc.root&.name)
      rescue Nokogiri::XML::SyntaxError => e
        parse_error = "Body advertised XML but failed to parse: #{e.message}"
      end
    end

    build_result(
      "up",
      http_status,
      final_url,
      started,
      parse_error,
      is_sitemap: is_sitemap
    )
  end

  def failure(http_status, final_url, started, message)
    build_result("down", http_status, final_url, started, message)
  end

  def build_result(
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
      checked_at: Time.current
    )
  end
end
