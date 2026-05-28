ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require "webmock/minitest"
require "async/http"
require "webmock/http_lib_adapters/async_http_client_adapter"
WebMock::HttpLibAdapters::AsyncHttpClientAdapter.enable!

# Route Zizq.enqueue_raw (used by `Audit.emit`) into an in-memory
# buffer so tests can assert on emitted audit events without
# needing a Zizq server. ActiveJob keeps using its own `:test`
# adapter — see config/environments/test.rb.
Zizq::Test.enable!

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup do
      WebMock.reset!
      Zizq::Test.reset!
    end
  end
end
