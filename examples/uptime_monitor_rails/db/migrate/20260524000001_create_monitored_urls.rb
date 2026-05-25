# frozen_string_literal: true

class CreateMonitoredUrls < ActiveRecord::Migration[8.1]
  def change
    create_table :monitored_urls do |t|
      t.string  :url,                  null: false
      t.string  :source,               null: false, default: "manual"
      t.string  :source_sitemap_url
      t.boolean :enabled,              null: false, default: true
      t.integer :consecutive_failures, null: false, default: 0
      t.datetime :last_checked_at
      t.string  :last_status

      t.timestamps
    end

    add_index :monitored_urls, :url, unique: true
  end
end
