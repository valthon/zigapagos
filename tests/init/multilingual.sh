#!/usr/bin/env bash
# E2E: `zigapagos init --multilingual` must fail cleanly, not panic.
#
# Multilingual scaffolding is advertised in `init --help` but not implemented
# yet (see AUD-012).  The unimplemented path used to `@panic("TODO: multilingual
# init")`, which aborts (exit 134) with a debug stack trace and — worse — leaves
# the user staring at an internal crash for a documented flag.  It now exits 1
# with a plain usage error and writes no files.  This test pins that behavior.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
REPO="$(pwd)"

BIN="$REPO/zig-out/bin/zigapagos"
if [ ! -x "$BIN" ]; then
  echo "building zigapagos..."
  mise exec -- zig build
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

set +e
OUT="$(cd "$WORK" && "$BIN" init --multilingual 2>&1)"
CODE=$?
set -e

# 1. Clean exit (1), not a panic/abort (134) and not success (0).
if [ "$CODE" -ne 1 ]; then
  echo "FAIL: expected exit code 1, got $CODE"
  echo "--- output ---"; echo "$OUT"
  exit 1
fi

# 2. A usage error, not a Zig panic / stack trace.
if echo "$OUT" | grep -qi 'panic\|reached unreachable\|TODO'; then
  echo "FAIL: output looks like a panic, not a clean diagnostic:"
  echo "$OUT"
  exit 1
fi
if ! echo "$OUT" | grep -qi 'not implemented yet'; then
  echo "FAIL: expected a 'not implemented yet' diagnostic; got:"
  echo "$OUT"
  exit 1
fi

# 3. No files scaffolded on the failed path.
REMAINING="$(find "$WORK" -mindepth 1)"
if [ -n "$REMAINING" ]; then
  echo "FAIL: init --multilingual created files despite failing:"
  echo "$REMAINING"
  exit 1
fi

echo "PASS: init --multilingual exits 1 cleanly and writes no files"
