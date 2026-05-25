# frozen_string_literal: true

class Check < ApplicationRecord
  belongs_to :monitored_url

  validates :status, inclusion: { in: MonitoredUrl::STATUSES }
end
