# Unique Jobs

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server.

Zizq is able to prevent duplicate enqueues of the same logical job within a
specified job lifecycle scope. Jobs are marked unique either within the job
class or at enqueue-time, which assigns a `unique_key` attribute to the job.

If that job is successfully enqueued and the same client or another client
attempts to enqueue a job with the same `unique_key`, the subsequent enqueue is
automatically de-duplicated by the server.

## Configuring Unique Jobs

> [!NOTE]
> If you are using `ActiveJob` you will need to extend `Zizq::ActiveJobConfig`
> onto your job class to access this feature.

Uniqueness for a job is enabled or disabled by calling `zizq_unique` within the
class.

``` ruby
class SendEmailJob
  include Zizq::Job

  zizq_unique true

  def perform(user_id, template:)
    # ...
  end
end
```

Calling `zizq_unique false` explicitly disables uniqueness for that job.

If we take a look at what `zizq_enqueue_request` generates for this job, we'll
see there is a `unique_key` present.

``` ruby
SendEmailJob.zizq_enqueue_request(42, template: 'welcome')
# #<Zizq::EnqueueRequest:0x00007fff3567bce0
#  @backoff=nil,
#  @delay=nil,
#  @payload={"args"=>[42], "kwargs"=>{"template"=>"welcome"}},
#  @priority=nil,
#  @queue="default",
#  @ready_at=nil,
#  @retention=nil,
#  @retry_limit=nil,
#  @type="SendEmailJob",
#  @unique_key="SendEmailJob:eb28cc4280934762bacd3f603600949c984ff96efe48831313e2e94f7f64ada1",
#  @unique_while=nil>
```

Because we didn't specify a scope for the uniqueness of this job, it will be
unique for the server's default scope, which is while `:queued`. We can specify
a different scope within the job.

``` ruby
class SendEmailJob
  include Zizq::Job

  zizq_unique true, scope: :exists

  def perform(user_id, template:)
    # ...
  end
end

SendEmailJob.zizq_enqueue_request(42, template: 'welcome')
# #<Zizq::EnqueueRequest:0x00007fff3e118fd8
#  @backoff=nil,
#  @delay=nil,
#  @payload={"args"=>[42], "kwargs"=>{"template"=>"welcome"}},
#  @priority=nil,
#  @queue="default",
#  @ready_at=nil,
#  @retention=nil,
#  @retry_limit=nil,
#  @type="SendEmailJob",
#  @unique_key="SendEmailJob:eb28cc4280934762bacd3f603600949c984ff96efe48831313e2e94f7f64ada1",
#  @unique_while=:exists>
```

The scope defines which statuses the job can be in while Zizq validates
uniqueness of that job on the server. If any attempt is made to enqueue a job
with the same `unique_key` while the job is in any of the statuses defined by
this scope, Zizq returns the existing job instead enqueueing a new job.

If two jobs are enqueued concurrently with the same `unique_key`, one of those
jobs will be automatically de-duplicated by the server. This is a race-free
operation.

## Uniqueness Scopes

Valid scope options are: `:queued` (default), `:active` and `:exists` and behave as
described below.

<table>
    <thead>
        <tr>
            <th>Scope</th>
            <th>Description</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td><code>:queued</code></td>
            <td>
                Prevent duplicate enqueues while this job is still in the
                <code>"scheduled"</code> or <code>"ready"</code> statuses (i.e.
                until a worker takes the job)
            </td>
        </tr>
        <tr>
            <td><code>:active</code></td>
            <td>
                Prevent duplicate enqueues while this job is still in the
                <code>"scheduled"</code>, <code>"ready"</code> or
                <code>"in_flight"</code> statuses (i.e. until this job
                successfully completes)
            </td>
        </tr>
        <tr>
            <td><code>:exists</code></td>
            <td>
                Prevent duplicate enqueues for as long as the Zizq server still
                has a record of this job (according to its retention policy)
            </td>
        </tr>
    </tbody>
</table>

The default scope when not otherwise specified is `:queued`. This means as soon
as a worker picks up that job and its status moves to `"in_flight"`, Zizq will
accept new job enqueues with the same `unique_key`, even if the job being
processed by the worker eventually fails and moves back to the queue for a
retry.

If a job is successfully enqueued with a `unique_key` in scope `:queued` and a
subsequent enqueue is attempted with the same `unique_key` and a broader scope,
such as `:active`, the second job does not replace the first. Whichever was
enqueued first is retained.

If a job is successfully enqueued with a `unique_key` in scope `:queued` and
that job is now leaves the scope for which it is unique, a new can cab be
enqueued with the same `unique_key` even if that job has a broader scope, such
as `:active`.

To make this expicit, uniquess refers to the behaviour applied to
_subsequent enqueues_ with the same key once this job is successfully enqueued.

## Unique Keys

As mentioned, uniquess is determined by a `unique_key` and a scope. By default
Zizq will generate a unique key using all job arguments within the given job
class. Two jobs with the same arguments but different classes have different
`unique_key` values. Two jobs with the same arguments and the same class have
the same `unique_key` values. This is fully customizable.

While the client generates unique keys specific to each job class, Zizq treats
uniquess as _logical_ rather than _concrete_. Your application could, for
example treat push notification jobs and email jobs as the same and give them
the same `unique_key` values.

### Overriding the `unique_key`

Zizq generates the `unique_key` value by calling
`zizq_unique_key(*args, **kwargs)` on your job class, passing in the same
arguments as those used to enqueue the job. The default implementation of this
method uses a normalized serialization approach before digesting the result
with a SHA256 hash.

You can easily see how this works and can easily write unit tests.

``` ruby
ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)
# "ExampleJob:0b9ca7f07581994caa848878576fed30e09e7177611c01aeafe7113921090c29"

ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)
# "ExampleJob:0b9ca7f07581994caa848878576fed30e09e7177611c01aeafe7113921090c29"

ExampleJob.zizq_unique_key("Bill", "Ben", example: 99)
# "ExampleJob:3be19cc482f366dcd538c22b8536d7947672071b8c8fb3a2486ebfd04b2216b6"
```

You can override this method in your job classes to either fully implement your
own unique key generation, or to _tweak_ the default implementation, for
example to enforce uniqueness only across a subset of keys, or within a
bucketed time window.

### Examples

This example uses the default implementation, but applied only to a subset of
the job arguments:

``` ruby
class ExampleJob
  include Zizq::Job
  zizq_unique true

  def self.zizq_unique_key(arg1, arg2, example:)
    super(arg1, arg2)
  end
end

ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)
# "ExampleJob:bcd08012e829243d82e953a8140ffb58aeeb839e545ee1547a894bb2c9ba1b8f"
ExampleJob.zizq_unique_key("Bill", "Ben", example: 99)
# "ExampleJob:bcd08012e829243d82e953a8140ffb58aeeb839e545ee1547a894bb2c9ba1b8f"
```

This example generates unique keys that fall into hourly time slots:

``` ruby
class ExampleJob
  include Zizq::Job
  zizq_unique true

  def self.zizq_unique_key(*args, **kwargs)
    super(*args, **kwargs, bucket: Time.now.to_i / 3600 * 3600)
  end
end

# At 1:30pm
ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)
# "ExampleJob:8176971c4bde8df43f3ffd9c61e3fd73b162d0595b2ae0fe62d36bc583a398b"

# At 1:59pm
ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)
# "ExampleJob:8176971c4bde8df43f3ffd9c61e3fd73b162d0595b2ae0fe62d36bc583a398b"

# At 2:00pm
# "ExampleJob:89d8cf87a568c0dd8706c6642e85d1cbc0e0c99b3e784499edb42c75a177799f"
ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)

# At 2:05pm
# "ExampleJob:89d8cf87a568c0dd8706c6642e85d1cbc0e0c99b3e784499edb42c75a177799f"
ExampleJob.zizq_unique_key("Bill", "Ben", example: 42)
```

## Enqueueing Unique Jobs

A job with uniqueness is enqueued just like any other job: using `Zizq.enqueue`.
Where a unique scope violation was encountered a `Zizq::Resources::Job` is
returned as normal, but it will have the same `id` as the existing job and the
`duplicate?` predicate will be set to `true`.

``` ruby
result = Zizq.enqueue(SendEmailJob, 42, template: 'welcome')
result.id # "03fu0wm75gxgmfyfplwvazhex"
result.duplicate? # false

result = Zizq.enqueue(SendEmailJob, 42, template: 'welcome')
result.id # "03fu0wm75gxgmfyfplwvazhex"
result.duplicate? # true
```

The same is true for [bulk enqueue](./enqueueing-jobs.md#bulk-job-enqueueing)
requests too.

This means your application generally does not need to treat duplicate enqueues
as errors and can instead handle them idempotently.
