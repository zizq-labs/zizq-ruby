# Uptime Monitor (Rails example)

A small Rails 8.1 app demonstrating end-to-end Zizq usage from a real
web application. Submit a URL (or a `sitemap.xml`) and it gets probed
on submission, again on a recurring cron schedule, and any
up→down/down→up transition fires a webhook.

Exercises various Zizq features and while this app is far from
production-ready, it is structured loosely like such an app would be
structured:

* **ActiveJob over Zizq** — `config.active_job.queue_adapter = :zizq`,
  jobs declared as normal `ApplicationJob` subclasses.
* **Bulk enqueue** — `ScheduleChecksJob` uses
  `ActiveJob.perform_all_later` so a backlog of N URLs is dispatched
  in a few round trips, not N.
* **Cron** — a `*/5 * * * * *` entry registered via
  `Zizq.define_crontab`, with a 403 rescue so the app still boots
  without a Pro license.
* **Retry/backoff** — `NotifyWebhookJob` declares `zizq_retry_limit`
  and `zizq_backoff`, treats 4xx receivers as poison
  (`discard_on PermanentFailure`) and lets Zizq retry 5xx / network
  errors.
* **Async-aware HTTP** — `UrlProber` and `DiscoverSitemapUrlsJob` use
  `Async::HTTP::Internet`, so the worker stays cooperative under
  multi-fiber dispatch.

## Prerequisites

* Ruby (`>= 3.3`).
* SQLite 3.
* A `zizq` binary on `PATH`. The app talks to a Zizq server at
  `ZIZQ_URL` (default `http://127.0.0.1:7890`).

## First-time setup

```sh
bundle install
bin/rails db:migrate
```

## Running everything

`bin/dev` boots Falcon (the Rack server) and the Zizq worker together
via [`foreman`](https://github.com/ddollar/foreman) using
`Procfile.dev`. By default it does **not** also boot a Zizq server —
either run `zizq serve` yourself, or uncomment the `zizq:` line in
`Procfile.dev` to have foreman manage it too.

```sh
bin/dev
```

The web UI is at <http://127.0.0.1:3000>.

## Configuration

Defaults live in `.env` (committed). Personal overrides go in
`.env.local` (gitignored). Both foreman and dotenv-rails read these.

| Variable              | Default                     | Notes                                          |
| --------------------- | --------------------------- | ---------------------------------------------- |
| `ZIZQ_URL`            | `http://127.0.0.1:7890`     | Zizq server.                                   |
| `ZIZQ_CA`             | unset                       | CA cert path for TLS.                          |
| `ZIZQ_CLIENT_CERT`    | unset                       | Client cert for mTLS.                          |
| `ZIZQ_CLIENT_KEY`     | unset                       | Client key for mTLS.                           |
| `ZIZQ_WORKER_THREADS` | `2`                         | Worker thread count.                           |
| `ZIZQ_WORKER_FIBERS`  | `10`                        | Fibers per thread.                             |
| `RAILS_MAX_THREADS`   | `20`                        | ActiveRecord connection pool size.             |
| `BIND`                | `127.0.0.1`                 | Falcon bind address.                           |
| `PORT`                | `3000`                      | Falcon port.                                   |
| `WEBHOOK_URL`         | `https://example.com/webhook` | Status-transition events get POSTed here.    |

To actually *see* webhook payloads, point `WEBHOOK_URL` at a
[webhook.site](https://webhook.site) URL. To watch Zizq's retry/backoff,
configure that URL's "Custom Response" to return HTTP 503.

## Trying it out

1. Boot via `bin/dev` (with the Zizq server running).
2. Visit <http://127.0.0.1:3000>.
3. Type a URL — `example.com`, `https://news.ycombinator.com`,
   `https://www.google.com/sitemap.xml`. The form auto-prefixes
   `https://` if you omit it.
4. The table auto-refreshes every 2s via a tiny vanilla-JS poll.
5. Sitemap URLs get their `<loc>` entries discovered and added as
   sitemap-sourced children (`source = "sitemap"`), and they're
   reconciled (re-enabled or disabled) on each subsequent re-check of
   the sitemap.
6. Re-submitting an existing URL is idempotent and re-checks it
   immediately.

## Running the tests

```sh
bin/rails test
```

The test suite uses ActiveJob's `:test` adapter (configured in
`config/environments/test.rb`), so no Zizq server is required to run
it.

## Code overview

| Path                                           | What it is                                                                            |
| ---------------------------------------------- | ------------------------------------------------------------------------------------- |
| `config/initializers/zizq.rb`                  | Zizq client config (URL, TLS, worker defaults, dispatcher).                            |
| `config/initializers/zizq_crontab.rb`          | Registers the 5s cron entry; rescues 403 / connection errors at boot.                  |
| `app/services/url_prober.rb`                   | One-shot HTTP probe with redirect following, timeout, and sitemap detection.           |
| `app/jobs/check_url_job.rb`                    | Probe one URL, record a `Check`, fan out follow-ups (sitemap discovery, webhook).      |
| `app/jobs/schedule_checks_job.rb`              | Cron sweep: bulk-enqueues `CheckUrlJob` for stale URLs.                                |
| `app/jobs/discover_sitemap_urls_job.rb`        | Re-fetches a sitemap, reconciles child URLs (create / re-enable / disable).            |
| `app/jobs/notify_webhook_job.rb`               | POSTs transition events; uses `zizq_retry_limit` + `zizq_backoff` + `discard_on`.      |
| `app/controllers/monitored_urls_controller.rb` | Web UI: index + create (`create_or_find_by!`, https:// prefix, AJAX partial).          |
