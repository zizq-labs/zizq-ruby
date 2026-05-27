# frozen_string_literal: true

# Force the test env before *anything* else — `Rakefile` loads
# dotenv before this file runs, and we don't want any RACK_ENV in
# .env to leak into the test process. Assignment (not `||=`) so an
# inherited `RACK_ENV=development` still gets overridden.
ENV["RACK_ENV"] = "test"

# Drop any leftover SQLite file, then migrate a fresh test DB
# *before* requiring app.rb. Sequel models load schema eagerly when
# their class body evaluates (to set up column accessors), so the
# tables need to exist by the time `models/` gets required.
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
require "webmock/minitest"
require "timecop"

# Buffer enqueues + raise on unsupported reads. Set once at suite
# boot so every test starts with the test client wired in.
Zizq::Test.enable!

class Minitest::Test
  include Rack::Test::Methods

  def app
    UptimeMonitorApp
  end

  def setup
    Zizq::Test.reset!
    [Check, MonitoredUrl].each { |klass| klass.dataset.delete }
    WebMock.reset!
  end
end
