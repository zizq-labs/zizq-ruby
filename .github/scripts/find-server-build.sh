#!/usr/bin/env bash

# Find the latest compatible Zizq server build artifact from GitHub.
#
# Searches the server repo's CI artifacts for the most recent build
# whose major version matches the client's, downloaded from main.
#
# Usage:
#   ./find-server-build.sh <major-version> <output-dir>
#
# Requires GH_TOKEN to be set (PAT with repo access for private repos).
#
# Outputs the server binary (unpacked) to <output-dir>/zizq.

set -euo pipefail

MAJOR="${1:?Usage: find-server-build.sh <major-version> <output-dir>}"
OUTPUT_DIR="${2:?Usage: find-server-build.sh <major-version> <output-dir>}"
SERVER_REPO="zizq-labs/zizq"

echo "Looking for server build with major version ${MAJOR}..."

# Query the server repo's artifacts API. Returns up to 100 most recent
# artifacts (newest first). We filter by:
#   - name matches our major version prefix
#   - built from the main branch
#   - not expired
#
# Then sort by semver (split version into numeric components so that
# v0.20.1 > v0.3.1) and take the highest version. Within the same
# version, sort by created_at descending so the newest build wins.
artifact=$(gh api "repos/${SERVER_REPO}/actions/artifacts?per_page=100" \
  --jq "[
    .artifacts[]
    | select(.name | test(\"^zizq-binary-v${MAJOR}[.]\"))
    | select(.workflow_run.head_branch == \"main\")
    | select(.expired == false)
  ]
  | sort_by(
      (.name | ltrimstr(\"zizq-binary-v\") | split(\".\") | map(tonumber)),
      .created_at
    )
  | reverse
  | .[0]")

if [[ -z "$artifact" || "$artifact" == "null" ]]; then
  echo "::error::No compatible server build found (need major version ${MAJOR})"
  exit 1
fi

name=$(echo "$artifact" | jq -r '.name')
run_id=$(echo "$artifact" | jq -r '.workflow_run.id')
version=$(echo "$name" | sed 's/zizq-binary-v//')

echo "Found: ${name} (version ${version}, run ${run_id})"

# Download and unpack.
mkdir -p "$OUTPUT_DIR"
gh run download "$run_id" \
  --repo "$SERVER_REPO" \
  --name "$name" \
  --dir "$OUTPUT_DIR"

tar -xzf "${OUTPUT_DIR}/zizq-${version}-linux-x86_64.tar.gz" -C "$OUTPUT_DIR"

echo "Server binary: ${OUTPUT_DIR}/zizq"
