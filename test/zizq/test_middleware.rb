# Copyright (c) 2026 Chris Corbyn <chris@zizq.io>
# Licensed under the MIT License. See LICENSE file for details.

# frozen_string_literal: true

require "test_helper"

class TestMiddleware < Minitest::Test
  # --- Chain ---

  def test_chain_with_no_middleware_calls_terminal_directly
    called_with = nil
    terminal = ->(arg) { called_with = arg }

    chain = Zizq::Middleware::Chain.new(terminal)
    chain.call("hello")

    assert_equal "hello", called_with
  end

  def test_chain_with_one_middleware
    log = []
    terminal = ->(arg) { log << "terminal:#{arg}" }

    mw = Object.new
    mw.define_singleton_method(:call) do |arg, chain|
      log << "before:#{arg}"
      chain.call(arg)
      log << "after:#{arg}"
    end

    chain = Zizq::Middleware::Chain.new(terminal)
    chain.use(mw)
    chain.call("x")

    assert_equal ["before:x", "terminal:x", "after:x"], log
  end

  def test_chain_with_multiple_middleware_runs_in_order
    log = []
    terminal = ->(arg) { log << "terminal" }

    first = Object.new
    first.define_singleton_method(:call) do |arg, chain|
      log << "first:before"
      chain.call(arg)
      log << "first:after"
    end

    second = Object.new
    second.define_singleton_method(:call) do |arg, chain|
      log << "second:before"
      chain.call(arg)
      log << "second:after"
    end

    chain = Zizq::Middleware::Chain.new(terminal)
    chain.use(first)
    chain.use(second)
    chain.call("x")

    assert_equal [
      "first:before",
      "second:before",
      "terminal",
      "second:after",
      "first:after"
    ], log
  end

  def test_middleware_can_modify_the_argument
    terminal = ->(arg) { arg }

    upcase_mw = Object.new
    upcase_mw.define_singleton_method(:call) do |arg, chain|
      chain.call(arg.upcase)
    end

    chain = Zizq::Middleware::Chain.new(terminal)
    chain.use(upcase_mw)

    # Terminal receives the modified value.
    received = nil
    chain = Zizq::Middleware::Chain.new(->(arg) { received = arg })
    chain.use(upcase_mw)
    chain.call("hello")

    assert_equal "HELLO", received
  end

  def test_chain_returns_terminal_result
    terminal = ->(arg) { arg.upcase }
    chain = Zizq::Middleware::Chain.new(terminal)

    result = chain.call("hello")
    assert_equal "HELLO", result
  end

  def test_middleware_can_return_modified_result
    terminal = ->(arg) { arg }

    mw = Object.new
    mw.define_singleton_method(:call) do |arg, chain|
      chain.call(arg + " world")
    end

    chain = Zizq::Middleware::Chain.new(terminal)
    chain.use(mw)

    assert_equal "hello world", chain.call("hello")
  end
end
