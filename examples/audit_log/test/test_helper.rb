# frozen_string_literal: true

# Force the test env before *anything* else — `Rakefile` loads
# dotenv before this file runs, and we don't want any RACK_ENV in
# .env to leak into the test process. Assignment (not `||=`) so an
# inherited `RACK_ENV=development` still gets overridden.
ENV["RACK_ENV"] = "test"

# Drop any leftover SQLite file, then migrate a fresh test DB
# *before* requiring app.rb. Sequel models load schema eagerly when
# their class body evaluates, so the tables need to exist by the
# time `audit_event.rb` gets required.
require "fileutils"
FileUtils.rm_f("storage/test.sqlite3")

require "sequel"
Sequel.extension :migration
Sequel.connect("sqlite://storage/test.sqlite3") do |db|
  Sequel::Migrator.run(db, "db/migrate")
end

require_relative "../app"

require "minitest/autorun"
require "rack/test"
require "timecop"

class Minitest::Test
  include Rack::Test::Methods

  def app
    AuditLogApp
  end

  def setup
    AuditEvent.dataset.delete
  end
end
