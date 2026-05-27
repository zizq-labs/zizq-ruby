# Uptime Monitor (Sinatra example)

A Sinatra version of the Rails [Uptime Monitor](../uptime_monitor_rails/)
example app. Same domain (monitor URLs, periodic re-checks, webhook
transitions) but built on a much smaller stack:

* **Sinatra** + **Puma** for the web layer.
* **Sequel** + **SQLite** for storage and migrations.
* **`Zizq::Job`** (the bare mixin — no Active Job) with the worker
  running **in the same process** as the web server. Threads only,
  no `Async` reactor — fiber_count is `1` deliberately, so this
  doubles as a demonstration that Zizq works without async-ruby.
* **`Zizq::Test`** for the test suite — this app exists in part to
  dogfood the test helpers we just shipped.

This is scaffolding-only right now. The actual app is being built
out incrementally.

## Prerequisites

* Ruby (see `.ruby-version` once it exists).
* SQLite 3.
* A running Zizq server on `ZIZQ_URL` (default `http://127.0.0.1:7890`).

## First-time setup

```sh
bundle install
bundle exec rake db:migrate
```

## Running

```sh
bin/dev
```

Boots Puma at `http://127.0.0.1:3000` via foreman.

## Tests

```sh
bundle exec rake test
```
