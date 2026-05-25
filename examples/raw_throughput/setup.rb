# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

# Shared setup code for all throughput entrypoints.
# Used to configure Zizq from the environment.

require 'zizq'

Zizq.configure do |c|
  c.url = ENV['ZIZQ_URL'] if ENV['ZIZQ_URL']
  c.format = ENV.fetch('ZIZQ_FORMAT', 'msgpack').to_sym
  c.tls.ca = ENV['ZIZQ_CA'].presence
  c.tls.client_cert = ENV['ZIZQ_CLIENT_CERT'].presence
  c.tls.client_key = ENV['ZIZQ_CLIENT_KEY'].presence
end
