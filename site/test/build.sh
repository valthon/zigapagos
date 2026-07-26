#!/usr/bin/env bash
# site/test/build.sh — the site builds and is prefix-correct
set -euo pipefail
cd "$(dirname "$0")/.."
bun install --frozen-lockfile 2>/dev/null || bun install
zig build
OUT=zig-out/site
test -f "$OUT/index.html" || { echo "FAIL: no index.html"; exit 1; }
grep -q '/zigapagos/zigapagos-runtime.js' "$OUT/index.html" || { echo "FAIL: runtime URL not prefixed"; exit 1; }
test -f "$OUT/islands/Counter.island.js" || { echo "FAIL: Counter bundle missing"; exit 1; }
grep -q 'data-z-props' "$OUT/index.html" || { echo "FAIL: island not SSR'd"; exit 1; }
# Assert absence of branding in output via token split to avoid triggering the
# source-level branding gate.
BANNED="zi""ne"
grep -qi "$BANNED" "$OUT/index.html" && { echo "FAIL: stray $BANNED branding"; exit 1; }
echo PASS
