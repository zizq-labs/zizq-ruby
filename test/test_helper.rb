# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "zizq"
require "minitest/autorun"
require "webmock/minitest"
require "async/http"
require "webmock/http_lib_adapters/async_http_client_adapter"

WebMock::HttpLibAdapters::AsyncHttpClientAdapter.enable!

# Shared base class for all Zizq tests.
#
# Resets global state and WebMock between tests so that each test
# starts with a clean environment.
class ZizqTestCase < Minitest::Test
  URL = "http://localhost:7890"

  def setup
    Zizq.reset!
    Zizq.configure { |c| c.url = URL; c.format = :json }
    WebMock.reset_executed_requests!
  end
end
