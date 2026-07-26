# Auto-loaded by Puma when present at `config/puma.rb`. Drives the
# server through environment variables so `.env` / `bin/dev` can
# tune everything without editing this file.

threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"))
threads threads_count, threads_count

bind "tcp://#{ENV.fetch("BIND", "127.0.0.1")}:#{ENV.fetch("PORT", "3000")}"

environment ENV.fetch("RACK_ENV", "development")
