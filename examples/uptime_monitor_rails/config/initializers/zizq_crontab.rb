# frozen_string_literal: true

# Registers a 5-second cron entry on the Zizq server that fires
# ScheduleChecksJob, which sweeps for URLs due for a re-check.
#
# Cron requires a Zizq Pro license. If the server rejects the request
# (403), we log a warning and continue without periodic re-checks so
# the app still works for one-shot manual probes.

return if Rails.env.test?

Rails.application.config.after_initialize do
  Zizq.define_crontab("uptime_monitor") do |cron|
    cron.define_entry(
      "schedule_checks",
      "*/5 * * * * *",
    ).enqueue(ScheduleChecksJob)
  end
rescue Zizq::ResponseError => e
  raise unless e.status == 403 # No Pro license

  Rails.logger.warn <<~MSG.squish
    [Zizq] Periodic re-checks disabled: cron requires a Pro license on
    the Zizq server (got HTTP 403). URLs will only be checked on
    submission until cron is enabled.
  MSG
end
