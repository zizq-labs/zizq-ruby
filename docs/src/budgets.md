# Concurrency &amp; Rate Limiting

> [!NOTE]
> This feature requires a [Pro license](https://zizq.io/pricing) on the server.

Applications enqueue jobs to offload expensive work to a background worker.
Some of those jobs may put pressure on upstream systems if running with high
throughput. For example, you may have jobs that resize images through an image
service, and that service may have a maximum throughput of 10,000 requests per
hour. Or you may send push notifications through your queue worker, but at
times bursts of notifications dominate your queue, starving other jobs of
processing time. Both of these problems can be solved with a feature Zizq calls
_budgets_.

Budgets are Zizq's approach to limiting throughput, both from a pure concurrency
control perspective (no more than N jobs in-flight at any given time), and also
from a rate limiting perspective (no more than N jobs dispatched over a period
of time). The server stores named budgets, which are pools of available _tokens_
managed under a specified _strategy_. Currently two strategies exist:
`while_in_flight`, and `time_based`. Jobs are enqueued referencing one or more
of these budgets, along with optional costs to run those jobs, where that cost
defaults to `1` token. Before a job can be dispatched to a worker, it needs to
successfully debit its cost from each of its budgets' shared token pools.

Unlike with some other job queues, throughput is controlled entirely by the
server, so workers do not need to receive a job and then wait or retry because
it exceeded some rate limit. Instead, workers remain naive to the dispatching
logic and just process every job they receive in the same way. If the budget
does not have enough tokens available for a job to run, Zizq does not dispatch
that job to a worker in the first place. It _parks_ that job and dispatches it
the moment its budget allows. Other jobs — those without budget restrictions
and those on other budgets that have tokens available — continue to be
dispatched to workers without stalling.

> [!NOTE]
> Budgets are a shared resource. The Zizq server currently enforces an upper
> limit on the number of distinct budgets that can be created. The default is
> `8192` different budgets, which should be far in excess of what typical
> applications would require, but this limit can be configured on the server
> via `--max-budgets` (`$ZIZQ_MAX_BUDGETS`) when running `zizq serve`. A future
> release will introduce a sub-bucket concept for dynamically allocated budget
> scenarios.

## Budget Strategies

There are currently two available strategies for budgeting: `:while_in_flight`
implements pure concurrency control, and `:time_based` implements a dispatch
rate limit over time. Both take a total `allocation` value, which is the number
of tokens made available in the budget's pool. Jobs can be bound to more than
one budget, mixing and matching across different strategies. In this case,
_all_ budgets must be satisified before the job can run.

Budgets must have an allocation greater than or equal to the `cost` of each
job that references that budget. That is, the Zizq server will reject any
attempt to enqueue a job that costs more than its budget will ever allow, and
it will reject any attempt to update a budget to allocate less tokens than some
job referencing that budget would cost.

### `:while_in_flight`

For pure concurrency control, where you need to ensure at most `N` workers are
processing a given job at once, use the `:while_in_flight` strategy. In this
strategy, the budget has a given token allocation of say `20` and no other
configuration.

> Ruby:
>
> ```ruby
> Zizq.define_budget(
>   "cpu-intensive",
>   allocation: 20,
>   strategy: { type: :while_in_flight }
> )
> ```

The above budget would allow at most 20 concurrent jobs with the default cost
of `1`, or 10 concurrent jobs with a cost of `2`, or any valid combination of
costs that is less than or equal to 20.

- `20 x cost=1`
- `10 x cost=2`
- `(5 x cost=2) + (10 x cost=1)`
- `(3 x cost=5) + (2 x cost=2)`

When a job is dispatched that uses a `:while_in_flight` strategy, it must debit
its cost in full from the budget's token pool. If the pool is too depleted to
do that, the job remains parked until more tokens are available in the pool.
Once dispatched, tokens remain debited from the pool for as long as that job is
`"in_flight"`. As soon as the worker acknowledges the job with a successful
completion, or reports a failure, the job is no longer `"in_flight"` and its
tokens are released back to the pool, allowing other jobs to run within that
same budget.

To illustrate how this works, take this example job that takes a consistent 2
seconds to run, bound to a `"while_in_flight"` budget with an allocation of 5.

> 2 second jobs with `:while_in_flight` 5:
> ```sh
> D, [2026-09-10T14:21:20.926911 #3954337] DEBUG -- : Received example (03guad5408l32mar6g23tnuql), dispatch queue: 0
> D, [2026-09-10T14:21:20.927188 #3954337] DEBUG -- : Received example (03guad540ozoaxl3fazxngdpv), dispatch queue: 1
> D, [2026-09-10T14:21:20.927403 #3954337] DEBUG -- : Received example (03guad540zxegggplf64q2td9), dispatch queue: 2
> D, [2026-09-10T14:21:20.927601 #3954337] DEBUG -- : Received example (03guad5415e9j83oqlgggdu3i), dispatch queue: 3
> D, [2026-09-10T14:21:20.927802 #3954337] DEBUG -- : Received example (03guad541gbzorp4uvufmeez8), dispatch queue: 4
> D, [2026-09-10T14:21:22.930215 #3954337] DEBUG -- : Job example (03guad5408l32mar6g23tnuql) completed in 2.0021s
> D, [2026-09-10T14:21:22.930456 #3954337] DEBUG -- : Job example (03guad540ozoaxl3fazxngdpv) completed in 2.0024s
> D, [2026-09-10T14:21:22.930512 #3954337] DEBUG -- : Job example (03guad540zxegggplf64q2td9) completed in 2.0024s
> D, [2026-09-10T14:21:22.930630 #3954337] DEBUG -- : Job example (03guad5415e9j83oqlgggdu3i) completed in 2.0025s
> D, [2026-09-10T14:21:22.930673 #3954337] DEBUG -- : Job example (03guad541gbzorp4uvufmeez8) completed in 2.0026s
> D, [2026-09-10T14:21:22.933266 #3954337] DEBUG -- : Received example (03guad541lsurizqiqrs1swx5), dispatch queue: 0
> D, [2026-09-10T14:21:22.933619 #3954337] DEBUG -- : Received example (03guad541r9puax48rtp1pghx), dispatch queue: 1
> D, [2026-09-10T14:21:22.933837 #3954337] DEBUG -- : Received example (03guad541wqkx29mjfw85w94h), dispatch queue: 2
> D, [2026-09-10T14:21:22.933969 #3954337] DEBUG -- : Received example (03guad54227fzu07za3g0truo), dispatch queue: 3
> D, [2026-09-10T14:21:22.934199 #3954337] DEBUG -- : Received example (03guad542d565dgd2794uhl9b), dispatch queue: 4
> D, [2026-09-10T14:21:24.936925 #3954337] DEBUG -- : Job example (03guad541lsurizqiqrs1swx5) completed in 2.0021s
> D, [2026-09-10T14:21:24.937260 #3954337] DEBUG -- : Job example (03guad541r9puax48rtp1pghx) completed in 2.0024s
> D, [2026-09-10T14:21:24.937317 #3954337] DEBUG -- : Job example (03guad541wqkx29mjfw85w94h) completed in 2.0025s
> D, [2026-09-10T14:21:24.937483 #3954337] DEBUG -- : Job example (03guad54227fzu07za3g0truo) completed in 2.0026s
> D, [2026-09-10T14:21:24.937524 #3954337] DEBUG -- : Job example (03guad542d565dgd2794uhl9b) completed in 2.0027s
> D, [2026-09-10T14:21:24.939414 #3954337] DEBUG -- : Received example (03guad542im184k4yuvstxmkh), dispatch queue: 0
> D, [2026-09-10T14:21:24.939531 #3954337] DEBUG -- : Received example (03guad542o2waw80tumu5kwes), dispatch queue: 1
> D, [2026-09-10T14:21:24.939584 #3954337] DEBUG -- : Received example (03guad542tjrdnxu6xdfosu1s), dispatch queue: 2
> D, [2026-09-10T14:21:24.939623 #3954337] DEBUG -- : Received example (03guad542z0mgfx5vmj1vhfnq), dispatch queue: 3
> D, [2026-09-10T14:21:24.939658 #3954337] DEBUG -- : Received example (03guad5434hhj72czyv8jhnc9), dispatch queue: 4
> D, [2026-09-10T14:21:26.941879 #3954337] DEBUG -- : Job example (03guad542im184k4yuvstxmkh) completed in 2.0021s
> D, [2026-09-10T14:21:26.942010 #3954337] DEBUG -- : Job example (03guad542o2waw80tumu5kwes) completed in 2.0022s
> D, [2026-09-10T14:21:26.942067 #3954337] DEBUG -- : Job example (03guad542tjrdnxu6xdfosu1s) completed in 2.0023s
> D, [2026-09-10T14:21:26.942116 #3954337] DEBUG -- : Job example (03guad542z0mgfx5vmj1vhfnq) completed in 2.0023s
> D, [2026-09-10T14:21:26.942170 #3954337] DEBUG -- : Job example (03guad5434hhj72czyv8jhnc9) completed in 2.0024s
> D, [2026-09-10T14:21:26.944265 #3954337] DEBUG -- : Received example (03guad5439yclyzloygnro4w1), dispatch queue: 0
> D, [2026-09-10T14:21:26.944686 #3954337] DEBUG -- : Received example (03guad543ff7oqjtumn1ix8kn), dispatch queue: 1
> D, [2026-09-10T14:21:26.945099 #3954337] DEBUG -- : Received example (03guad543qcxu9jmvg5gxpr32), dispatch queue: 2
> D, [2026-09-10T14:21:26.945199 #3954337] DEBUG -- : Received example (03guad543vtsx13snzic6s7x0), dispatch queue: 3
> D, [2026-09-10T14:21:26.945392 #3954337] DEBUG -- : Received example (03guad5441anzt166s2yn805o), dispatch queue: 4
> D, [2026-09-10T14:21:28.947714 #3954337] DEBUG -- : Job example (03guad5439yclyzloygnro4w1) completed in 2.0021s
> D, [2026-09-10T14:21:28.947848 #3954337] DEBUG -- : Job example (03guad543ff7oqjtumn1ix8kn) completed in 2.0022s
> D, [2026-09-10T14:21:28.947904 #3954337] DEBUG -- : Job example (03guad543qcxu9jmvg5gxpr32) completed in 2.0023s
> D, [2026-09-10T14:21:28.947962 #3954337] DEBUG -- : Job example (03guad543vtsx13snzic6s7x0) completed in 2.0023s
> D, [2026-09-10T14:21:28.948016 #3954337] DEBUG -- : Job example (03guad5441anzt166s2yn805o) completed in 2.0024s
> D, [2026-09-10T14:21:28.950214 #3954337] DEBUG -- : Received example (03guad5446rj2kqag18apd9vd), dispatch queue: 0
> D, [2026-09-10T14:21:28.950899 #3954337] DEBUG -- : Received example (03guad544c8e5c5rqlw2jjpnw), dispatch queue: 1
> D, [2026-09-10T14:21:28.951521 #3954337] DEBUG -- : Received example (03guad544hp983tq2svu2wz8b), dispatch queue: 2
> D, [2026-09-10T14:21:28.951895 #3954337] DEBUG -- : Received example (03guad544smzdmtscfpzsfms7), dispatch queue: 3
> D, [2026-09-10T14:21:28.952252 #3954337] DEBUG -- : Received example (03guad544y3ugexkkord5fy4d), dispatch queue: 4
> ```

Jobs are running 5 at once, taking 2 seconds to complete and then another 5
jobs run at once.

### `:time_based`

Where concurrency is not the concern, but overall throughput is, the
`:time_based` strategy can be used to enforce a rate limit. Just like a
`:while_in_flight` budget, a `:time_based` one has a token allocation, which
represents the number of tokens that can be _spent_ over some period of time.
Unlike the `:while_in_flight` strategy, a `:time_based` strategy is specified
along with a `duration`, specifying the number of seconds (or if you have
`ActiveSupport`, an `ActiveSupport::Duration` like `5.minutes`) over which
its allocation can be spent.

> Ruby:
>
> ```ruby
> Zizq.define_budget(
>   "image-service",
>   allocation: 10000,
>   strategy: { type: :time_based, duration: 3600 }
> )
> ```

The above budget states that at most 10,000 tokens can be spent over a
1 hour period, hence it is a rate limit of `10000/hour`.

When a job is dispatched that uses a `:time_based` budget, it must debit its
cost in full, otherwise it remains parked until enough tokens become available.
Unlike `:while_in_flight`, tokens are not released back to the pool when the
job completes, but rather are released back to the pool on the cadence
specified by the duration. This means a `:time_based` budget controls how many
jobs are _dispatched_ over time, but it cares not how many of those jobs finish
up running at once (i.e. jobs that take longer than `duration` to run may
overlap). The server implements this _lazily_. There is no constant scanning of
the database to look for jobs that can now be dispatched. The server is smart
enough to know when tokens will next become available and sleeps until that
time, or until some other event wakes it.

The `:time_based` strategy implements a _continuous drip_ rate limiter. Also
known as a [leaky bucket](https://en.wikipedia.org/wiki/Leaky_bucket) rate
limit. Unlike some rate limiters which bucket tokens into fixed time intervals
— e.g. for a 5 minute limit, `00:00 - 00:05`, `00:05 - 00:10`, ... — a
continuous drip rate limiter sets a pace. For example if 100 tokens are
available over 5 minutes, and the pool is empty, after 1 minute the pool has 20
tokens available, after 4 minutes it has 80 tokens available, and after the
full 5 minutes it has all 100 tokens available. This naturally spreads work
over time, rather than sending sharp bursts of jobs across fixed bucket
boundaries, then stalling until the next bucket etc. When the pool is _full_
however, it has 100 tokens available and therefore a sudden burst of 100 jobs
with a cost of 1 could all go at once, followed by a steady pace of around 1
job every 3 seconds. This is generally desirable in order to accommodate
short-lived spikes, but not always, and the behaviour is configurable through
the `burst` parameter on on the strategy.

To illustrate how this works, take this example which runs a job that takes a
consistent 2 seconds per execution, using a budget configured at 6/minute.

> `time_based` at 6/minute:
> ```sh
> D, [2026-09-10T14:32:22.804431 #3955340] DEBUG -- : Received example2 (03guaf86qr82o2avowmz7yy1x), dispatch queue: 0
> D, [2026-09-10T14:32:24.807137 #3955340] DEBUG -- : Job example2 (03guaf86qr82o2avowmz7yy1x) completed in 2.0021s
> D, [2026-09-10T14:32:32.803674 #3955340] DEBUG -- : Received example2 (03guaf86qwoxqtiauglqa24jv), dispatch queue: 0
> D, [2026-09-10T14:32:34.806273 #3955340] DEBUG -- : Job example2 (03guaf86qwoxqtiauglqa24jv) completed in 2.0021s
> D, [2026-09-10T14:32:42.802740 #3955340] DEBUG -- : Received example2 (03guaf86r7mnwd0g5ms3ssciz), dispatch queue: 0
> D, [2026-09-10T14:32:44.805806 #3955340] DEBUG -- : Job example2 (03guaf86r7mnwd0g5ms3ssciz) completed in 2.0021s
> D, [2026-09-10T14:32:52.803952 #3955340] DEBUG -- : Received example2 (03guaf86rd3iz4kqg39tqvl8o), dispatch queue: 0
> D, [2026-09-10T14:32:54.807137 #3955340] DEBUG -- : Job example2 (03guaf86rd3iz4kqg39tqvl8o) completed in 2.0028s
> D, [2026-09-10T14:33:02.805181 #3955340] DEBUG -- : Received example2 (03guaf86rike1w42oka0tpw5w), dispatch queue: 0
> D, [2026-09-10T14:33:04.807812 #3955340] DEBUG -- : Job example2 (03guaf86rike1w42oka0tpw5w) completed in 2.0021s
> D, [2026-09-10T14:33:12.803981 #3955340] DEBUG -- : Received example2 (03guaf86rti47fcur3fmwounf), dispatch queue: 0
> D, [2026-09-10T14:33:14.806749 #3955340] DEBUG -- : Job example2 (03guaf86rti47fcur3fmwounf) completed in 2.0021s
> D, [2026-09-10T14:33:22.802674 #3955340] DEBUG -- : Received example2 (03guaf86ryyza7bcc64o67ov3), dispatch queue: 0
> D, [2026-09-10T14:33:24.805673 #3955340] DEBUG -- : Job example2 (03guaf86ryyza7bcc64o67ov3) completed in 2.0021s
> ```

As you can see, each job takes its 2 seconds to complete, but the worker
continues receiving and processing these jobs at a rate of 6 per second.

The `burst` is how full the token pool can be at any single point in time. When
not specified, the `allocation` is used, so for our 100 jobs/5 minute example
the default burst is 100, as descibed above. Budgets specifying a different
`burst` look like so:

> Ruby:
>
> ```ruby
> Zizq.define_budget(
>   "image-service",
>   allocation: 10000,
>   strategy: { type: :time_based, duration: 3600, burst: 500 }
> )
> ```

In this example, no more than 500 jobs can be dispatched at any moment, then
10,000/hour at a steady pace thereafter. Setting a `burst` of just `1` is
equivalent to enforcing the 10,000/hour always. It is also possible to set the
`burst` _higher_ than the total allocation — say 20,000 tokens — which allows
for brief spikes of high throughput that exceed the rate limit by design, if
and only if the budget was otherwise unused for an equivalent period of time.

Again, to illustrate how this works, here's that 6/minute job with its upfront
default burst of 6 jobs in one go.

> `time_based` at 6/minute, with its burst:
> ```sh
> D, [2026-09-10T14:32:12.802443 #3955340] DEBUG -- : Received example2 (03guaf86oxlpqukoqrsaop7i1), dispatch queue: 0
> D, [2026-09-10T14:32:12.802553 #3955340] DEBUG -- : Received example2 (03guaf86pjh61x0ge1m3vot7i), dispatch queue: 1
> D, [2026-09-10T14:32:12.802623 #3955340] DEBUG -- : Received example2 (03guaf86puew7g5327hfv4txc), dispatch queue: 2
> D, [2026-09-10T14:32:12.802694 #3955340] DEBUG -- : Received example2 (03guaf86pzvra89d4k7rr4wgz), dispatch queue: 3
> D, [2026-09-10T14:32:12.802753 #3955340] DEBUG -- : Received example2 (03guaf86qathfre87u46ro62s), dispatch queue: 4
> D, [2026-09-10T14:32:12.802809 #3955340] DEBUG -- : Received example2 (03guaf86qgaciim321320xx9v), dispatch queue: 5
> D, [2026-09-10T14:32:14.805240 #3955340] DEBUG -- : Job example2 (03guaf86oxlpqukoqrsaop7i1) completed in 2.0021s
> D, [2026-09-10T14:32:14.805384 #3955340] DEBUG -- : Job example2 (03guaf86pjh61x0ge1m3vot7i) completed in 2.0023s
> D, [2026-09-10T14:32:14.805446 #3955340] DEBUG -- : Job example2 (03guaf86puew7g5327hfv4txc) completed in 2.0024s
> D, [2026-09-10T14:32:14.805496 #3955340] DEBUG -- : Job example2 (03guaf86pzvra89d4k7rr4wgz) completed in 2.0024s
> D, [2026-09-10T14:32:14.805545 #3955340] DEBUG -- : Job example2 (03guaf86qathfre87u46ro62s) completed in 2.0024s
> D, [2026-09-10T14:32:14.805589 #3955340] DEBUG -- : Job example2 (03guaf86qgaciim321320xx9v) completed in 2.0025s
> D, [2026-09-10T14:32:22.804431 #3955340] DEBUG -- : Received example2 (03guaf86qr82o2avowmz7yy1x), dispatch queue: 0
> D, [2026-09-10T14:32:24.807137 #3955340] DEBUG -- : Job example2 (03guaf86qr82o2avowmz7yy1x) completed in 2.0021s
> D, [2026-09-10T14:32:32.803674 #3955340] DEBUG -- : Received example2 (03guaf86qwoxqtiauglqa24jv), dispatch queue: 0
> D, [2026-09-10T14:32:34.806273 #3955340] DEBUG -- : Job example2 (03guaf86qwoxqtiauglqa24jv) completed in 2.0021s
> D, [2026-09-10T14:32:42.802740 #3955340] DEBUG -- : Received example2 (03guaf86r7mnwd0g5ms3ssciz), dispatch queue: 0
> D, [2026-09-10T14:32:44.805806 #3955340] DEBUG -- : Job example2 (03guaf86r7mnwd0g5ms3ssciz) completed in 2.0021s
> D, [2026-09-10T14:32:52.803952 #3955340] DEBUG -- : Received example2 (03guaf86rd3iz4kqg39tqvl8o), dispatch queue: 0
> D, [2026-09-10T14:32:54.807137 #3955340] DEBUG -- : Job example2 (03guaf86rd3iz4kqg39tqvl8o) completed in 2.0028s
> D, [2026-09-10T14:33:02.805181 #3955340] DEBUG -- : Received example2 (03guaf86rike1w42oka0tpw5w), dispatch queue: 0
> D, [2026-09-10T14:33:04.807812 #3955340] DEBUG -- : Job example2 (03guaf86rike1w42oka0tpw5w) completed in 2.0021s
> D, [2026-09-10T14:33:12.803981 #3955340] DEBUG -- : Received example2 (03guaf86rti47fcur3fmwounf), dispatch queue: 0
> D, [2026-09-10T14:33:14.806749 #3955340] DEBUG -- : Job example2 (03guaf86rti47fcur3fmwounf) completed in 2.0021s
> D, [2026-09-10T14:33:22.802674 #3955340] DEBUG -- : Received example2 (03guaf86ryyza7bcc64o67ov3), dispatch queue: 0
> D, [2026-09-10T14:33:24.805673 #3955340] DEBUG -- : Job example2 (03guaf86ryyza7bcc64o67ov3) completed in 2.0021s
> ```

Here it is visible that before the worker settles into receiving these jobs at
a rate of 6 per second, it receives an upfront burst of 6 jobs in one go. This
only happens:

1. If no jobs have been dispatched for the configured duration (i.e. the token
   pool is full); or
2. The budget is freshly allocated (newly created, or the Zizq server was
   restarted).

When using `burst`, all jobs that reference the budget must have a cost less
than or equal to the configured burst, and any attempts to update the budget
such that this condition is violated are rejected.

## Binding jobs to budgets

A job class using `Zizq::Job` declares which budgets it is bound to using
`zizq_budget`, and every enqueue carries that information:

> Ruby:
>
> ```ruby
> class ProcessImageJob
>   include Zizq::Job
>
>   zizq_budget "image-service", cost: 2
>
>   def perform(attachment_id)
>   end
> end
> ```

> [!NOTE]
> The default `cost` is `1` and can be omitted.

Jobs can also bind to more than one budget at once, in which case all budgets
must be satisfied before the job can be dispatched:

> Ruby:
>
> ```ruby
> class ProcessImageJob
>   include Zizq::Job
>
>   zizq_budget "image-service", cost: 2
>   zizq_budget "cpu-intensive"
>
>   def perform(attachment_id)
>   end
> end
> ```

A single enqueue can override the job class' default:

> Ruby:
>
> ```ruby
> Zizq.enqueue_with(
>   budgets: [{ key: "storage" }]
> ).enqueue(ProcessImageJob, 42)
> ```

With no budgets a job is unthrottled and dispatches as soon as it reaches the
front of the queue. With several, it must satisfy of them. A job bound to
a `:while_in_flight` limit of 10 and a `:time_based` limit of 1000/hour honours
both: never more than 10 at once, never more than 1000 an hour.

Use `cost` to make jobs weigh differently against the same pool. A bulk
operation costing `10` against an allocation of `100` leaves room for 90 more
single operations.

### Creating budgets lazily

A budget normally exists before anything binds to it. `create_with` lets one
enqueue do both atomically:

> Ruby:
>
> ```ruby
> class ProcessImageJob
>   include Zizq::Job
>
>   zizq_budget "image-service", cost: 2, create_with: {
>     allocation: 10000,
>     strategy: { type: :time_based, duration: 60 }
>   }
>
>   def perform(attachment_id)
>   end
> end
> ```

If the budget already exists the policy is _ignored_ and the stored one stays
authoritative — an enqueue with a `create_with` will never clobber an existing
tuned budget.

## Managing budgets

> Ruby:
>
> ```ruby
> # List all budgets on the server
> Zizq.budgets
>
> # Fetch a single budget
> Zizq.budget("emails")
>
> # Create a :while_in_flight budget raises Zizq::ConflictError if exists
> Zizq.define_budget(
>   "controlled-fan-out",
>   allocation: 10,
>   strategy: { type: :while_in_flight }
> )
>
> # Create a :time_based budget raises Zizq::ConflictError if exists
> Zizq.define_budget(
>   "controlled-throughput",
>   allocation: 100,
>   strategy: { type: :time_based, duration: 60 }
> )
>
> # Create a :time_based budget with burst
> Zizq.define_budget(
>   "controlled-throughput",
>   allocation: 100,
>   strategy: { type: :time_based, duration: 60, burst: 10 }
> )
>
> # Create or replace a budget
> Zizq.define_budget(
>   "controlled-fan-out",
>   allocation: 10,
>   strategy: { type: :while_in_flight },
>   replace: true
> )
>
> # Update any setting of an existing budget
> # Raises ConflictError if settings are unsatisfiable.
> Zizq.update_budget("controlled-throughput", strategy: { burst: 5 })
>
> # Delete an existing budget
> # Raises ConflictError if jobs still reference the budget
> Zizq.delete_budget("controlled-fan-out")
> ```

`Zizq.define_budget` refuses an existing key with `Zizq::ConflictError`
and leaves the stored policy alone. Hence it is ok for every process in a
horizontally scaled workload to declare its budgets on boot without
coordination, and those one that lose the race simply treat the conflict as
success.

> Ruby:
>
> ```ruby
> begin
>   Zizq.define_budget(
>     "image-service",
>     allocation: 10000,
>     strategy: { type: :time_based, duration: 60 }
>   )
> rescue Zizq::ConflictError
>   # ok, already declared
> end
> ```

Pass `replace: true` to overwrite instead. A replace changes the policy, not
the budget's identity, so `created_at` remains true to when the budget was
first created.

`Zizq.update_budget` is a deep (recursive) merge patch, so it is valid to
change a single field inside the `strategy` without repeating all the others.
`burst: nil` is the one meaningful use of `nil` — it clears the bucket's
ceiling back to the default (its total allocation).

## Changing which budgets jobs are bound to

Bindings are mutable even after jobs are enqueued. This is allows making
adjustments e.g. during an incident response, such as splitting one shared
budget in two, or taking a rate limit off a job that is stuck behind it.

This can be done directly on a single job resource object already in hand:

> Ruby:
>
> ```ruby
> # Bind a new budget to an existing Zizq::Resources::Job object
> # The cost is optional and default to 1. If the job is already
> # bound this raises Zizq::ConflictError.
> job.bind_budget("emails", cost: 2)
>
> # The same as above, but replace rather than raising.
> job.rebind_budget("emails", cost: 3)
>
> # Bind a new budget to an existing Zizq::Resources::Job object
> # creating one atomically if it does not already exist. create_with also
> # works on job.rebind_budget(...).
> job.bind_budget("emails", cost: 2, create_with: {
>   allocation: 20000,
>   strategy: { type: :time_based, duration: 3600 }
> })
>
> # Change the cost of an existing binding.
> job.set_budget_cost("emails", 5)
>
> # Remove an existing binding from a job.
> job.unbind_budget("emails")
>
> # Remove all bindings from a job (job becomes completely unthrottled)
> job.unbind_all_budgets
>
> # Atomically replace the entire set of bindings on the job.
> # Passing the empty array is the equivalent of job.unbind_all_budgets.
> job.replace_budgets([{key: "emails", cost: 2}])
> ```

Each updates the job data, so its `#budgets` reflects the change without a
second read. `Job#bind_budget` conflicts if the job is already bound to that
budget; `#rebind_budget` replaces the binding whole.

The same operations run over a filtered selection of jobs through `Zizq.query`:

> Ruby:
>
> ```ruby
> # Bind a new budget to all matching jobs. Ignore any that already have the
> # binding.
> Zizq.query.by_queue("emails").bind_budget("stripe", cost: 2)
>
> # The same as above, but overwrite rather than ignore existing.
> Zizq.query.by_queue("emails").rebind_budget("stripe", cost: 2)
>
> # Change the cost for the named binding on all matching jobs.
> Zizq.query.by_queue("emails").set_budget_cost("stripe", 3)
>
> # Remove an existing binding from all matching jobs. Ignore any that don't
> # have the binding.
> Zizq.query.by_queue("emails").unbind_budget("stripe")
>
> # Remove all bindings from all matching jobs. If the query is not filtered
> # this strips all jobs of their bindings, making them regular unthrottled
> # jobs.
> Zizq.query.by_queue("emails").unbind_all_budgets
> ```

> [!IMPORTANT]
> Only queued jobs (`scheduled`, `ready`) can be rebound. An in-flight job
> has already debited its tokens, and jobs in terminal states are always
> immutable. The bulk forms report the ones they could not touch rather than
> skipping them silently:
>
> ```ruby
> Zizq.query.by_queue("emails").set_budget_cost("stripe", 3)
> # => {changed: 1252, blocked: ["03guad54591kly4v1vrezu536", "03guad546m9cauqlh07z2ut84"]}
> ```
>
> `:blocked` is always in-flight jobs, so it can be interpreted as a retry
> list.

## Querying jobs bound to a budget

A budget cannot be deleted while anything remains bound to it. The
`#by_budgets_key` filter selects exactly what is bound, and works anywhere
jobs are filtered:

> Ruby:
>
> ```ruby
> # See how many jobs have the "emails" budget binding
> Zizq.query.by_budgets_key("emails").count
>
> # Remove the "emails" budget binding from those jobs
> Zizq.query.by_budgets_key("emails").unbind_budget("emails")
>
> # This should now work (assuming nothing was in-flight)
> Zizq.delete_budget("emails")
> ```

`Zizq::Resources::Job` also reports its bindings:

> Ruby:
>
> ```ruby
> job = Zizq.client.get_job("03guad54591kly4v1vrezu536")
> job.budgets
> # => [{key: "emails", cost: 2}]
> ```

Note that there is no `create_with` on a read — that was acted upon at
enqueue-time and is not permanently stored as part of the details of the job
itself.
