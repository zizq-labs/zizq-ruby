# Using Middleware

Zizq supports injecting middleware that runs during job enqueue, and during job
dequeue. These are two separate middleware chains and can be managed through
`Zizq.configure { ... }`.

Middleware can be used to do a range of things, such as additional logging,
error handling, transformation or metrics/instrumentation.

## Enqueue Middleware

Enqueue middleware runs for each job enqueued with `Zizq.enqueue`,
`Zizq.enqueue_raw` or `Zizq.enqueue_bulk`. Each middleware in the chain
receives the `Zizq::EnqueueRequest` instance, which it may modify, and then
calls the next link in the chain. The required signature is `#call(req, chain)`
where `req` is the `Zizq::EnqueueRequest`, and `chain` implements `#call(req)`
to continue the middleware chain.

To register an enqueue middleware, call `enqueue_middleware.use` within
`Zizq.configure { ... }`.

``` ruby
Zizq.configure do |c|
  c.enqueue_middleware.use(EnqueueMetricsMiddleware.new)
  c.enqueue_middleware.use(EnqueueLoggingMiddleware.new)
end
```

Middlewares are invoked in the order last-to-first, so in the above the
`EnqueueLoggingMiddleware` is called and then the `EnqueueMetricsMiddleware` is
called.

### Custom Enqueue Middleware

To write your own custom middleware, define anything that implements `#call`
with the two arguments `req` and `chain`.

``` ruby
class EnqueueMetricsMiddleware
  def call(req, chain)
    MetricsService.increment(
      metric: 'job_enqueued',
      tags: { type: req.type, queue: req.queue }
    )
    chain.call(req)
  end
end
```

## Dequeue Middleware

> [!TIP]
> See [Custom Dispatchers](./dispatchers.md) for details on writing a custom
> dispatcher.

When the Zizq worker dequeues a job from the server and performs that job, it
does so by invoking a _dispatcher_. Before the job reaches the dispatcher it is
passed through a dequeue middleware chain. Each middleware in the chain
receives the `Zizq::Resources::Job` instance, which it may modify, and then
calls the next link in the chain. The required signature is `#call(job, chain)`
where `job` is the `Zizq::Resources::Job`, and `chain` implements `#call(job)`
to continue the middleware chain.

To register a dequeue middleware, call `dequeue_middleware.use` within
`Zizq.configure { ... }`.

``` ruby
Zizq.configure do |c|
  c.dequeue_middleware.use(TimingMetricsMiddleware.new)
  c.dequeue_middleware.use(InternalRetryMiddleware.new)
end
```

Middlewares are invoked in the order last-to-first, so in the above the
`InternalRetryMiddleware` is called and then the `TimingMetricsMiddleware` is
called.

### Custom Dequeue Middleware

To write your own custom middleware, define anything that implements `#call`
with the two arguments `job` and `chain`.

``` ruby
class TimingMetricsMiddleware
  def call(job, chain)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      chain.call(job)
    ensure
      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      MetricsService.timing(
        metric: 'job',
        duration: finished_at - started_at,
        tags: { type: req.type, queue: req.queue }
      )
    end
  end
end
```
