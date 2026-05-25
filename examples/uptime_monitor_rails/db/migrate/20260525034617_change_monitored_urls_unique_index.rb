# frozen_string_literal: true

# Replace the simple `url` unique index with a composite that
# distinguishes manual vs sitemap-sourced rows.
#
# COALESCE(source_sitemap_url, '') so SQLite treats two manual rows
# (both NULL) as colliding. The result: at most one manual row per
# URL, plus one sitemap-sourced row per (URL, parent sitemap).
class ChangeMonitoredUrlsUniqueIndex < ActiveRecord::Migration[8.1]
  def change
    remove_index :monitored_urls, :url
    add_index :monitored_urls,
              "url, COALESCE(source_sitemap_url, '')",
              unique: true,
              name: "idx_monitored_urls_url_scoped"
  end
end
