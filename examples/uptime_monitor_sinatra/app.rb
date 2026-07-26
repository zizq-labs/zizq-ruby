# frozen_string_literal: true

# Boots the Sinatra app, the Sequel DB connection, and the embedded
# Zizq worker. Required by both `config.ru` (for the web server) and
# by tests.

require "dotenv/load" if ENV["RACK_ENV"] != "production"

require "sinatra/base"
require "sequel"
require "zizq"

# --- Database ------------------------------------------------------

DB =
  Sequel.connect(
    ENV.fetch(
      "DATABASE_URL",
      "sqlite://storage/#{ENV.fetch("RACK_ENV", "development")}.sqlite3"
    ),
    max_connections: Integer(ENV.fetch("DB_POOL_SIZE", "20"))
  )
DB.run "PRAGMA journal_mode=WAL" # multi-connection-friendly

# --- Zizq ----------------------------------------------------------

ZIZQ_QUEUE = "uptime_monitor/zizq_job"

Zizq.configure do |c|
  c.url = ENV.fetch("ZIZQ_URL", "http://127.0.0.1:7890")
  c.tls.ca = ENV["ZIZQ_CA"].to_s.then { |s| s.empty? ? nil : s }
  c.tls.client_cert =
    ENV["ZIZQ_CLIENT_CERT"].to_s.then { |s| s.empty? ? nil : s }
  c.tls.client_key = ENV["ZIZQ_CLIENT_KEY"].to_s.then { |s| s.empty? ? nil : s }
  # Multi-threaded, not Async.
  c.worker.thread_count = Integer(ENV.fetch("ZIZQ_WORKER_THREADS", "4"))
  c.worker.queues = [ZIZQ_QUEUE]
end

# --- Models --------------------------------------------------------
#
# Sequel models bind to `Sequel::Model.db` (the most recent
# `Sequel.connect`) when their class body is evaluated, so they must
# load *after* the DB is established. Order matters within the
# `models/` dir — `Check#validate` references `MonitoredUrl::STATUSES`.

require_relative "models/monitored_url"
require_relative "models/check"

# --- Services & jobs ----------------------------------------------
#
# Loaded here (rather than autoloaded) so the embedded worker below
# can dispatch them by class name. Order matters — `CheckUrlJob`
# references `UrlProber`.

require_relative "lib/url_prober"
require_relative "jobs/check_url_job"
require_relative "jobs/schedule_checks_job"
require_relative "jobs/discover_sitemap_urls_job"
require_relative "jobs/notify_webhook_job"

# --- Embedded worker ----------------------------------------------
#
# A Zizq::Worker runs inside the same process as the web server.
# Spawning here (at app.rb load time) makes it portable across most
# web servers — Puma single-process, WEBrick, Falcon, etc. — because
# they each load `app.rb` once at boot.
#
# Caveats:
#   * **Puma clustered mode** (`workers > 0`): Ruby threads don't
#     survive `fork(2)`. If you switch to clustered Puma, move the
#     spawn block into `on_worker_boot` in `config/puma.rb`.
#   * **Graceful shutdown** rides on Ruby's normal `exit` path. Web
#     servers that exit via `exit!` (double Ctrl-C, force kill) skip
#     `at_exit` — the Zizq server returns unfinished jobs to the
#     queue when the connection drops, so nothing is lost, but
#     in-flight jobs may be re-dispatched to another worker.
#
# Skip when:
#   * `RACK_ENV=test` — tests use `Zizq::Test`, no real worker needed.
#   * `ZIZQ_DISABLE_WORKER=1` — opt-out for `irb -r./app`, `bin/console`,
#     one-off scripts where the worker would just get in the way.

unless ENV["RACK_ENV"] == "test" || ENV["ZIZQ_DISABLE_WORKER"] == "1"
  # Register the periodic sweep with the Zizq server. Idempotent —
  # subsequent boots replace any existing entries. Cron requires a
  # Pro license; without one the server returns 403, which we log
  # and ignore so the app still boots usefully for ad-hoc checks.
  begin
    Zizq.define_crontab("uptime_monitor_sinatra") do |cron|
      cron.define_entry("schedule_checks", "*/5 * * * * *").enqueue(
        ScheduleChecksJob
      )
    end
  rescue Zizq::ResponseError => e
    raise unless e.status == 403
    warn "[zizq] Periodic re-checks disabled: cron requires a Pro license (HTTP 403)."
  rescue Zizq::ConnectionError => e
    warn "[zizq] Could not register cron: #{e.message}"
  end

  worker = Zizq::Worker.new
  worker_thread = Thread.new { worker.run }

  # Web server tells us to shut down -> Ruby unwinds -> at_exit runs.
  # We ask the worker to stop, then wait up to the deadline for it
  # to drain. If it doesn't, escalate to `kill` (force-exit) and
  # give it a brief moment to clean up.
  at_exit do
    deadline = Integer(ENV.fetch("ZIZQ_SHUTDOWN_DEADLINE", "30"))
    worker.stop

    unless worker_thread.join(deadline)
      warn "[zizq] worker didn't stop within #{deadline}s, killing..."
      worker.kill
      worker_thread.join(5)
    end
  end
end

# --- Application ---------------------------------------------------

class UptimeMonitorApp < Sinatra::Base
  set :root, File.expand_path(__dir__)
  set :views, File.expand_path("views", __dir__)
  set :public_folder, File.expand_path("public", __dir__)

  # Sinatra default port doesn't honour PORT; foreman exports it
  # via .env. Just here for `ruby app.rb` runs.
  set :bind, ENV.fetch("BIND", "127.0.0.1")
  set :port, Integer(ENV.fetch("PORT", "3000"))

  # Sessions back the flash messages on form post. Pin the secret
  # via `SESSION_SECRET` so cookies survive process restarts (.env
  # ships a dev default; override in .env.local / production env).
  # Without a pinned secret, Sinatra rotates one per boot and emits
  # "Session cookie encryptor error: invalid message" on the first
  # request after each restart.
  enable :sessions
  set :session_secret, ENV["SESSION_SECRET"] if ENV["SESSION_SECRET"]

  # Sinatra 4 ships with Rack::Protection's HostAuthorization, which
  # only allows localhost out of the box. `DEV_HOSTS` is a
  # comma-separated allowlist (e.g. `magnolia.local,foo.example`) for
  # accessing the dev server from another machine on the network.
  if (extra_hosts = ENV["DEV_HOSTS"]) && !extra_hosts.empty?
    set :host_authorization,
        { permitted_hosts: extra_hosts.split(",").map(&:strip) }
  end

  helpers do
    # Stripped + auto-prefixed if no scheme. Anything that already
    # starts with a `scheme://` prefix is left alone — model
    # validation rejects schemes other than http/https.
    def normalize_url(input)
      url = input.to_s.strip
      return url if url.empty? || url.match?(%r{\A[a-z][a-z0-9+.\-]*://}i)
      "https://#{url}"
    end

    def time_ago(time)
      return "never" unless time
      seconds = (Time.now - time).to_i
      case seconds
      when 0..59
        "#{seconds}s ago"
      when 60..3599
        "#{seconds / 60}m ago"
      when 3600..86_399
        "#{seconds / 3600}h ago"
      else
        "#{seconds / 86_400}d ago"
      end
    end
  end

  get "/" do
    @monitored_urls =
      MonitoredUrl.order(
        Sequel.desc(:last_checked_at),
        Sequel.desc(:created_at)
      ).all

    if request.xhr?
      erb :_urls, layout: false
    else
      erb :index
    end
  end

  post "/monitored_urls" do
    url = normalize_url(params[:url])
    monitored = MonitoredUrl.where(url: url, source_sitemap_url: nil).first

    if monitored
      session[:notice] = "Re-checking #{url}"
    else
      begin
        monitored = MonitoredUrl.create(url: url)
        session[:notice] = "Now monitoring #{url}"
      rescue Sequel::UniqueConstraintViolation
        # Race window between the find and the create — retry the find.
        monitored = MonitoredUrl.where(url: url, source_sitemap_url: nil).first
        session[:notice] = "Re-checking #{url}"
      rescue Sequel::ValidationFailed => e
        session[:alert] = e.message
      end
    end

    Zizq.enqueue(CheckUrlJob, monitored.id) if monitored
    redirect "/"
  end
end
