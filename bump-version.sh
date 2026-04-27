#!/usr/bin/env bash
set -euo pipefail

# Bump the project version.
#
# Usage:
#   ./bump-version.sh           # increment patch (e.g. 0.1.1 -> 0.1.2)
#   ./bump-version.sh 0.2.0     # set an explicit version
#
# Updates:
#   - lib/zizq/version.rb (VERSION constant)
#   - Gemfile.lock (via bundle install)
#   - CHANGELOG.md (adds a new section header)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Read current version from version.rb.
CURRENT=$(ruby -r ./lib/zizq/version -e 'puts Zizq::VERSION')

if [ -z "$CURRENT" ]; then
    echo "Error: could not read current version from lib/zizq/version.rb"
    exit 1
fi

if [ $# -ge 1 ]; then
    NEW="$1"
else
    # Increment patch version.
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    PATCH=$((PATCH + 1))
    NEW="${MAJOR}.${MINOR}.${PATCH}"
fi

if [ "$NEW" = "$CURRENT" ]; then
    echo "Already at version ${CURRENT}."
    exit 0
fi

echo "Bumping version: ${CURRENT} -> ${NEW}"

# Update version.rb.
sed -i "s/VERSION = \"${CURRENT}\"/VERSION = \"${NEW}\"/" lib/zizq/version.rb
echo "  Updated lib/zizq/version.rb"

# Update Gemfile.lock.
bundle install --quiet
echo "  Updated Gemfile.lock"

# Add new CHANGELOG section if it doesn't already exist.
if ! grep -q "^## ${NEW}" CHANGELOG.md 2>/dev/null; then
    sed -i "0,/^## /s//## ${NEW}\n\n\n## /" CHANGELOG.md
    echo "  Added CHANGELOG.md section for ${NEW}"
fi

echo "Done. Version is now ${NEW}."
echo ""
echo "Next steps:"
echo "  1. Edit CHANGELOG.md with release notes"
echo "  2. Commit: git add -A && git commit -m \"Bump version to ${NEW}\""
