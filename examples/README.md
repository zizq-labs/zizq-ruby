# Zizq Ruby Client — Examples

Sample apps and scripts demonstrating how to use Zizq from Ruby. Each
subdirectory is self-contained.

| Directory                                              | What it is                                                                                                                       |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| [`uptime_monitor_rails/`](./uptime_monitor_rails/)     | A small Rails 8.1 app that monitors URLs (including sitemaps), reports transitions to a webhook, and re-checks on a cron schedule. Touches most of Zizq's surface area: ActiveJob, bulk enqueue, cron, retry/backoff. |
| [`uptime_monitor_sinatra/`](./uptime_monitor_sinatra/) | The same domain rebuilt on Sinatra + Sequel + Puma, with a `Zizq::Worker` running embedded in the web process. Uses `Zizq::Job` directly and intentionally uses threads only. Uses `Zizq::Test` for assertions. |
| [`audit_log/`](./audit_log/)                           | A central audit-log sink on Sinatra + Sequel + Falcon (async-fiber). Demonstrates the low-level / cross-language path: `Zizq::Router` dispatching `audit.create` jobs by `type` string, plain JSON payloads, no `Zizq::Job` mixin. Worker runs as an isolated `zizq-worker` process. Includes a `bin/simulate` producer that fires fake-but-plausible events. `uptime_monitor_rails` is also integrated with this example (it emits audit logs). |
| [`raw_throughput/`](./raw_throughput/)                 | Standalone benchmarks measuring enqueue + dispatch throughput under different job styles (`Zizq::Job`, ActiveJob, custom dispatcher).                                                                                |

Each example has its own README with run instructions.
