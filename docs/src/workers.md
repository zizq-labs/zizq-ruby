# Running Workers

Your jobs are ultimately handled in a separate process which runs
`Zizq::Worker`. You can either run this manually within your Ruby application
code, or via the `zizq-worker` executable that is part of the `zizq` RubyGem.
The worker supports multi-threaded and multi-fiber execution (N threads * M
fibers).

## The `zizq-worker` Executable

Start the worker by running `zizq-worker` on the command line, and specifying
how many threads and fibers to use. If your application is not ready for
multi-fiber support, leave `--fibers` set to `1`. In this case the Zizq worker
will avoid loading any `Async` context. If your application is not thread safe,
leave `--fibers` also set to `1`.

The only required input to `zizq-worker` is your application's entrypoint file.
In a Rails application this is `config/environment.rb`. In a Sinatra app this
could be your `config.ru` file or your `app.rb`. It is needed in order to
setup your application and make sure your job classes are accessible to the
worker.

If your dependencies are managed through Bundler you should start `zizq-worker`
through `bundle exec`. Otherwise you can just launch `zizq-worker` directly.

``` shell
$ bundle exec zizq-worker --threads 5 --fibers 2 app.rb
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

All configuration will be taken from any `Zizq.configure { ... }` your
application performs during startup.

### Listening to Specific Queues

Some deployments may run different worker processes in different environments
each processing jobs from different queues. You can specify which queues each
worker process listens to by providing `--queue` to `zizq-worker`. This option
accepts a comma separated list of queues, or can be specified more than once to
listen to more the one queue. The default is to listen to all queues.

``` shell
$ zizq-worker --threads 2 --fibers 1 --queue foo,bar --queue zip app.rb
I, [2026-03-25T17:44:31.274274 #1390198]  INFO -- : Zizq worker starting: 2 threads, 1 fibers, prefetch=4
I, [2026-03-25T17:44:31.274360 #1390198]  INFO -- : Queues: foo, bar, zip
I, [2026-03-25T17:44:31.274890 #1390198]  INFO -- : Worker 0:0 started
I, [2026-03-25T17:44:31.274955 #1390198]  INFO -- : Worker 1:0 started
I, [2026-03-25T17:44:31.275058 #1390198]  INFO -- : Zizq producer thread started
I, [2026-03-25T17:44:31.275195 #1390198]  INFO -- : Connecting to http://localhost:7890...
I, [2026-03-25T17:44:31.352037 #1390198]  INFO -- : Connected. Listening for jobs.
```

### Shutting Down `zizq-worker`

The usual signals, `INT` (`ctrl-c`) and `TERM` can be sent to the worker to
cleanly terminate. Zizq gives any in-flight jobs a grace period to complete
before eventually exiting forcefully. You can specify `--shutdown-timeout` to
define how many seconds Zizq gives in-flight jobs to finish. The default is
`30` seconds.

``` shell
I, [2026-03-25T17:50:51.481076 #1390456]  INFO -- : Shutting down. Waiting up to 30.00s for workers to finish...
I, [2026-03-25T17:50:51.481154 #1390456]  INFO -- : Worker 0:0 stopped
I, [2026-03-25T17:50:51.481200 #1390456]  INFO -- : Worker 1:0 stopped
I, [2026-03-25T17:51:05.293738 #1390456]  INFO -- : Zizq producer thread stopped
I, [2026-03-25T17:51:05.294013 #1390456]  INFO -- : Zizq worker stopped
```

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

The following keyword arguments are available on `Zizq::Worker#initialize`:

* `thread_count:` - Number of worker threads. Default 5.
* `fiber_count:` - Number of fibers per worker thread. Default 1.
* `queues:` - Array of queues to listen to (empty array means all queues).
* `prefetch:` - Number of jobs to dequeue at once. Should not be lower than
  `thread_count * fiber_count`.
* `logger:` - Logger instance. Defaults to `Zizq.configuration.logger`.
* `dispatcher:` - Custom dispatcher implementation. Defaults to
  `Zizq.configuration.deqeueue_middleware`.

### Examples

Running a worker with 5 threads and 10 fibers per thread.

``` ruby
require "zizq"

worker = Zizq::Worker.new(
  thread_count: 5,
  fiber_count: 10,
  queues: ["emails", "payments"],
)

Signal.trap("INT") { worker.stop }

worker.run
```

The above will block the main thread until a `SIGINT` is received to terminate
the worker. If you need to run other code while the worker runs, put the worker
into a background thread.

``` ruby
require "zizq"

worker = Zizq::Worker.new(queues: ["emails", "payments"])

Signal.trap("INT") { worker.stop }

worker_thread = Thread.new { worker.run }

# ... Other code in your application ...

# Block until shutdown.
worker_thread.join
```

By default `Zizq::Worker#stop` will wait for in-flight jobs to wrap up, with
unbounded time. If you could have jobs that run for a long time and need to
force the worker to terminate early, use `Zizq::Worker#kill` (or if you can
safely do so, just `exit(status)`.

``` ruby
require "zizq"

worker = Zizq::Worker.new(queues: ["emails", "payments"])

worker_thread = Thread.new { worker.run }

Signal.trap("INT") do
  worker.stop
  Thread.new do
    Timeout::timeout(60) do
      worker_thread.join
    end
  rescue Timeout::Error
    worker.kill # or exit(1)
  end
end

# ... Other code in your application ...

worker_thread.join
```

For cross-languae/low-level worker usage, you can provide a `dispatcher`
implementation directly to the worker.

``` ruby
require "zizq"

worker = Zizq::Worker.new(
  queues: ["generic"],
  dispatcher: ->(job) do
    case job.type
    when "send_email"
      # ...
    when "..."
      # ...
    end
  end
)

worker.run
```

The `Zizq::Worker` automatically handles acknowledgment and failure for you.
