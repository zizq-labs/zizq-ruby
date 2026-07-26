# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# rbs_inline: enabled
# frozen_string_literal: true

module Zizq
  # TLS settings for connecting to the Zizq server over HTTPS.
  #
  # Set inside a `Zizq.configure` block via the `c.tls` accessors:
  #
  #   Zizq.configure do |c|
  #     c.tls.ca          = "/path/to/ca-cert.pem"
  #     c.tls.client_cert = "/path/to/client-cert.pem"
  #     c.tls.client_key  = "/path/to/client-key.pem"
  #   end
  #
  # All values may be PEM-encoded strings or file paths.
  #
  # Note: Mutual TLS support requires a Zizq Pro license on the server.
  TlsConfiguration =
    Struct.new(
      :ca, #: String?
      :client_cert, #: String?
      :client_key, #: String?
      keyword_init: true
    )
end
