# Running Workers

Your jobs are ultimately handled in a separate process which runs
`Zizq::Worker`. You can either run this manually within your Ruby application
code, or via the `zizq-worker` executable that is part of the `zizq` RubyGem.
The worker supports multi-threaded and multi-fiber execution (N threads * M
fibers).

## The `zizq-worker` Executable

Start the worker by running `zizq-worker` on the command line. If your
dependencies are managed through Bundler you should start it through
`bundle exec`. Otherwise you can launch `zizq-worker` directly.

### Loading your application

`zizq-worker` needs to load your application code so that `Zizq.configure`
runs and your job classes become available. The path to that **entrypoint**
file is resolved in this order:

1. The `ENTRYPOINT` positional argument, if given:
   `zizq-worker path/to/boot.rb`.
2. The `ZIZQ_ENTRYPOINT` environment variable, if set.
3. `config/environment.rb` in the current directory, if it exists. This is
   the canonical Rails boot file, so **Rails apps run with no entrypoint
   argument at all** — just `bundle exec zizq-worker` from the app root.

For Sinatra and other non-Rails apps, point `zizq-worker` at whatever Ruby
file sets up your application (often `app.rb`):

> Command:
>
> ```bash
> $ bundle exec zizq-worker app.rb
> ```

### Configuration via `Zizq.configure`

Worker defaults (queues, threads, fibers, prefetch) live in
your application's `Zizq.configure` block — the same block that already
configures the client. CLI flags below override the configured defaults
on a per-run basis.

> Ruby:
>
> ``` ruby
> Zizq.configure do |c|
>   c.url = "https://zizq.your.network:7890"
>   c.worker.queues       = ["emails", "webhooks"]
>   c.worker.fiber_count  = 25
>   c.worker.prefetch     = 100
> end
> ```

Any field left unset falls through to `Zizq::Worker`'s hardcoded fallback
defaults — `thread_count: 1`, `fiber_count: 1`, `prefetch: 2 × threads × fibers`,
all queues.

### Running

For a Rails app with the above configuration:

> Shell:
>
> ```bash
> $ bundle exec zizq-worker
> I, [...] INFO -- : Zizq worker starting: 1 threads, 25 fibers, prefetch=100
> I, [...] INFO -- : Queues: emails, webhooks
> I, [...] INFO -- : Worker 0:0 started
> I, [...] INFO -- : Worker 0:1 started
> ...
> I, [...] INFO -- : Connecting to https://zizq.your.network:7890...
> I, [...] INFO -- : Connected. Listening for jobs.
> ```

If your application is not ready for multi-fiber execution, leave
`fiber_count` at `1` (the default). In this case the Zizq worker will
avoid loading any `Async` context to run your jobs.

### Listening to Specific Queues

Some deployments run different worker processes processing different queues.
The recommended way to set this is via `Zizq.configure { |c| c.worker.queues = [...] }`,
but you can also override it on a per-run basis with the `--queue` flag.
The flag accepts a comma-separated list, or can be repeated:

> Shell:
>
> ```bash
> $ bundle exec zizq-worker --queue foo,bar --queue zip
> I, [...] INFO -- : Zizq worker starting: 1 threads, 1 fibers, prefetch=2
> I, [...] INFO -- : Queues: foo, bar, zip
> ...
> ```

To force the worker to process **all** queues — overriding any configured
`c.worker.queues` for one run — use `--all-queues` (mutually exclusive with
`--queue`):

> Shell:
>
> ```bash
> $ bundle exec zizq-worker --all-queues
> I, [...] INFO -- : Queues: (all)
> ```

If neither flag is given, the worker uses whatever is configured (or all
queues if nothing is configured).

### Shutting Down `zizq-worker`

The usual signals, `INT` (`ctrl-c`) and `TERM` can be sent to the worker to
cleanly terminate. Zizq gives any in-flight jobs a grace period to complete
before eventually exiting forcefully. You can specify `--shutdown-timeout` to
define how many seconds Zizq gives in-flight jobs to finish. The default is
`30` seconds.

> Shell:
>
> ```bash
> I, [2026-03-25T17:50:51.481076 #1390456]  INFO -- : Shutting down. Waiting up to 30.00s for workers to finish...
> I, [2026-03-25T17:50:51.481154 #1390456]  INFO -- : Worker 0:0 stopped
> I, [2026-03-25T17:50:51.481200 #1390456]  INFO -- : Worker 1:0 stopped
> I, [2026-03-25T17:51:05.293738 #1390456]  INFO -- : Zizq producer thread stopped
> I, [2026-03-25T17:51:05.294013 #1390456]  INFO -- : Zizq worker stopped
> ```

If a second `INT` or `TERM` signal is sent to the worker process while waiting
for a clean shutdown, the worker will immediately exit with exit code `1`.

In the case of an unclean shutdown, any in-flight jobs are automatically
returned to the queue by the Zizq server and another worker will naturally
receive those jobs. There is no risk of job loss in the case of an unclean
shutdown.

## Using `Zizq::Worker` in Code

If you want more control (for example to run the worker in a single process
alongside a Rack application), you can easily use `Zizq::Worker` directly in
your application code. This is exactly what the `zizq-worker` executable does
under the hood.

Options are passed the the `Zizq::Worker` initializer, and the worker's `#run`
method is called, which blocks until the worker terminates. The worker can be
terminated by sending `Zizq::Worker#stop` (graceful shutdown), or
`Zizq::Worker#kill` (hard, unclean forced shutdown).

### Available Options

`Zizq::Worker.new` resolves each setting as
`kwarg || Zizq.configuration.worker.<field> || hardcoded_default`. All
kwargs are optional; pass them only when you want to override the
configured default for a specific instance.

* `thread_count:` - Number of worker threads. Fallback default `1`.
* `fiber_count:` - Number of fibers per worker thread. Fallback default `1`.
  Any value greater than `1` runs handlers inside an `Async` reactor.
* `queues:` - Array of queues to listen to. Empty array (the fallback
  default) means all queues.
* `prefetch:` - Number of jobs to dequeue at once. Fallback default
  `2 × thread_count × fiber_count`. Should not be lower than
  `thread_count × fiber_count`.
* `retry_min_wait:` / `retry_max_wait:` / `retry_multiplier:` -
  Reconnect backoff parameters. Fallback defaults `1`, `30`, `2`.
* `logger:` - Logger instance. Defaults to `Zizq.configuration.logger`.
* `dispatcher:` - Custom dispatcher implementation. Defaults to
  `Zizq.configuration.dequeue_middleware`.

The same fields are settable on `Zizq.configuration.worker` from inside a
`Zizq.configure` block, so an app can centralise its worker config there
and rely on `Zizq::Worker.new` (or `bundle exec zizq-worker`) without
arguments.

### Examples

Inheriting defaults from `Zizq.configure`:

> Ruby:
>
> ``` ruby
> require "zizq"
> 
> Zizq.configure do |c|
>   c.worker.queues       = ["emails", "payments"]
>   c.worker.fiber_count  = 10
> end
> 
> worker = Zizq::Worker.new   # picks up queues + fiber_count from config
> 
> Signal.trap("INT") { worker.stop }
> 
> worker.run
> ```

Passing kwargs directly (ignoring whatever's configured):

> Ruby:
>
> ``` ruby
> worker = Zizq::Worker.new(
>   thread_count: 5,
>   fiber_count:  10,
>   queues:       ["emails", "payments"],
> )
> ```

The above will block the main thread until a `SIGINT` is received to terminate
the worker. If you need to run other code while the worker runs, put the worker
into a background thread.

> Ruby:
>
> ``` ruby
> require "zizq"
> 
> worker = Zizq::Worker.new(queues: ["emails", "payments"])
> 
> Signal.trap("INT") { worker.stop }
> 
> worker_thread = Thread.new { worker.run }
> 
> # ... Other code in your application ...
> 
> # Block until shutdown.
> worker_thread.join
> ```

By default `Zizq::Worker#stop` will wait for in-flight jobs to wrap up, with
unbounded time. If you could have jobs that run for a long time and need to
force the worker to terminate early, use `Zizq::Worker#kill` (or if you can
safely do so, just `exit(status)`.

> Ruby:
>
> ``` ruby
> require "zizq"
> 
> worker = Zizq::Worker.new(queues: ["emails", "payments"])
> 
> worker_thread = Thread.new { worker.run }
> 
> Signal.trap("INT") do
>   worker.stop
>   Thread.new do
>     Timeout::timeout(60) do
>       worker_thread.join
>     end
>   rescue Timeout::Error
>     worker.kill # or exit(1)
>   end
> end
> 
> # ... Other code in your application ...
> 
> worker_thread.join
> ```

For cross-languae/low-level worker usage, you can provide a `dispatcher`
implementation directly to the worker.

> Ruby:
>
> ``` ruby
> require "zizq"
> 
> worker = Zizq::Worker.new(
>   queues: ["generic"],
>   dispatcher: ->(job) do
>     case job.type
>     when "send_email"
>       # ...
>     when "..."
>       # ...
>     end
>   end
> )
> 
> worker.run
> ```

The `Zizq::Worker` automatically handles acknowledgment and failure for you.
