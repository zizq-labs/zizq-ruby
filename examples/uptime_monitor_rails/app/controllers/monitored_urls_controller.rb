# frozen_string_literal: true

class MonitoredUrlsController < ApplicationController
  def index
    @monitored_urls = MonitoredUrl.order(last_checked_at: :desc, created_at: :desc)
  end

  def create
    url = normalize_url(params.require(:monitored_url).fetch(:url, ""))

    # If the URL is already monitored, be idempotent, but just re-check it.
    monitored = MonitoredUrl.create_or_find_by!(url: url)
    CheckUrlJob.perform_later(monitored)

    notice = monitored.previously_new_record? ? "Now monitoring #{url}" : "Re-checking #{url}"
    redirect_to root_path, notice: notice
  rescue ActiveRecord::RecordInvalid => e
    redirect_to root_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  # Prepend `https://` when the user typed a bare hostname like
  # `example.com`. Anything that already starts with a `scheme://`
  # prefix is left as-is — the model validation rejects schemes other
  # than http/https.
  def normalize_url(input)
    url = input.to_s.strip
    return url if url.empty? || url.match?(%r{\A[a-z][a-z0-9+.\-]*://}i)
    "https://#{url}"
  end
end
