#!/usr/bin/env bash
# parity-bundle.sh — byte-parity guard between bundle-island.ts driver output
# and an equivalent raw `bun build` invocation.
#
# Asserts: for both the Hero island and the zigapagos-runtime, the driver's
# output is byte-for-byte identical to what `bun build` would produce directly.
# This guards against the driver accidentally altering output bytes (e.g. via
# a buggy onLoad that mutates contents).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(cd ../.. && pwd)"

# ── 0. Install deps ────────────────────────────────────────────────────────────
cd "$REPO_ROOT/runtime" && mise exec -- bun install >/dev/null
cd - >/dev/null
mise exec -- bun install >/dev/null

# ── 1. Build via driver (build.sh) ────────────────────────────────────────────
bash build.sh

DRIVER_HERO="zig-out/site/islands/Hero.island.js"
DRIVER_RT="zig-out/site/zigapagos-runtime.js"
test -f "$DRIVER_HERO" || { echo "FAIL: driver hero bundle missing"; exit 1; }
test -f "$DRIVER_RT"   || { echo "FAIL: driver runtime bundle missing"; exit 1; }

# ── 2. Build via raw `bun build` (no plugin, pure CLI) ────────────────────────
# Island: cwd = tsx-site, matching the `--island-src-dir` the driver is spawned
# with (src/cli/release.zig's `bundleIslands`), so the consumer tsconfig's
# jsxImportSource drives the JSX transform in both invocations. NODE_ENV and
# --minify are load-bearing: bun picks jsx-runtime vs jsx-dev-runtime from its
# own NODE_ENV, and the driver minifies every island.
NODE_ENV=production mise exec -- bun build \
  components/Hero.island.tsx \
  --external=@z/runtime --external=@z/runtime/jsx-runtime \
  --format=esm --minify \
  --outfile=/tmp/parity-plain-hero.js \
  >/dev/null

# Runtime: the entry is an absolute path either way, so cwd cannot change the
# bytes; repo root is used here only because that is where the source lives.
(cd "$REPO_ROOT" && mise exec -- bun build \
  runtime/src/browser-entry.ts \
  --format=esm --minify \
  --outfile=/tmp/parity-plain-runtime.js \
  >/dev/null)

# ── 3. Compare ─────────────────────────────────────────────────────────────────
cmp "$DRIVER_HERO" /tmp/parity-plain-hero.js \
  || { echo "FAIL: Hero island driver output != raw bun build (byte mismatch)"; /usr/bin/diff "$DRIVER_HERO" /tmp/parity-plain-hero.js || true; exit 1; }
echo "PASS: Hero.island.js driver == raw bun build (byte-identical)"

cmp "$DRIVER_RT" /tmp/parity-plain-runtime.js \
  || { echo "FAIL: zigapagos-runtime.js driver output != raw bun build (byte mismatch)"; /usr/bin/diff "$DRIVER_RT" /tmp/parity-plain-runtime.js || true; exit 1; }
echo "PASS: zigapagos-runtime.js driver == raw bun build (byte-identical)"
