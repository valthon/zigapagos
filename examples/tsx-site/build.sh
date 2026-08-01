#!/usr/bin/env bash
# Build the tsx-site example.
#
# This is the ONE canonical invocation: CI and every script under test/ call
# this file rather than restating the flags, so there is exactly one place where
# the island and SPA entries are declared.
#
# `zigapagos` is a standalone executable. Nothing here is a build graph: the
# binary is either handed over in ZIGAPAGOS_BIN, already sitting in the
# repository's zig-out/bin, or compiled once — and after that a site build is
# the binary, bun, and this file.
set -euo pipefail
cd "$(dirname "$0")"
SITE="$PWD"
REPO="$(cd ../.. && pwd)"

ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos ($ZIGAPAGOS missing)..."
  ( cd "$REPO" && zig build ) || { echo "FAIL: zig build failed"; exit 1; }
fi

command -v bun >/dev/null || { echo "FAIL: bun not found on PATH"; exit 1; }

bun install --frozen-lockfile 2>/dev/null || bun install

# The runtime tree this build's sidecar, bundlers and slicers come out of. Set
# for a checkout the same way the npm launcher sets it for an install: the SPA
# and slice drivers are paths INTO that tree and have no flags of their own.
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"

# Islands and SPAs are ENUMERATED rather than left to `zigapagos release`'s
# discovery scan — see site/build.sh for why. It matters more here: this project
# carries a vendored `vendor/` tree and a gitignored `zig-pkg/`, neither of which
# the scan skips, and the five SPAs exist precisely to pin per-deployable runtime
# slicing against DECLARED bases (`public` and `admin` slice, `fallback` and
# `compat` bail to the shared runtime), which a discovered SPA's empty base
# would stop checking.
#
# `--spa-not-found=app` makes the universal 404.html reuse the `app` SPA's "/"
# shell explicitly, so declaration order does not decide it.
exec "$ZIGAPAGOS" release \
  --force \
  --output="$SITE/zig-out/site" \
  --island=components/Hero.island.tsx \
  --island=components/Flagged.island.tsx \
  --island=components/Panel.island.tsx \
  --island=components/Widget.island.tsx \
  --spa='app/app.spa.tsx|/app' \
  --spa='slices/public.spa.tsx|/public' \
  --spa='slices/admin.spa.tsx|/admin' \
  --spa='slices/fallback.spa.tsx|/fallback' \
  --spa='slices/compat.spa.tsx|/compat' \
  --spa-not-found=app \
  --island-props-check=error \
  --bun=bun \
  --css-minify-driver="$REPO/runtime/sidecar/minify-css.ts" \
  "$@"
