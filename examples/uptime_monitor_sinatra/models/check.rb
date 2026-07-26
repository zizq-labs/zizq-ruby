# frozen_string_literal: true

class Check < Sequel::Model
  many_to_one :monitored_url

  def validate
    super
    unless MonitoredUrl::STATUSES.include?(status)
      errors.add(:status, "must be one of #{MonitoredUrl::STATUSES.inspect}")
    end
  end
end
