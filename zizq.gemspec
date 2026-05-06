# frozen_string_literal: true

require_relative "lib/zizq/version"

Gem::Specification.new do |spec|
  spec.name = "zizq"
  spec.version = Zizq::VERSION
  spec.authors = ["Chris Corbyn <chris@zizq.io>"]
  spec.license = "MIT"

  spec.summary = "The official Ruby client for the Zizq job queue"

  spec.description = "This is the official Ruby client for the Zizq job queue server." \
                     "\n\n" \
                     "Zizq is a simple, single binary, zero dependency, " \
                     "language agnostic job queue." \
                     "\n\n"
                     "Features:" \
                     "\n\n" \
                     "- Enqueue and process jobs across programming languages\n" \
                     "- Persistent/journalled\n" \
                     "- Multi-thread and/or multi-fiber\n" \
                     "- Scheduled jobs\n" \
                     "- Prioritized queues\n" \
                     "- Optional ActiveJob integration\n" \
                     "- Unique jobs\n" \
                     "- Cron scheduling (recurring jobs)\n" \
                     "- Job introspection and management, including `jq` filters\n"
                     "\n\n" \
                     "This client supports multi-threaded and/or multi-fiber " \
                     "concurrency and is very fast. The Zizq server provides " \
                     "everything needed. There are no separate external storage " \
                     "dependencies to configure such as Redis or a RDBMS." \
                     "\n\n" \
                     "See https://zizq.io for full details and documentation."

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
