#!/usr/bin/env bash
# Isolate the index; never disturb the developer's staged changes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
PROBE="$REPO/tests/.snapshot-index-probe.txt"
trap 'rm -f "$PROBE"; rm -rf "$TMP"' EXIT
cd "$REPO"
export GIT_INDEX_FILE="$TMP/index"
git read-tree HEAD
git add -- "$REPO/tests"
git diff --cached --binary > "$TMP/before"
printf 'untracked snapshot probe\n' > "$PROBE"
if zig build test > "$TMP/test.log" 2>&1; then
  cat "$TMP/test.log"
  echo 'FAIL: untracked snapshot was ignored'
  exit 1
fi
grep -q 'snapshot-index-probe' "$TMP/test.log" || { cat "$TMP/test.log"; exit 1; }
git diff --cached --binary > "$TMP/after"
cmp "$TMP/before" "$TMP/after"
# In particular intent-to-add must not stage the probe's contents.
git diff --cached --exit-code -- "$PROBE"
echo 'PASS: snapshot gate detects new files without staging contents'
