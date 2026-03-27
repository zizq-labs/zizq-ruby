# Job Classes

For most Ruby applications the preferred way to write jobs in Zizq will by
including the `Zizq::Job` module in your Ruby classes. This module adds
instance and class methods to the class, which enable dispatching work to
instances if that class.

## Using `Zizq::Job`

In Zizq, jobs have a number of required attributes, such as a named `queue`, a
job `type` and a `payload`. A number of optional attributes also exist.
`Zizq::Job` provides convenience methods to derive and set these attributes,
allowing you to think only in terms of these simple job classes when writing
code for your application.

### Defining a Job Class

Any named class can include `Zizq::Job`. This can be a top-level class, or a
class namespaced within a module hierarchy. Classes including `Zizq::Job`
*must* implement a `#perform` method; the arguments to which are arbitrary.

> [!CAUTION]
> You *cannot* make an anonymous class a `Zizq::Job`. The worker would have no
> way of finding it and instantiating it.

``` ruby
class MyApp::MyJob
  include Zizq::Job

  def perform(arg1, arg2)
    puts "Hello, #{arg1} and #{arg2}"
  end
end
```

We would enqueue an instance of this job by calling `Zizq.enqueue` with the
class and the job arguments.

``` ruby
Zizq.enqueue(MyApp::MyJob, "Bill", "Ben")
# #<Zizq::Resources::Job @data={"id"=>"03ftfjjuhc59aliu4wadzi06j", ... }>
```

This job isn't very interesting but it is a valid `Zizq::Job` implementation
and allows us to highlight some concepts.

> [!TIP]
> The examples in this documentation use positional arguments in the `#perform`
> method. This is perfectly valid but experience shows such methods are more
> difficult to evolve over time than those that use keyword arguments with
> optional defaults.

### Job Attributes

Zizq will derive the job type from the class name `"MyApp::MyJob"`.

Because the job class does not specify a queue explicitly, jobs of this type
will be placed onto the `default` queue.

``` ruby
MyApp::MyJob.zizq_queue
# "default"
```

There are a number of class methods added to the job class—all prefixed with
`zizq_`—which allow getting or setting the various attributes. These can all be
overridden at enqueue-time too.

#### Specifying the Queue

Use `zizq_queue` to set or get the `queue`. The default queue is `"default"`.

``` ruby
class MyApp::MyJob
  include Zizq::Job
  zizq_queue 'example'
end

MyApp::MyJob.zizq_queue
# "example"
```

#### Setting the Priority

Use `zizq_priority` to set or get the `priority` of the job. Valid values range
between `0` and `65536`. The default priority is not specified by the client,
but by the Zizq server (generally `32768`).

``` ruby
class MyApp::MyJob
  include Zizq::Job
  zizq_priority 500
end

MyApp::MyJob.zizq_priority
# 500
```

#### Setting the Backoff Policy

Use `zizq_retry_limit` to set the maximum number of retries before a job is
marked `"dead"`, and `zizq_backoff` to set the backoff formula parameters. The
defaults are managed by the server (generally the default `retry_limit` is 25
and the `backoff` parameters are `base: 10, exponent: 4, jitter: 30`).

Backoff parameters are in seconds. Floating point values are acceptable. All
three `backoff` arguments must be provided together.

The values are used in the following formula:

```
delay = base + (attempts ** exponent) + (rand(0.0..jitter) * attempts)
```

The randomness in the jitter component is designed to avoid situations where a
cascade of failures all retry at the same time. They naturally spread out.

``` ruby
class MyApp::MyJob
  include Zizq::Job
  zizq_retry_limit 50
  zizq_backoff base: 5, exponent: 2, jitter: 10
end

MyApp::MyJob.zizq_retry_limit
# 50

MyApp::MyJob.zizq_backoff
# {:exponent=>2.0, :base=>5.0, :jitter=>10.0}
```

#### Setting the Retention Policy

Use `zizq_retention` to set or get the number of seconds for which dead and
completed jobs are retained by the server before being reaped (hard deleted).
Values are in seconds and floating points are acceptable. Thd defaults are
managed by the server but are generally set at 7 days for dead jobs, and zero
for completed jobs, meaning only dead jobs are kept.

Both arguments are optional.

``` ruby
class MyApp::MyJob
  include Zizq::Job
  zizq_retention dead: 86_400 * 30, completed: 86_400 * 2
end

MyApp::MyJob.zizq_retention
# {:completed=>172800.0, :dead=>2592000.0}
```

#### Specifying Job Uniqueness

> [!TIP]
> This section of the documentation deals mostly with how to define unique jobs.
> See [Unique Jobs](./unique-jobs.md) for more detailed documentation on using
> this feature.

This requires a pro license on the server. Zizq is able to prevent duplicate
enqueues of the same job within a specified job lifecycle scope. Use
`zizq_unique` enable or disable uniqueness for a job.

The `scope:` argument specifies for which part of the job's lifecycle it is
considered unique. Options are:

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

The default scope is `:queued`. Zizq does not force you to select an arbitrary
expiry deadline for unique jobs. The implementation is _purely_ lifecycle
based.

``` ruby
class MyApp::MyJob
  include Zizq::Job
  zizq_unique true, scope: :active
end

MyApp::MyJob.zizq_unique
# true

MyApp::MyJob.zizq_unique_scope
# :active
```

##### Unique Keys

Identity is based on the generation of a `unique_key` for a job, which is
handled through the `zizq_unique_key` class method. This method takes the same
arguments as the `#perform` method and returns a string for the unique key.

The default implementation is a function of the job type and its arguments.

``` ruby
MyApp::MyJob.zizq_unique_key("Bill", "Ben", example: 42)
# "MyApp::MyJob:0b9ca7f07581994caa848878576fed30e09e7177611c01aeafe7113921090c29"

MyApp::MyJob.zizq_unique_key("Bill", "Ben", example: 42)
# "MyApp::MyJob:0b9ca7f07581994caa848878576fed30e09e7177611c01aeafe7113921090c29"

MyApp::MyJob.zizq_unique_key("Bill", "Ben", example: 99)
# "MyApp::MyJob:3be19cc482f366dcd538c22b8536d7947672071b8c8fb3a2486ebfd04b2216b6"
```

If, for example, you need uniqueness only on a subset of the arguments you may
override this method in your class:

``` ruby
class MyApp::MyJob
  include Zizq::Job
  zizq_unique true, scope: :active

  def self.zizq_unique_key(arg1, arg2, example:)
    super(arg1, arg2)
  end
end

MyApp::MyJob.zizq_unique_key("Bill", "Ben", example: 42)
# "MyApp::MyJob:bcd08012e829243d82e953a8140ffb58aeeb839e545ee1547a894bb2c9ba1b8f"
MyApp::MyJob.zizq_unique_key("Bill", "Ben", example: 99)
# "MyApp::MyJob:bcd08012e829243d82e953a8140ffb58aeeb839e545ee1547a894bb2c9ba1b8f"
```

### Dynamic Job Configuration { #dynamic-config }

When the client generates parameters to send to the Zizq server, it does this
by calling `zizq_enqueue_request(*args, **kwargs)` on your job class, passing
the job arguments. The return value is a `Zizq::EnqueueRequest` instance,
exactly the same as the one yielded to the caller in `Zizq.enqueue`.

If you need to do any kind of dynamic configuration in your job classes, such
as assigning a different priority based on time of day, or based on some of the
arguments, you can override this method.

``` ruby
class MyApp::MyJob
  include Zizq::Job

  zizq_priority 500

  def self.zizq_enqueue_request(arg1, arg2, example:)
    req = super
    req.priority -= 50 if arg1 == "Bill"
    req
  end
end
```

### Payload Serialization & Deserialization

When jobs are enqueued, Zizq produces the `payload` from the JSON serialized
representation of the job arguments. This means by default all
jobs arguments must be JSON serializable, though it is possible to write your
own argument serialization and deserialization implementation.

The default serialization implementation is done through the `zizq_serialize`
class method, which takes the same input arguments as the `#perform` method and
returns a JSON-serializable value encoding those arguments (i.e. a Hash).

``` ruby
MyApp::MyJob.zizq_serialize("Bill", "Ben", example: 42)
# {"args"=>["Bill", "Ben"], "kwargs"=>{"example"=>42}}
```

A corresponding `zizq_deserialize` exists. This method returns two values:
an `args` array for the positional arguments and a `kwargs` hash for any
keyword arguments.

``` ruby
args, kwargs = MyApp::MyJob.zizq_deserialize({"args"=>["Bill", "Ben"], "kwargs"=>{"example"=>42}})

args
# ["Bill", "Ben"]
kwargs
# {:example=>42}
```

Your classes may override these methods if you need custom serialization logic.

### Performing & Error Handling

The Zizq worker will instantiate your job class and call its `#perform` method
with the same arguments that were used to enqueue the job. There is no maximum
runtime imposed on jobs. They can run for as long as necessary. Provided the
`#perform` method returns successfully and no errors are raised, Zizq will
acknowledge (mark completed) this job. If any errors are raised from the
`#perform` method, Zizq will report that error to the Zizq server and either
backoff and retry, or kill the job, depending on the retry limit and the
backoff policy.

If you do not want errors to trigger retries, you have two options:

1. Allow the error and configure `zizq_retry_limit` to `0`.
2. Rescue the error inside the `#perform` method so the Zizq worker does not
   see it as a failure.

## Using `ActiveJob`

If your application is a Rails app, you can also use `ActiveJob` to manage your
jobs with the `:zizq` queue adapter. See
[Integration with ActiveJob](./active-job.md) for full documentation on this
feature.
