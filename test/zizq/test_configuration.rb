# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class TestConfiguration < ZizqTestCase
  def test_defaults
    config = Zizq::Configuration.new
    assert_equal "http://localhost:7890", config.url
    assert_equal :msgpack, config.format
    assert_instance_of Logger, config.logger
    assert_equal 30, config.read_timeout
    assert_equal 30, config.stream_idle_timeout
  end

  def test_validate_rejects_non_positive_read_timeout
    config = Zizq::Configuration.new
    config.url = "http://localhost:7890"
    config.read_timeout = 0
    assert_raises(ArgumentError) { config.validate! }

    config.read_timeout = -1
    assert_raises(ArgumentError) { config.validate! }
  end

  def test_validate_rejects_non_positive_stream_idle_timeout
    config = Zizq::Configuration.new
    config.url = "http://localhost:7890"
    config.stream_idle_timeout = 0
    assert_raises(ArgumentError) { config.validate! }

    config.stream_idle_timeout = -1
    assert_raises(ArgumentError) { config.validate! }
  end

  def test_configure_block
    Zizq.configure do |c|
      c.url = "http://localhost:7890"
      c.format = :json
    end

    assert_equal "http://localhost:7890", Zizq.configuration.url
    assert_equal :json, Zizq.configuration.format
  end

  def test_validate_rejects_empty_url
    config = Zizq::Configuration.new
    config.url = ""
    assert_raises(ArgumentError) { config.validate! }
  end

  def test_validate_rejects_invalid_format
    config = Zizq::Configuration.new
    config.url = "http://localhost:7890"
    config.format = :xml
    assert_raises(ArgumentError) { config.validate! }
  end

  def test_validate_accepts_valid_config
    config = Zizq::Configuration.new
    config.url = "http://localhost:7890"
    config.format = :msgpack
    config.validate! # should not raise
  end

  def test_client_memoized
    Zizq.configure { |c| c.url = "http://localhost:7890" }
    client1 = Zizq.client
    client2 = Zizq.client
    assert_same client1, client2
  end

  def test_reset_clears_client
    Zizq.configure { |c| c.url = "http://localhost:7890" }
    client1 = Zizq.client
    Zizq.reset!
    Zizq.configure { |c| c.url = "http://localhost:7890" }
    client2 = Zizq.client
    refute_same client1, client2
  end
end
