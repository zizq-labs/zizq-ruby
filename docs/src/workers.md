# Running Workers

Your jobs are ultimately handled in a separate process via the `zizq-worker`
executable that is part of the `zizq` RubyGem. The worker supports
multi-threaded and multi-fiber execution (N threads * M fibers).

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

## Listening to Specific Queues

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

## Shutting Down

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
