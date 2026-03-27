# Custom Dispatchers

When the Zizq worker fetches jobs from the server and executes them within your
application, it does so by invoking a _dispatcher_ for each job.

A dispatcher is any object that implements `#call(job)`, where `job` is an
instance of `Zizq::Resources::Job` and carries all the information about the
`queue`, `type`, `payload`, `piority`, `backoff`, etc.

## Configuring the Dispatcher

Which dispatcher is used by the Zizq worker is determined by the configuration
provided by `Zizq.configure { ... }`.

Specify the `dispatcher` to change the default:

``` ruby
Zizq.configure do |c|
  c.dispatcher = MyDispatcher.new
end
```

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

``` ruby
class MyDispatcher
  def call(job)
    case job.type
    when 'send_email'
      command = SendEmailCommand.new(
        job.payload.fetch('user_id'),
        job.payload.fetch('template'),
      )
      command.run
    when 'generate_report'
      command = GenerateReportCommand.new(job.payload.fetch('month'))
      command.run
    else
      # raise "Unknown Job type: #{job.type}"
    end
  end
end
```

Configure Zizq to use this dispatcher.

``` ruby
Zizq.configure do |c|
  c.dispatcher = MyDispatcher.new
end
```

When the Zizq worker dequeues a job and needs your application to perform that
job, it invokes the dispatcher's `#call` method with the job. Provided the
dispatcher does not raise any errors, Zizq will acknowledge the job by marking
it as successful and that job will not be dequeued by the server again

If the dispatcher raises any errors, Zizq automatically notifies the server of
that error and the server either kills the job, or schedules it for retry with
a backoff, depending on the backoff policy.

## Conditionally Using `Zizq::Job`

Say, for example, your application manages most jobs via `Zizq::Job`, but has
one particular job type, or one particular queue that receives jobs using some
other structure. You may write a custom dispatcher that delegates to
`Zizq::Job` conditionally.

``` ruby
class MyDispatcher
  def call(job)
    case job.type
    when 'generate_report'
      command = GenerateReportCommand.new(job.payload.fetch('month'))
      command.run
    else
      Zizq::Job.call(job) # Fall through to the default dispatcher
    end
  end
end
```

Dispatchers may be composed in many ways.
