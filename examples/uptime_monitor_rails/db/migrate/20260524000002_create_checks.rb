# frozen_string_literal: true

class CreateChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :checks do |t|
      t.references :monitored_url, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :checked_at,       null: false
      t.string   :status,           null: false
      t.integer  :http_status
      t.integer  :response_time_ms
      t.string   :final_url
      t.string   :error_message

      t.datetime :created_at, null: false
    end
  end
end
