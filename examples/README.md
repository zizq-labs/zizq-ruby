# Zizq Ruby Client — Examples

Sample apps and scripts demonstrating how to use Zizq from Ruby. Each
subdirectory is self-contained.

| Directory                                          | What it is                                                                                                                       |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [`uptime_monitor_rails/`](./uptime_monitor_rails/) | A small Rails 8.1 app that monitors URLs (including sitemaps), reports transitions to a webhook, and re-checks on a cron schedule. Touches most of Zizq's surface area: ActiveJob, bulk enqueue, cron, retry/backoff. |
| [`raw_throughput/`](./raw_throughput/)             | Standalone benchmarks measuring enqueue + dispatch throughput under different job styles (`Zizq::Job`, ActiveJob, custom dispatcher).                                                                              |

Each example has its own README with run instructions.
