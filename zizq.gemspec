# frozen_string_literal: true

require_relative "lib/zizq/version"

Gem::Specification.new do |spec|
  spec.name = "zizq"
  spec.version = Zizq::VERSION
  spec.authors = ["Chris Corbyn <chris@zizq.io>"]
  spec.license = "MIT"

  spec.summary = "The official Ruby client for the Zizq job queue"

  spec.description = "This is the Ruby client for the Zizq job queue server.\n\n" \
                     "[Zizq](https://zizq.io/) is a simple, single binary, zero dependency, " \
                     "language agnostic job queue.\n\n" \
                     "This client supports multi-threaded and/or multi-fiber concurrency and " \
                     "is very fast. The Zizq server provides everything needed. There are no " \
                     "separate external storage dependencies to configure."

  spec.homepage = "https://zizq.io"
  spec.required_ruby_version = ">= 3.2.8"
  spec.metadata = {
    "source_code_uri" => "https://github.com/zizq-labs/zizq-ruby",
    "documentation_uri" => "https://zizq.io/docs/clients/ruby/",
    "homepage_uri" => "https://zizq.io",
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/**/*",
    "sig/zizq.rbs",
    "sig/generated/**/*.rbs",
    "README.md",
    "LICENSE",
  ]
  spec.executables = ["zizq-worker"]
  spec.require_paths = ["lib"]

  spec.add_dependency "async-http", "~> 0.82"
  spec.add_dependency "msgpack", "~> 1.7"
end
