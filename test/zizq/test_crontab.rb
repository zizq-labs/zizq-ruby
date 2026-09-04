# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class CronTestJob
  include Zizq::Job
  zizq_queue "cron-q"
  def perform(x) = nil
end

class BatchedCronTestJob
  include Zizq::Job
  zizq_queue "cron-q"
  zizq_batched true, limit: 100
  def perform(items) = nil
end

class TestCrontab < ZizqTestCase
  CRON_GROUP = {
    "name" => "default",
    "paused" => false,
    "entries" => [
      {
        "name" => "e1",
        "expression" => "* * * * *",
        "paused" => false,
        "job" => {
          "type" => "CronTestJob",
          "queue" => "cron-q",
          "payload" => {
            "args" => [1],
            "kwargs" => {
            }
          }
        },
        "next_enqueue_at" => 1_700_000_060_000
      }
    ]
  }.freeze

  CRON_ENTRY = CRON_GROUP["entries"][0].freeze

  # --- Zizq.crontabs ---

  def test_crontabs_lists_group_names
    stub_request(:get, "#{URL}/crons").to_return(
      json_response({ "crons" => %w[default billing] })
    )

    assert_equal %w[default billing], Zizq.crontabs
  end

  # --- Zizq.crontab (lazy handle) ---

  def test_crontab_returns_handle_without_api_call
    # No stubs — if an API call is made, WebMock will error.
    tab = Zizq.crontab("default")
    assert_instance_of Zizq::Crontab, tab
    assert_equal "default", tab.name
  end

  def test_crontab_materializes_on_data_access
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    tab = Zizq.crontab("default")
    assert_equal false, tab.paused?
    assert_equal 1, tab.entries.size
    assert_equal "e1", tab.entries["e1"].name
  end

  def test_crontab_reads_the_schedule_timezone
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP.merge("timezone" => "Australia/Melbourne"))
    )

    assert_equal "Australia/Melbourne", Zizq.crontab("default").timezone
  end

  def test_crontab_timezone_is_nil_when_the_schedule_has_none
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    assert_nil Zizq.crontab("default").timezone
  end

  # An entry's own timezone is part of what it is, so reading a schedule has
  # to bring it back — otherwise a read-and-rewrite silently drops it.
  def test_crontab_entries_keep_their_own_timezone
    group =
      CRON_GROUP.merge(
        "entries" => [CRON_ENTRY.merge("timezone" => "Europe/Rome")]
      )

    stub_request(:get, "#{URL}/crons/default").to_return(json_response(group))

    assert_equal "Europe/Rome", Zizq.crontab("default").entries["e1"].timezone
  end

  # Same reasoning as the timezone above: a template's budgets are part
  # of what the entry is, so a read has to bring them back.
  def test_crontab_entries_keep_their_budgets
    group =
      CRON_GROUP.merge(
        "entries" => [
          CRON_ENTRY.merge(
            "job" =>
              CRON_ENTRY["job"].merge(
                "budgets" => [{ "key" => "emails", "cost" => 2 }]
              )
          )
        ]
      )

    stub_request(:get, "#{URL}/crons/default").to_return(json_response(group))

    job = Zizq.crontab("default").entries["e1"].job
    assert_equal [{ key: "emails", cost: 2 }], job.budgets
  end

  # `batch` was dropped the same way, which predates budgets.
  def test_crontab_entries_keep_their_batch_config
    batch = { "key" => "b", "when" => "true", "fold" => "." }
    group =
      CRON_GROUP.merge(
        "entries" => [
          CRON_ENTRY.merge("job" => CRON_ENTRY["job"].merge("batch" => batch))
        ]
      )

    stub_request(:get, "#{URL}/crons/default").to_return(json_response(group))

    job = Zizq.crontab("default").entries["e1"].job
    assert_equal({ key: "b", when: "true", fold: "." }, job.batch)
  end

  # The failure that matters: reading a schedule and writing it back
  # must not quietly unthrottle it or un-batch it.
  def test_read_then_redefine_preserves_budgets_and_batch
    batch = { "key" => "b", "when" => "true", "fold" => "." }
    budgets = [{ "key" => "emails", "cost" => 2 }]
    group =
      CRON_GROUP.merge(
        "entries" => [
          CRON_ENTRY.merge(
            "job" =>
              CRON_ENTRY["job"].merge("batch" => batch, "budgets" => budgets)
          )
        ]
      )

    stub_request(:get, "#{URL}/crons/default").to_return(json_response(group))

    sent = nil
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        sent = JSON.parse(req.body)
        true
      end
      .to_return(json_response(group))

    tab = Zizq.crontab("default")
    existing = tab.entries.values
    tab.redefine do |cron|
      existing.each do |entry|
        cron.define_entry(entry.name, entry.expression).enqueue_raw(
          **entry.job.to_enqueue_params
        )
      end
    end

    written = sent["entries"][0]["job"]
    assert_equal budgets, written["budgets"]
    assert_equal batch, written["batch"]
  end

  def test_crontab_materializes_only_once
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    tab = Zizq.crontab("default")
    tab.paused?
    tab.entries
    tab.paused_at

    # Should have been called exactly once.
    assert_requested(:get, "#{URL}/crons/default", times: 1)
  end

  # --- Crontab#pause! / resume! ---

  def test_pause_calls_patch_and_materializes
    paused =
      CRON_GROUP.merge("paused" => true, "paused_at" => 1_700_000_000_000)
    stub_request(:patch, "#{URL}/crons/default").with(
      body: JSON.generate({ paused: true })
    ).to_return(json_response(paused))

    tab = Zizq.crontab("default")
    tab.pause!
    assert tab.paused?
  end

  def test_resume_calls_patch_and_materializes
    resumed =
      CRON_GROUP.merge("paused" => false, "resumed_at" => 1_700_000_000_000)
    stub_request(:patch, "#{URL}/crons/default").with(
      body: JSON.generate({ paused: false })
    ).to_return(json_response(resumed))

    tab = Zizq.crontab("default")
    tab.resume!
    refute tab.paused?
  end

  # --- Crontab#delete! ---

  def test_delete_calls_delete
    stub_request(:delete, "#{URL}/crons/default").to_return(
      status: 204,
      body: "",
      headers: {
      }
    )

    Zizq.crontab("default").delete!
  end

  # --- Zizq.define_crontab ---

  def test_define_crontab_puts_schedule
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        body = JSON.parse(req.body)
        body["entries"].size == 1 && body["entries"][0]["name"] == "e1" &&
          body["entries"][0]["expression"] == "*/5 * * * *" &&
          body["entries"][0]["job"]["type"] == "CronTestJob" &&
          body["entries"][0]["job"]["queue"] == "cron-q"
      end
      .to_return(json_response(CRON_GROUP))

    tab =
      Zizq.define_crontab("default") do |cron|
        cron.define_entry("e1", "*/5 * * * *").enqueue(CronTestJob, 1)
      end

    assert_instance_of Zizq::Crontab, tab
    assert_equal "default", tab.name
    assert_equal 1, tab.entries.size
  end

  # Sent as the schedule's own timezone, not copied onto each entry, so a
  # schedule read back later still reports which timezone it runs in.
  # A batched job class carries a `batch` on its enqueue request, so the
  # cron job template has to accept one — scheduling a batched job used
  # to raise `ArgumentError: unknown keyword: :batch` before any request
  # was made.
  def test_define_crontab_with_a_batched_job_class
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        batch = JSON.parse(req.body)["entries"][0]["job"]["batch"]
        !batch.nil? && batch.key?("key") && batch.key?("when") &&
          batch.key?("fold")
      end
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default") do |cron|
      cron.define_entry("e1", "*/5 * * * *").enqueue(BatchedCronTestJob, [1])
    end
  end

  # The same via the raw form, where the caller supplies the expressions.
  def test_define_crontab_with_an_explicit_batch
    batch = {
      key: "push:apple",
      when: "($existing.args[0] + $new.args[0]) | length <= 100",
      fold: "$existing | .args[0] += $new.args[0]"
    }

    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        JSON.parse(req.body)["entries"][0]["job"]["batch"] ==
          {
            "key" => batch[:key],
            "when" => batch[:when],
            "fold" => batch[:fold]
          }
      end
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default") do |cron|
      cron.define_entry("e1", "*/5 * * * *").enqueue_raw(
        queue: "push",
        type: "SendPushNotifications",
        payload: {
          "args" => [[]],
          "kwargs" => {
          }
        },
        batch: batch
      )
    end
  end

  # The raw form works inside a cron entry too, which is the whole point
  # of the dispatch — cross-language scheduling without `enqueue_raw`.
  def test_define_crontab_accepts_both_enqueue_forms
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        JSON.parse(req.body)["entries"].map { |e| e["job"]["type"] } ==
          %w[CronTestJob digest]
      end
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default") do |cron|
      cron.define_entry("e1", "*/5 * * * *").enqueue(CronTestJob, 1)
      cron.define_entry("e2", "0 9 * * *").enqueue(
        queue: "emails",
        type: "digest",
        payload: {
        }
      )
    end
  end

  # A cron entry fires on its schedule and cannot also be scheduled.
  # `enqueue`'s raw form omits these keywords so they do not typecheck;
  # `enqueue_raw` is a `**opts` catch-all and can only refuse at
  # runtime, which is what this pins.
  def test_cron_enqueue_raw_refuses_a_scheduled_job
    %i[ready_at delay].each do |key|
      error =
        assert_raises(ArgumentError) do
          Zizq.define_crontab("default") do |cron|
            cron.define_entry("e1", "* * * * *").enqueue_raw(
              :queue => "q",
              :type => "T",
              :payload => {
              },
              key => 60
            )
          end
        end
      assert_match(/not permitted via cron/, error.message)
    end
  end

  def test_define_crontab_with_timezone
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        body = JSON.parse(req.body)
        body["timezone"] == "Australia/Melbourne" &&
          !body["entries"][0].key?("timezone")
      end
      .to_return(
        json_response(CRON_GROUP.merge("timezone" => "Australia/Melbourne"))
      )

    tab =
      Zizq.define_crontab("default", timezone: "Australia/Melbourne") do |cron|
        cron.define_entry("e1", "* * * * *").enqueue(CronTestJob, 1)
      end

    assert_equal "Australia/Melbourne", tab.timezone
  end

  def test_define_crontab_entry_timezone_overrides_the_schedule
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        body = JSON.parse(req.body)
        body["timezone"] == "Australia/Melbourne" &&
          body["entries"][0]["timezone"] == "Europe/Rome"
      end
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default", timezone: "Australia/Melbourne") do |cron|
      cron.define_entry("e1", "* * * * *", timezone: "Europe/Rome").enqueue(
        CronTestJob,
        1
      )
    end
  end

  def test_define_crontab_timezone_can_be_assigned_in_the_block
    stub_request(:put, "#{URL}/crons/default")
      .with { |req| JSON.parse(req.body)["timezone"] == "Europe/Rome" }
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default") do |cron|
      cron.timezone = "Europe/Rome"
      cron.define_entry("e1", "* * * * *").enqueue(CronTestJob, 1)
    end
  end

  def test_define_crontab_without_timezone_sends_none
    stub_request(:put, "#{URL}/crons/default")
      .with { |req| !JSON.parse(req.body).key?("timezone") }
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default") do |cron|
      cron.define_entry("e1", "* * * * *").enqueue(CronTestJob, 1)
    end
  end

  def test_define_crontab_with_paused
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        body = JSON.parse(req.body)
        body["paused"] == true
      end
      .to_return(json_response(CRON_GROUP.merge("paused" => true)))

    tab =
      Zizq.define_crontab("default", paused: true) do |cron|
        cron.define_entry("e1", "* * * * *").enqueue(CronTestJob, 1)
      end

    assert tab.paused?
  end

  def test_define_crontab_with_enqueue_raw
    stub_request(:put, "#{URL}/crons/default")
      .with do |req|
        body = JSON.parse(req.body)
        body["entries"][0]["job"]["type"] == "raw_job" &&
          body["entries"][0]["job"]["queue"] == "raw-q" &&
          body["entries"][0]["job"]["payload"] == { "key" => "value" }
      end
      .to_return(json_response(CRON_GROUP))

    Zizq.define_crontab("default") do |cron|
      cron.define_entry("e1", "* * * * *").enqueue_raw(
        type: "raw_job",
        queue: "raw-q",
        payload: {
          key: "value"
        }
      )
    end
  end

  def test_define_crontab_rejects_ready_at
    assert_raises(ArgumentError) do
      Zizq.define_crontab("default") do |cron|
        cron.define_entry("e1", "* * * * *").enqueue_raw(
          type: "t",
          queue: "q",
          payload: {
          },
          ready_at: 12_345
        )
      end
    end
  end

  def test_define_crontab_rejects_delay
    assert_raises(ArgumentError) do
      Zizq.define_crontab("default") do |cron|
        cron
          .define_entry("e1", "* * * * *")
          .enqueue_with(delay: 60)
          .enqueue_raw(type: "t", queue: "q", payload: {})
      end
    end
  end

  # --- Crontab#redefine ---

  def test_redefine_replaces_schedule
    # Initial state.
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    # PUT for redefine.
    stub_request(:put, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    tab = Zizq.crontab("default")
    tab.entries # materialize

    tab.redefine do |cron|
      cron.define_entry("e1", "* * * * *").enqueue(CronTestJob, 1)
    end

    assert_requested(:put, "#{URL}/crons/default", times: 1)
  end

  # --- CrontabEntry#pause! / resume! / delete! ---

  def test_entry_pause
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    paused_entry =
      CRON_ENTRY.merge("paused" => true, "paused_at" => 1_700_000_000_000)
    stub_request(:patch, "#{URL}/crons/default/entries/e1").with(
      body: JSON.generate({ paused: true })
    ).to_return(json_response(paused_entry))

    tab = Zizq.crontab("default")
    tab.entry("e1").pause!
    assert tab.entries["e1"].paused
  end

  def test_entry_resume
    paused_group = CRON_GROUP.dup
    paused_group["entries"] = [CRON_ENTRY.merge("paused" => true)]

    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(paused_group)
    )

    resumed_entry =
      CRON_ENTRY.merge("paused" => false, "resumed_at" => 1_700_000_000_000)
    stub_request(:patch, "#{URL}/crons/default/entries/e1").with(
      body: JSON.generate({ paused: false })
    ).to_return(json_response(resumed_entry))

    tab = Zizq.crontab("default")
    tab.entry("e1").resume!
    refute tab.entries["e1"].paused
  end

  def test_entry_delete
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    stub_request(:delete, "#{URL}/crons/default/entries/e1").to_return(
      status: 204,
      body: "",
      headers: {
      }
    )

    tab = Zizq.crontab("default")
    tab.entry("e1").delete!
    assert_empty tab.entries
  end

  # --- Crontab#define_entry (single entry upsert) ---

  def test_define_entry_outside_block
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    stub_request(:put, "#{URL}/crons/default/entries/e2")
      .with do |req|
        body = JSON.parse(req.body)
        body["name"] == "e2" && body["expression"] == "0 0 * * *" &&
          body["job"]["type"] == "CronTestJob"
      end
      .to_return(
        json_response(
          {
            "name" => "e2",
            "expression" => "0 0 * * *",
            "paused" => false,
            "job" => {
              "type" => "CronTestJob",
              "queue" => "cron-q",
              "payload" => {
                "args" => [1],
                "kwargs" => {
                }
              }
            },
            "next_enqueue_at" => 1_700_000_060_000
          }
        )
      )

    tab = Zizq.crontab("default")
    tab.define_entry("e2", "0 0 * * *").enqueue(CronTestJob, 1)

    assert_equal 2, tab.entries.size
    assert tab.entries.key?("e2")
  end

  # --- CrontabEntry accessors ---

  def test_entry_accessors
    stub_request(:get, "#{URL}/crons/default").to_return(
      json_response(CRON_GROUP)
    )

    entry = Zizq.crontab("default").entry("e1")
    assert_equal "e1", entry.name
    assert_equal "* * * * *", entry.expression
    assert_instance_of Zizq::EnqueueRequest, entry.job
    assert_equal "CronTestJob", entry.job.type
    assert_equal "cron-q", entry.job.queue
  end

  private

  def json_response(body)
    {
      status: 200,
      body: JSON.generate(body),
      headers: {
        "Content-Type" => "application/json"
      }
    }
  end
end
