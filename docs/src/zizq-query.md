# Querying & Managing Jobs

Zizq makes _vivibility_ and _control_ key design focuses. The server provides
a number of endpoints for querying and managing job data, which are all
packaged up in `Zizq::Query` in the Ruby client.

Queries are initiated with `Zizq.query` and built by chaining methods onto that
query. All queries are lazy (they don't execute until enumerated), and each
builder method returns a _new instance_ of the query, so intermediate queries
can be passed around without worrying about mutability.

## `Zizq::Query`

Methods starting with `by_` _replace_ the current condition, while methods
starting with `add_` append to the condition. These methods also all accept
arrays which form `IN (...)` style conditions.

* [`#by_id`](#zizqquery-by_id)
* [`#add_id`](#zizqquery-by_id)
* [`#by_queue`](#zizqquery-by_queue)
* [`#add_queue`](#zizqquery-by_queue)
* [`#by_type`](#zizqquery-by_type)
* [`#add_type`](#zizqquery-by_type)
* [`#by_status`](#zizqquery-by_status)
* [`#add_status`](#zizqquery-by_status)

These methods only accept strings and combine to narrow down the current
filter (using the `and` operator):

* [`#by_jq_filter`](#zizqquery-by_jq_filter)
* [`#add_jq_filter`](#zizqquery-by_jq_filter)

These methods wrap `#by_type` and `#add_jq_filter` to find jobs enqueued using
`Zizq::Job` or Active Job classes extending `Zizq::ActiveJobConfig`:

* [`#by_job_class_and_args`](#zizqquery-by_job_class_and_args)
* [`#by_job_class_and_args_subset`](#zizqquery-by_job_class_and_args)

These methods have special meaning (see docs):

* [`#order`](#zizqquery-order)
* [`#limit`](#zizqquery-limit)
* [`#in_pages_of`](#zizqquery-in_pages_of)

These methods enumerate the results of the query:

* [`#each`](#zizqquery-each)
* [`#each_page`](#zizqquery-each_page)

These methods apply a delete or update to the entire scope of the query.

* [`#delete_all`](#zizqquery-delete_all)
* [`#update_all`](#zizqquery-update_all)

These methods apply a delete or update to the first result of the query (if
any):

* [`#delete_one`](#zizqquery-delete_one)
* [`#update_one`](#zizqquery-update_one)

Additionally, and importantly, `Zizq::Query` is also `Enumerable` so methods
like `#count`, `#reverse_each`, `#take` etc do exactly what you would expect.

### `#by_id`, `#add_id` { #zizqquery-by_id }

Narrows the query down to a given `id` or set of `id`s.

``` ruby
Zizq.query.by_id("03fvmay0zcoskwdf2sm0u94aw").each do |job|
  puts "#{job.id}: #{job.payload.inspect}"
end
# 03fvmay0zcoskwdf2sm0u94aw: {"greet"=>"World"}


Zizq.query
  .by_id("03fvmay0zcoskwdf2sm0u94aw")
  .add_id("03fvqg68ra0od9u1b8m0txgka").each do |job|
    puts "#{job.id}: #{job.payload.inspect}"
  end
# 03fvmay0zcoskwdf2sm0u94aw: {"greet"=>"World"}
# 03fvqg68ra0od9u1b8m0txgka: {"greet"=>"Moon"}

Zizq.query
  .by_id("03fvmay0zcoskwdf2sm0u94aw")
  .add_id("03fvqg68ra0od9u1b8m0txgka")
  .count
# 2
```

### `#by_queue`, `#add_queue` { #zizqquery-by_queue }

Narrows the query down to a given `queue` or set of `queue`s.

``` ruby
Zizq.query.by_queue("analytics").count
# 90

Zizq.query.by_queue(["analytics", "example"]).count
# 93

Zizq.query.by_queue(["analytics", "example"]).add_queue("comms").count
# 3631
```

### `#by_type`, `#add_type` { #zizqquery-by_type }

Narrows the query down to a given `type` or set of `type`s. By default these
are job class names but if you are using cross-language features the types can
be arbitrary.

``` ruby
Zizq.query.by_queue("default").by_type("ProcessVideoJob").count
# 401

Zizq.query
  .by_queue("default")
  .by_type("ProcessVideoJob")
  .add_type("ClearNotesJob")
  .count
# 491
```

### `#by_status`, `#add_status` { #zizqquery-by_status }

Narrows the query down to a given `status` or set of `status`es.

Valid statuses are:

* `scheduled`
* `ready`
* `in_flight`
* `completed`
* `dead`

``` ruby
Zizq.query.by_status(["scheduled", "ready"]).count
# 5003

Zizq.query.by_status("ready").count
# 4993

Zizq.query.by_queue("default").by_status("ready").add_status("scheduled").count
# 491
```

### `#by_jq_filter`, `#add_jq_filter` { #zizqquery-by_jq_filter }

Narrows the query down by matching on the `payload`. Since payloads are
arbitrary and known only to your application, filtering is done by using `jq`
expressions.

> [!TIP]
> For more details on the `jq` query language, read the language specification
> on the [jaq website](https://gedenkt.at/jaq/manual/#corelang) or on
> [jq](https://jqlang.org/manual/#basic-filters).

``` ruby
Zizq.query.by_type("hello_world").by_jq_filter('.greet == "Moon"').each do |job|
  puts "#{job.id}: #{job.payload}"
end
# 03fvqg68ra0od9u1b8m0txgka: {"greet"=>"Moon"}

Zizq.query.by_type("hello_world").by_jq_filter('.greet | contains("o")').each do |job|
  puts "#{job.id}: #{job.payload}"
end
# 03fvmay0zcoskwdf2sm0u94aw: {"greet"=>"World"}
# 03fvqg68ra0od9u1b8m0txgka: {"greet"=>"Moon"}

Zizq.query.by_type("TestJob").by_jq_filter('.args[0] <= 15').each do |job|
  puts "#{job.id}: #{job.payload}"
end
# 03fvqm2ejnbjahvhayikrkltr: {"args"=>[1, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhayk0y3i9k: {"args"=>[2, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaykq7d4fh: {"args"=>[3, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaynwu2ije: {"args"=>[4, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaypw8nkng: {"args"=>[5, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhayr7ytglw: {"args"=>[6, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaysw8ggq1: {"args"=>[7, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhayvtolt8p: {"args"=>[8, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhayx9j2rmx: {"args"=>[9, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhayzkj79ca: {"args"=>[10, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaz26z9dgz: {"args"=>[11, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaz2yke1ga: {"args"=>[12, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaz5308g6x: {"args"=>[13, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaz6c9pt9z: {"args"=>[14, 5000], "kwargs"=>{}}
# 03fvqm2ejnbjahvhaz93heeqc: {"args"=>[15, 5000], "kwargs"=>{}}
```

### `#by_job_class_and_args`, `#by_job_class_and_args_subset` { #zizqquery-by_job_class_and_args }

These methods are specific to `Zizq::Job` classes and Active Job classes that
extend `Zizq::ActiveJobConfig`. They match jobs on the queue by wrapping
`#by_type` and `#add_jq_filter` internally. You can match either using exact
argument matches, or on just a subset of the arguments (N positional arguments
and partial keyword argument match).

``` ruby
Zizq.query.by_job_class_and_args(TestJob, 223, 5000).each do |job|
  puts "#{job.id}: #{job.payload}"
end
# 03fvqm2ejnbjahvhbao96krod: {"args"=>[223, 5000], "kwargs"=>{}}

Zizq.query.by_job_class_and_args(TestJob, 223).each do |job|
  puts "#{job.id}: #{job.payload}"
end
# (no output)

Zizq.query.by_job_class_and_args_subset(TestJob, 223).each do |job|
  puts "#{job.id}: #{job.payload}"
end
# 03fvqm2ejnbjahvhbao96krod: {"args"=>[223, 5000], "kwargs"=>{}}
```

### `#order` { #zizqquery-order }

Changes the sort order in which results are returned. Use Symbols  `:asc` or
`:desc`. The default is `:asc`.

``` ruby
Zizq.query.by_status("scheduled").each do |job|
  puts "#{job.id}"
end
# 03fvmay0zcoskwdf2sm0u94aw
# 03fvqg4qxj39zecl43gnwwh04
# 03fvqg68ra0od9u1b8m0txgka
# 03fvqhdcqsftfxrzb6xc8acjy
# 03fvqhdcqsftfxrzb6zq57rqs
# 03fvqhdcqsftfxrzb71cxvk13
# 03fvqhdcqsftfxrzb74afpg6x
# 03fvqhdcqsftfxrzb75rabbrt
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb7a5g3hpm

Zizq.query.by_status("scheduled").order(:desc).each do |job|
  puts "#{job.id}"
end
# 03fvqhdcqsftfxrzb7a5g3hpm
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb75rabbrt
# 03fvqhdcqsftfxrzb74afpg6x
# 03fvqhdcqsftfxrzb71cxvk13
# 03fvqhdcqsftfxrzb6zq57rqs
# 03fvqhdcqsftfxrzb6xc8acjy
# 03fvqg68ra0od9u1b8m0txgka
# 03fvqg4qxj39zecl43gnwwh04
# 03fvmay0zcoskwdf2sm0u94aw
```

### `#limit` { #zizqquery-limit }

Changes the maximum number of total results returned by the query.

``` ruby
Zizq.query.by_status("scheduled").order(:desc).limit(3).each do |job|
  puts "#{job.id}"
end
# 03fvqhdcqsftfxrzb7a5g3hpm
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb75rabbrt
```

### `#in_pages_of` { #zizqquery-in_pages_of }

Changes the number of results fetched in a single page as the client enumerates
jobs. When not specified, the server's default page size applies.

This also affects how `#update_all` and `#delete_all` are applied. Without
specifying `#in_pages_of`, these operations apply to the entire result set in a
single transaction. When `#in_pages_of` is specified, the bulk delete or update
is done in a batched manner.

``` ruby
Zizq.query.by_status("scheduled").in_pages_of(2).each do |job|
  puts "#{job.id}"
end
# 03fvmay0zcoskwdf2sm0u94aw
# 03fvqg4qxj39zecl43gnwwh04
# 03fvqg68ra0od9u1b8m0txgka
# 03fvqhdcqsftfxrzb6xc8acjy
# 03fvqhdcqsftfxrzb6zq57rqs
# 03fvqhdcqsftfxrzb71cxvk13
# 03fvqhdcqsftfxrzb74afpg6x
# 03fvqhdcqsftfxrzb75rabbrt
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb7a5g3hpm

Zizq.query
  .by_status("scheduled")
  .in_pages_of(2)
  .each_page
  .with_index do |page, idx|
    puts "Page #{idx+1}"
    page.jobs.each { |job| puts "#{job.id}" }
  end
# Page 1
# 03fvmay0zcoskwdf2sm0u94aw
# 03fvqg4qxj39zecl43gnwwh04
# Page 2
# 03fvqg68ra0od9u1b8m0txgka
# 03fvqhdcqsftfxrzb6xc8acjy
# Page 3
# 03fvqhdcqsftfxrzb6zq57rqs
# 03fvqhdcqsftfxrzb71cxvk13
# Page 4
# 03fvqhdcqsftfxrzb74afpg6x
# 03fvqhdcqsftfxrzb75rabbrt
# Page 5
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb7a5g3hpm
```

### `#each` { #zizqquery-each }

Enumerates each `Zizq::Resources::Job` in the query result. Until this method,
or some other `Enumerable` method is called, the query is not yet executed.

``` ruby
Zizq.query.by_status("scheduled").each do |job|
  puts "#{job.id}"
end
# 03fvmay0zcoskwdf2sm0u94aw
# 03fvqg4qxj39zecl43gnwwh04
# 03fvqg68ra0od9u1b8m0txgka
# 03fvqhdcqsftfxrzb6xc8acjy
# 03fvqhdcqsftfxrzb6zq57rqs
# 03fvqhdcqsftfxrzb71cxvk13
# 03fvqhdcqsftfxrzb74afpg6x
# 03fvqhdcqsftfxrzb75rabbrt
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb7a5g3hpm
```

### `#each_page` { #zizqquery-each_page }

Enumerates each `Zizq::Resources::JobPage` in the query result.

> [!NOTE]
> When combined with `#limit`, `#each_page` stops at the page boundary but the
> entire last page is returned even if the jobs it contains exceeds the limit.

``` ruby
Zizq.query
  .by_status("scheduled")
  .in_pages_of(2)
  .each_page
  .with_index do |page, idx|
    puts "Page #{idx+1}"
    page.jobs.each { |job| puts "#{job.id}" }
  end
# Page 1
# 03fvmay0zcoskwdf2sm0u94aw
# 03fvqg4qxj39zecl43gnwwh04
# Page 2
# 03fvqg68ra0od9u1b8m0txgka
# 03fvqhdcqsftfxrzb6xc8acjy
# Page 3
# 03fvqhdcqsftfxrzb6zq57rqs
# 03fvqhdcqsftfxrzb71cxvk13
# Page 4
# 03fvqhdcqsftfxrzb74afpg6x
# 03fvqhdcqsftfxrzb75rabbrt
# Page 5
# 03fvqhdcqsftfxrzb78any8s1
# 03fvqhdcqsftfxrzb7a5g3hpm
```

### `#delete_all` { #zizqquery-delete_all }

Deletes all jobs from the server that match the given query and returns the
number of deleted jobs. When the query is unfiltered, deletes _all jobs_ from
the server. This can be useful in tests.

When combined with `#in_pages_of`, jobs are deleted in a batch-wise manner,
otherwise all jobs are deleted in a single transaction.

This method also combines safely with `#limit` in order to explicitly prevent
deleting more than a specified number of jobs (implies batch-wise deletion).

``` ruby
Zizq.query.by_queue("analytics").count
# 90

Zizq.query.by_queue("analytics").delete_all
# 90

Zizq.query.by_queue("analytics").count
# 0

Zizq.query.by_queue("comms").count
# 3538

Zizq.query.by_queue("comms").in_pages_of(20).limit(30).order(:desc).delete_all
# 30

Zizq.query.by_queue("comms").count
# 3528
```

### `#update_all` { #zizqquery-update_all }

Updates all jobs from the server that match the given query and returns the
number of updated jobs. When the query is unfiltered, updates _all jobs_ on the
server.

The following job fields are mutable:

* `queue`
* `priority`
* `ready_at`
* `retry_limit`
* `backoff`
* `retention`

Only the fields specified in the argument list are updated. All other fields
are left unchanged.

This method can be used for example to re-assign/rename `queue`s or to change
`priority`.

Setting an optional field to `nil` tells the server to restore that field back
to its default value, so for example to un-schedule a job and make it
immediately `ready` you can set `ready_at` to `nil` and the server will make it
`ready` immediately.

When combined with `#in_pages_of`, jobs are updated in a batch-wise manner,
otherwise all jobs are updated in a single transaction.

This method also combines safely with `#limit` in order to explicitly prevent
updating more than a specified number of jobs (implies batch-wise update).

``` ruby
Zizq.query.by_queue("default").count
# 15491

Zizq.query.by_queue("analytics").count
# 90

Zizq.query.by_queue("analytics").update_all(queue: "default")
# 90

Zizq.query.by_queue("default").count
# 15581

Zizq.query.by_queue("analytics").count
# 0

Zizq.query.by_queue("payments").by_status("scheduled").count
# 3

Zizq.query.by_queue("payments").by_status("scheduled").update_all(ready_at: nil)
# 3

Zizq.query.by_queue("payments").by_status("scheduled").count
# 0
```

### `#delete_one` { #zizqquery-delete_one }

Deletes at most the first matching result from the query.

``` ruby
Zizq.query.by_queue("payments").count
# 881

Zizq.query.by_queue("payments").order(:desc).delete_one
# 1

Zizq.query.by_queue("payments").count
# 880
```

### `#update_one` { #zizqquery-update_one }

Updates at most the first matching result from the query.

``` ruby
Zizq.query.by_queue("comms").by_status("scheduled").count
# 2

Zizq.query.by_queue("comms").by_status("scheduled").update_one(ready_at: nil)
# 1

Zizq.query.by_queue("comms").by_status("scheduled").count
# 1
```

## `Zizq::Resources::Job`

Each job in the result of `Zizq::Query#each` also implements methods to inspect
errors and manage the job.

The following method provides access to the job's errors:

* [`#errors`](#zizqresourcesjob-errors)

The following methods allow deleting or updating the job's properties:

* [`#delete`](#zizqresourcesjob-delete)
* [`#update`](#zizqresourcesjob-update)

### `#errors` { #zizqresourcesjob-errors }

Enumerates the errors on this job, either in reverse or ascending order. This
can also be done in pages.

``` ruby
job = Zizq.query.by_id("03fvqhdcqsftfxrzb7m9owqsf").first
job.errors.in_pages_of(20).order(:desc).each do |err|
  puts "Attempt: #{err.attempt}, Message: #{err.message}"
end
# Attempt: 2, Message: Something went wrong
# Attempt: 1, Message: Something went wrong
```

### `#delete`

Permanently deletes this job from the server. Returns `nil` on success. Raises
on failure (e.g. 404 - job not found).

``` ruby
job = Zizq.query.by_queue("comms").first

job.id
# 03fvqhdcqsftfxrzb7hekw4if

Zizq.query.by_id("03fvqhdcqsftfxrzb7hekw4if").count
# 1

job.delete
# nil

Zizq.query.by_id("03fvqhdcqsftfxrzb7hekw4if").count
# 0

job.delete
#! job not found (Zizq::NotFoundError)
```

### `#update`

Updates mutable properties on this job. Returns the updated job metadata on
success. Raises `Zizq::ClientError` on failure.

Jobs in the `completed` or `dead` statuses are immutable and cannot be updated.

``` ruby
job = Zizq.query.by_queue("comms").first

job.id
# 03fvqhdcqsftfxrzb7nn5h57r

Zizq.query.by_id("03fvqhdcqsftfxrzb7nn5h57r").map(&:queue)
# ["comms"]

job.update(queue: "default")
# #<Zizq::Resources::Job @data={"id"=>"03fvqhdcqsftfxrzb7nn5h57r", ...}>

job.queue
# default

Zizq.query.by_id("03fvqhdcqsftfxrzb7nn5h57r").map(&:queue)
# ["default"]
```

## `Zizq::Resources::JobPage`

The pages of jobs yielded by `Zizq::Query#each_page` also provide some helper
methods that operate across the whole page.

* [`#delete_all`](#zizqresourcesjobpage-delete_all)
* [`#update_all`](#zizqresourcesjobpage-update_all)

The page itself is also an `Enumerable` so `#each`, `#count`, `#take` etc work
as expected.

### `#delete_all` { #zizqresourcesjobpage-delete_all }

Delete all jobs on the current page by their IDs.

> [!WARNING]
> This method behaves differently to `Zizq::Query#delete_all` which respects
> the original query filters. This method deletes every record on the page
> unconditionally, even if it may have since been updated and does not match
> the filters.

The example here deletes all jobs on the first 5 pages where the queue is
`example`.

``` ruby
Zizq.query.by_queue("example").each_page.take(5).each(&:delete_all)
```

### `#update_all` { #zizqresourcesjobpage-update_all }

Update all jobs on the current page by their IDs.

> [!WARNING]
> This method behaves differently to `Zizq::Query#update_all` which respects
> the original query filters. This method updates every record on the page
> unconditionally, even if it may have since been updated and does not match
> the filters.

The example here update all jobs on the first 2 pages where the queue is
`example`.

``` ruby
Zizq.query.by_queue("example").each_page.take(5).each do |page|
  page.update_all(queue: "other")
end
```
