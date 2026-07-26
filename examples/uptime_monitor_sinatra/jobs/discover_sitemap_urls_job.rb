# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
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
# After reconciliation we bulk-enqueue an immediate `CheckUrlJob`
# for every enabled child — same UX promise as the Rails example:
# submitting a sitemap probes its URLs straight away, then the
# periodic sweep handles the rest.
#
# Sitemap-index files (`<sitemapindex>`) parse to zero `urlset > url
# > loc` matches and reconcile down to "no children" — same as the
# Rails example.
class DiscoverSitemapUrlsJob
  include Zizq::Job

  zizq_queue ZIZQ_QUEUE
  zizq_retry_limit 3

  TIMEOUT_SECONDS = 30 # sitemaps can be larger than a regular probe
  BATCH_SIZE = 500

  def perform(monitored_url_id)
    sitemap = MonitoredUrl[monitored_url_id]
    return unless sitemap

    body = fetch_body(sitemap.url)
    return unless body

    discovered = extract_urls(body)
    return if discovered.nil? # parse error: leave existing children untouched

    reconcile(sitemap, discovered)
    enqueue_immediate_checks(sitemap)
  end

  private

  def fetch_body(url)
    response = connection.get(url)
    return nil unless response.success?
    response.body
  rescue Faraday::Error => e
    warn "[DiscoverSitemapUrlsJob] failed to fetch #{url}: #{e.class}: #{e.message}"
    nil
  end

  def connection
    Faraday.new do |f|
      f.response :follow_redirects, limit: 5
      f.options.open_timeout = 5
      f.options.timeout = TIMEOUT_SECONDS
    end
  end

  def extract_urls(body)
    doc = Nokogiri.XML(body) { |c| c.strict.nonet }
    doc.remove_namespaces! # default sitemap xmlns would otherwise block plain CSS
    doc
      .css("urlset > url > loc")
      .map { |node| node.text.strip }
      .reject(&:empty?)
  rescue Nokogiri::XML::SyntaxError => e
    warn "[DiscoverSitemapUrlsJob] malformed sitemap body: #{e.message}"
    nil
  end

  def reconcile(sitemap, discovered_urls)
    # Create any URLs we haven't seen before, under this parent.
    discovered_urls.each do |url|
      next if MonitoredUrl.where(url: url, source_sitemap_url: sitemap.url).any?

      begin
        MonitoredUrl.create(
          url: url,
          source: "sitemap",
          source_sitemap_url: sitemap.url
        )
      rescue Sequel::UniqueConstraintViolation
        # Race window with another worker; the row exists now, fine.
      end
    end

    children = MonitoredUrl.where(source_sitemap_url: sitemap.url)
    # Re-enable returning children, disable departed ones. Bulk
    # UPDATEs; `updated_at` bumped manually since dataset.update
    # bypasses the timestamps plugin.
    children.where(url: discovered_urls).update(
      enabled: true,
      updated_at: Time.now
    )
    children.exclude(url: discovered_urls).update(
      enabled: false,
      updated_at: Time.now
    )
  end

  def enqueue_immediate_checks(sitemap)
    enabled_ids =
      MonitoredUrl.where(
        source_sitemap_url: sitemap.url,
        enabled: true
      ).select_map(:id)

    enabled_ids.each_slice(BATCH_SIZE) do |batch|
      Zizq.enqueue_bulk { |b| batch.each { |id| b.enqueue(CheckUrlJob, id) } }
    end
  end
end
