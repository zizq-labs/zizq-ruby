# Custom Dispatchers

When the Zizq worker fetches jobs from the server and executes them within your
application, it does so by invoking a _dispatcher_ for each job.

A dispatcher is any object that implements `#call(job)`, where `job` is an
instance of `Zizq::Resources::Job` and carries all the information about the
`queue`, `type`, `payload`, `priority`, `backoff`, etc.

> [!TIP]
> [`Zizq::Router`](#router) is a convenient way to compose a custom dispatcher.

## Configuring the Dispatcher

Which dispatcher is used by the Zizq worker is determined by the configuration
provided by `Zizq.configure { ... }`.

Specify the `dispatcher` to change the default:

> Ruby:
>
> ``` ruby
> Zizq.configure do |c|
>   c.dispatcher = MyDispatcher.new
> end
> ```

## Default Dispatcher

By default Zizq automatically dispatches jobs that include the `Zizq::Job`
module. It does this by using `Zizq::Job` (the module) as the default
dispatcher unless otherwise specified. `Zizq::Job.call(job)` reads finds the
constant for the class, validates and instantiates that class, deserializes the
arguments in the payload and calls `#perform` on that instance.

You can read the
[default implementation](https://github.com/zizq-labs/zizq-ruby/blob/main/lib/zizq/job.rb)
on Github. At the time of writing this was just 16 lines of code.

## Writing a Dispatcher

If you are working in a multi-stack environment where applications written in
one language (e.g. NodeJS) may enqueue jobs to be picked up in another language
(e.g. Ruby), you may need to write a custom dispatcher that does not use
`Zizq::Job`, translates jobs to instances of `Zizq::Job`.

A simple example using a `case..when` based on the `type` follows:

> Ruby:
>
> ``` ruby
> class MyDispatcher
>   def call(job)
>     case job.type
>     when 'send_email'
>       command = SendEmailCommand.new(
>         job.payload.fetch('user_id'),
>         job.payload.fetch('template'),
>       )
>       command.run
>     when 'generate_report'
>       command = GenerateReportCommand.new(job.payload.fetch('month'))
>       command.run
>     else
>       # raise "Unknown Job type: #{job.type}"
>     end
>   end
> end
> ```

Configure Zizq to use this dispatcher.

> Ruby:
>
> ``` ruby
> Zizq.configure do |c|
>   c.dispatcher = MyDispatcher.new
> end
> ```

When the Zizq worker dequeues a job and needs your application to perform that
job, it invokes the dispatcher's `#call` method with the job. Provided the
dispatcher does not raise any errors, Zizq will acknowledge the job by marking
it as successful and that job will not be dequeued by the server again

If the dispatcher raises any errors, Zizq automatically notifies the server of
that error and the server either kills the job, or schedules it for retry with
a backoff, depending on the backoff policy.

## Using `Zizq::Router` { #router }

For the common "dispatch by `type` string" pattern, Zizq ships a
`Zizq::Router` that lets you register handlers directly, without writing
the `case`/`when` plumbing. Designed for low-level or cross-language workflows:
payloads are plain JSON values, types are strings the producer agrees
on with the consumer, and routes are registered explicitly.

> Ruby:
>
> ``` ruby
> Zizq.configure do |c|
>   c.dispatcher = Zizq::Router.new do
>     route("send_email") do |payload|
>       SendEmailCommand.new(
>         payload.fetch("user_id"),
>         payload.fetch("template"),
>       ).run
>     end
> 
>     route("generate_report") do |payload|
>       GenerateReportCommand.new(payload.fetch("month")).run
>     end
> 
>     # Optional. When set, types with no registered route fall through
>     # to this handler instead of raising `Zizq::Router::UnknownJobType`.
>     fallback { |job| Zizq::Job.call(job) }
>   end
> end
> ```

Handler blocks are called as `handler.call(payload, job)`:

* `route("...") { |payload| ... }` — the common case; ignore the
  second arg.
* `route("...") { |payload, job| ... }` — when you need `job.attempts`,
  `job.queue`, etc.
* `route("...") { ... }` — neither (e.g. trigger-style jobs whose
  payload is not useful).

Routes defined through the constructor block are bound to the router instance
(`self` is an instance of `Zizq::Router`). Methods defined directly within
the block are accessible to each route:

> Ruby:
>
> ``` ruby
> router = Zizq::Router.new do
>   route("send_email") do |payload|
>     normalize(payload) => {user_id:, template:}
>     SendEmailCommand.new(user_id, template:).run
>   end
> 
>   def normalize(payload)
>     case payload
>     when Hash
>       payload.map { |k, v| [k.to_sym, normalize(v)] }.to_h
>     when Array
>       payload.map { |v| normalize(v) }
>     else
>       payload
>     end
>   end
> end
> ```

Routes can also be added outside the constructor block:

> Ruby:
>
> ``` ruby
> router = Zizq::Router.new
> router.route("send_email") { |payload| ... }
> ```

In this case `self` is intentionally not bound to the `Zizq::Router` instance
so you can compose a Router that uses methods accessible to the caller. If a
route defined outside the constructor needs access to the router instance, it
should refer to it directly:

> Ruby:
>
> ``` ruby
> router = Zizq::Router.new
> router.route("send_email") do |payload|
>   args = router.normalize(payload)
>   # ...
> end
> ```

When no route matches and no fallback is registered,
`Zizq::Router::UnknownJobType` is raised — caught by the worker's
normal error path, which nacks (fails) the job for retry (or kills it once
the retry limit is hit).

The `fallback` example above shows a useful composition pattern: most
of your jobs go through `Zizq::Job` as usual, with a handful of
explicit `route(...)` entries for cross-language types. The fallback
receives the full `Resources::Job` (not the `(payload, job)` pair that
routes get), so you can delegate to any other dispatcher cleanly.

## Conditionally Using `Zizq::Job`

Say, for example, your application manages most jobs via `Zizq::Job`, but has
one particular job type, or one particular queue that receives jobs using some
other structure. You may write a custom dispatcher that delegates to
`Zizq::Job` conditionally.

> Ruby:
>
> ``` ruby
> class MyDispatcher
>   def call(job)
>     return Zizq::Job.call(job) unless job.queue == 'special'
> 
>     case job.type
>     when 'generate_report'
>       command = GenerateReportCommand.new(job.payload.fetch('month'))
>       command.run
>     end
>   end
> end
> ```

Dispatchers may be composed in any number of creative ways.

## Direct Usage in `Zizq::Worker`

> [!NOTE]
> Passing `dispatcher` directly to `Zizq::Worker` ignores any configured
> dequeue middleware chain and directly executes the dispatcher.

If your application directly uses `Zizq::Worker` rather than the `zizq-worker`
executable, you may instead provide a dispatcher implementation directly to the
worker instance. Since a dispatcher is just any object that implements
`#call(job)`, this can easily be a proc or a lambda, which is handy for
ad-hoc worker instances.

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
