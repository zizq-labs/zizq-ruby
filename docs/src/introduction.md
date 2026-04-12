# Introduction

Zizq is a simple single-binary persistent job queue server with clients in
various programming languages. All official Zizq clients are **MIT licensed**.

This documentation details how to use Zizq with Ruby by using the official Zizq
Ruby Client, which is available on RubyGems as
[zizq](https://rubygems.org/gems/zizq).

The worker is multi-threaded and optionally multi-fiber via the
[`async`](https://github.com/socketry/async) gem. You could run just one
thread, 10 threads, 100 fibers, or 10 threads with 20 fibers. You could do this
across 5 worker processes simultaneously. It's up to your application how you
manage concurrency.

> [!NOTE]
> If you have not yet installed the Zizq server, follow the
> [Getting Started](/docs/getting-started) guide first.

## Issues & Source

All client source code is
[available on Github](https://github.com/zizq-labs/zizq-ruby). Issues can be
raised on the [Issue tracker](https://github.com/zizq-labs/zizq-ruby/issues).

## High-Level Structure

The Ruby client has two main parts:

1. A client library with classes and modules to integrate in your Ruby
   application, such as enqueueing and query primitives, as well as a `Worker`
   class for inline worker usage.
2. An executable used to run concurrent workers and perform your jobs.

Jobs can be managed in one of three ways:

1. By mixing `Zizq::Job` into your classes and enqueueing those jobs with args.
2. By enqueueing raw payloads and using a custom dispatcher implementation.
3. By using Active Job with the `:zizq` queue adapter.

In each case Zizq handles the persistence, acknowledgement, backoff and retry
handling automatically.

## Example

For the common case, jobs are written using [`Zizq::Job`](/job-classes.md) like this.

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

Instances of those jobs are enqueued like this:

```ruby
Zizq.enqueue(SendEmailJob, user.id, template: 'welcome')
```

And the worker is run to perform those jobs like this:

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

The worker dequeues jobs from the server, loads and instantiates the job class
and then calls the `#perform` method on that job instance. As long as no errors
are raised by the job, the client acknowledges execution of that job with the
server. Any errors raised are handled by the worker and reported to the server
which will either backoff and retry, or kill the job if it has exceeded its
retry limit.

> [!TIP]
> For more advanced and cross-language use cases, jobs can be enqueued and
> processed directly by using a [custom dispatcher](./dispatchers.md).
