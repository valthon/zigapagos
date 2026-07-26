#!/usr/bin/env bash
# Branding gate: fail if any "zine" reference survives outside the attribution
# allowlist below. Upstream attribution is legitimate and lives in LICENSE,
# README.md and CLAUDE.md; everything else must use the zigapagos name.
set -euo pipefail
cd "$(dirname "$0")/.."

matches=$(git grep -i -n zine -- \
  ':!LICENSE' \
  ':!README.md' \
  ':!CLAUDE.md' \
  ':!docs/upstream' \
  ':!src/hacks/CoreFoundation.h.zig' \
  ':!zig-pkg' \
  ':!tests/branding.sh' \
  || true)

if [ -n "$matches" ]; then
  echo "FAIL: non-attribution 'zine' references remain:"
  echo "$matches"
  echo
  echo "count: $(echo "$matches" | wc -l)"
  exit 1
fi
echo "PASS: no stray zine references"
