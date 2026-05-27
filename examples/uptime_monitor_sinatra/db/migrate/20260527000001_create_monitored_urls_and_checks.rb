# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:monitored_urls) do
      primary_key :id

      String    :url,                  null: false
      String    :source,               null: false, default: "manual"
      String    :source_sitemap_url
      TrueClass :enabled,              null: false, default: true
      Integer   :consecutive_failures, null: false, default: 0
      DateTime  :last_checked_at
      String    :last_status

      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false
    end

    # Composite unique index that distinguishes manual rows (NULL
    # source_sitemap_url) from sitemap-sourced rows — same shape as
    # the Rails example. SQLite treats two NULLs as distinct, so we
    # COALESCE to '' inside the index. Sequel's DSL doesn't have a
    # clean way to express expression indexes, so this is raw SQL.
    run <<~SQL
      CREATE UNIQUE INDEX idx_monitored_urls_url_scoped
        ON monitored_urls (url, COALESCE(source_sitemap_url, ''))
    SQL

    create_table(:checks) do
      primary_key :id
      foreign_key :monitored_url_id, :monitored_urls,
                  null: false, on_delete: :cascade, index: true

      DateTime :checked_at,        null: false
      String   :status,            null: false
      Integer  :http_status
      Integer  :response_time_ms
      String   :final_url
      String   :error_message

      DateTime :created_at, null: false
    end
  end
end
