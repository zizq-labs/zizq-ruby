ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require "webmock/minitest"
require "async/http"
require "webmock/http_lib_adapters/async_http_client_adapter"
WebMock::HttpLibAdapters::AsyncHttpClientAdapter.enable!

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup { WebMock.reset! }
  end
end
