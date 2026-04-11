# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require "logger"

module Zizq
  # Top-level worker process which orchestrates fetching jobs from the server
  # and dispatching them to a pool of worker tasks for processing.
  #
  # Fiber support (when `fiber_count > 1`) creates an Async context. When
  # `fiber_count == 1`, no Async context is created.
  #
  # Total concurrency is calculated as `thread_count * fiber_count`.
  class Worker
    DEFAULT_THREADS = 5 #: Integer
    DEFAULT_FIBERS = 1 #: Integer
    DEFAULT_SHUTDOWN_TIMEOUT = 30 #: Integer
    DEFAULT_RETRY_MIN_WAIT = 1
    DEFAULT_RETRY_MAX_WAIT = 30
    DEFAULT_RETRY_MULTIPLIER = 2

    # Convenience class method to create and run a worker.
    def self.run(...) #: (**untyped) -> void
      new(...).run
    end

    # The total number of worker threads to run.
    #
    # For applications that are not threadsafe, this should be set to 1
    # (default: 5).
    attr_reader :thread_count #: Integer

    # The total number of fibers to run within each worker thread.
    #
    # For applications that cannot handle multi-fiber execution, this should be
    # set to 1. Any value greater than 1 runs workers inside an Async context
    # (default: 1).
    attr_reader :fiber_count #: Integer

    # The set of queues from which to fetch jobs.
    #
    # An empty set (default) means all queues.
    attr_reader :queues #: Array[String]

    # The total number of jobs to allow to be sent from the server at once.
    #
    # Defaults to 2x the total concurrency (threads * fibers) to keep the
    # pipeline full while ack round-trips are in flight.
    attr_reader :prefetch #: Integer

    # The maximum amount of time to wait for all workers to wrap up on shutdown.
    #
    # Once this timeout is reached, worker tasks are forcibly killed, which
    # will cause any in-flight jobs to be returned to the queue. No jobs are
    # lost (default: 30).
    attr_reader :shutdown_timeout #: Integer

    # Backoff configuration used for reconnects and ack/nack retries.
    attr_reader :backoff #: Backoff

    # Proc to derive a worker ID string for each thread and fiber.
    #
    # When not present, the Zizq server assigns a random worker ID.
    attr_reader :worker_id_proc #: (^(Integer, Integer) -> String?)?

    # An instance of a Logger to be used for worker logging.
    attr_reader :logger #: Logger

    # @rbs queues: Array[String]
    # @rbs thread_count: Integer
    # @rbs fiber_count: Integer
    # @rbs prefetch: Integer?
    # @rbs shutdown_timeout: Integer
    # @rbs retry_min_wait: (Float | Integer)
    # @rbs retry_max_wait: (Float | Integer)
    # @rbs retry_multiplier: (Float | Integer)
    # @rbs worker_id: (^(Integer, Integer) -> String?)?
    # @rbs logger: Logger?
    # @rbs return: void
    def initialize(
      queues: [],
      thread_count: DEFAULT_THREADS,
      fiber_count: DEFAULT_FIBERS,
      prefetch: nil,
      shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT,
      retry_min_wait: DEFAULT_RETRY_MIN_WAIT,
      retry_max_wait: DEFAULT_RETRY_MAX_WAIT,
      retry_multiplier: DEFAULT_RETRY_MULTIPLIER,
      worker_id: nil,
      logger: nil
    )
      raise ArgumentError, "thread_count must be at least 1 (got #{thread_count})" if thread_count < 1
      raise ArgumentError, "fiber_count must be at least 1 (got #{fiber_count})" if fiber_count < 1

      @queues = queues
      @thread_count = thread_count
      @fiber_count = fiber_count
      @prefetch = prefetch || thread_count * fiber_count * 2
      @shutdown_timeout = shutdown_timeout
      @backoff = Backoff.new(
        min_wait:   retry_min_wait,
        max_wait:   retry_max_wait,
        multiplier: retry_multiplier
      )
      @worker_id_proc = worker_id
      @logger = logger || Zizq.configuration.logger
      @lifecycle = Lifecycle.new
      @dispatch_queue = Thread::Queue.new
      @streaming_response = nil #: untyped
      @killing = false

      Zizq.configuration.validate!
      @ack_processor = AckProcessor.new(
        client:   Zizq.client,
        capacity: @prefetch * 2,
        logger:   @logger,
        backoff:  @backoff
      )
    end

    # Request a graceful shutdown.
    #
    # Transitions the lifecycle to `:draining` and closes the dispatch
    # queue. Worker threads finish any in-flight jobs, the ack processor
    # flushes pending acks, and the producer stays connected to the server
    # while all of that drains — only then is the streaming connection
    # closed and `#run` returns.
    #
    # Safe to call from a signal handler (uses only atomic ivar assignment
    # and `Thread::Queue#close`).
    def stop #: () -> void
      @lifecycle.drain!
      @dispatch_queue.close rescue nil
    end

    # Request an immediate shutdown.
    #
    # Like `#stop`, but the streaming connection is closed immediately
    # during teardown (rather than after workers drain), so the server
    # re-dispatches any in-flight jobs after its visibility timeout. Use
    # this when `#stop` has been given adequate time and still hasn't
    # returned.
    #
    # In-progress jobs on worker threads continue to completion — we
    # don't interrupt user code mid-execution — but no new jobs are
    # pulled from the queue and cleanup uses short deadlines.
    #
    # Safe to call from a signal handler.
    def kill #: () -> void
      @killing = true
      @lifecycle.drain!
      @dispatch_queue.close rescue nil
    end

    # Start the worker.
    #
    # Spawns the desired number of worker threads and fibers, distributes jobs
    # to those workers and then blocks until shutdown.
    def run #: () -> void
      logger.info do
        format(
          "Zizq worker starting: %d threads, %d fibers, prefetch=%d",
          thread_count,
          fiber_count,
          prefetch,
        )
      end

      logger.info { "Queues: #{queues.empty? ? '(all)' : queues.join(', ')}" }

      # Everything runs in the background initially.
      @ack_processor.start
      worker_threads = start_worker_threads
      producer_thread = start_producer_thread

      # Block until the lifecycle leaves :running (stop, kill, or crash).
      @lifecycle.wait_while_running

      if @killing
        logger.info { "Killing. Closing stream and forcing shutdown..." }

        # Close the streaming response immediately so the server
        # re-dispatches any in-flight jobs after its visibility timeout.
        # This also unblocks the producer's IO read.
        @streaming_response&.close rescue nil

        # Workers will finish their current job (can't be interrupted)
        # and then see the closed dispatch queue and exit. Give them a
        # short deadline — we don't wait for the full shutdown_timeout.
        join_with_deadline(worker_threads)

        # Drain whatever acks are still pending with a short deadline.
        @ack_processor.stop(timeout: [shutdown_timeout, 2].min)
      else
        logger.info do
          format(
            "Shutting down. Waiting up to %.2fs for workers to finish...",
            shutdown_timeout,
          )
        end

        # Workers drain remaining jobs from the closed dispatch queue.
        # The producer stays connected so in-flight jobs aren't requeued
        # by the server while workers are still finishing them.
        join_with_deadline(worker_threads)

        # Drain pending acks/nacks while the connection is still open.
        @ack_processor.stop(timeout: shutdown_timeout)

        # Close the streaming response to unblock the producer's IO read.
        # This happens after workers and acks have drained so the server
        # doesn't requeue in-flight jobs while workers are still finishing.
        @streaming_response&.close rescue nil
      end

      # Signal the producer that cleanup is complete. The watcher fiber
      # inside the producer's Sync block wakes up on this and cancels
      # the producer's main task, so the stream is closed from its own
      # reactor rather than via a cross-thread close.
      @lifecycle.stop!
      unless producer_thread.join(shutdown_timeout)
        logger.warn { "Producer did not exit cleanly, killing" }
        producer_thread.kill
      end

      logger.info { "Zizq worker stopped" }
    end

    private

    def start_producer_thread #: () -> Thread
      Thread.new do
        Thread.current.name = "zizq-producer"

        logger.info { "Zizq producer thread started" }

        # The producer runs inside its own Sync block so we can spawn a
        # watcher fiber that cancels the main producer task on final
        # shutdown. `task.stop` raises `Async::Stop` at the next fiber
        # yield point, which means we can interrupt the producer
        # wherever it's currently blocked — inside `stream_http.get`
        # reading response headers, inside `parse_ndjson` waiting on
        # the body, or inside `wait_until_stopped`. All of those are
        # fiber yield points, so the cancellation is immediate.
        #
        # The watcher waits on `wait_until_stopped` (not
        # `wait_while_running`) so the producer stays connected through
        # the worker+ack drain phase. Only once main has finished
        # cleanup and called `@lifecycle.stop!` does the producer get
        # cancelled.
        Sync do |task|
          task.async do
            @lifecycle.wait_until_stopped
            task.stop
          end

          while @lifecycle.running?
            begin
              client = Zizq.client
              logger.info { "Connecting to #{client.url}..." }

              client.take_jobs(
                prefetch:,
                queues:,
                on_connect: -> {
                  logger.info { "Connected. Listening for jobs." }
                  @backoff.reset
                },
                on_response: ->(resp) { @streaming_response = resp },
              ) do |job|
                begin
                  logger.debug do
                    format(
                      "Received %s (%s), dispatch queue: %d",
                      job.type,
                      job.id,
                      @dispatch_queue.size
                    )
                  end

                  @dispatch_queue.push(job)
                rescue ClosedQueueError
                  # Shutdown in progress. Stay connected so in-flight jobs
                  # aren't requeued while workers and acks drain. The
                  # watcher fiber will cancel this task when main calls
                  # `@lifecycle.stop!` at the end of cleanup.
                  @lifecycle.wait_until_stopped
                  break
                end
              end

              # Stream ended normally — clear stale reference and reset backoff.
              @streaming_response = nil
              @backoff.reset
            rescue Async::Stop
              # Watcher fiber cancelled us — shutdown is complete.
              break
            rescue Zizq::ConnectionError, Zizq::StreamError => error
              break unless @lifecycle.running?

              logger.warn do
                format(
                  "%s: %s. Reconnecting in %.2fs...",
                  error.class,
                  error.message,
                  @backoff.duration,
                )
              end

              @backoff.wait
            rescue => error
              break unless @lifecycle.running?

              logger.error { "Error: #{error.class}: #{error.message}" }
              logger.debug { error.backtrace&.join("\n") }
              @backoff.wait
            end
          end
        end

        # Ensure queue is closed so workers can drain and exit
        @dispatch_queue.close rescue nil
        logger.info { "Zizq producer thread stopped" }
      ensure
        # Wake the main thread if the producer crashes during normal
        # operation (before a shutdown signal).
        @lifecycle.drain!
      end
    end

    def start_worker_threads #: () -> Array[Thread]
      (0...thread_count).map do |thread_idx|
        Thread.new(thread_idx) do |tidx|
          Thread.current.name = "zizq-worker-#{tidx}"

          if fiber_count > 1
            run_fiber_workers(tidx)
          else
            run_loop(tidx, 0)
          end
        end
      end
    end

    # Internal worker run loop.
    #
    # Each worker thread or fiber continually pops jobs from the internal queue
    # and dispatches them to the correct job class until the queue is closed
    # and drained.
    def run_loop(thread_idx, fiber_idx) #: (Integer, Integer) -> void
      logger.info do
        format("Worker %d:%d started", thread_idx, fiber_idx)
      end

      wid = resolve_worker_id(thread_idx, fiber_idx)

      loop do
        # pop returns nil when queue is closed and empty
        job = @dispatch_queue.pop
        break if job.nil?

        dispatch(job, wid)
      end

      logger.info do
        format("Worker %d:%d stopped", thread_idx, fiber_idx)
      end
    end

    # Fiber-based worker loop. Requires the `async` gem.
    def run_fiber_workers(thread_idx) #: (Integer) -> void
      require "async"

      Async do |task|
        fiber_count.times do |fiber_idx|
          task.async do
            run_loop(thread_idx, fiber_idx)
          end
        end
      end
    end

    # Process a single job.
    #
    # Delegates to the configured dispatcher (default: `Zizq::Job.dispatch`)
    # and reports success or failure.
    def dispatch(job, worker_id) #: (Resources::Job, String?) -> void
      job_id, job_type = job.id, job.type

      begin
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          Zizq.configuration.dequeue_middleware.call(job)
        ensure
          finish_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          elapsed_time = finish_time - start_time
        end
      rescue Exception => error
        raise if !@lifecycle.running? && error.is_a?(Async::Stop)

        logger.error do
          format(
            "Job %s (%s) failed in %.4fs: %s: %s",
            job_type,
            job_id,
            elapsed_time,
            error.class,
            error.message
          )
        end

        push_nack(job_id, error)
        return
      end

      push_ack(job_id)

      logger.debug do
        format(
          "Job %s (%s) completed in %.4fs",
          job_type,
          job_id,
          elapsed_time
        )
      end
    rescue Async::Stop, ClosedQueueError
      # In the case jobs take too long to terminate, they are force killed
      # which produces errors as they attempt to ack/nack etc.
      #
      # This means those jobs terminate without finishing their work but the
      # Zizq backend automatically returns them to the queue when the client
      # disconnects, so they'll be received by another worker when one connects.
      logger.debug { "Job #{job_type} (#{job_id}) interrupted during shutdown" }
    end

    # @rbs job_id: String
    # @rbs return: void
    def push_ack(job_id)
      @ack_processor.push(AckProcessor::Ack.new(job_id:))
    end

    # @rbs job_id: String
    # @rbs error: Exception
    # @rbs return: void
    def push_nack(job_id, error)
      @ack_processor.push(AckProcessor::Nack.new(
        job_id:     job_id,
        message:    "#{error.class}: #{error.message}",
        error_type: error.class.name,
        backtrace:  error.backtrace&.join("\n")
      ))
    end

    def resolve_worker_id(thread_idx, fiber_idx) #: (Integer, Integer) -> String?
      worker_id_proc&.call(thread_idx, fiber_idx)
    end

    # Join all threads within the shutdown timeout. Any thread that hasn't
    # finished by the deadline is forcibly killed.
    #
    # Thread#join(timeout) returns nil when the timeout expires without the
    # thread finishing — it does NOT kill the thread. We must kill it
    # explicitly so we don't leave zombie threads running after shutdown.
    def join_with_deadline(threads) #: (Array[Thread]) -> void
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + shutdown_timeout

      threads.each do |t|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        next if remaining > 0 && t.join(remaining)
        next unless t.alive?

        logger.warn { "Shutdown timeout reached. Killing thread #{t.name}" }
        t.kill
      end
    end
  end
end
