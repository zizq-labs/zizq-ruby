# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

require "delegate"
require "logger"
require "openssl"

module Zizq
  # Global configuration for the Zizq client.
  #
  # The configuration stores only client-level concerns: server URL,
  # serialization format, and logger. Worker-specific settings (queues,
  # threads, etc.) are passed directly to the Worker.
  #
  # See: [`Zizq::configure]`.
  # See: [`Zizq::configuration]`.
  class Configuration
    # Base URL of the Zizq server (default: "http://localhost:7890").
    attr_accessor :url #: String

    # Choice of content-type encoding used in communication with the Zizq
    # server.
    #
    # One of: `:json`, `:msgpack` (default)
    attr_accessor :format #: Zizq::format

    # Logger instance to which to write log messages.
    attr_accessor :logger #: Logger

    # Per-operation socket I/O timeout (seconds) for regular API calls
    # (enqueue, queries, mutations). Each socket read/write is bounded
    # by this value. A request whose handshake or any single read exceeds
    # this raises `IO::TimeoutError`.
    #
    # Default: 30.
    attr_accessor :read_timeout #: Numeric

    # Per-operation socket I/O timeout (seconds) for the long-lived
    # `#take_jobs` stream. The server sends heartbeats every ~3 seconds,
    # so each read returns within that window and keeps the connection
    # alive; the connection only times out if the server falls silent for
    # longer than this. The Worker catches the resulting error and
    # reconnects with backoff.
    #
    # Should be comfortably above the server's heartbeat interval to
    # avoid false-positive disconnects.
    #
    # Default: 30.
    attr_accessor :stream_idle_timeout #: Numeric

    # Middleware chain for enqueue. Each middleware receives an
    # `EnqueueRequest` and a chain to continue.
    attr_reader :enqueue_middleware #: Middleware::Chain[EnqueueRequest, EnqueueRequest]

    # Middleware chain for dequeue/dispatch. Each middleware receives
    # a `Resources::Job` and a chain to continue.
    attr_reader :dequeue_middleware #: Middleware::Chain[Resources::Job, void]

    def initialize #: () -> void
      @url = "http://localhost:7890"
      @format = :msgpack
      @logger = Logger.new(FlushingIO.new($stdout), level: Logger::INFO)
      @tls = nil
      @worker = nil
      @read_timeout = 30
      @stream_idle_timeout = 30
      @enqueue_middleware = Middleware::Chain.new(Identity.new)
      @dequeue_middleware = Middleware::Chain.new(Zizq::Job)
    end

    # TLS settings for connecting to the server over HTTPS.
    #
    # Configure via the `c.tls` accessors inside a `Zizq.configure`
    # block:
    #
    #   Zizq.configure do |c|
    #     c.tls.ca          = "/path/to/server-ca-cert.pem"
    #     c.tls.client_cert = "/path/to/client-cert.pem"
    #     c.tls.client_key  = "/path/to/client-key.pem"
    #   end
    #
    # All values may be PEM-encoded strings or file paths. Set
    # `c.tls = nil` to explicitly disable TLS.
    #
    # Note: Mutual TLS support requires a Zizq Pro license on the
    # server.
    def tls #: () -> TlsConfiguration
      @tls ||= TlsConfiguration.new
    end

    def tls=(value) #: ((Hash[Symbol, String?] | TlsConfiguration)?) -> void
      case value
      when nil
        @tls = nil
      when TlsConfiguration
        @tls = value
      when Hash
        @tls = TlsConfiguration.new(**value)
      else
        raise ArgumentError,
          "Zizq.configure: tls= expects a Hash, Zizq::TlsConfiguration, or nil " \
          "(got #{value.class})"
      end
    end

    # Defaults for `Zizq::Worker` instances. Apps populate this in
    # their `Zizq.configure` block:
    #
    #   Zizq.configure do |c|
    #     c.worker.queues = ["emails"]
    #     c.worker.fiber_count = 25
    #   end
    #
    # Anything left unset here falls through to the Worker's
    # hardcoded defaults; anything explicitly passed to `Worker.new`
    # (or set via `zizq-worker` CLI flags / env vars) overrides
    # whatever is configured here.
    def worker #: () -> WorkerConfiguration
      @worker ||= WorkerConfiguration.new
    end

    def worker=(value) #: ((Hash[Symbol, untyped] | WorkerConfiguration)?) -> void
      case value
      when nil
        @worker = nil
      when WorkerConfiguration
        @worker = value
      when Hash
        @worker = WorkerConfiguration.new(**value)
      else
        raise ArgumentError,
          "Zizq.configure: worker= expects a Hash, Zizq::WorkerConfiguration, or nil " \
          "(got #{value.class})"
      end
    end

    # The job dispatcher.
    # This is the terminal of the dequeue middleware chain.
    # Defaults to `Zizq::Job` which finds and executes jobs written by mixing
    # in the `Zizq::Job` module.
    def dispatcher #: () -> Zizq::dispatcher
      @dequeue_middleware.terminal
    end

    # Set the dispatcher to a custom dispatcher implementation.
    #
    # A dispatcher is any object that responds to `#call` with a
    # `Zizq::Resources::Job` instance and performs that job through some
    # application-specific logic.
    #
    # This is the terminal of the dequeue middleware chain.
    #
    # Any errors raised by the dispatcher will result in the normal
    # backoff/retry behaviour. Jobs are acknowledged automatically on success.
    def dispatcher=(dispatcher) #: (Zizq::dispatcher) -> void
      @dequeue_middleware.terminal = dispatcher
    end

    # Validates that required configuration is present.
    def validate! #: () -> void
      raise ArgumentError, "Zizq.configure: url is required" if url.empty?

      unless %i[msgpack json].include?(format)
        raise ArgumentError, "Zizq.configure: format must be :msgpack or :json, got #{format.inspect}"
      end

      unless read_timeout.is_a?(Numeric) && read_timeout > 0
        raise ArgumentError, "Zizq.configure: read_timeout must be a positive number, got #{read_timeout.inspect}"
      end

      unless stream_idle_timeout.is_a?(Numeric) && stream_idle_timeout > 0
        raise ArgumentError, "Zizq.configure: stream_idle_timeout must be a positive number, got #{stream_idle_timeout.inspect}"
      end

      tls = @tls
      validate_tls!(tls) if tls
    end

    # @private
    # Build an OpenSSL::SSL::SSLContext from the TLS options, or nil if
    # no TLS options are configured.
    def ssl_context #: () -> OpenSSL::SSL::SSLContext?
      tls = @tls
      return nil unless tls
      return nil if tls.to_h.values.all?(&:nil?)

      ctx = OpenSSL::SSL::SSLContext.new

      if (ca = tls.ca)
        store = OpenSSL::X509::Store.new
        store.add_cert(load_cert(ca))
        ctx.cert_store = store
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      if (client_cert = tls.client_cert)
        ctx.cert = load_cert(client_cert)
      end

      if (client_key = tls.client_key)
        ctx.key = load_key(client_key)
      end

      ctx
    end

    # @private
    # Identity terminal — returns the argument unchanged.
    class Identity
      def call(arg) #: (untyped) -> untyped
        arg
      end
    end

    # @private
    # IO delegator that flushes the underlying IO after every write.
    # We wrap `$stdout` in this for the default logger so log lines
    # appear immediately when stdout is connected to a pipe (foreman,
    # systemd, k8s). Without it, the C-stdio default switches from
    # line-buffered to fully-buffered for pipes and log output piles
    # up in a 4–8KB buffer until the process exits.
    #
    # The wrapper is local to the default logger — apps supplying
    # their own `c.logger = ...` retain full control over flushing.
    class FlushingIO < SimpleDelegator
      def write(*args) #: (*untyped) -> Integer
        result = super
        __getobj__.flush
        result
      end

      # Declared explicitly so the type checker sees us satisfying
      # `Logger::_WriteCloser`; SimpleDelegator forwards `close` via
      # `method_missing`, but Steep doesn't follow that.
      def close #: () -> void
        __getobj__.close
      end
    end

    private

    def validate_tls!(tls) #: (TlsConfiguration) -> void
      if tls.client_cert && !tls.client_key
        raise ArgumentError, "Zizq.configure: tls.client_key is required when tls.client_cert is set"
      end

      if tls.client_key && !tls.client_cert
        raise ArgumentError, "Zizq.configure: tls.client_cert is required when tls.client_key is set"
      end
    end

    # Load a certificate from a PEM string or file path.
    def load_cert(pem_or_path) #: (String) -> OpenSSL::X509::Certificate
      OpenSSL::X509::Certificate.new(resolve_pem(pem_or_path))
    end

    # Load a private key from a PEM string or file path.
    def load_key(pem_or_path) #: (String) -> OpenSSL::PKey::PKey
      OpenSSL::PKey.read(resolve_pem(pem_or_path))
    end

    # If the value looks like PEM data, return it as-is; otherwise treat
    # it as a file path and read the contents.
    def resolve_pem(value) #: (String) -> String
      if value.include?("-----BEGIN ")
        value
      else
        File.read(value)
      end
    end
  end
end
