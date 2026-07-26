# frozen_string_literal: true

# Boots the Sinatra app, the Sequel DB connection, and configures
# Zizq with the audit Router. Required by:
#   * `config.ru` (web server)
#   * `bin/worker` -> `zizq-worker app.rb` (background worker)
#   * the test suite
#
# The worker runs as a separate process (`bin/worker` or the `worker:`
# see Procfile.dev). This is a consumer side application. Other systems
# enqueue `audit.create` events and this app maintains them. This
# infrastructure decouples the audit system from other systems, allowing
# one to go offline without impacting the other.
#
# The web side of this app is read-only.

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
    max_connections: Integer(ENV.fetch("DB_POOL_SIZE", "10"))
  )
DB.run "PRAGMA journal_mode=WAL"

# Without this, SQLite's TEXT timestamps drop the offset and get
# read back as local Time on the way out — which makes a UTC event
# stored from +1000 look like it happened 10h ago.
Sequel.default_timezone = :utc

# --- Models --------------------------------------------------------
#
# Sequel models bind to `Sequel::Model.db` (the most recent
# `Sequel.connect`) when their class body is evaluated, so they must
# load *after* the DB is established.

require_relative "audit_event"

# --- Zizq ----------------------------------------------------------
#
# The Router is the dispatcher. `zizq-worker app.rb` loads this file,
# sees `c.dispatcher = AUDIT_ROUTER`, and dispatches `audit.create`
# jobs (and any future audit-namespaced jobs) by `type` string.

require_relative "audit_router"

# Systems write to this queue for auditing.
ZIZQ_QUEUE = "audit"

Zizq.configure do |c|
  c.url = ENV.fetch("ZIZQ_URL", "http://127.0.0.1:7890")
  c.tls.ca = ENV["ZIZQ_CA"].to_s.then { |s| s.empty? ? nil : s }
  c.tls.client_cert =
    ENV["ZIZQ_CLIENT_CERT"].to_s.then { |s| s.empty? ? nil : s }
  c.tls.client_key = ENV["ZIZQ_CLIENT_KEY"].to_s.then { |s| s.empty? ? nil : s }

  # Not using Zizq::Job or ActiveJob so we're full stack compatible.
  c.dispatcher = AUDIT_ROUTER

  c.worker.fiber_count = Integer(ENV.fetch("ZIZQ_WORKER_FIBERS", "25"))
  c.worker.queues = [ZIZQ_QUEUE]
end

# --- Application ---------------------------------------------------

class AuditLogApp < Sinatra::Base
  PAGE_SIZE = 50

  set :root, File.expand_path(__dir__)
  set :views, File.expand_path("views", __dir__)
  set :public_folder, File.expand_path("public", __dir__)

  set :bind, ENV.fetch("BIND", "127.0.0.1")
  set :port, Integer(ENV.fetch("PORT", "3000"))

  # Sinatra 4's Rack::Protection HostAuthorization only allows
  # localhost by default. `DEV_HOSTS` opens it up for LAN access.
  if (extra_hosts = ENV["DEV_HOSTS"]) && !extra_hosts.empty?
    set :host_authorization,
        { permitted_hosts: extra_hosts.split(",").map(&:strip) }
  end

  helpers do
    def time_ago(time)
      return "" unless time
      seconds = (Time.now - time).to_i
      case seconds
      when ...0
        time.utc.iso8601 # future
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

    def format_data(json_value)
      if json_value.nil? || (json_value.is_a?(Hash) && json_value.empty?)
        return ""
      end
      JSON.pretty_generate(json_value)
    end
  end

  # Most-recent-first audit feed, cursor-paginated by (occurred_at,
  # id). The cursor in the URL is "<epoch_micros>:<id>"; the first
  # page omits it.
  get "/" do
    @events = page_dataset(params[:cursor]).limit(PAGE_SIZE).all
    @next_cursor = next_cursor_for(@events)
    erb :index
  end

  private

  def page_dataset(cursor)
    ds = AuditEvent.order(Sequel.desc(:occurred_at), Sequel.desc(:id))
    return ds unless cursor

    occurred_at, id = parse_cursor(cursor)
    return ds unless occurred_at && id

    # SQLite doesn't support row-value comparisons, so spell the
    # tuple ordering out by hand.
    ds.where do
      (Sequel[:occurred_at] < occurred_at) |
        ((Sequel[:occurred_at] =~ occurred_at) & (Sequel[:id] < id))
    end
  end

  def parse_cursor(cursor)
    micros, id = cursor.to_s.split(":", 2)
    [Time.at(Rational(Integer(micros), 1_000_000)), Integer(id)]
  rescue ArgumentError, TypeError
    [nil, nil]
  end

  def next_cursor_for(events)
    return nil if events.size < PAGE_SIZE
    last = events.last
    micros = (last.occurred_at.to_r * 1_000_000).to_i
    "#{micros}:#{last.id}"
  end
end
