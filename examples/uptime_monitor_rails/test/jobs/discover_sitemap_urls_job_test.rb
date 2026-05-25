# frozen_string_literal: true

require "test_helper"

class DiscoverSitemapUrlsJobTest < ActiveJob::TestCase
  SITEMAP_URL = "https://example.com/sitemap.xml"

  def sitemap_body(*urls)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        #{urls.map { |u| "<url><loc>#{u}</loc></url>" }.join("\n")}
      </urlset>
    XML
  end

  def stub_sitemap(*urls, body: nil)
    stub_request(:get, SITEMAP_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "application/xml" },
      body: body || sitemap_body(*urls),
    )
  end

  test "discovers and creates child URLs as sitemap-sourced" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    stub_sitemap("https://example.com/a", "https://example.com/b")

    DiscoverSitemapUrlsJob.new.perform(sitemap)

    children = MonitoredUrl.where(source_sitemap_url: sitemap.url)
    assert_equal 2, children.count
    assert_equal %w[https://example.com/a https://example.com/b].sort,
                 children.pluck(:url).sort
    assert children.all?(&:enabled?)
    assert children.all? { |c| c.source == "sitemap" }
  end

  test "re-enables previously disabled children that are back in the sitemap" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    child = MonitoredUrl.create!(
      url:                "https://example.com/a",
      source:             "sitemap",
      source_sitemap_url: sitemap.url,
      enabled:            false,
    )
    stub_sitemap("https://example.com/a")

    DiscoverSitemapUrlsJob.new.perform(sitemap)

    assert child.reload.enabled?
  end

  test "disables children no longer present in the sitemap" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    to_remove = MonitoredUrl.create!(
      url:                "https://example.com/old",
      source:             "sitemap",
      source_sitemap_url: sitemap.url,
    )
    stub_sitemap("https://example.com/new")

    DiscoverSitemapUrlsJob.new.perform(sitemap)

    refute to_remove.reload.enabled?
  end

  test "a manual row and a sitemap-sourced row for the same URL can coexist" do
    MonitoredUrl.create!(url: "https://example.com/page")
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    stub_sitemap("https://example.com/page")

    DiscoverSitemapUrlsJob.new.perform(sitemap)

    assert_equal 1, MonitoredUrl.where(url: "https://example.com/page", source_sitemap_url: nil).count
    assert_equal 1, MonitoredUrl.where(url: "https://example.com/page", source_sitemap_url: sitemap.url).count
  end

  test "malformed sitemap leaves existing children untouched" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    child = MonitoredUrl.create!(
      url:                "https://example.com/keep",
      source:             "sitemap",
      source_sitemap_url: sitemap.url,
      enabled:            true,
    )
    stub_sitemap(body: "<unclosed")

    DiscoverSitemapUrlsJob.new.perform(sitemap)

    assert child.reload.enabled?, "existing children should be untouched when the sitemap fails to parse"
  end

  test "enqueues an immediate CheckUrlJob for each enabled child after reconcile" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    stub_sitemap("https://example.com/a", "https://example.com/b")

    assert_enqueued_jobs(2, only: CheckUrlJob) do
      DiscoverSitemapUrlsJob.new.perform(sitemap)
    end
  end

  test "doesn't enqueue checks for newly-disabled children" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    MonitoredUrl.create!(
      url:                "https://example.com/gone",
      source:             "sitemap",
      source_sitemap_url: sitemap.url,
    )
    stub_sitemap("https://example.com/still-here")

    assert_enqueued_jobs(1, only: CheckUrlJob) do
      DiscoverSitemapUrlsJob.new.perform(sitemap)
    end
  end

  test "a sitemapindex (no <urlset>) discovers zero URLs and disables prior children" do
    sitemap = MonitoredUrl.create!(url: SITEMAP_URL)
    old = MonitoredUrl.create!(
      url:                "https://example.com/old",
      source:             "sitemap",
      source_sitemap_url: sitemap.url,
    )
    stub_sitemap(body: <<~XML)
      <?xml version="1.0"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>https://example.com/inner.xml</loc></sitemap>
      </sitemapindex>
    XML

    DiscoverSitemapUrlsJob.new.perform(sitemap)

    assert_equal 0, MonitoredUrl.where(source_sitemap_url: sitemap.url, enabled: true).count
    refute old.reload.enabled?
  end
end
