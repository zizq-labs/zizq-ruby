# Audit Log (Sinatra example)

A central audit-log sink. Other systems enqueue `audit.create` jobs
to its queue; this app drains them, stores them, and shows them in
a paginated feed.

Deliberately low-level: every job is dispatched via
[`Zizq::Router`](https://zizq.io/docs/clients/ruby/dispatchers.html#router),
payloads are plain JSON, and the audit app has no `Zizq::Job`
classes at all. The point is to demonstrate the cross-language /
producer-decoupled shape — any service in any language can drop an
event in this queue without sharing code with the audit app.

* **Sinatra** + **Falcon** (async-fiber web server) for the
  (read-only) web UI.
* **Sequel** + **SQLite** for storage and migrations. Note: the
  `sqlite3` gem is synchronous C, so queries don't yield to the
  fiber scheduler — Falcon's async benefit here is on the HTTP
  side (cheap concurrent connections), not on storage. WAL helps
  with engine-level reader/writer concurrency, not Ruby-side
  blocking.
* **`Zizq::Router`** as the dispatcher — one route, `audit.create`.
* **Isolated `zizq-worker` process** via `bin/worker`, running in
  Zizq's multi-fiber Async mode (`fiber_count > 1`). The web
  process never runs jobs. This is the more production-realistic
  shape (web and worker scaled independently).
* **`enqueue_raw`** everywhere — there's no Ruby class on the
  producer side, just a `type` string and a JSON payload.

A planned follow-up adds a second route, `audit.export`, kicked off
from this app's own UI to demonstrate async fan-out.

## Prerequisites

* Ruby **3.2.8 or newer**
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

Boots Falcon at `http://127.0.0.1:3000` *and* a separate
`zizq-worker` process via foreman.

To run just the worker:

```sh
bin/worker
```

## Emitting an event

The audit app is a *consumer* — it doesn't produce events. The
quickest way to see something on the dashboard is `bin/simulate`,
which enqueues fake-but-plausible events drawn from a small catalog
of source systems (billing, auth, admin console, CRM):

```sh
bin/simulate           # one event
bin/simulate 50        # fifty events
```

To stream events at variable intervals:

```sh
while true; do bin/simulate; sleep $((RANDOM % 3 + 1)); done
```

`bin/simulate` is just a producer that shares no code with the
audit app — it `require`s the `zizq` gem and calls
`Zizq.enqueue_raw(type: "audit.create", queue: "audit", payload: {...})`.
The same shape works from any language with a Zizq client. For
reference, the equivalent Ruby snippet by hand:

```ruby
require "zizq"

Zizq.configure { |c| c.url = "http://127.0.0.1:7890" }

Zizq.enqueue_raw(
  type:  "audit.create",
  queue: "audit",
  payload: {
    "occurred_at" => Time.now.utc.iso8601,
    "source"      => "billing_api",
    "event_type"  => "invoice.refunded",
    "actor"       => "alice@example.com",
    "ip"          => "203.0.113.7",
    "resource"    => "invoice:42",
    "text"        => "Refunded $24.00 to card ending 1234",
    "data"        => { "amount_cents" => 2400, "card_last4" => "1234" }
  }
)
```

The audit app's `Zizq::Router` matches on `"audit.create"`, calls
`AuditEvent.from_payload(...).save`, and the row appears in the
feed at `/`.

## Tests

```sh
bundle exec rake test
```
