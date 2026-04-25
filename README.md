# Zizq — Official Ruby Client

Zizq is a simple, zero dependency, single binary job queue system that is both
fast and durable. It is designed to work in any stack through a simple HTTP
API.

This is the official Zizq client library for Ruby.

[![CI](https://github.com/zizq-labs/zizq-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/zizq-labs/zizq-ruby/actions/workflows/ci.yml)

## Features

* Multi-thread and/or multi-fiber concurrent worker (via [`async`](https://github.com/socketry/async))
* `Zizq::Job` based job classes, Active Job support, or completely custom
* Enqueue and process jobs from one language to another
* Arbitrary named queues
* Granular job priorities
* Scheduled jobs
* Configurable backoff policies
* Configurable job retention policies
* Job introspection and management APIs, with support for `jq` query filters
* Unique jobs

## Example

> [!TIP]
> The client is very flexible and supports being used in a range of different
> ways. Read the [full documentation](https://zizq.io/docs/clients/ruby/) on
> the website for more details.

Mixin-based job class.

```ruby
class SendEmailJob
  include Zizq::Job

  zizq_queue 'emails'
  zizq_priority 100

  def perform(user_id, template:)
    # your application logic here
  end
end
```

Enqueueing a job.

```ruby
Zizq.enqueue(SendEmailJob, 42, template: 'welcome')
```

> [!NOTE]
> Jobs can also be enqueued and processed without `Zizq::Job`, which is
> designed to support interoperability with any programming language.

Using the included `zizq-worker` executable.

```shell
$ zizq-worker --threads 5 --fibers 2 app.rb
I, [2026-03-24T15:25:57.738131 #1331422]  INFO -- : Zizq worker starting: 5 threads, 2 fibers, prefetch=20
I, [2026-03-24T15:25:57.738222 #1331422]  INFO -- : Queues: (all)
I, [2026-03-24T15:25:57.739861 #1331422]  INFO -- : Worker 0:0 started
I, [2026-03-24T15:25:57.739962 #1331422]  INFO -- : Worker 0:1 started
I, [2026-03-24T15:25:57.740131 #1331422]  INFO -- : Worker 1:0 started
I, [2026-03-24T15:25:57.740211 #1331422]  INFO -- : Worker 1:1 started
I, [2026-03-24T15:25:57.740352 #1331422]  INFO -- : Worker 2:0 started
I, [2026-03-24T15:25:57.740408 #1331422]  INFO -- : Worker 2:1 started
I, [2026-03-24T15:25:57.740532 #1331422]  INFO -- : Worker 3:0 started
I, [2026-03-24T15:25:57.740590 #1331422]  INFO -- : Worker 3:1 started
I, [2026-03-24T15:25:57.740722 #1331422]  INFO -- : Worker 4:0 started
I, [2026-03-24T15:25:57.740776 #1331422]  INFO -- : Worker 4:1 started
I, [2026-03-24T15:25:57.740844 #1331422]  INFO -- : Zizq producer thread started
I, [2026-03-24T15:25:57.740878 #1331422]  INFO -- : Connecting to http://localhost:7890...
I, [2026-03-24T15:25:57.792173 #1331422]  INFO -- : Connected. Listening for jobs.
```

> [!NOTE]
> Workers can also be created directly in code. There is no requirement to use
> `zizq-worker`.

## Resources

* [Ruby Client Docs](https://zizq.io/docs/clients/ruby/)
* [Getting Started Docs](https://zizq.io/docs/getting-started/)
* [Zizq Command Reference](https://zizq.io/docs/cli/)
* [Zizq Node.js Client Source](https://github.com/zizq-labs/zizq-node)
* [Zizq Source](https://github.com/zizq-labs/zizq)

## Support & Feedback

If you need help using Zizq,
[create an issue](https://github.com/zizq-labs/zizq-ruby/issues) on the
[zizq-ruby](https://github.com/zizq-labs/zizq-ruby) repo. Feedback is very
welcome.
