# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

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

    # TLS options for connecting to the server over HTTPS.
    #
    # All values may be PEM-encoded strings or file paths.
    #
    #   {
    #     ca:          "path/to/ca-cert.pem",       # CA certificate for server verification
    #     client_cert: "path/to/client-cert.pem",   # Client certificate for mTLS
    #     client_key:  "path/to/client-key.pem",    # Client private key for mTLS
    #   }
    #
    # Note: Mutual TLS support requires a Zizq Pro license on the server.
    attr_accessor :tls #: Zizq::tls_options?

    # Middleware chain for enqueue. Each middleware receives an
    # `EnqueueRequest` and a chain to continue.
    attr_reader :enqueue_middleware #: Middleware::Chain[EnqueueRequest, EnqueueRequest]

    # Middleware chain for dequeue/dispatch. Each middleware receives
    # a `Resources::Job` and a chain to continue.
    attr_reader :dequeue_middleware #: Middleware::Chain[Resources::Job, void]

    def initialize #: () -> void
      @url = "http://localhost:7890"
      @format = :msgpack
      @logger = Logger.new($stdout, level: Logger::INFO)
      @tls = nil
      @enqueue_middleware = Middleware::Chain.new(Identity.new)
      @dequeue_middleware = Middleware::Chain.new(Zizq::Job)
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

      tls = @tls
      validate_tls!(tls) if tls
    end

    # @private
    # Build an OpenSSL::SSL::SSLContext from the TLS options, or nil if
    # no TLS options are configured.
    def ssl_context #: () -> OpenSSL::SSL::SSLContext?
      tls = @tls
      return nil unless tls

      ctx = OpenSSL::SSL::SSLContext.new

      if (ca = tls[:ca])
        store = OpenSSL::X509::Store.new
        store.add_cert(load_cert(ca))
        ctx.cert_store = store
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      if (client_cert = tls[:client_cert])
        ctx.cert = load_cert(client_cert)
      end

      if (client_key = tls[:client_key])
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

    private

    # @rbs tls: Zizq::tls_options
    def validate_tls!(tls) #: (Zizq::tls_options) -> void
      if tls[:client_cert] && !tls[:client_key]
        raise ArgumentError, "Zizq.configure: tls[:client_key] is required when tls[:client_cert] is set"
      end

      if tls[:client_key] && !tls[:client_cert]
        raise ArgumentError, "Zizq.configure: tls[:client_cert] is required when tls[:client_key] is set"
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
