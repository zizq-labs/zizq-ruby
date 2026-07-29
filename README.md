# Zizq — Official Ruby Client

This is the official Zizq client library for Ruby.

Zizq is a simple, zero dependency, single binary job queue system that is both
fast and durable. It is designed to work in any stack through a simple HTTP
API.

[![CI](https://github.com/zizq-labs/zizq-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/zizq-labs/zizq-ruby/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/zizq.svg)](https://rubygems.org/gems/zizq)

## Features

* Multi-thread and/or multi-fiber concurrent worker (via [`async`](https://github.com/socketry/async))
* `Zizq::Job` based job classes, Active Job support, or low-level/custom
* Enqueue and process jobs from one language to another
* Arbitrary named queues
* Granular job priorities
* Scheduled jobs
* Configurable backoff policies
* Configurable job retention policies
* Recurring jobs (cron)
* Job introspection and management APIs, with support for `jq` query filters
* Unique jobs (deduplicated)
* Batched jobs (folded/merged)
* Testing helpers

## Installation

> [!NOTE]
> If you have not yet installed the Zizq server, follow the
> [Getting Started](https://zizq.io/docs/getting-started) guide first.

Add it to your application's `Gemfile`:

```ruby
gem 'zizq', '~> 0.6.0'
```

Or install it manually:

```shell
$ gem install zizq -v 0.6.0
```

Ruby **3.2.8 or newer** is required. Client and server share version
numbers — keep the client's major/minor at or below the server's.

## Configuration

Out of the box, the client talks to a server at `http://localhost:7890` —
fine for local development. For anything else, configure it with
`Zizq.configure` in your application's bootstrap (e.g. a Rails initializer):

```ruby
require 'zizq'

Zizq.configure do |c|
  c.url    = 'https://zizq.your.network:7890'
  c.logger = Logger.new('log/zizq.log')

  c.tls.ca = '/path/to/server-ca-cert.pem'

  # Optional worker defaults — applied to every Zizq::Worker
  # instance and to runs of the `zizq-worker` executable. Explicit
  # kwargs or CLI flags override these.
  c.worker.queues = ['emails', 'payments']
  c.worker.fiber_count  = 25
end
```

For mutual TLS, also set `c.tls.client_cert` and `c.tls.client_key`.

> [!CAUTION]
> If your server is exposed directly to the internet, it should require
> mutual TLS — otherwise anybody can talk to it.

## Usage

> [!TIP]
> This README is an overview. The
> [full documentation](https://zizq.io/docs/clients/ruby/) covers each
> feature in depth — middleware, custom dispatchers, Active Job, job
> querying, and more.

### Defining a job

In most Ruby applications, a job is a plain class that includes `Zizq::Job`.
The class declares its defaults with the `zizq_*` DSL and implements
`#perform`:

```ruby
class SendEmailJob
  include Zizq::Job

  zizq_queue 'emails'
  zizq_priority 100
  zizq_retry_limit 5

  def perform(user_id, template:)
    user = User.find(user_id)
    Mailer.deliver(user, template)
  end
end
```

Every default — `zizq_queue`, `zizq_priority`, `zizq_retry_limit`,
`zizq_backoff`, `zizq_retention`, `zizq_unique` — can be overridden per
enqueue. The job's class name (`"SendEmailJob"`) becomes the API-level job
type, so keep it stable once jobs are in flight.

### Enqueuing jobs

Enqueue a job by passing the class and the arguments your `#perform` method
expects:

```ruby
job = Zizq.enqueue(SendEmailJob, 42, template: 'welcome')
job.id  # => "03fu0wm75gxgmfyfplwvazhex"
```

Override defaults for a single call with `Zizq.enqueue_with`, or with a block
that mutates the request:

```ruby
# Don't retry this one.
Zizq.enqueue_with(retry_limit: 0).enqueue(SendEmailJob, 42, template: 'welcome')

# Bump the priority via the block form.
Zizq.enqueue(SendEmailJob, 42, template: 'welcome') do |req|
  req.priority = 1000
end
```

Schedule a job for later with `delay` (seconds from now) or an absolute
`ready_at`:

```ruby
Zizq.enqueue_with(delay: 3600).enqueue(SendEmailJob, 42, template: 'welcome')
Zizq.enqueue_with(ready_at: Time.new(2027, 3, 15, 14, 30)).enqueue(SendEmailJob, 42, template: 'welcome')
```

To enqueue many jobs efficiently, `Zizq.enqueue_bulk` sends them in a single
atomic request — across queues and job types, and `enqueue_raw` enqueues can
be mixed in too:

```ruby
Zizq.enqueue_bulk do |b|
  signups.each { |user_id| b.enqueue(SendEmailJob, user_id, template: 'welcome') }
end
```

Jobs can also be enqueued without `Zizq::Job` via `Zizq.enqueue_raw` —
designed for lower-level code style, and for cross-language workflows where,
for example, a Ruby app enqueues jobs consumed by a Go service.

```ruby
Zizq.enqueue_raw(
  type: "send_email",
  queue: "comms",
  payload: { user_id: 42, template: "welcome" }
)
```

### Cross-language and low-level dispatch

When a Ruby app needs to *process* jobs enqueued by another language
(or by `Zizq.enqueue_raw`), `Zizq::Router` maps `type` strings to
handler blocks operating on plain JSON payloads:

```ruby
Zizq.configure do |c|
  c.dispatcher = Zizq::Router.new do
    route('send_email') do |payload|
      Mailer.deliver(payload['user_id'], payload['template'])
    end

    # Apps that mix the two styles can fall back to Zizq::Job
    # for anything not handled by an explicit route.
    fallback { |job| Zizq::Job.call(job) }
  end
end
```

See [Custom Dispatchers](https://zizq.io/docs/clients/ruby/dispatchers.html)
for full details. Dispatchers in Zizq are just objects that implement `#call`
with a single `Zizq::Resources::Job` argument, and `Zizq::Router` is just a
dispatcher itself.

### Running a worker

Jobs are processed by a worker, typically in a separate process. The simplest
way is the `zizq-worker` executable bundled with the gem. **Rails apps need
no arguments** — `zizq-worker` auto-detects `config/environment.rb` when run
from the app's root:

```shell
$ bundle exec zizq-worker
I, [...] INFO -- : Zizq worker starting: 1 threads, 25 fibers, prefetch=50
I, [...] INFO -- : Connected. Listening for jobs.
```

For Sinatra or other apps, pass the entrypoint explicitly:

```shell
$ bundle exec zizq-worker app.rb
```

Worker defaults (`queues`, `thread_count`, `fiber_count`, `prefetch`) come
from your `Zizq.configure { |c| c.worker.* }` block. CLI flags
(`--threads`, `--fibers`, `--queue`, `--all-queues`, etc.) override the
configured defaults when needed. Leave `--fibers 1` if your application
isn't fiber-safe — no `Async` context is loaded in that case. `INT` /
`TERM` trigger a graceful shutdown (drains in-flight jobs up to
`--shutdown-deadline`, default 30s).

For more control — for example running the worker in-process alongside a
Rack app — construct `Zizq::Worker` directly:

```ruby
require 'zizq'

# Picks up queues, fiber_count, etc. from Zizq.configure { |c| c.worker.* };
# any kwarg here overrides those defaults.
worker = Zizq::Worker.new(queues: ['emails', 'payments'])

Signal.trap('INT') { worker.stop }
worker.run  # blocks until the worker stops
```

`#run` blocks until the worker terminates; `#stop` drains in-flight jobs
gracefully, `#kill` forces an immediate stop. On any unclean shutdown the
server returns unfinished jobs to the queue — no job is lost.

### Recurring jobs (cron)

Define a cron schedule in your application's startup code. Definitions are
idempotent — every process can safely define the same schedule, and Zizq
keeps the server in sync by adding, replacing, and removing entries as the
definition changes. Cron requires a Pro license on the server.

```ruby
Zizq.define_crontab('maintenance', timezone: 'Europe/London') do |cron|
  # Every 15 minutes.
  cron.define_entry('refresh_warehouse', '*/15 * * * *').enqueue(
    RefreshWarehouseJob, incremental: true
  )

  # 9am London time, every day.
  cron.define_entry('daily_digest', '0 9 * * *').enqueue(SendDailyDigestJob)
end
```

Once defined, schedules can be inspected and managed via
`Zizq.crontab('maintenance')` — paused/resumed at the schedule level or per
entry, and deleted entirely when no longer needed.

### Testing

Set `c.test_mode = true` in your test helper and Zizq swaps the real
client out for an in-memory `Zizq::Test::Client` that buffers enqueues
instead of dispatching them. Tests can then assert on what was
enqueued and drain the buffer through the configured dispatcher —
no running server required.

```ruby
# test/test_helper.rb (or spec/spec_helper.rb)
Zizq::Test.enable!

class ActiveSupport::TestCase
  setup { Zizq::Test.reset! }
end

# In a test
def test_signup_fans_out
  SignupService.new.run

  assert Zizq::Test.enqueued?(SendWelcomeEmailJob, user_id: 42)
  assert_equal 2, Zizq::Test.pending_jobs(only_queues: 'emails').size

  # Drain the buffer through Zizq.configuration.dequeue_middleware
  # (same path the real worker takes — registered middleware runs too).
  Zizq::Test.dispatch_enqueued_jobs
end
```

See [Testing](https://zizq.io/docs/clients/ruby/testing.html) for
full details.

## Resources

* [Ruby Client Docs](https://zizq.io/docs/clients/ruby/)
* [Getting Started Docs](https://zizq.io/docs/getting-started/)
* [Zizq Command Reference](https://zizq.io/docs/cli/)
* [Zizq Ruby Client Source](https://github.com/zizq-labs/zizq-ruby)
* [Zizq Source](https://github.com/zizq-labs/zizq)

## Support & Feedback

If you need help using Zizq,
[create an issue](https://github.com/zizq-labs/zizq-ruby/issues) on the
[zizq-ruby](https://github.com/zizq-labs/zizq-ruby) repo. Feedback is very
welcome.

## License

MIT — see [LICENSE](LICENSE).
