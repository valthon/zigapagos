#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."  # repo root

ZIG="mise exec -- zig"

# Build the CLI (suppress output). This is `zig build` building ZIGAPAGOS, not a
# site: the subject here is the binary's own `migrate --doctor`.
$ZIG build >/dev/null 2>&1 || true

BIN="zig-out/bin/zigapagos"

if [ ! -x "$BIN" ]; then
  echo "FAIL: binary not found at $BIN"
  exit 1
fi

# --- (a) Clean island: checklist prints, exit 0, component name is Flagged ---
set +e
out=$("$BIN" migrate --doctor examples/tsx-site/components/Flagged.island.tsx 2>&1)
rc=$?
set -e

if [ $rc -ne 0 ]; then
  echo "FAIL: expected exit 0 for clean island (Flagged.island.tsx), got $rc"
  echo "$out"
  exit 1
fi

if ! echo "$out" | grep -q "Port doctor: Flagged"; then
  echo "FAIL: expected 'Port doctor: Flagged' in output (clean island)"
  echo "Got: $out"
  exit 1
fi

# --- (b) Dirty fixture (bare npm import): must exit non-zero ---
set +e
"$BIN" migrate --doctor examples/tsx-site/test/fixtures/Dirty.tsx >/dev/null 2>&1
rc=$?
set -e

if [ $rc -eq 0 ]; then
  echo "FAIL: expected non-zero exit for guardrail violation (Dirty.tsx), got 0"
  exit 1
fi

echo "doctor.sh: PASS"
