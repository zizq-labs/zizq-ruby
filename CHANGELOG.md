# Changelog

## 0.3.4

- **Fixed `zizq_backoff` serialising `base_ms` / `jitter_ms` as
  floats.** The server expects integer milliseconds (`u32`), and was
  rejecting the request with
  `invalid MessagePack: invalid type: floating point, expected u32`.
  These fields now go over the wire as integers (matching the existing
  treatment of `retention[:completed_ms]` / `retention[:dead_ms]`).
  `exponent` stays a float — it's a ratio, not a duration.

## 0.3.3

- **The default logger now flushes after every log line.** Under
  process supervisors like foreman, systemd, or Kubernetes, a Ruby
  process's stdout is a pipe rather than a TTY, which switches the
  default C-stdio mode from line-buffered to fully-buffered — log
  lines pile up in a 4–8KB buffer and only flush on process exit (or
  Ctrl-C). The default `Zizq.configuration.logger` now wraps stdout
  in a small delegator that calls `flush` after every write, so log
  output appears immediately under any environment without
  globally mutating `$stdout.sync`. Apps that set their own
  `c.logger = ...` are unaffected.

## 0.3.2

- **TLS settings can now be configured via accessors** instead of (or in
  addition to) a hash:

      Zizq.configure do |c|
        c.tls.ca          = "/path/to/server-ca-cert.pem"
        c.tls.client_cert = "/path/to/client-cert.pem"
        c.tls.client_key  = "/path/to/client-key.pem"
      end

  The hash form (`c.tls = { ca: "..." }`) still works for backward
  compatibility — each assignment builds a fresh `TlsConfiguration`,
  matching the prior replace-on-assign behaviour. Set `c.tls = nil`
  to explicitly disable TLS.

- **Worker defaults are now configurable via `Zizq.configure`.** Apps
  can set per-Worker defaults inside their existing `Zizq.configure`
  block via the new `c.worker.*` accessors (`queues`, `thread_count`,
  `fiber_count`, `prefetch`, retry knobs). `Zizq::Worker.new` resolves
  each setting as
  `kwarg || Zizq.configuration.worker.<field> || DEFAULT_*`,
  so explicit kwargs still override and unset fields fall through to
  the Worker's hardcoded defaults. Also accessible as
  `Zizq.configuration.worker`.

      Zizq.configure do |c|
        c.url = "https://..."
        c.worker.queues = ["emails", "webhooks"]
        c.worker.fiber_count = 25
      end

- **`zizq-worker` auto-detects the entrypoint** for Rails apps. Run it
  with no arguments from your Rails app's root directory and it will
  load `config/environment.rb` automatically. Explicit `ENTRYPOINT`
  argument or `ZIZQ_ENTRYPOINT` env var still take precedence. Other
  frameworks (Sinatra, plain Ruby) continue to require an explicit
  entrypoint.

- **New `--all-queues` CLI flag.** Explicitly overrides any configured
  `c.worker.queues` to process all queues. Mutually exclusive with
  `--queue` / `ZIZQ_QUEUES`. Without this flag, omitting `--queue`
  means "defer to whatever the app configured."

- **Default `thread_count` reduced from 5 to 1.** The previous default
  ran 5 threads × 1 fiber = 5 concurrent handlers. The new default of
  1 thread × 1 fiber = 1 handler is a safer baseline that is more
  intuitive when setting e.g. `c.worker.fiber_count = 25`
  (expecting 25 handlers, not 125). Apps that relied on the implicit
  5-thread default should set `c.worker.thread_count = 5` explicitly.

- **Fixed `zizq-worker` failing to exit when the shutdown deadline
  fires.** The watchdog thread was calling `exit(1)`, which only
  raises `SystemExit` inside the watchdog thread itself — the main
  thread (joining the busy worker) was untouched and the process kept
  running. Replaced with `exit!(1)`, which is the process-wide hard
  exit and works correctly from any thread.

## 0.3.1

- Added `read_timeout` and `stream_idle_timeout` options on
  `Zizq.configure`. `read_timeout` (default 30s) bounds per-operation
  socket I/O for regular API calls; `stream_idle_timeout` (default 30s)
  bounds per-operation socket I/O on the long-lived `/jobs/take`
  stream used by `Zizq::Worker`, so dead connections are detected and
  the worker reconnects with backoff instead of waiting forever on a zombie
  socket. Both are reset on each read, so server heartbeats keep the
  stream alive while only genuinely silent connections trigger a
  reconnect.

## 0.3.0

- Added cron (recurring jobs) scheduling support via `Zizq.define_crontab`

## 0.2.1

- Support enqueueing Active Job classes through `Zizq.enqueue`

## 0.2.0

- Implement `Client#count_jobs`
- Optimise `Zizq::Query#count`

## 0.1.0

- Initial release
- Client using HTTP/2 and HTTP/1.1 with MessagePack
- Multi-threaded, optionally multi-fiber Worker
- Bulk acknowledgment batching
- Job classes with Zizq::Job mixin
- Active Job adapter
- Low-level custom enqueue and dispatch
- Enqueue and bulk enqueue with middleware support
- Composable lazy query builder for jobs
- Unique job support
- RBS type annotations
- TLS and mutual TLS support
