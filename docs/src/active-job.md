# Using Active Job

If your application is a Rails application, you may choose to use
[Active Job](https://guides.rubyonrails.org/active_job_basics.html) configured
to use Zizq as its backend.

> [!NOTE]
> If throughput performance is a concern for your application, you should be
> aware that Active Job does its own serialization and dispatching, and this is
> much slower than using Zizq directly. You should consider just using
> `Zizq::Job` directly instead.

## Configuring Rails to Use Zizq

Active Job requires the queue adapter be configured either in
`config/application.rb` or in `config/environments/{env}.rb`. Zizq provides the
`ActiveJob::QueueAdapters::ZizqAdapter` implementation needed to set this up.
You can just use `:zizq` as the name once you have required the adapter.

``` ruby
# Load the adapter.
require 'active_job/queue_adapters/zizq_adapter'

# Tell ActiveJob to use it.
config.active_job.queue_adapter = :zizq
```

You also need to configure Zizq itself to dispatch jobs to `ActiveJob`.

## Configuring Zizq to Use Active Job

Zizq uses a wrapperless adapter implementation, which means enqueued jobs use
the original job class name and are not wrapped in a higher level job class
that handles dispatching to Active Job internally. This is good for visibility
and for performance, but requires explicit configuration. Set the Zizq
dispatcher to `ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher`.

``` ruby
# Load the adapter.
require 'active_job/queue_adapters/zizq_adapter'

Zizq.configure do |c|
  # Tell Zizq to dispatch via ActiveJob
  c.dispatcher = ActiveJob::QueueAdapters::ZizqAdapter::Dispatcher
end
```

## Writing Job Classes

With Rails configured to use Zizq, you can now write your job classes in
Active Job.

``` ruby
class SendEmailJob < ApplicationJob
  def perform(user_id, template:)
    # ...
  end
end

# ActiveJob enqueues this job with Zizq.
SendEmailJob.perform_later(42, template: 'welcome')
```

The usual `queue_as` and `priority` options work out of the box.

``` ruby
class SendEmailJob < ApplicationJob
  queue_as 'emails'
  self.priority = 20

  def perform(user_id, template:)
    # ...
  end
end
```

Bulk enqueue works too.

``` ruby
ActiveJob.perform_all_later(
  emails.map do |user_id, template|
    SendEmailJob.new(user_id, template:)
  end
)
```

## Accessing Zizq-Specific Features

For access to Zizq-specific features such as retention policies and unique jobs
you need to extend `Zizq::ActiveJobConfig` onto your job classes. This adds the
necessary class methods such as `zizq_retention` and `zizq_unique` to the
class. You can do this specific job classes, or in your `ApplicationJob` base
class.

``` ruby
class ApplicationJob < ActiveJob::Base
  extend Zizq::ActiveJobConfig
end
```

``` ruby
class SendEmailJob < ApplicationJob
  zizq_unique true, scope: :active

  def perform(user_id, template:)
    # ...
  end
end
```
