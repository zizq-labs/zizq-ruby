# frozen_string_literal: true

require "async"
require "async/http/internet/instance"
require "nokogiri"

# Re-fetches a known sitemap URL, parses out the child `<url><loc>`
# entries, and reconciles them against existing `MonitoredUrl`s with
# the same `source_sitemap_url`:
#
# * URLs in the sitemap but not the DB    -> created (enabled).
# * URLs in both DB and sitemap           -> re-enabled if they had been
#                                            disabled by a prior sweep.
# * URLs in the DB but not the sitemap    -> disabled (kept for history;
#                                            stop probing).
#
# Sitemap-index files (`<sitemapindex>`) are not recursed into in this
# example app.
class DiscoverSitemapUrlsJob < ApplicationJob
  TIMEOUT_SECONDS = 15
  BATCH_SIZE  = 500

  def perform(sitemap)
    discovered = fetch_and_parse(sitemap.url)
    return if discovered.nil? # parse error: leave existing children untouched

    reconcile(sitemap, discovered)
  end

  private

  def fetch_and_parse(url)
    body = Sync do
      Async::Task.current.with_timeout(TIMEOUT_SECONDS) do
        response = Async::HTTP::Internet.get(url)
        begin
          response.read.to_s
        ensure
          response&.finish
          response&.close
        end
      end
    end

    extract_urls(body)
  rescue => e
    logger.warn "DiscoverSitemapUrlsJob: failed to fetch #{url}: #{e.class}: #{e.message}"
    nil
  end

  def extract_urls(body)
    doc = Nokogiri::XML(body) { |c| c.strict.nonet }
    doc.remove_namespaces! # default sitemap xmlns would otherwise block plain CSS
    doc.css("urlset > url > loc").filter_map { |node| node.text.strip.presence }
  rescue Nokogiri::XML::SyntaxError => e
    logger.warn "DiscoverSitemapUrlsJob: malformed sitemap body: #{e.message}"
    nil
  end

  def reconcile(sitemap, discovered_urls)
    discovered_urls.each do |url|
      MonitoredUrl.create_or_find_by!(url: url, source_sitemap_url: sitemap.url) do |m|
        m.source = "sitemap"
      end
    end

    children = MonitoredUrl.where(source_sitemap_url: sitemap.url)
    children.where(url: discovered_urls).update_all(enabled: true, updated_at: Time.current)
    children.where.not(url: discovered_urls).update_all(enabled: false, updated_at: Time.current)

    Audit.emit(
      event_type: "sitemap.scanned",
      actor:      "system",
      resource:   "monitored_url:#{sitemap.id}",
      text:       "Found #{discovered_urls.size} URL(s) in #{sitemap.url}",
      data:       {
        "sitemap_url"      => sitemap.url,
        "discovered_count" => discovered_urls.size,
      },
    )

    children.enabled.in_batches(of: BATCH_SIZE) do |batch|
      jobs = batch.map { |child| CheckUrlJob.new(child) }
      ActiveJob.perform_all_later(jobs)
    end
  end
end
