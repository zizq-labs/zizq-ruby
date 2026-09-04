# Batched Jobs

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server.

Batched jobs let you accumulate many enqueue calls into a single pending job.
This is useful when your application enqueues one work unit at a time, but the
downstream service you're calling accepts (or prefers) batches — for example,
push notification providers that accept up to 1000 device tokens per request,
or bulk email APIs that accept many recipients per call.

Rather than each enqueue creating its own job, subsequent enqueues that share
a batch key are _folded_ into the pending job's payload. When a worker
eventually claims the job, it sees a single job with a combined payload and
makes a single downstream call.

Once claimed, a batched job is just a normal job — the worker sees one merged
payload and acks once.

## Configuring Batched Jobs

> [!NOTE]
> If you are using `ActiveJob` you will need to extend `Zizq::ActiveJobConfig`
> onto your job class to access this feature.

Batching is enabled by calling `zizq_batched` within the class. At minimum you
must supply a `limit:` — the maximum combined length of the batched payload
before the current batch is sealed and a new one starts.

> Ruby:
>
> ``` ruby
> class SendPushNotifications
>   include Zizq::Job
>
>   zizq_batched true, limit: 100
>
>   def perform(notifications, platform:)
>     # notifications is an Array, batched across multiple enqueue calls
>   end
> end
> ```

By default the first positional argument is the _batch target_ — the value
that gets accumulated across enqueues. The remaining arguments participate in
the [batch key](#batch-keys), so enqueues with the same `platform:` fold
together while enqueues with a different `platform:` end up in separate
batches.

You can target a specific positional arg or a specific keyword arg:

> Ruby:
>
> ``` ruby
> # Target the third positional arg (index 2).
> zizq_batched true, arg: 2, limit: 100
>
> # Target the :notifications keyword arg.
> zizq_batched true, kwarg: :notifications, limit: 100
> ```

Calling `zizq_batched false` disables batching for that class (useful in a
subclass).

## Options

<table>
    <thead>
        <tr>
            <th>Option</th>
            <th>Description</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td><code>limit:</code></td>
            <td>
                Required. Maximum combined length of the batched value. When
                a new enqueue would push the combined length over the limit,
                the current batch is sealed and a fresh one starts.
            </td>
        </tr>
        <tr>
            <td><code>arg:</code></td>
            <td>
                Positional argument index to batch on. Defaults to <code>0</code>
                (the first positional arg).
            </td>
        </tr>
        <tr>
            <td><code>kwarg:</code></td>
            <td>
                Keyword argument name to batch on. Mutually exclusive with
                <code>arg:</code>.
            </td>
        </tr>
        <tr>
            <td><code>dedup:</code></td>
            <td>
                When <code>true</code>, the fold expression appends
                <code>| unique</code> to remove duplicate entries within the
                batch. Also has the side effect of sorting the entries.
            </td>
        </tr>
        <tr>
            <td><code>sorted:</code></td>
            <td>
                When <code>true</code>, the fold expression appends
                <code>| sort</code> to sort entries within the batch. Ignored
                when <code>dedup:</code> is also <code>true</code> (since
                <code>unique</code> already sorts).
            </td>
        </tr>
    </tbody>
</table>

## Batch Semantics

> [!NOTE]
> When reading the `jq` expressions here be aware that `Zizq::Job`'s serialized
> payload shape is `{"args": [...], "kwargs": {...}}`.

Zizq applies your batch configuration server-side using two [`jq`][jq]
expressions — a `when` predicate that decides whether to fold, and a `fold`
reducer that produces the merged payload. The Ruby client generates these
expressions automatically from your `zizq_batched` declaration, but you can
see and override them.

For the `SendPushNotifications` job above with `arg: 0, limit: 100`, the
generated expressions are:

* `when` = `($existing.args[0] + $new.args[0]) | length <= 100`
* `fold` = `$existing | .args[0] += $new.args[0]`

Reading these:

- `$existing` is the currently enqueued payload; `$new` is the incoming
  payload.
- The `when` predicate returns true when the combined length would still fit
  within the limit — in which case the new payload is folded in.
- When `when` returns false, the existing batch is _sealed_ (no more folds)
  and a fresh pending job is created with just the new payload.

This is _all-or-nothing_: an incoming payload of 20 elements against an
existing batch of 90 does not partially fill the batch to 100 and overflow the
remaining 10 into a new one — it seals the existing batch at 90 and starts a
new one with all 20. Applications that need strict per-batch caps should size
their enqueues to avoid overshoot.

## Batch Keys

Enqueues that share a batch key fold into the same pending job. The Zizq Ruby
client computes the batch key by hashing all job arguments _except_ the batch
target. Two enqueues with the same non-batch arguments therefore produce the
same batch key and fold; enqueues that differ in any non-batch argument end
up in separate batches.

> Ruby:
>
> ``` ruby
> # These two enqueues fold together (same :platform, different notifications).
> Zizq.enqueue(SendPushNotifications, [n1], platform: 'apple')
> Zizq.enqueue(SendPushNotifications, [n2, n3], platform: 'apple')
>
> # This enqueue starts a separate batch (different :platform).
> Zizq.enqueue(SendPushNotifications, [n4], platform: 'android')
> ```

### Overriding the Batch Key

You can inspect the derived key directly:

> Ruby:
>
> ``` ruby
> SendPushNotifications.zizq_batch_key([n1], platform: 'apple')
> # "SendPushNotifications:8f0c...b3"
> ```

Override `zizq_batch_key` on the class if the default derivation isn't a good
fit — for example, to batch by tenant regardless of the other arguments:

> Ruby:
>
> ``` ruby
> class SendPushNotifications
>   include Zizq::Job
>   zizq_batched true, limit: 100
>
>   def self.zizq_batch_key(notifications, tenant_id:, platform:)
>     "#{name}:tenant-#{tenant_id}"
>   end
>
>   def perform(notifications, tenant_id:, platform:)
>     # ...
>   end
> end
> ```

You may also call `super` here.

### Overriding the Expressions

For advanced cases, override `zizq_batch_expressions` to return a
`{when:, fold:}` hash. Use the [`jq`][jq] manual as a reference; the
expressions run against `$existing` and `$new`, which are the current and
incoming payloads respectively.

> Ruby:
>
> ``` ruby
> class MyBatchedJob
>   include Zizq::Job
>   zizq_batched true, limit: 100
>
>   def self.zizq_batch_expressions
>     {
>       when: "($existing.args[0] + $new.args[0]) | length <= 100",
>       fold: "$existing | .args[0] = (.args[0] + $new.args[0] | map(select(.active)))"
>     }
>   end
> end
> ```

## Enqueuing Batched Jobs

Batched jobs are enqueued exactly like any other job: `Zizq.enqueue`. The
returned `Zizq::Resources::Job` exposes a `folded?` predicate that tells you
whether this enqueue was folded into an existing pending job or created a
new one.

> Ruby:
>
> ``` ruby
> # First enqueue creates a new pending job.
> result = Zizq.enqueue(SendPushNotifications, [n1], platform: 'apple')
> result.id       # "03fu0wm75gxgmfyfplwvazhex"
> result.folded?  # false
>
> # Second enqueue with the same non-batch args folds into the existing job.
> result = Zizq.enqueue(SendPushNotifications, [n2], platform: 'apple')
> result.id       # "03fu0wm75gxgmfyfplwvazhex" (same job id)
> result.folded?  # true
>
> # The job's payload combines both enqueues
> Zizq.client.get_job(result.id).payload
> # {"args": [#<n1>, #<n2>], "kwargs": {"platform": "apple"}}
> ```

The same is true for [bulk enqueue](./enqueuing-jobs.md#bulk-job-enqueueing)
requests — items within the same bulk call that share a batch key fold
together.

### Raw enqueue

For the low-level raw enqueue API (typically used for cross-language enqueue
or when you want to bypass the DSL), pass `batch:` explicitly as a hash.
You're responsible for the `when`/`fold` expressions and the batch key.

> Ruby:
>
> ``` ruby
> Zizq.enqueue(
>   queue: "push",
>   type:  "SendPushNotifications",
>   payload: { "notifications" => [n1], "platform" => "apple" },
>   batch: {
>     key:  "push:apple",
>     when: "($existing.notifications + $new.notifications) | length <= 100",
>     fold: "$existing | .notifications += $new.notifications"
>   }
> )
> ```

## Inspecting Batched Jobs

The `batch` attribute on `Zizq::Resources::Job` returns the batch
configuration stored on the job. Useful for debugging when a fold isn't
behaving as expected — the [_first_ enqueue's expressions](#config-first-wins)
are what apply for the life of the batch, so this is the source of truth
regardless of what subsequent enqueues supplied.

> Ruby:
>
> ``` ruby
> job = Zizq.client.get_job("03fu0wm75gxgmfyfplwvazhex")
> job.batch
> # {
> #   key:  "SendPushNotifications:8f0c...b3",
> #   when: "($existing.args[0] + $new.args[0]) | length <= 100",
> #   fold: "$existing | .args[0] += $new.args[0]"
> # }
> ```

## First-Enqueue Config Wins {#config-first-wins}

The `when` and `fold` expressions stored on the first enqueued job are used
for every subsequent fold against it. Follow-up enqueues that produce
different expressions (perhaps because you changed the DSL and redeployed)
don't take effect until the current batch is sealed and a new one starts.

If you need new expressions to take immediate effect, changing the
[batch key](#batch-keys) — for example by version-suffixing it — forces a
fresh batch.

## Incompatibility with Unique Jobs

`zizq_batched` and `zizq_unique` are mutually exclusive on the same class.
The client raises `ArgumentError` at class-definition time if you try to
declare both, and the server independently rejects the combination with
`400 Bad Request` at enqueue time.

## Interaction with ActiveJob

For `ActiveJob` classes extending `Zizq::ActiveJobConfig`, batching works
the same way — the generated expressions target `.arguments[N]` (positional)
or `.arguments[-1].NAME` (kwarg), matching the ActiveJob envelope shape.
When targeting a kwarg the class must actually receive keyword arguments at
enqueue time for the generated `jq` expressions to be valid. Targeting kwargs
when they are not used at enqueue-time is unspecified behaviour.

## Enqueue-Time Validation

Both the compile step and a dry-run against the incoming payload run on
every batched enqueue. Bad expressions (syntax errors, undefined variables,
runtime shape errors when evaluated against the payload) surface as
`422 Unprocessable Entity` up front rather than at first fold. Developers
should still test their expressions in development — the dry-run catches
common mistakes but can't detect logic errors that only manifest on data
your first enqueue didn't include.

[jq]: https://jqlang.github.io/jq/manual/
