# Changelog

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
