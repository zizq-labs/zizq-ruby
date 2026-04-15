#!/usr/bin/env bash

# Build a release artifact for the Zizq Ruby client.
#
# Produces:
#   target/release/zizq-<version>.gem
#   target/release/zizq-<version>.gem.sha256
#
# Usage:
#   ./release.sh           # build only
#   ./release.sh --check   # verify tests + typecheck pass first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Read version from the gem's own source of truth.
VERSION="$(ruby -r ./lib/zizq/version -e 'puts Zizq::VERSION')"
OUT_DIR="target/release"

echo "==> Zizq Ruby Client v${VERSION}"

# Optional pre-flight checks.
if [[ "${1:-}" == "--check" ]]; then
    echo "    Running tests..."
    bundle exec rake test

    echo "    Running typecheck..."
    bundle exec rake typecheck
fi

# Generate RBS signatures from inline annotations (shipped in the gem).
echo "    Generating RBS..."
bundle exec rake rbs

# Build the gem.
echo "    Building gem..."
mkdir -p "$OUT_DIR"
gem build zizq.gemspec --output "${OUT_DIR}/zizq-${VERSION}.gem"

# Checksum.
echo "    Computing checksum..."
(cd "$OUT_DIR" && shasum -a 256 "zizq-${VERSION}.gem" > "zizq-${VERSION}.gem.sha256")

echo "==> Done."
echo "    ${OUT_DIR}/zizq-${VERSION}.gem"
echo "    ${OUT_DIR}/zizq-${VERSION}.gem.sha256"
