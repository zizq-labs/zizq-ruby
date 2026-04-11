# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

# Shared setup code for all test entrypoints.
# Used to configure Zizq from the environment.

require 'zizq'

Zizq.configure do |c|
  c.url = ENV['ZIZQ_URL'] if ENV['ZIZQ_URL']
  c.format = ENV.fetch('ZIZQ_FORMAT', 'msgpack').to_sym

  if ENV['ZIZQ_CA']
    c.tls = {
      ca: ENV['ZIZQ_CA'],
      client_cert: ENV['ZIZQ_CLIENT_CERT'],
      client_key: ENV['ZIZQ_CLIENT_KEY'],
    }
  end
end
