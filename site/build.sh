#!/usr/bin/env bash
# Build the zigapagos marketing site.
#
# This is the ONE canonical invocation: CI, pages.yml and every script under
# site/test/ call this file rather than restating the flags, so there is exactly
# one place where the island and SPA entries are declared.
#
# `zigapagos` is a standalone executable. Nothing here is a build graph: the
# binary is either handed over in ZIGAPAGOS_BIN, already sitting in the
# repository's zig-out/bin, or compiled once — and after that a site build is
# the binary, bun, and this file.
set -euo pipefail
cd "$(dirname "$0")"
SITE="$PWD"
REPO="$(cd .. && pwd)"

ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos ($ZIGAPAGOS missing)..."
  ( cd "$REPO" && zig build ) || { echo "FAIL: zig build failed"; exit 1; }
fi

command -v bun >/dev/null || { echo "FAIL: bun not found on PATH"; exit 1; }

bun install --frozen-lockfile 2>/dev/null || bun install
# Mirrors are gitignored build artifacts, so a fresh clone has none. Generating
# them here rather than assuming a prior step did: the docs sidebar links to
# mirrored pages by name, and a missing mirror fails the build pointing at the
# sidebar instead of at the real cause.
bun run scripts/gen-docs-mirror.ts

# The runtime tree this build's sidecar, bundlers and slicers come out of. Set
# for a checkout the same way the npm launcher sets it for an install: the SPA
# and slice drivers are paths INTO that tree and have no flags of their own.
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"

# Islands and SPAs are ENUMERATED rather than left to `zigapagos release`'s
# discovery scan. Discovery finds the same set here today, but it walks the
# filesystem — so its order (and therefore the islands slicer's input order) is
# fs-dependent, it does not skip the gitignored zig-pkg/ vendored tree, and a
# discovered SPA carries an empty declared base, which silently skips the
# base-agreement check between `--spa=<src>|<base>` and the module's own
# `spa.base` that this site deliberately exercises.
exec "$ZIGAPAGOS" release \
  --force \
  --output="$SITE/zig-out/site" \
  --island=components/Counter.island.tsx \
  --island=components/CodeTabs.island.tsx \
  --island=components/DirectiveDemo.island.tsx \
  --island=components/MigrateDiff.island.tsx \
  --spa='demo/app.spa.tsx|/demos/app' \
  --spa-not-found=app \
  --island-props-check=error \
  --bun=bun \
  --css-minify-driver="$REPO/runtime/sidecar/minify-css.ts" \
  "$@"
