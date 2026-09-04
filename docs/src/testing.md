# Testing

Zizq ships with a test mode that swaps the real client out for an
in-memory `Zizq::Test::Client`. Calls to `Zizq.enqueue`,
`Zizq.enqueue_job_class`, `Zizq.enqueued_raw` and `Zizq.enqueue_bulk` buffer
jobs in memory instead of sending to the server, so tests run without needing a
running Zizq instance.

The intended scope is purely **enqueue paths**: assertions like
"did this job get enqueued with these args?" and "drain the queue
and check the side effects." Other operations (`Zizq.query`,
`Zizq.queues`, etc.) deliberately raise
`Zizq::Test::Client::NotSupported` rather than silently returning
empty results.

## Enabling test mode

Flip the flag in your test helper, before any tests run:

> Ruby:
>
> ``` ruby
> # test/test_helper.rb (Minitest) or spec/spec_helper.rb (RSpec)
> require "zizq"
> 
> Zizq::Test.enable!
> ```

`Zizq::Test.enable!` is a thin wrapper around
`Zizq.configure { |c| c.test_mode = true }` — use whichever reads
better with the rest of your test setup. After this, `Zizq.client`
lazily resolves to a `Zizq::Test::Client` instead of the real HTTP
client. Nothing else in your app code needs to change —
`Zizq.enqueue(...)` keeps working, it just goes into an in-memory
buffer.

`Zizq::Test.disable!` is the inverse if you ever need to swap back
to the real client (e.g. an integration test that talks to a
running server).

## Resetting between tests

Call `Zizq::Test.reset!` in your setup hook to clear the buffer
between tests:

> Ruby:
>
> ``` ruby
> class ActiveSupport::TestCase
>   setup { Zizq::Test.reset! }
> end
> ```

The `test_mode` flag stays set across resets — only the buffered
jobs are cleared.

## Inspecting the buffer

`Zizq::Test` exposes status-filtered views over the buffer.
Each accepts a common set of filter kwargs (see [Filter
kwargs](#filter-kwargs) below).

| Method                                              | Returns                                                                          |
| --------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Zizq::Test.enqueued_jobs(**filters)`               | All buffered jobs, in submission order, regardless of status.                    |
| `Zizq::Test.enqueued_requests(**filters)`           | Original `EnqueueRequest`s. Useful for `unique_key`, `unique_while`, etc.        |
| `Zizq::Test.pending_jobs(**filters)`                | `ready` + `scheduled` (waiting on `ready_at`).                                   |
| `Zizq::Test.in_flight_jobs(**filters)`              | Jobs currently mid-dispatch.                                                     |
| `Zizq::Test.completed_jobs(**filters)`              | Jobs whose dispatcher returned successfully.                                     |
| `Zizq::Test.dead_jobs(**filters)`                   | Jobs whose dispatcher raised. Test mode never retries.                           |

Each method delegates to the underlying `Zizq::Test.client`, which
exposes the same accessors if you'd rather work with the client
directly.

## Asserting enqueues

For the common "was this job enqueued?" check, use the predicates.
Both class-based and raw forms are supported, with optional
positional + keyword args to match the job's serialized payload:

> Ruby:
>
> ``` ruby
> # Class-based (Zizq::Job or ActiveJob)
> assert Zizq::Test.enqueued?(SendEmailJob)                                  # any args
> assert Zizq::Test.enqueued?(SendEmailJob, 42, template: "welcome")         # exact args
> assert_equal 3, Zizq::Test.enqueued_count(SendEmailJob)                    # how many?
> 
> # Raw (Zizq.enqueue_raw)
> assert Zizq::Test.enqueued_raw?(type: "send_email")
> assert Zizq::Test.enqueued_raw?(type: "send_email", payload: { user_id: 42 })
> assert_equal 2, Zizq::Test.enqueued_raw_count(queue: "emails", type: "send_email")
> ```

The class form uses the class's own `zizq_serialize` to compute the
expected payload — so it works for both `Zizq::Job` and
`extend Zizq::ActiveJobConfig` classes. For ActiveJob, only the
`arguments` portion is compared; volatile fields like `job_id` and
`enqueued_at` are ignored.

For matchers, subset matching, or any custom predicate, use the
[`filter:`](#filter-kwargs) predicate — see below.

## Running buffered jobs

`Zizq::Test.dispatch_enqueued_jobs` drains the buffer, dispatching
each pending entry through the configured dequeue middleware chain
(`Zizq.configuration.dequeue_middleware` — the same path the real
worker uses, so any registered middleware runs too). It loops until
no more pending entries match the filters, so handler re-enqueues
fall through naturally.

> Ruby:
>
> ``` ruby
> # No block — drains whatever's pending now.
> SignupService.new.run
> Zizq::Test.dispatch_enqueued_jobs
> 
> # Block form — yields first (test code enqueues), then drains.
> # Same semantics as ActiveJob's `perform_enqueued_jobs do ... end`.
> Zizq::Test.dispatch_enqueued_jobs do
>   SignupService.new.run
> end
> ```

Handler exceptions transition the entry's status to `dead` and
re-raise from `dispatch_enqueued_jobs`. A block exception
propagates without draining.

Scheduled jobs (those with a future `ready_at`) are skipped until
their time arrives. Combine with [Timecop](https://github.com/travisjeffery/timecop)
or similar to advance the clock and drain due jobs:

> Ruby:
>
> ``` ruby
> Timecop.travel(2.hours) do
>   Zizq::Test.dispatch_enqueued_jobs    # picks up anything now due
> end
> ```

## Filter kwargs

Every accessor and `dispatch_enqueued_jobs` accepts the same
filter kwargs:

| Kwarg              | Type                                  | Meaning                                                |
| ------------------ | ------------------------------------- | ------------------------------------------------------ |
| `only_queues:`     | `String` or `Array<String>`           | Restrict to these queue names.                         |
| `except_queues:`   | `String` or `Array<String>`           | Exclude these queue names.                             |
| `only_types:`      | `String`, `Class`, or `Array`         | Restrict to these types. Classes match via `.to_s`.    |
| `except_types:`    | `String`, `Class`, or `Array`         | Exclude these types.                                   |
| `filter:`          | `->(Resources::Job) -> bool`          | Arbitrary predicate. Defaults to "pass all".           |

Filters compose via AND. Nonsensical combinations (e.g. `only_queues:
"a", except_queues: "a"`) naturally produce no matches — there's no
validation.

The `filter:` lambda is the fallback for when the named filters
aren't expressive enough — useful for matching on payload contents,
RSpec/Minitest matchers, or any custom logic:

> Ruby:
>
> ``` ruby
> # RSpec-style matcher (a tiny custom matcher file is all it takes)
> RSpec::Matchers.define :have_enqueued_zizq_job do |klass|
>   match do |args_matchers|
>     Zizq::Test.enqueued_jobs(only_types: klass).any? do |job|
>       args = job.payload["arguments"] || job.payload["args"]
>       args == args_matchers
>     end
>   end
> end
> ```

## Lifecycle states

Buffered jobs have a valid Zizq status. Test mode mirrors the
real lifecycle, but without retries — `in_flight` only ever transitions
to `completed` or `dead`:

| Status        | Meaning                                                                               |
| ------------- | ------------------------------------------------------------------------------------- |
| `scheduled`   | `ready_at` is in the future. Skipped by `dispatch_enqueued_jobs` until due.           |
| `ready`       | Runnable now. Drained on the next `dispatch_enqueued_jobs` call.                      |
| `in_flight`   | Currently being dispatched. You usually only see this from inside a dispatcher.       |
| `completed`   | Dispatcher returned cleanly.                                                          |
| `dead`        | Dispatcher raised. The exception is re-raised from `dispatch_enqueued_jobs`.          |

## Limitations

* **Utility APIs raise.** `Zizq.query`, `Zizq.queues`, `Zizq.client.get_job`,
  `Zizq.client.list_jobs`, `Zizq.client.count_jobs`, etc. all raise
  `Zizq::Test::Client::NotSupported` in test mode. Use the buffer
  accessors (`Zizq::Test.enqueued_jobs(...)`) for assertions, or
  stub these calls explicitly if your code under test needs them.

* **`Zizq::Worker` and `take_jobs` are not stubbed.** Test mode
  buffers enqueues; if you need to test a worker handler in
  isolation, call it directly or use `dispatch_enqueued_jobs` to
  invoke it through the dequeue middleware chain.

* **No automatic retries.** A handler that raises is recorded as
  `dead` and the exception re-raises from
  `dispatch_enqueued_jobs`. If you want to test retry behaviour,
  point at a real Zizq server.

* **Pro-only features (cron, unique jobs) are not enforced** in
  test mode. The `unique_*` fields are preserved on the buffered
  `EnqueueRequest` for assertion purposes, but the test client
  doesn't actually deduplicate.
