# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require "async"
require "async/barrier"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http/body/buffered"
require "msgpack"
require "json"
require "stringio"
require "uri"
require "weakref"

module Zizq
  # Low-level HTTP wrapper for the Zizq job queue server API.
  #
  # Supports both JSON and MessagePack serialization formats, determined at
  # construction time.
  #
  # HTTP requests are dispatched through a persistent background IO thread
  # when called from non-Async contexts, keeping the HTTP/2 connection alive
  # across calls and avoiding ephemeral port exhaustion. When called from
  # within an existing Async reactor, the shared HTTP client is used directly.
  class Client
    # A fully-read HTTP response (status + decoded body), safe to use outside
    # the async reactor that produced it.
    RawResponse = Data.define(:status, :body, :content_type)

    CONTENT_TYPES = { #: Hash[Zizq::format, String]
      msgpack: "application/msgpack",
      json: "application/json"
    }.freeze

    STREAM_ACCEPT = { #: Hash[Zizq::format, String]
      msgpack: "application/vnd.zizq.msgpack-stream",
      json: "application/x-ndjson"
    }.freeze

    # The base URL of the Zizq server (e.g. "https://localhost:7890")
    attr_reader :url #: String

    # The message format to use for all communication between the client and
    # the server (default = `:msgpack`).
    attr_reader :format #: Zizq::format

    # Initialize a new instance of the client with the given base URL and
    # optional format options.
    #
    # `read_timeout` and `stream_idle_timeout` are per-operation socket
    # I/O timeouts (seconds). Each individual socket read/write is
    # bounded by the timeout. The streaming `#take_jobs` endpoint uses
    # `stream_idle_timeout` because the server sends heartbeats at
    # periodic intervals which keeps the connection alive.
    #
    # @rbs url: String
    # @rbs format: Zizq::format
    # @rbs ssl_context: OpenSSL::SSL::SSLContext?
    # @rbs read_timeout: Numeric
    # @rbs stream_idle_timeout: Numeric
    # @rbs return: void
    def initialize(
      url:,
      format: :msgpack,
      ssl_context: nil,
      read_timeout: 30,
      stream_idle_timeout: 30
    )
      @url = url.chomp("/")
      @format = format

      endpoint_options = {
        protocol: Async::HTTP::Protocol::HTTP2,
        timeout: read_timeout
      } #: Hash[Symbol, untyped]
      endpoint_options[:ssl_context] = ssl_context if ssl_context

      @endpoint = Async::HTTP::Endpoint.parse(@url, **endpoint_options)

      # Streaming take uses a dedicated HTTP/1.1 endpoint. The take
      # connection is long-lived and carries only one request, so HTTP/2's
      # multiplexing, stream IDs, and frame headers add overhead with no
      # benefit — there's nothing to multiplex against. Acks/enqueues run
      # on separate threads with their own HTTP/2 clients, so they're
      # unaffected either way. HTTP/1.1 gives the stream a plain TCP
      # socket with no framing tax and measurably better throughput.
      #
      # The stream endpoint uses `stream_idle_timeout` for its socket
      # timeout so server heartbeats (~3s) keep it alive while only
      # genuinely dead connections (no data for the full window)
      # trigger a reconnect.
      stream_endpoint_options =
        endpoint_options.merge(
          protocol: Async::HTTP::Protocol::HTTP11,
          timeout: stream_idle_timeout
        )
      @stream_endpoint =
        Async::HTTP::Endpoint.parse(@url, **stream_endpoint_options)

      @mutex = Mutex.new

      @io_thread = nil #: Thread?
      @io_queue = nil #: Thread::Queue?

      # Each thread gets its own Async::HTTP::Client bound to its own
      # reactor — one for regular request/response traffic (HTTP/2) and
      # a separate one lazily created on the first take_jobs call
      # (HTTP/1.1). Both kinds of clients are tracked in a single array
      # so `close` can shut them all down together.
      @http_clients = [] #: Array[Async::HTTP::Client]
      @http_key = :"zizq_http_#{object_id}"
      @stream_http_key = :"zizq_stream_http_#{object_id}"

      @content_type = CONTENT_TYPES.fetch(format)
      @stream_accept = STREAM_ACCEPT.fetch(format)
    end

    # Close all thread-local HTTP clients and release connections.
    def close #: () -> void
      if @io_thread&.alive?
        @mutex.synchronize do
          @io_queue&.close
          @io_thread&.join
        end
      end

      self.class.make_finalizer(@io_queue, @http_clients).call
    end

    def cleanup_internal_clients #: () -> void
      @mutex.synchronize do
        @http_clients.each do |ref|
          ref.close
        rescue WeakRef::RefError
          # Client already GC'd (owning thread exited).
        rescue NoMethodError
          # The async connection pool may hold references to tasks whose
          # fibers were already reclaimed when their owning Sync reactor
          # exited. Stopping those dead tasks raises NoMethodError; safe
          # to ignore.
        end
        @http_clients.clear
      end
    end

    # Enqueue a new job.
    #
    # This is a low-level primitive that makes a direct API call to the server
    # using the Zizq API's expected inputs. Callers should generally use
    # [`Zizq::enqueue`] instead.
    #
    # Durations and timestamps are fractional seconds throughout to align with
    # Ruby, as opposed to the server's integer milliseconds representation.
    #
    # Returns a resource instance of the new job wrapping the API response.
    #
    # @rbs queue: String
    # @rbs type: String
    # @rbs payload: Hash[String | Symbol, untyped]
    # @rbs priority: Integer?
    # @rbs ready_at: Zizq::to_f?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs batch: Zizq::batch?
    # @rbs return: Resources::Job
    def enqueue(
      queue:,
      type:,
      payload:,
      priority: nil,
      ready_at: nil,
      retry_limit: nil,
      backoff: nil,
      retention: nil,
      unique_key: nil,
      unique_while: nil,
      batch: nil
    )
      body = { queue:, type:, payload: } #: Hash[Symbol, untyped]
      body[:priority] = priority if priority
      # ready_at is fractional seconds in Ruby; the server expects ms.
      body[:ready_at] = (ready_at.to_f * 1000).to_i if ready_at
      body[:retry_limit] = retry_limit if retry_limit
      body[:backoff] = wire_backoff(backoff) if backoff
      body[:retention] = wire_retention(retention) if retention
      body[:unique_key] = unique_key if unique_key
      body[:unique_while] = unique_while.to_s if unique_while
      body[:batch] = batch if batch

      response = post("/jobs", body)
      data = handle_response!(response, expected: [200, 201])
      Resources::Job.new(self, data)
    end

    # Enqueue multiple jobs atomically in a single bulk request.
    #
    # This is a low-level primitive that makes a direct API call to the server
    # using the Zizq API's expected inputs. Callers should generally use
    # [`Zizq::enqueue_bulk`] instead.
    #
    # Returns an array of resource instances wrapping the API response.
    #
    # @rbs jobs: Array[Hash[Symbol, untyped]]
    # @rbs return: Array[Resources::Job]
    def enqueue_bulk(jobs:)
      body = {
        jobs:
          jobs.map do |job|
            wire = {
              type: job[:type],
              queue: job[:queue],
              payload: job[:payload]
            } #: Hash[Symbol, untyped]
            wire[:priority] = job[:priority] if job[:priority]
            # ready_at is fractional seconds in Ruby; the server expects ms.
            wire[:ready_at] = (job[:ready_at].to_f * 1000).to_i if job[
              :ready_at
            ]
            wire[:retry_limit] = job[:retry_limit] if job[:retry_limit]
            wire[:backoff] = wire_backoff(job[:backoff]) if job[:backoff]
            wire[:retention] = wire_retention(job[:retention]) if job[
              :retention
            ]
            wire[:unique_key] = job[:unique_key] if job[:unique_key]
            wire[:unique_while] = job[:unique_while].to_s if job[:unique_while]
            wire[:batch] = job[:batch] if job[:batch]
            wire
          end
      }

      response = post("/jobs/bulk", body)
      data = handle_response!(response, expected: [200, 201])
      data["jobs"].map { |j| Resources::Job.new(self, j) }
    end

    # Get a single job by ID.
    def get_job(id) #: (String) -> Resources::Job
      response = get("/jobs/#{enc(id)}")
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # List jobs with optional filters.
    #
    # Multi-value filters (`status`, `queue`, `type`, `id`) accept arrays —
    # they are joined with commas as the server expects.
    #
    # The `filter` parameter accepts a jq expression for filtering jobs by
    # payload content (e.g. `.user_id == 42`).
    #
    # Range filters (`priority`, `attempts`, `ready_at`) accept exact values or
    # inclusive ranges.
    #
    # @rbs id: (String | Array[String])?
    # @rbs status: (String | Array[String])?
    # @rbs queue: (String | Array[String])?
    # @rbs type: (String | Array[String])?
    # @rbs filter: String?
    # @rbs priority: (Integer | Range[Integer?])?
    # @rbs ready_at: (Zizq::to_f | Range[Zizq::to_f?])?
    # @rbs attempts: (Integer | Range[Integer?])?
    # @rbs from: String?
    # @rbs order: Zizq::sort_direction?
    # @rbs limit: Integer?
    # @rbs return: Resources::JobPage
    def list_jobs(
      id: nil,
      status: nil,
      queue: nil,
      type: nil,
      filter: nil,
      priority: nil,
      ready_at: nil,
      attempts: nil,
      from: nil,
      order: nil,
      limit: nil
    )
      options = {
        id:,
        status:,
        queue:,
        type:,
        filter:,
        priority: encode_range(priority),
        ready_at: encode_range(ready_at) { |v| (v.to_f * 1000).to_i },
        attempts: encode_range(attempts),
        from:,
        order:,
        limit:
      }.compact #: Hash[Symbol, untyped]

      multi_keys = %i[id status queue type]
      params = build_where_params(options, multi_keys:)

      # An empty filter ([] or "") matches nothing — short-circuit.
      multi_keys.each do |key|
        if params[key] == ""
          return Resources::JobPage.new(self, { "jobs" => [], "pages" => {} })
        end
      end

      response = get("/jobs", params:)
      data = handle_response!(response, expected: 200)
      Resources::JobPage.new(self, data)
    end

    # Count jobs matching the given filters.
    #
    # Accepts the same filter arguments as `list_jobs` (minus pagination).
    # Returns the count as an integer.
    #
    # @rbs id: (String | Array[String])?
    # @rbs status: (String | Array[String])?
    # @rbs queue: (String | Array[String])?
    # @rbs type: (String | Array[String])?
    # @rbs filter: String?
    # @rbs priority: (Integer | Range[Integer?])?
    # @rbs ready_at: (Zizq::to_f | Range[Zizq::to_f?])?
    # @rbs attempts: (Integer | Range[Integer?])?
    # @rbs return: Integer
    def count_jobs(
      id: nil,
      status: nil,
      queue: nil,
      type: nil,
      filter: nil,
      priority: nil,
      ready_at: nil,
      attempts: nil
    )
      options = {
        id:,
        status:,
        queue:,
        type:,
        filter:,
        priority: encode_range(priority),
        ready_at: encode_range(ready_at) { |v| (v.to_f * 1000).to_i },
        attempts: encode_range(attempts)
      }.compact #: Hash[Symbol, untyped]

      multi_keys = %i[id status queue type]
      params = build_where_params(options, multi_keys:)

      # An empty filter ([] or "") matches nothing — short-circuit.
      multi_keys.each { |key| return 0 if params[key] == "" }

      response = get("/jobs/count", params:)
      data = handle_response!(response, expected: 200)
      data.fetch("count")
    end

    # Delete a single job by ID.
    #
    # @rbs id: String
    # @rbs return: void
    def delete_job(id)
      response = delete("/jobs/#{enc(id)}")
      handle_response!(response, expected: [200, 204])
      nil
    end

    # Delete jobs matching the given filters.
    #
    # Filters in the `where:` argument use the same keys as `list_jobs`. An
    # empty `where:` hash deletes all jobs.
    #
    # Returns the number of deleted jobs.
    #
    # @rbs where: Zizq::where_params
    # @rbs return: Integer
    def delete_all_jobs(where: {})
      params = filter_params(where)
      return 0 if params.nil?

      response = delete("/jobs", params:)
      data = handle_response!(response, expected: 200)
      data.fetch("deleted")
    end

    # Wipe *every* cron group and *every* job on the server.
    #
    # Equivalent to calling `delete_all_crons` followed by
    # `delete_all_jobs` (no filter), but in a single request. Useful
    # primarily as a setup/teardown step in tests where you want a
    # known-empty server between scenarios.
    #
    # **Destructive.** No filters, no escape hatch, no confirmation —
    # the server-side operation simply returns once everything is gone.
    #
    # Named `erase_all_data` rather than `reset` because `Zizq.reset!`
    # already exists at the module level for client-side SDK state.
    #
    # @rbs return: void
    def erase_all_data
      response = raw_post("/reset")
      handle_response!(response, expected: 204)
      nil
    end

    # Update a single job's mutable fields.
    #
    # Fields not provided are left unchanged. Use `Zizq::RESET` to clear
    # a nullable field back to the server default.
    #
    # Raises `Zizq::NotFoundError` if the job does not exist.
    # Raises `Zizq::ClientError` (422) if the job is in a terminal state.
    #
    # @rbs id: String
    # @rbs queue: (String | singleton(Zizq::UNCHANGED))?
    # @rbs priority: (Integer | singleton(Zizq::UNCHANGED))?
    # @rbs ready_at: (Zizq::to_f | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retry_limit: (Integer | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs backoff: (Zizq::backoff | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retention: (Zizq::retention | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs return: Resources::Job
    def update_job(
      id,
      queue: UNCHANGED,
      priority: UNCHANGED,
      ready_at: UNCHANGED,
      retry_limit: UNCHANGED,
      backoff: UNCHANGED,
      retention: UNCHANGED
    )
      body =
        build_set_body(
          queue:,
          priority:,
          ready_at:,
          retry_limit:,
          backoff:,
          retention:
        )
      response = patch("/jobs/#{enc(id)}", body)
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Update all jobs matching the given filters.
    #
    # Filters in the `where:` argument use the same keys as `list_jobs`.
    # Fields in the `apply:` argument use the same keys as `update_job`.
    #
    # Terminal jobs (completed/dead) are silently skipped unless explicitly
    # requested via `status:` in `where:`, which returns 422.
    #
    # Returns the number of updated jobs.
    #
    # @rbs where: Zizq::where_params
    # @rbs apply: Zizq::apply_params
    # @rbs return: Integer
    def update_all_jobs(where: {}, apply: {})
      params = filter_params(where)
      return 0 if params.nil?

      body = validate_and_build_set(**apply)
      response = patch("/jobs", body, params:)
      data = handle_response!(response, expected: 200)
      data.fetch("patched")
    end

    # Get a single error record by job ID and attempt number.
    #
    # @rbs id: String
    # @rbs attempt: Integer
    # @rbs return: Resources::ErrorRecord
    def get_error(id, attempt:)
      response = get("/jobs/#{enc(id)}/errors/#{enc(attempt.to_s)}")
      data = handle_response!(response, expected: 200)
      Resources::ErrorRecord.new(self, data)
    end

    # List error records for a job.
    #
    # @rbs id: String
    # @rbs from: String?
    # @rbs order: Zizq::sort_direction?
    # @rbs limit: Integer?
    # @rbs return: Resources::ErrorPage
    def list_errors(id, from: nil, order: nil, limit: nil)
      params = { from:, order:, limit: }.compact #: Hash[Symbol, untyped]
      response = get("/jobs/#{enc(id)}/errors", params:)
      data = handle_response!(response, expected: 200)
      Resources::ErrorPage.new(self, data)
    end

    # Health check.
    def health #: () -> Hash[String, untyped]
      response = get("/health")
      handle_response!(response, expected: 200)
    end

    # Server version string.
    def server_version #: () -> String
      response = get("/version")
      data = handle_response!(response, expected: 200)
      data["version"]
    end

    # List all distinct queue names on the server.
    def get_queues #: () -> Array[String]
      response = get("/queues")
      data = handle_response!(response, expected: 200)
      data["queues"]
    end

    # List every defined budget, with its policy.
    #
    # Requires a Pro license on the server, else a `Zizq::ClientError`
    # is raised.
    #
    # @rbs return: Array[Zizq::Resources::Budget]
    def list_budgets
      response = get("/budgets")
      data = handle_response!(response, expected: 200)
      (data["budgets"] || []).map { |b| Resources::Budget.new(self, b) }
    end

    # Fetch one budget's policy.
    #
    # Raises `Zizq::NotFoundError` if no budget exists under this key.
    #
    # @rbs key: String
    # @rbs return: Zizq::Resources::Budget
    def get_budget(key)
      response = get("/budgets/#{enc(key)}")
      data = handle_response!(response, expected: 200)
      Resources::Budget.new(self, data)
    end

    # Create a budget, raising if the key would be overwritten.
    #
    # Raises a `Zizq::ConflictError` (409) if a budget already
    # exists under this key, leaving the stored policy untouched.
    #
    # See `#put_budget` for the version that would overwrite the existing
    # key.
    #
    # `strategy` is one of:
    #
    #     { type: :time_based, duration: 60 }
    #     { type: :time_based, duration: 60, burst: 5 }
    #     { type: :while_in_flight }
    #
    # `duration` is fractional seconds and is also read back as fractional
    # seconds.
    #
    # A newly created bucket starts full, so a budget with no burst set
    # hands out an entire allocation the moment work arrives and only
    # then settles to its continuous drip rate — `10` per minute really
    # does permit twenty in the first minute. Setting a burst caps that
    # spike without changing the long-run rate; a burst of `1` paces
    # dispatches evenly at all times. The burst rule also applies to
    # budgets that have not been consumed for an entire duration's worth
    # of time.
    #
    # It is valid for `burst` to be set higher than the `allocation`. In
    # this case the meaning is to continue filling the bucket after the
    # duration has elapsed, so a `burst` of 200 on a 100 token allocation
    # would continue accruing across two consecutive periods, but no more
    # than that.
    #
    # This is designed to allow applications to absorb short-lived
    # spikes.
    #
    # @rbs key: String
    # @rbs allocation: Integer
    # @rbs strategy: Zizq::budget_strategy
    # @rbs return: Zizq::Resources::Budget
    def create_budget(key, allocation:, strategy:)
      body = { allocation:, strategy: wire_strategy(strategy) }
      response = post("/budgets/#{enc(key)}", body)
      data = handle_response!(response, expected: 201)
      Resources::Budget.new(self, data)
    end

    # Create a budget, or replace an existing budgets policy outright.
    #
    # Unlike `create_budget` this never conflicts. `created_at` is
    # preserved when the budget already exists — a replace changes the
    # policy, not the budget's identity.
    #
    # Raises a `Zizq::ClientError` (422) if the new allocation is below
    # a cost already committed to the budget by a queued job or a cron
    # entry, since those could then never be afforded.
    #
    # `strategy` takes the same shape as `create_budget`.
    #
    # @rbs key: String
    # @rbs allocation: Integer
    # @rbs strategy: Zizq::budget_strategy
    # @rbs return: Zizq::Resources::Budget
    def put_budget(key, allocation:, strategy:)
      body = { allocation:, strategy: wire_strategy(strategy) }
      response = put("/budgets/#{enc(key)}", body)
      data = handle_response!(response, expected: 200)
      Resources::Budget.new(self, data)
    end

    # Update specified fields of a budget's policy, leaving the rest
    # unchanged.
    #
    # Follows JSON merge patch semantics, and recurses into `strategy`, so
    # e.g. the burst can be changed without restating the type and period:
    #
    #     update_budget("emails", strategy: {burst: 5})
    #
    # Within `strategy`, an absent field is left alone and `burst: nil`
    # clears it back to the default value of the allocation. `burst` is
    # the only field with a meaningful "unset": a strategy with no type, or
    # a `time_based` strategy with no period, is not a valid strategy.
    #
    # Raises `Zizq::NotFoundError` if no budget exists under this key.
    #
    # @rbs key: String
    # @rbs allocation: Integer?
    # @rbs strategy: Zizq::budget_strategy_patch?
    # @rbs return: Zizq::Resources::Budget
    def update_budget(key, allocation: nil, strategy: nil)
      body = {
        allocation:,
        strategy: strategy && wire_strategy(strategy)
      }.compact
      response = patch("/budgets/#{enc(key)}", body)
      data = handle_response!(response, expected: 200)
      Resources::Budget.new(self, data)
    end

    # Delete a budget.
    #
    # Raises `Zizq::NotFoundError` if no budget exists under this key.
    #
    # Raises a `Zizq::ConflictError` (409) while anything still
    # references it.
    #
    # @rbs key: String
    # @rbs return: void
    def delete_budget(key)
      response = delete("/budgets/#{enc(key)}")
      handle_response!(response, expected: 204)
      nil
    end

    # Replace the whole set of budgets a job is bound to.
    #
    # Budgets omitted from `budgets` will be unbound. Passing `[]` is
    # the same as `clear_job_budgets`.
    #
    # Only queued (scheduled, ready) jobs may have their budgets changed —
    # an in-flight job already debited tokens against its budgets, and
    # jobs in a terminal state are immutable to all further changes.
    # Either raises a `Zizq::ClientError` (422).
    #
    # Requires a Pro license on the server, else a `Zizq::ClientError`
    # (403) is raised.
    #
    # @rbs id: String
    # @rbs budgets: Array[Zizq::budget_binding]
    # @rbs return: Resources::Job
    def replace_job_budgets(id, budgets:)
      body = { budgets: budgets.map { |b| wire_binding(b) } }
      response = put("/jobs/#{enc(id)}/budgets", body)
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Unbind every budget from a job, leaving it unthrottled.
    #
    # @rbs id: String
    # @rbs return: Resources::Job
    def clear_job_budgets(id)
      response = delete("/jobs/#{enc(id)}/budgets")
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Bind a job to a budget it is not already bound to.
    #
    # Raises a `Zizq::ConflictError` (409) if the job is already bound
    # to this budget, leaving the existing binding untouched — use
    # `put_job_budget` to replace it, or `update_job_budget` to change
    # only its cost.
    #
    # `create_with` declares the budget's policy should it not exist
    # yet, binding and creating in one atomic call. It is ignored when
    # the budget already exists.
    #
    # @rbs id: String
    # @rbs key: String
    # @rbs cost: Integer?
    # @rbs create_with: Zizq::budget_policy?
    # @rbs return: Resources::Job
    def add_job_budget(id, key, cost: nil, create_with: nil)
      body = binding_body(cost:, create_with:)
      response = post("/jobs/#{enc(id)}/budgets/#{enc(key)}", body)
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Bind a job to a budget, replacing any existing binding to it.
    #
    # Unlike `add_job_budget` this never conflicts. The binding is
    # replaced whole, so a `cost` left unset returns to the default of 1
    # rather than keeping what was there.
    #
    # @rbs id: String
    # @rbs key: String
    # @rbs cost: Integer?
    # @rbs create_with: Zizq::budget_policy?
    # @rbs return: Resources::Job
    def put_job_budget(id, key, cost: nil, create_with: nil)
      body = binding_body(cost:, create_with:)
      response = put("/jobs/#{enc(id)}/budgets/#{enc(key)}", body)
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Change what an existing binding costs, leaving the rest alone.
    #
    # Raises `Zizq::NotFoundError` if the job is not bound to this
    # budget. Unlike `put_job_budget`, a change of cost has nothing to
    # apply to and does not create the binding if missing.
    #
    # Raises a `Zizq::ClientError` (422) if the new cost exceeds the
    # budget's capacity.
    #
    # @rbs id: String
    # @rbs key: String
    # @rbs cost: Integer
    # @rbs return: Resources::Job
    def update_job_budget(id, key, cost:)
      response = patch("/jobs/#{enc(id)}/budgets/#{enc(key)}", { cost: })
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Unbind one budget from a job, leaving its other budgets alone.
    #
    # Raises `Zizq::NotFoundError` if the job is not bound to it.
    #
    # @rbs id: String
    # @rbs key: String
    # @rbs return: Resources::Job
    def delete_job_budget(id, key)
      response = delete("/jobs/#{enc(id)}/budgets/#{enc(key)}")
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Bind every job matching the filter to a budget, skipping over the
    # ones that are already bound to it.
    #
    # The bulk form of `add_job_budget`; each of these takes the same
    # name with `job` widened to `all_jobs`.
    #
    # Filters in the `where:` argument use the same keys as `list_jobs`.
    # An unfiltered call binds every queued job on the server.
    #
    # Unlike the single-job form this does not conflict but simply
    # skips.
    #
    # @rbs key: String
    # @rbs where: Zizq::where_params
    # @rbs cost: Integer?
    # @rbs create_with: Zizq::budget_policy?
    # @rbs return: Zizq::bulk_budget_change
    def add_all_jobs_budget(key, where: {}, cost: nil, create_with: nil)
      bulk_budget_request(
        :post,
        "/jobs/budgets/#{enc(key)}",
        where,
        binding_body(cost:, create_with:)
      )
    end

    # Bind every job matching the filter to a budget, replacing any
    # existing binding to it.
    #
    # See `add_all_jobs_budget` for the filter semantics, and
    # `put_job_budget` for how a binding is replaced.
    #
    # @rbs key: String
    # @rbs where: Zizq::where_params
    # @rbs cost: Integer?
    # @rbs create_with: Zizq::budget_policy?
    # @rbs return: Zizq::bulk_budget_change
    def put_all_jobs_budget(key, where: {}, cost: nil, create_with: nil)
      bulk_budget_request(
        :put,
        "/jobs/budgets/#{enc(key)}",
        where,
        binding_body(cost:, create_with:)
      )
    end

    # Change what an existing binding costs, across every job matching
    # the filter. Jobs not bound to this budget are skipped.
    #
    # The bulk form of `update_job_budget`.
    #
    # Raises a `Zizq::ClientError` (422) if the new cost exceeds the
    # budget's capacity.
    #
    # @rbs key: String
    # @rbs cost: Integer
    # @rbs where: Zizq::where_params
    # @rbs return: Zizq::bulk_budget_change
    def update_all_jobs_budget(key, cost:, where: {})
      bulk_budget_request(:patch, "/jobs/budgets/#{enc(key)}", where, { cost: })
    end

    # Unbind one budget from every job matching the filter, leaving
    # their other budgets alone. The bulk form of `delete_job_budget`.
    #
    # This is the way to drain a budget before deleting it, since
    # `delete_budget` refuses while anything is still bound to it.
    #
    # @rbs key: String
    # @rbs where: Zizq::where_params
    # @rbs return: Zizq::bulk_budget_change
    def delete_all_jobs_budget(key, where: {})
      bulk_budget_request(:delete, "/jobs/budgets/#{enc(key)}", where, nil)
    end

    # Unbind *every* budget from every job matching the filter. The
    # bulk form of `clear_job_budgets`.
    #
    # Beware: An unfiltered call leaves every queued job on the server
    # unthrottled — include a filter unless that is the intent.
    #
    # @rbs where: Zizq::where_params
    # @rbs return: Zizq::bulk_budget_change
    def clear_all_jobs_budgets(where: {})
      bulk_budget_request(:delete, "/jobs/budgets", where, nil)
    end

    # List all cron group names.
    #
    # @rbs return: Array[String]
    def list_cron_groups
      response = get("/crons")
      data = handle_response!(response, expected: 200)
      data["crons"]
    end

    # Fetch a cron group and all its entries.
    #
    # @rbs name: String
    # @rbs return: Resources::CronGroup
    def get_cron_group(name)
      response = get("/crons/#{enc(name)}")
      data = handle_response!(response, expected: 200)
      Resources::CronGroup.new(self, data)
    end

    # Create or replace an entire cron group.
    #
    # Entries not present in the request are removed. Entries with unchanged
    # expressions preserve their scheduling state.
    #
    # The timezone applies to every entry that does not specify one of its
    # own. Since this replaces the group in full, omitting it clears whatever
    # the group had.
    #
    # @rbs name: String
    # @rbs paused: bool?
    # @rbs timezone: String?
    # @rbs entries: Array[Zizq::cron_entry_params]
    # @rbs return: Resources::CronGroup
    def replace_cron_group(name, paused: nil, timezone: nil, entries: [])
      body = {
        paused:,
        timezone:,
        entries: entries.map { |entry| build_cron_entry(**entry) }
      }.compact
      response = put("/crons/#{enc(name)}", body)
      data = handle_response!(response, expected: 200)
      Resources::CronGroup.new(self, data)
    end

    # Update group-level fields (currently just pause/unpause).
    #
    # @rbs name: String
    # @rbs paused: bool?
    # @rbs return: Resources::CronGroup
    def update_cron_group(name, paused: nil)
      response = patch("/crons/#{enc(name)}", { paused: }.compact)
      data = handle_response!(response, expected: 200)
      Resources::CronGroup.new(self, data)
    end

    # Delete a cron group and all its entries.
    #
    # @rbs name: String
    # @rbs return: void
    def delete_cron_group(name)
      response = delete("/crons/#{enc(name)}")
      handle_response!(response, expected: 204)
      nil
    end

    # Delete every cron group on the server in a single call.
    #
    # Returns the number of cron groups removed.
    #
    # **Destructive.** This deletes *every cron group on the server*.
    # For granular deletes, use `delete_cron_group` with a specific
    # name.
    #
    # Requires a Pro license on the server.
    #
    # @rbs return: Integer
    def delete_all_crons
      response = delete("/crons")
      data = handle_response!(response, expected: 200)
      data.fetch("deleted")
    end

    # Fetch a single cron entry.
    #
    # @rbs group: String
    # @rbs entry: String
    # @rbs return: Resources::CronEntry
    def get_cron_group_entry(group, entry)
      response = get("/crons/#{enc(group)}/entries/#{enc(entry)}")
      data = handle_response!(response, expected: 200)
      Resources::CronEntry.new(self, data)
    end

    # Add a single entry to a cron group (creates the group if needed).
    #
    # Raises a `Zizq::ConflictError` (409) if an entry with the same name
    # already exists.
    #
    # @rbs group: String
    # @rbs name: String
    # @rbs expression: String
    # @rbs job: Zizq::cron_job_params
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs return: Resources::CronEntry
    def add_cron_group_entry(
      group,
      name:,
      expression:,
      job:,
      timezone: nil,
      paused: nil
    )
      body = build_cron_entry(name:, expression:, job:, timezone:, paused:)
      response = post("/crons/#{enc(group)}/entries", body)
      data = handle_response!(response, expected: 201)
      Resources::CronEntry.new(self, data)
    end

    # Create or replace a single cron entry.
    #
    # Preserves scheduling state if the expression is unchanged.
    #
    # @rbs group: String
    # @rbs entry: String
    # @rbs expression: String
    # @rbs job: Zizq::cron_job_params
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs return: Resources::CronEntry
    def replace_cron_group_entry(
      group,
      entry,
      expression:,
      job:,
      timezone: nil,
      paused: nil
    )
      body =
        build_cron_entry(name: entry, expression:, job:, timezone:, paused:)
      response = put("/crons/#{enc(group)}/entries/#{enc(entry)}", body)
      data = handle_response!(response, expected: 200)
      Resources::CronEntry.new(self, data)
    end

    # Update entry-level fields (currently just pause/unpause).
    #
    # @rbs group: String
    # @rbs entry: String
    # @rbs paused: bool
    # @rbs return: Resources::CronEntry
    def update_cron_group_entry(group, entry, paused:)
      response =
        patch("/crons/#{enc(group)}/entries/#{enc(entry)}", { paused: })
      data = handle_response!(response, expected: 200)
      Resources::CronEntry.new(self, data)
    end

    # Delete a single cron entry.
    #
    # @rbs group: String
    # @rbs entry: String
    # @rbs return: void
    def delete_cron_group_entry(group, entry)
      response = delete("/crons/#{enc(group)}/entries/#{enc(entry)}")
      handle_response!(response, expected: 204)
      nil
    end

    # Mark a job as successfully completed (ack).
    #
    # If this method (or [`#report_failure`]) is not called upon job
    # completion, the Zizq server will consider it in-flight and will not
    # send any more jobs if the prefetch limit has been reached, or the
    # server's global in-flight limit has been reached. Jobs must be either
    # acknowledged or failed before new jobs are sent.
    #
    # Jobs are durable and "at least once" delivery is guaranteed. If the
    # client disconnects before it is able to report success or failure the
    # server automatically moves the job back to the queue where it will be
    # provided to another worker. Clients should be prepared to see the same
    # job more than once for this reason.
    #
    # The Zizq server sends heartbeat messages to connected workers so that
    # it can quickly detect and handle disconnected clients.
    def report_success(id) #: (String) -> nil
      response = raw_post("/jobs/#{enc(id)}/success")
      handle_response!(response, expected: 204)
      nil
    end

    # Bulk-mark jobs as successfully completed (bulk ack).
    #
    # See [`#report_success`] for full details of how acknowledgemen works.
    #
    # There are two ways in which the server can respond successfully:
    #
    # 1. 204 - No Content (All jobs acknowledged)
    # 2. 422 - Unprocessible Entity (Some jobs were not found)
    #
    # Both of these statuses are in reality treated as success because missing
    # jobs have either been previously acknowledged and purged, or moved to
    # some other status that cannot be acknowledged.
    #
    # Other error response types will still raise.
    #
    # @rbs ids: Array[String]
    # @rbs return: nil
    def report_success_bulk(ids)
      response = post("/jobs/success", { ids: ids })
      return nil if response.status == 422
      handle_response!(response, expected: 204)
    end

    alias ack_bulk report_success_bulk

    # Report a job failure (nack).
    #
    # Returns the updated job metadata.
    #
    # If this method is not called when errors occur processing jobs, the
    # Zizq server will consider it in-flight and will not send any more jobs
    # if the prefetch limit has been reached, or the server's global in-flight
    # limit has been reached. Jobs must be either acknowledged or failed before
    # new jobs are sent.
    #
    # Jobs are durable and "at least once" delivery is guaranteed. If the
    # client disconnects before it is able to report success or failure the
    # server automatically moves the job back to the queue where it will be
    # provided to another worker. Clients should be prepared to see the same
    # job more than once for this reason.
    #
    # The Zizq server sends heartbeat messages to connected workers so that
    # it can quickly detect and handle disconnected clients.
    #
    # @rbs id: String
    # @rbs message: String
    # @rbs error_type: String?
    # @rbs backtrace: String?
    # @rbs retry_at: Float?
    # @rbs kill: bool
    # @rbs return: Resources::Job
    def report_failure(
      id,
      message:,
      error_type: nil,
      backtrace: nil,
      retry_at: nil,
      kill: false
    )
      body = { message: } #: Hash[Symbol, untyped]
      body[:error_type] = error_type if error_type
      body[:backtrace] = backtrace if backtrace
      # retry_at is fractional seconds in Ruby; the server expects ms.
      body[:retry_at] = (retry_at * 1000).to_i if retry_at
      body[:kill] = kill if kill

      response = post("/jobs/#{enc(id)}/failure", body)
      data = handle_response!(response, expected: 200)
      Resources::Job.new(self, data)
    end

    # Aliases for ack/nack vs report_success/report_failure.
    alias ack report_success
    alias nack report_failure

    # Stream jobs from the server. Yields parsed job hashes.
    #
    # This method does not return unless the server closes the connection or
    # the connection is otherwise interrupted. Jobs are continuously streamed
    # to the client, and when no jobs are available the client waits for new
    # jobs to become ready.
    #
    # If the client does not acknowledge or fail jobs with `[#report_success`]
    # or [`#report_failure`] the server will stop sending new jobs to the
    # client as it hits its prefetch limit.
    #
    # Jobs are durable and "at least once" delivery is guaranteed. If the
    # client disconnects before it is able to report success or failure the
    # server automatically moves the job back to the queue where it will be
    # provided to another worker. Clients should be prepared to see the same
    # job more than once for this reason.
    #
    # The Zizq server sends periodic heartbeat messages to the client which are
    # silently consumed.
    #
    # Example:
    #
    #    client.take_jobs(prefetch: 5) do |job|
    #      puts "Got job: #{job.inspect}"
    #      client.ack(job.id) # mark the job completed
    #    end
    #
    # @rbs prefetch: Integer
    # @rbs queues: Array[String]
    # @rbs worker_id: String?
    # @rbs &block: (Resources::Job) -> void
    # @rbs return: void
    def take_jobs(
      prefetch: 1,
      queues: [],
      worker_id: nil,
      on_connect: nil,
      on_response: nil,
      &block
    )
      raise ArgumentError, "take_jobs requires a block" unless block

      params = { prefetch: } #: Hash[Symbol, untyped]
      params[:queue] = queues.join(",") unless queues.empty?

      path = build_path("/jobs/take", params:)
      headers = { "accept" => @stream_accept }
      headers["worker-id"] = worker_id if worker_id

      Sync do
        response = stream_http.get(path, headers)

        begin
          unless response.status == 200
            raise StreamError,
                  "take jobs stream returned HTTP #{response.status}"
          end
          on_connect&.call
          on_response&.call(response)

          # Wrap each parsed hash in a Resources::Job before yielding.
          wrapper = proc { |data| block.call(Resources::Job.new(self, data)) }

          # async-http returns `nil` for empty response bodies over HTTP/1.1
          # (e.g. a 200 with content-length: 0 from the server closing the
          # stream immediately). Treat that as "no chunks" rather than
          # crashing in the parser.
          body = response.body || []

          case @format
          when :json
            self.class.parse_ndjson(body, &wrapper)
          when :msgpack
            self.class.parse_msgpack_stream(body, &wrapper)
          end
        ensure
          begin
            response.close
          rescue StandardError
            nil
          end
        end
      end
    rescue SocketError,
           IOError,
           EOFError,
           Errno::ECONNRESET,
           Errno::EPIPE,
           IO::TimeoutError,
           OpenSSL::SSL::SSLError => e
      raise ConnectionError, e.message
    end

    # Parse an NDJSON stream from an enumerable of byte chunks.
    #
    # Buffers chunks and splits on newline boundaries. The buffer only
    # ever holds one partial line between extractions, so the `slice!`
    # cost is trivial. Empty lines (heartbeats) are silently skipped.
    def self.parse_ndjson(chunks) #: (Enumerable[String]) { (Hash[String, untyped]) -> void } -> void
      buffer = +""
      chunks.each do |chunk|
        buffer << chunk
        while (idx = buffer.index("\n"))
          line = buffer.slice!(0, idx + 1) #: String
          line.strip!
          next if line.empty?
          yield JSON.parse(line)
        end
      end
    end

    # Parse a length-prefixed MessagePack stream from an enumerable of byte
    # chunks.
    #
    # Format: [4-byte big-endian length][MsgPack payload].
    # A zero-length frame is a heartbeat and is silently skipped.
    #
    # Uses StringIO for efficient position-based reading rather than
    # repeatedly slicing from the front of a String (which copies all
    # remaining bytes on every extraction).
    def self.parse_msgpack_stream(chunks) #: (Enumerable[String]) { (Hash[String, untyped]) -> void } -> void
      io = StringIO.new("".b)

      chunks.each do |chunk|
        # Append new data at the end, then return to the read position.
        read_pos = io.pos
        io.seek(0, IO::SEEK_END)
        io.write(chunk.b)
        io.seek(read_pos)

        # Extract complete frames.
        while io.size - io.pos >= 4
          len_bytes = io.read(4) #: String
          len = len_bytes.unpack1("N") #: Integer

          if len == 0 # heartbeat
            next
          end

          if io.size - io.pos < len
            # Incomplete frame — rewind past the length header and wait
            # for more data.
            io.seek(-4, IO::SEEK_CUR)
            break
          end

          yield MessagePack.unpack(io.read(len))
        end

        # Compact: discard already-consumed bytes so the StringIO doesn't
        # grow without bound over the life of the stream.
        remaining = io.read
        io = StringIO.new(remaining || "".b)
      end
    end

    # GET a path on the server and return the decoded response body.
    #
    # The path should include any query parameters already (e.g. pagination
    # links from the server's `pages` object). This is intentionally public
    # so that resource objects like Page can follow links without resorting
    # to `.send`.
    def get_path(path) #: (String) -> Hash[String, untyped]
      response =
        request do |http|
          consume_response(http.get(path, { "accept" => @content_type }))
        end
      handle_response!(response, expected: 200)
    end

    private

    # URL-encode a single path segment.
    def enc(value) #: (String) -> String
      URI.encode_uri_component(value)
    end

    # Build a relative path with optional query parameters.
    def build_path(path, params: {}) #: (String, ?params: Hash[Symbol, untyped]) -> String
      path = "#{path}?#{URI.encode_www_form(params)}" unless params.empty?
      path
    end

    # Validate and build a cron entry body from keyword arguments.
    #
    # @rbs name: String
    # @rbs expression: String
    # @rbs job: Zizq::cron_job_params
    # @rbs timezone: String?
    # @rbs paused: bool?
    # @rbs return: Hash[Symbol, untyped]
    def build_cron_entry(
      name: nil,
      expression: nil,
      job: nil,
      timezone: nil,
      paused: nil
    )
      {
        name:,
        expression:,
        timezone:,
        paused:,
        job: build_cron_job(**job)
      }.compact
    end

    # Validate and build a cron job template from keyword arguments.
    #
    # Uses keyword args so that unknown keys raise ArgumentError.
    #
    # @rbs type: String
    # @rbs queue: String
    # @rbs payload: untyped
    # @rbs priority: Integer?
    # @rbs retry_limit: Integer?
    # @rbs backoff: Zizq::backoff?
    # @rbs retention: Zizq::retention?
    # @rbs unique_key: String?
    # @rbs unique_while: Zizq::unique_scope?
    # @rbs batch: Zizq::batch?
    # @rbs return: Hash[Symbol, untyped]
    def build_cron_job(
      type: nil,
      queue: nil,
      payload: nil,
      priority: nil,
      retry_limit: nil,
      backoff: nil,
      retention: nil,
      unique_key: nil,
      unique_while: nil,
      batch: nil
    )
      job = { type:, queue:, payload: } #: Hash[Symbol, untyped]
      job[:priority] = priority if priority
      job[:retry_limit] = retry_limit if retry_limit
      job[:backoff] = wire_backoff(backoff) if backoff
      job[:retention] = wire_retention(retention) if retention
      job[:unique_key] = unique_key if unique_key
      job[:unique_while] = unique_while.to_s if unique_while
      job[:batch] = batch if batch
      job
    end

    # Validate and normalize filter parameters for bulk operations.
    #
    # Uses keyword arguments so that unknown keys raise ArgumentError.
    #
    # @rbs id: (String | Array[String])?
    # @rbs status: (String | Array[String])?
    # @rbs queue: (String | Array[String])?
    # @rbs type: (String | Array[String])?
    # @rbs filter: String?
    # @rbs priority: (Integer | Range[Integer?])?
    # @rbs ready_at: (Zizq::to_f | Range[Zizq::to_f?])?
    # @rbs attempts: (Integer | Range[Integer?])?
    # @rbs return: Hash[Symbol, untyped]
    def validate_where(
      id: nil,
      status: nil,
      queue: nil,
      type: nil,
      filter: nil,
      priority: nil,
      ready_at: nil,
      attempts: nil
    )
      {
        id:,
        status:,
        queue:,
        type:,
        filter:,
        priority: encode_range(priority),
        ready_at: encode_range(ready_at) { |v| (v.to_f * 1000).to_i },
        attempts: encode_range(attempts)
      }.compact
    end

    # Encode an Integer or Range filter into the server's query format.
    #
    # Accepted shapes:
    #
    # - `nil` -> `nil` (no filter sent)
    # - `Integer` -> `"N"` (single value)
    # - `(a..b)` -> `"A..B"` (inclusive both ends)
    # - `(a..)` -> `"A.."` (lower bound only)
    # - `(..b)` -> `"..B"` (upper bound only)
    #
    # Exclusive ranges (`a...b`, `a...`, `...b`) raise `ArgumentError` — the
    # server only supports inclusive bounds. A bound transformation block can
    # convert values before formatting (e.g. seconds -> ms for `ready_at`).
    #
    # @rbs value: untyped
    # @rbs &block: ?(untyped) -> Integer
    # @rbs return: String?
    def encode_range(value, &block)
      block ||= ->(v) { v.to_i }

      case value
      when nil
        nil
      when Range
        if value.exclude_end?
          raise ArgumentError,
                "exclusive ranges are not supported by the server; use an inclusive range (a..b) instead"
        end
        "#{value.begin&.then(&block)}..#{value.end&.then(&block)}"
      else
        block.call(value).to_s
      end
    end

    # Validate set parameters via keyword args (rejects unknown keys) and
    # build the JSON body. Used by `update_all_jobs`.
    #
    # @rbs queue: (String | singleton(Zizq::UNCHANGED))?
    # @rbs priority: (Integer | singleton(Zizq::UNCHANGED))?
    # @rbs ready_at: (Zizq::to_f | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retry_limit: (Integer | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs backoff: (Zizq::backoff | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs retention: (Zizq::retention | singleton(Zizq::RESET) | singleton(Zizq::UNCHANGED))?
    # @rbs return: Hash[Symbol, untyped]
    def validate_and_build_set(
      queue: UNCHANGED,
      priority: UNCHANGED,
      ready_at: UNCHANGED,
      retry_limit: UNCHANGED,
      backoff: UNCHANGED,
      retention: UNCHANGED
    )
      build_set_body(
        queue:,
        priority:,
        ready_at:,
        retry_limit:,
        backoff:,
        retention:
      )
    end

    # Build the JSON body hash for a PATCH request from set parameters.
    #
    # - `UNCHANGED` values are omitted (field not sent).
    # - `RESET` values are sent as `nil` (JSON null).
    # - `nil` is rejected — use `RESET` to clear a field.
    # - Other values are converted to their wire format.
    #
    # @rbs return: Hash[Symbol, untyped]
    def build_set_body(
      queue: UNCHANGED,
      priority: UNCHANGED,
      ready_at: UNCHANGED,
      retry_limit: UNCHANGED,
      backoff: UNCHANGED,
      retention: UNCHANGED
    )
      body = {} #: Hash[Symbol, untyped]

      unless queue.equal?(UNCHANGED)
        if queue.nil?
          raise ArgumentError,
                "queue cannot be nil; use Zizq::RESET to clear or Zizq::UNCHANGED to leave as-is"
        end
        body[:queue] = queue
      end

      unless priority.equal?(UNCHANGED)
        if priority.nil?
          raise ArgumentError,
                "priority cannot be nil; use Zizq::RESET to clear or Zizq::UNCHANGED to leave as-is"
        end
        body[:priority] = priority
      end

      unless ready_at.equal?(UNCHANGED)
        body[:ready_at] = (
          if ready_at.equal?(RESET)
            nil
          else
            (ready_at.to_f * 1000).to_i
          end
        )
      end

      unless retry_limit.equal?(UNCHANGED)
        body[:retry_limit] = retry_limit.equal?(RESET) ? nil : retry_limit
      end

      unless backoff.equal?(UNCHANGED)
        body[:backoff] = backoff.equal?(RESET) ? nil : wire_backoff(backoff)
      end

      unless retention.equal?(UNCHANGED)
        body[:retention] = if retention.equal?(RESET)
          nil
        else
          wire_retention(retention)
        end
      end

      body
    end

    # Convert a `Zizq::backoff` (fractional seconds) into the server's form
    # (integer milliseconds under keys suffixed `_ms`).
    #
    # @rbs backoff: Zizq::backoff
    # @rbs return: Hash[Symbol, untyped]
    def wire_backoff(backoff)
      {
        exponent: backoff[:exponent].to_f,
        base_ms: (backoff[:base].to_f * 1000).to_i,
        jitter_ms: (backoff[:jitter].to_f * 1000).to_i
      }
    end

    # Convert a `Zizq::retention` (fractional seconds) into the server's form
    # (integer milliseconds under keys suffixed `_ms`). Both fields are
    # optional.
    #
    # @rbs retention: Zizq::retention
    # @rbs return: Hash[Symbol, Integer]
    def wire_retention(retention)
      wire = {} #: Hash[Symbol, Integer]
      wire[:completed_ms] = (
        retention[:completed].to_f * 1000
      ).to_i if retention[:completed]
      wire[:dead_ms] = (retention[:dead].to_f * 1000).to_i if retention[:dead]
      wire
    end

    # Build the body for a single binding, where the budget key travels
    # in the path rather than the body.
    #
    # @rbs cost: Integer?
    # @rbs create_with: Zizq::budget_policy?
    # @rbs return: Hash[Symbol, untyped]
    def binding_body(cost:, create_with:)
      body = {} #: Hash[Symbol, untyped]
      body[:cost] = cost if cost
      body[:create_with] = wire_policy(create_with) if create_with
      body
    end

    # Convert a `Zizq::budget_binding` into the wire form, key included.
    #
    # @rbs binding: Zizq::budget_binding
    # @rbs return: Hash[Symbol, untyped]
    def wire_binding(binding)
      { key: binding[:key] }.merge(
        binding_body(cost: binding[:cost], create_with: binding[:create_with])
      )
    end

    # Convert a `Zizq::budget_policy` into the wire form.
    #
    # @rbs policy: Zizq::budget_policy
    # @rbs return: Hash[Symbol, untyped]
    def wire_policy(policy)
      {
        allocation: policy[:allocation],
        strategy: wire_strategy(policy[:strategy])
      }
    end

    # Send one of the bulk job-budget requests and read its result.
    #
    # `body` is `nil` for the two that carry none, which are sent as
    # `DELETE` with the filter in the query string.
    #
    # @rbs method: Symbol
    # @rbs path: String
    # @rbs where: Zizq::where_params
    # @rbs body: Hash[Symbol, untyped]?
    # @rbs return: Zizq::bulk_budget_change
    def bulk_budget_request(method, path, where, body)
      params = filter_params(where)

      # An empty multi-value filter matches nothing — short-circuit
      # rather than send a request that would match everything.
      return { changed: 0, blocked: [] } if params.nil?

      response =
        case method
        when :post
          post(build_path(path, params:), body || {})
        when :put
          put(build_path(path, params:), body || {})
        when :patch
          patch(path, body || {}, params:)
        else
          delete(path, params:)
        end
      data = handle_response!(response, expected: 200)
      { changed: data.fetch("changed"), blocked: data.fetch("blocked") }
    end

    # Validate a `where:` filter and build its query params.
    #
    # Returns `nil` when a multi-value filter is present but empty,
    # which matches nothing — callers short-circuit rather than send a
    # request that would match everything instead.
    #
    # @rbs where: Zizq::where_params
    # @rbs return: Hash[Symbol, untyped]?
    def filter_params(where)
      multi_keys = %i[id status queue type]
      params = build_where_params(validate_where(**where), multi_keys:)
      return nil if multi_keys.any? { |key| params[key] == "" }

      params
    end

    # Convert a budget strategy into the wire form — the period as
    # integer milliseconds under `duration_ms`, and the kind as a
    # string. A `while_in_flight` strategy carries neither field.
    #
    # Takes the merge-patch shape, which a whole `Zizq::budget_strategy`
    # also satisfies, so `create_budget` and `update_budget` share this.
    # Key presence is what the server reads either way: a field absent
    # from a patch is absent from the body and left alone, while an
    # explicit `burst: nil` is sent as JSON null and clears the burst.
    # That is why `burst` is tested with `key?` rather than for truth.
    #
    # @rbs strategy: Zizq::budget_strategy_patch
    # @rbs return: Hash[Symbol, untyped]
    def wire_strategy(strategy)
      wire = {} #: Hash[Symbol, untyped]
      wire[:type] = strategy[:type].to_s if strategy[:type]
      if (duration = strategy[:duration])
        wire[:duration_ms] = (duration.to_f * 1000).to_i
      end
      wire[:burst] = strategy[:burst] if strategy.key?(:burst)
      wire
    end

    # Build query params for list endpoints, joining multi-value keys with ",".
    def build_where_params(options, multi_keys: []) #: (Hash[Symbol, untyped], ?multi_keys: Array[Symbol]) -> Hash[Symbol, untyped]
      params = {} #: Hash[Symbol, untyped]
      options.each do |key, value|
        if multi_keys.include?(key) && value.is_a?(Array)
          params[key] = value.join(",")
        else
          params[key] = value
        end
      end
      params
    end

    def encode_body(body) #: (Hash[Symbol, untyped]) -> String
      case @format
      when :msgpack
        MessagePack.pack(body)
      when :json
        JSON.generate(body)
      else
        raise ArgumentError, "Unknown format: #{@format}"
      end
    end

    def decode_body(data, content_type: nil) #: (String, ?content_type: String?) -> Hash[String, untyped]
      format =
        case content_type
        when /msgpack/
          :msgpack
        when /json/
          :json
        else
          @format
        end
      case format
      when :msgpack
        MessagePack.unpack(data)
      when :json
        JSON.parse(data)
      else
        raise ArgumentError, "Unknown format: #{format}"
      end
    end

    # Dispatch a block to the appropriate execution context.
    #
    # If already inside an Async reactor (e.g. AckProcessor, producer),
    # yields the calling thread's HTTP client directly. Otherwise,
    # dispatches via the persistent background IO thread.
    def request(&block) #: () { (Async::HTTP::Client) -> RawResponse } -> RawResponse
      if Async::Task.current?
        yield http
      else
        sync_call(&block)
      end
    end

    # Read the response body and close it, returning a RawResponse that is
    # safe to use outside the reactor.
    def consume_response(response) #: (untyped) -> RawResponse
      RawResponse.new(
        status: response.status,
        body: response.read,
        content_type: response.headers["content-type"]
      )
    ensure
      response.close
    end

    # Push a work block to the background IO thread and block until it
    # completes, returning the result or re-raising any exception.
    def sync_call(&block) #: () { (Async::HTTP::Client) -> RawResponse } -> RawResponse
      ensure_io_thread

      result_queue = Thread::Queue.new
      @io_queue.push([block, result_queue])

      tag, value = result_queue.pop
      if tag == :ok
        value
      else
        raise value
      end
    rescue ClosedQueueError
      raise ConnectionError, "client is closed"
    end

    # Lazily start the background IO thread (double-checked locking).
    def ensure_io_thread #: () -> void
      return if @io_thread&.alive?

      @mutex.synchronize do
        return if @io_thread&.alive?

        @io_queue = Thread::Queue.new
        @io_thread = Thread.new { io_thread_run }
        @io_thread.name = "zizq-io"
      end
    end

    # Main loop for the background IO thread. Mirrors AckProcessor: runs an
    # Async reactor, pops work from the queue (fiber-scheduler-aware), and
    # dispatches each call as a concurrent fiber via a barrier.
    def io_thread_run #: () -> void
      ObjectSpace.define_finalizer(
        self,
        self.class.make_finalizer(@io_queue, @http_clients)
      )

      Sync do
        barrier = Async::Barrier.new

        while (item = @io_queue.pop)
          block, result_queue = item
          barrier.async do
            result_queue.push([:ok, block.call(http)])
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Must catch Exception (not just StandardError) to ensure the
            # caller is always unblocked. Without this, errors like
            # NoMemoryError or library-level Exceptions would kill the IO
            # thread and leave callers blocking on result_queue.pop forever.
            result_queue.push([:error, e])
          end
        end

        barrier.wait
      end
    ensure
      ObjectSpace.undefine_finalizer(self)
    end

    # Return the calling thread's HTTP client, creating one if needed.
    # Uses thread_variable_get/set (not Thread.current[]) because the
    # latter is fiber-local — each Async fiber would get its own client.
    # The tracking array holds WeakRefs so clients from exited threads
    # can be garbage-collected.
    def http #: () -> Async::HTTP::Client
      thread_local_http(@http_key, @endpoint)
    end

    # Return the calling thread's streaming HTTP client (HTTP/1.1),
    # creating one if needed. See `#http` for the thread-local locking
    # rationale. Kept separate from the main client so the long-lived
    # `/jobs/take` connection doesn't share an HTTP/2 session with
    # ack/enqueue traffic.
    def stream_http #: () -> Async::HTTP::Client
      thread_local_http(@stream_http_key, @stream_endpoint)
    end

    def thread_local_http(key, endpoint) #: (Symbol, Async::HTTP::Endpoint) -> Async::HTTP::Client
      Thread.current.thread_variable_get(key) ||
        begin
          client = Async::HTTP::Client.new(endpoint)
          @mutex.synchronize do
            @http_clients.reject! { |ref| !ref.weakref_alive? }
            @http_clients << WeakRef.new(client)
          end
          Thread.current.thread_variable_set(key, client)
          client
        end
    end

    def get(path, params: {}) #: (String, ?params: Hash[Symbol, untyped]) -> RawResponse
      request do |http|
        consume_response(
          http.get(build_path(path, params:), { "accept" => @content_type })
        )
      end
    end

    def post(path, body) #: (String, Hash[Symbol, untyped]) -> RawResponse
      request do |http|
        consume_response(
          http.post(
            build_path(path),
            { "content-type" => @content_type, "accept" => @content_type },
            Protocol::HTTP::Body::Buffered.wrap(encode_body(body))
          )
        )
      end
    end

    def raw_post(path) #: (String) -> RawResponse
      request do |http|
        consume_response(
          http.post(build_path(path), { "accept" => @content_type })
        )
      end
    end

    def put(path, body) #: (String, Hash[Symbol, untyped]) -> RawResponse
      request do |http|
        consume_response(
          http.put(
            build_path(path),
            { "content-type" => @content_type, "accept" => @content_type },
            Protocol::HTTP::Body::Buffered.wrap(encode_body(body))
          )
        )
      end
    end

    def delete(path, params: {}) #: (String, ?params: Hash[Symbol, untyped]) -> RawResponse
      request do |http|
        consume_response(
          http.delete(build_path(path, params:), { "accept" => @content_type })
        )
      end
    end

    def patch(path, body, params: {}) #: (String, Hash[Symbol, untyped], ?params: Hash[Symbol, untyped]) -> RawResponse
      request do |http|
        consume_response(
          http.patch(
            build_path(path, params:),
            { "content-type" => @content_type, "accept" => @content_type },
            Protocol::HTTP::Body::Buffered.wrap(encode_body(body))
          )
        )
      end
    end

    # Check response status and decode body, raising on errors.
    def handle_response!(response, expected:) #: (RawResponse, expected: Integer | Array[Integer]) -> Hash[String, untyped]?
      status = response.status
      expected_statuses = Array(expected)

      ct = response.content_type

      if expected_statuses.include?(status)
        return nil if status == 204
        decode_body(response.body, content_type: ct)
      else
        body =
          begin
            decode_body(response.body, content_type: ct)
          rescue StandardError
            nil
          end
        message = body&.fetch("error", nil) || "HTTP #{status}"
        error_class =
          case status
          when 404
            NotFoundError
          when 409
            ConflictError
          when 400..499
            ClientError
          when 500..599
            ServerError
          else
            ResponseError
          end
        raise error_class.new(message, status: status, body: body)
      end
    end

    # @private
    def self.make_finalizer(io_queue, http_clients)
      -> do
        io_queue&.close
        http_clients.each do |ref|
          ref.close
        rescue WeakRef::RefError
          # Client already GC'd (owning thread exited).
        rescue NoMethodError
          # The async connection pool may hold references to tasks whose
          # fibers were already reclaimed when their owning Sync reactor
          # exited. Stopping those dead tasks raises NoMethodError; safe
          # to ignore.
        end
        http_clients.clear
      end
    end
  end
end
