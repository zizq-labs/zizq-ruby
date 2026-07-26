# frozen_string_literal: true

require_relative "test_helper"

class TestDiscoverSitemapUrlsJob < Minitest::Test
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
      headers: {
        "Content-Type" => "application/xml"
      },
      body: body || sitemap_body(*urls)
    )
  end

  def test_discovers_and_creates_child_urls_as_sitemap_sourced
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    stub_sitemap("https://example.com/a", "https://example.com/b")

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    children = MonitoredUrl.where(source_sitemap_url: sitemap.url).all
    assert_equal 2, children.size
    assert_equal %w[https://example.com/a https://example.com/b].sort,
                 children.map(&:url).sort
    assert children.all?(&:enabled)
    assert children.all? { |c| c.source == "sitemap" }
  end

  def test_re_enables_previously_disabled_children_back_in_the_sitemap
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    child =
      MonitoredUrl.create(
        url: "https://example.com/a",
        source: "sitemap",
        source_sitemap_url: sitemap.url,
        enabled: false
      )
    stub_sitemap("https://example.com/a")

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    assert child.refresh.enabled
  end

  def test_disables_children_no_longer_present_in_the_sitemap
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    to_remove =
      MonitoredUrl.create(
        url: "https://example.com/old",
        source: "sitemap",
        source_sitemap_url: sitemap.url
      )
    stub_sitemap("https://example.com/new")

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    refute to_remove.refresh.enabled
  end

  def test_manual_and_sitemap_sourced_rows_for_the_same_url_can_coexist
    MonitoredUrl.create(url: "https://example.com/page")
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    stub_sitemap("https://example.com/page")

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    assert_equal 1,
                 MonitoredUrl.where(
                   url: "https://example.com/page",
                   source_sitemap_url: nil
                 ).count
    assert_equal 1,
                 MonitoredUrl.where(
                   url: "https://example.com/page",
                   source_sitemap_url: sitemap.url
                 ).count
  end

  def test_malformed_sitemap_leaves_existing_children_untouched
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    child =
      MonitoredUrl.create(
        url: "https://example.com/keep",
        source: "sitemap",
        source_sitemap_url: sitemap.url,
        enabled: true
      )
    stub_sitemap(body: "<unclosed")

    # Job warns on stderr when the body fails to parse — capture so
    # the warning doesn't muddy the test output.
    _out, err = capture_io { DiscoverSitemapUrlsJob.new.perform(sitemap.id) }

    assert child.refresh.enabled,
           "existing children should be untouched when the sitemap fails to parse"
    assert_match(/malformed sitemap body/, err)
  end

  def test_enqueues_an_immediate_check_for_each_discovered_child
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    stub_sitemap("https://example.com/a", "https://example.com/b")

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    assert_equal 2, Zizq::Test.enqueued_count(CheckUrlJob)
  end

  def test_disabled_children_are_not_enqueued_for_immediate_check
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    MonitoredUrl.create(
      url: "https://example.com/gone",
      source: "sitemap",
      source_sitemap_url: sitemap.url
    )
    stub_sitemap("https://example.com/still-here")

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    # Only the surviving child gets a CheckUrlJob; the disabled one
    # is skipped.
    assert_equal 1, Zizq::Test.enqueued_count(CheckUrlJob)
  end

  def test_a_sitemapindex_discovers_zero_urls_and_disables_prior_children
    sitemap = MonitoredUrl.create(url: SITEMAP_URL)
    old =
      MonitoredUrl.create(
        url: "https://example.com/old",
        source: "sitemap",
        source_sitemap_url: sitemap.url
      )
    stub_request(:get, SITEMAP_URL).to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/xml"
      },
      body: <<~XML
        <?xml version="1.0"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://example.com/inner.xml</loc></sitemap>
        </sitemapindex>
      XML
    )

    DiscoverSitemapUrlsJob.new.perform(sitemap.id)

    refute old.refresh.enabled
    assert_equal 0, Zizq::Test.enqueued_count(CheckUrlJob)
  end
end
