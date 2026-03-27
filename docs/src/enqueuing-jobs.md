# Enqueuing Jobs

Jobs that use `Zizq::Job` are enqueued via `Zizq.enqueue` which builds the
necessary inputs to send to the Zizq server. Jobs that do not use `Zizq::Job`
can be enqueued via `Zizq.enqueue_raw`, which is a much more bare bones method
intended for advanced use cases, such as cross-language jobs where e.g. a Ruby
application enqueues a job that is ultimately processed by a Go application.

## Using `Zizq::Job`

The `Zizq::Job` module takes a lot of the work out of building the correct
enqueue inputs for Zizq. You provide the job class and some arguments to be
passed to the `#perfom` method and Zizq reads all the inputs from the job.

> [!NOTE]
> See [Job Classes](./job-classes.md) for more details on defining jobs.

Your application calls the `Zizq.enqueue` method.

``` ruby
result = Zizq.enqueue(SendEmailJob, user.id, template: "welcome")
result.id # "03fu0wm75gxgmfyfplwvazhex"
```

The job is immediately pushed to the Zizq server for your workers to process
and the `Zizq::Resources::Job` instance is returned.

Any configuration on the job, such as the queue name, priority, backoff policy
etc are included in the enqueue request.

When the worker runs this job, it will execute something like:

``` ruby
job = SendEmailJob.new
job.perform(42, template: "welcome")
```

### Configuration Overrides

All options that can be configured on the job can also be overridden at
enqueue-time by providing a block to `Zizq.enqueue`. The block receives the
default `Zizq::EnqueueRequest` object based on the job class, and the caller
can modify it as needed (e.g. to specify a higher priority).

> [!TIP]
> Job classes can also do dynamic configuration, such as dynamic prioritisation
> based on their arguments. See
> [Dynamic Job Configuration](./job-classes.md#dynamic-config) for more info.

``` ruby
# Override the priority on this job.
Zizq.enqueue(SendEmailJob, user.id, template: "welcome") do |req|
  req.priority = 100
end

# Disable retries on this job.
Zizq.enqueue(SendEmailJob, user.id, template: "welcome") do |req|
  req.retry_limit = 0
end
```

### Scheduling Jobs

Jobs can be enqueued to run at a future date or time. This is done by setting
either the `ready_at` timestamp (seconds since the Unix epoch), or a `delay`
(seconds).

``` ruby
# Schedule the job to run in 1 hour.
Zizq.enqueue(SendEmailJob, user.id, template: "welcome") do |req|
  req.delay = 3600
end
```

``` ruby
# Schedule the job to run at a specific time.
Zizq.enqueue(SendEmailJob, user.id, template: "welcome") do |req|
  req.ready_at = Time.new(2027, 3, 15, 14, 30).to_f
end
```

## Raw Job Enqueueing

For more advanced use cases, for example in an environment where services in
multiple different programming languages interact with one another, jobs can
be enqueued more directly by using `Zizq.enqueue_raw`. In this case, the
`queue`, `type`, `payload` and other options must be provided by the caller.

``` ruby
Zizq.enqueue_raw(
  queue: "emails",
  type: "send_email",
  payload: {user_id: 42, template: "welcome"},
  priority: 500,
  ready_at: Time.now.to_f + 3600,
)
```

This method should generally not be used for cases where you are enqueueing a
job for consumption by the same Ruby application. If you really do need to do
this, like you likely need to also write a [Custom Dispatcher](./dispatchers.md).

## Bulk Job Enqueueing

If your application needs to enqueue many jobs as part of a single operation,
throughput can be significantly increased by enqueueing those jobs together in
a single request. Zizq supports this and it works across queues and across job
types. You can mix raw enqueues with regular `Zizq::Job` enqueues too.

This is an atomic operation. All jobs are either enqueued successfully, or none
at all. Jobs will not be visible to workers until the operation returns
successfully.

There is no upper limit on the number of jobs enqueued in a single request,
though you should most likely experiment to find a reasonable request size for
your use case. Anything less than around 5,000 jobs in one request should be
trivial.

Use `Zizq.enqueue_bulk`, which yields a `BulkEnqueue` object that implements
same `enqueue` and `enqueue_raw` signatures as `Zizq` itself.

``` ruby
Zizq.enqueue_bulk do |b|
  emails.each do |user_id, template|
    b.enqueue(SendEmailJob, user_id, template:)
  end

  b.enqueue_raw(
    queue: "metrics",
    type: "increment_metric",
    payload: {key: "emails_enqueued", value: emails.size},
  )
end
```
