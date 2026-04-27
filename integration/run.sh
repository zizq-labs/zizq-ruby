#!/usr/bin/env bash

# Run the Ruby client integration tests against a real Zizq server.
#
# Usage:
#   ./run.sh --binary /path/to/zizq --gem /path/to/zizq-0.1.0.gem
#
# The test runs in an isolated temp directory to ensure it exercises the
# installed gem, not the local source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BINARY=""
GEM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BINARY="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --gem)    GEM="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        *)        echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$BINARY" || -z "$GEM" ]]; then
    echo "Usage: ./run.sh --binary /path/to/zizq --gem /path/to/zizq-x.y.z.gem"
    exit 1
fi

if [[ ! -x "$BINARY" ]]; then
    echo "Error: binary not found or not executable: $BINARY"
    exit 1
fi

if [[ ! -f "$GEM" ]]; then
    echo "Error: gem not found: $GEM"
    exit 1
fi

# --- Set up isolated work directory ---

WORKDIR="$(mktemp -d)"
SERVER_ROOT="$(mktemp -d)"

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR" "$SERVER_ROOT"
}
trap cleanup EXIT

echo "==> Setting up integration test (Ruby $(ruby --version | awk '{print $2}'))"

# --- Install the gem ---

cp "$SCRIPT_DIR"/*.rb "$WORKDIR/"

cd "$WORKDIR"

echo "    Installing gems..."
gem install --no-document "$GEM" 2>&1 | sed 's/^/    /'
gem install --no-document activejob -v '~> 8.0' 2>&1 | sed 's/^/    /'

# --- Start the server ---

echo "    Starting Zizq server..."

SERVER_LOG="$(mktemp)"
"$BINARY" serve \
    --port 0 \
    --no-admin \
    --root-dir "$SERVER_ROOT" \
    --log-format json \
    --log-level info \
    > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for the "listening" log line with api="primary" and extract the
# address.
ZIZQ_URL=""
DEADLINE=$((SECONDS + 10))
while [[ $SECONDS -lt $DEADLINE ]]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Error: server exited unexpectedly:"
        cat "$SERVER_LOG"
        exit 1
    fi

    LINE="$(grep '"api":"primary"' "$SERVER_LOG" 2>/dev/null || true)"
    if [[ -n "$LINE" ]]; then
        ADDR="$(echo "$LINE" | jq -r '.fields.addr')"
        SCHEME="$(echo "$LINE" | jq -r '.fields.scheme')"
        ZIZQ_URL="${SCHEME}://${ADDR}"
        break
    fi

    sleep 0.1
done

if [[ -z "$ZIZQ_URL" ]]; then
    echo "Error: timed out waiting for server to start."
    cat "$SERVER_LOG"
    exit 1
fi

echo "    Server listening on ${ZIZQ_URL}"

# --- Run tests ---

echo "    Running integration tests..."
ZIZQ_URL="$ZIZQ_URL" ruby test.rb
