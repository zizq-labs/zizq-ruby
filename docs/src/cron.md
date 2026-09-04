# Cron Scheduling

> [!NOTE]
> This feature requires a Zizq [pro license](https://zizq.io/pricing) on the
> server.

Zizq supports running jobs periodically, using a cron scheduling system that is
managed atomically by the Zizq server. Multiple schedules can be defined, and
any number of entries can exist on each schedule. Both schedules and individual
entries within a schedule can be paused and resumed. Explicit time zones are
supported.

The official Zizq Ruby client exposes this functionality through
`Zizq::Crontab`.

## Defining a Schedule

Schedules are defined by your application, not by configuration files on the
Zizq server. Your application includes a `Zizq.define_crontab { ... }` block
somewhere in its startup code (e.g. in a Rails initializer for a Rails app).

Schedule definitions are idempotent. There is no requirement to designate one
particular process as the process that defines the schedule. If you have 50
application processes and they all define the same schedule on startup, that is
fine and expected.

Schedule defintions are also mutable. If you change a schedule between
application versions, Zizq is smart enough to retain existing entries, replace
modified entries, and delete removed entries.

The structure of a crontab definition is one outer `Zizq.define_crontab { ... }`,
and a series of `cron.define_entry(...).enqueue(...)` calls inside the block.

Each entry is assigned a name known to your application, which uniquely
identifies that entry within the schedule.

Both 6-field (with seconds) and standard 5-field cron expressions are accepted.

> Ruby:
>
> ``` ruby
> Zizq.define_crontab("my_cron", timezone: "Europe/London") do |cron|
>   # Incrementally refresh data in the data warehouse every 15 minutes.
>   cron.define_entry("refresh_data_warehouse", "*/15 * * * *").enqueue(
>     RefreshDataWarehoseJob,
>     incremental: true,
>   )
> 
>   # Send the daily digest email at 9am (London) every day.
>   cron.define_entry("send_daily_digest", "0 9 * * *").enqueue(SendDailyDigestJob)
> 
>   # Run the log rotation process at midnight UTC.
>   cron.define_entry("rotate_logs", "0 0 * * *", timezone: "UTC").enqueue(
>     queue: "system/maintenance",
>     type: "rotate_logs",
>     priority: 100,
>     payload: {},
>   )
> end
> ```

### Timezones

The `timezone:` given to `Zizq.define_crontab` applies to every entry that does
not specify one of its own, so a schedule that runs in a single timezone says
so once. An entry passing its own `timezone:` overrides it, which is how one
schedule can hold entries in several zones.

With neither set, expressions are evaluated in the system timezone of the Zizq
server.

The schedule's timezone is stored on the server as the schedule's own rather
than being copied onto each entry, so it is still there when the schedule is
read back:

> Ruby:
>
> ``` ruby
> Zizq.crontab("my_cron").timezone #=> "Europe/London"
> ```

> [!NOTE]
> A schedule-level timezone requires Zizq 0.7.0 or newer on the server. Against
> an older server it is ignored, and entries relying on it fall back to the
> server's system timezone.

The Zizq server will push jobs to the queue and advance the schedule
atomically. There is no risk that a job will be enqueued twice for the same
schedule tick. However, because Zizq simply enqueues the job without waiting
for completion, you _could_ end up with overlapping jobs if they are scheduled
too close together and take a long time to run. If this is a concern for your
application, you should combine cron scheduling with
[Unique Jobs](./unique-jobs.md) in order to prevent duplicate enqueues.

## Inspecting Existing Schedules

Once defined, cron schedules can be fetched and inspected by your application
by using `Zizq.crontab("...")`. Some management operations such as pause/resume
are also available on the returned schedule.

> [!NOTE]
> `Zizq.crontab` is lazy. Requests to fetch the schedule data are only sent to
> Zizq server when the data is first accessed.

> Ruby:
>
> ``` ruby
> Zizq.crontab("my_cron").paused?
> 
> Zizq.crontab("my_cron").entries.each do |name, entry|
>   puts "#{name}: #{entry.expression} (#{entry.job.type}) last enqueued: #{entry.last_enqueued_at}"
> end
> ```

## Pausing & Resuming Schedules

Schedules can be paused and resumed at two distinct levels:

1. At the outer `Crontab` level.
2. Per-entry within the schedule.

If the `Crontab` itself is paused, no entries within that schedule will execute
even if they are not paused.

> Ruby:
>
> ``` ruby
> # Pause/resume entire schedule
> 
> Zizq.crontab("my_cron").pause!
> Zizq.crontab("my_cron").paused? # true
> Zizq.crontab("my_cron").paused_at # ~ now
> 
> Zizq.crontab("my_cron").resume!
> Zizq.crontab("my_cron").paused? # false
> Zizq.crontab("my_cron").paused_at # ~ before
> Zizq.crontab("my_cron").resumed_at # ~ now
> 
> # Pause/resume individual entry
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").paused? # false
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").pause!
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").paused? # true
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").paused_at # ~ now
> 
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").resume!
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").paused? # false
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").paused_at # ~ before
> Zizq.crontab("my_cron").entry("refresh_data_warehouse").resumed_at # ~ now
> ```

When paused, Zizq stops enqeueing jobs but continues to advance the schedule.

It is also possible for the paused state to be specified within the schedule
definition itself, which is useful e.g. if schedule pausing needs to be coupled
to app deployments (e.g. as part of a phased rollout of a complex change).

> Ruby:
>
> ``` ruby
> Zizq.define_crontab("my_cron", paused: true) do |cron|
>   # ...
> end
> ```

> [!TIP]
> `define_entry` also accepts `paused: true` or `paused: false`.

## Deleting a Schedule

Entire `Zizq::Crontab` schedules can be deleted, along with all of their
entries by calling `#delete!` on the crontab instance.

> Ruby:
>
> ``` ruby
> Zizq.crontab("my_cron").delete!
> ```

## Adding, Replacing or Deleting Entries within a Schedule

In general you should just define your schedule(s) in your application startup
code using `Zizq.define_crontab { ... }` and let Zizq keep that schedule in
sync. However it is also possible to add/replace entries dynamically by calling
`define_entry` directly on the `Crontab` instance.

> Ruby:
>
> ``` ruby
> Zizq.crontab("my_cron").define_entry("example", "* * * * *").enqueue(ExampleJob)
> ```

If `"example"` already exists on this schedule, it is replaced with the new
entry, otherwise the new entry is appended to the schedule.

Call `#delete!` on an entry to remove it from the schedule.

> Ruby:
>
> ``` ruby
> Zizq.crontab("my_cron").entry("example").delete!
> ```
