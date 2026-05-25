# Raw Throughput Benchmarks

Standalone scripts that measure how fast the Zizq Ruby client can
enqueue and dispatch jobs end-to-end against a real Zizq server. Each
script enqueues `JOB_COUNT` near-no-op jobs, then runs a worker that
drains the queue and exits when it sees the last job.

## Scripts

| Script                            | Dispatch path                                                                                  |
| --------------------------------- | ---------------------------------------------------------------------------------------------- |
| `zizq_job_throughput.rb`          | Plain `Zizq::Job` mixin — the lowest-overhead dispatcher.                                      |
| `active_job_throughput.rb`        | ActiveJob via `ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher`. Useful baseline for Rails apps. |
| `custom_dispatcher_throughput.rb` | Custom dispatcher (anything responding to `#call(job)`) — handy for cross-language workflows.    |

## Prerequisites

* A running Zizq server (default `http://localhost:7890`).
* The `zizq` gem installed (`gem install zizq`, or run from the source
  repo with `bundle exec`).

## Running

```sh
bundle exec ruby examples/raw_throughput/zizq_job_throughput.rb
bundle exec ruby examples/raw_throughput/active_job_throughput.rb
bundle exec ruby examples/raw_throughput/custom_dispatcher_throughput.rb
```

## Tuning via environment variables

| Variable           | Default          | What it controls                                                        |
| ------------------ | ---------------- | ----------------------------------------------------------------------- |
| `JOB_COUNT`        | `10000`          | How many jobs to enqueue and process.                                   |
| `THREADS`          | `5`              | Worker thread count.                                                    |
| `FIBERS`           | `1`              | Fibers per thread. `> 1` runs handlers inside an `Async` reactor.       |
| `ZIZQ_URL`         | `http://localhost:7890` | Zizq server URL.                                                 |
| `ZIZQ_FORMAT`      | `msgpack`        | Wire format (`msgpack` or `json`).                                      |
| `ZIZQ_CA`          | unset            | Path to server CA cert if Zizq is using TLS.                            |
| `ZIZQ_CLIENT_CERT` | unset            | Path to client cert for mTLS.                                           |
| `ZIZQ_CLIENT_KEY`  | unset            | Path to client key for mTLS.                                            |

Each script prints the enqueue and dispatch durations on completion so
you can compare configurations side by side.
