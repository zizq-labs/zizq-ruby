# frozen_string_literal: true

require "async"
require "async/http/internet/instance"
require "uri"

# Performs a single HTTP probe of a URL, following up to MAX_REDIRECTS
# redirects, and returns a Result struct describing the outcome.
#
#   UrlProber.call("https://example.com")
#   # => #<Result status="up" http_status=200 response_time_ms=42
#   #             final_url="https://example.com/" error_message=nil
#   #             checked_at=2026-05-24 12:34:56 UTC>
#
# A 2xx final response is "up". Anything else — non-2xx final, network
# error, missing Location header on a redirect, exceeded redirect cap —
# is "down".
class UrlProber
  MAX_REDIRECTS = 5

  Result = Struct.new(
    :status,
    :http_status,
    :response_time_ms,
    :final_url,
    :error_message,
    :checked_at,
    keyword_init: true,
  )

  def self.call(url)
    new(url).call
  end

  def initialize(url)
    @url = url
  end

  def call
    Sync { probe }
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
          return success(status_code, current_url, started)
        when 300..399
          location = response.headers["location"]
          return failure(status_code, current_url, started, "Redirect without Location header") unless location

          hops += 1
          return failure(status_code, current_url, started, "Too many redirects (> #{MAX_REDIRECTS})") if hops > MAX_REDIRECTS

          current_url = URI.join(current_url, location).to_s
        else
          return failure(status_code, current_url, started, "HTTP #{status_code}")
        end
      ensure
        response&.finish
        response&.close
      end
    end
  rescue => e
    failure(nil, current_url || @url, started, "#{e.class}: #{e.message}")
  end

  def success(http_status, final_url, started)
    build_result("up", http_status, final_url, started, nil)
  end

  def failure(http_status, final_url, started, message)
    build_result("down", http_status, final_url, started, message)
  end

  def build_result(status, http_status, final_url, started, message)
    Result.new(
      status:           status,
      http_status:      http_status,
      response_time_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      final_url:        final_url,
      error_message:    message,
      checked_at:       Time.current,
    )
  end
end
