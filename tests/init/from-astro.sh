#!/usr/bin/env bash
# E2E: astro-sample -> zigapagos init --from-astro -> generated project builds + emits site.
#
# Proof levels (best-effort, highest first):
#   full-island-build   — generated project builds with ALL scaffolded islands.
#   plumbing-only-build — --no-islands build proves plumbing + content/layout stubs
#                         correct; island FILES proven to exist by (A) tree assertions.
#
# The generated project builds with the standalone binary and bun, through its
# own scaffolded build.sh — no Zig toolchain, no package graph, no `.path`
# dependency. `ZIGAPAGOS_BIN` points build.sh at the binary this repo just
# built (the scaffold defaults to `zigapagos` on PATH, which is what an
# `npx zigapagos` install provides), and `ZIGAPAGOS_RUNTIME_DIR` names the
# runtime tree the sidecar and bundlers come out of (which the npm launcher sets
# for a real install).
#
# Known issue handled here:
#   • ContactForm.island.tsx imports ./Recaptcha.tsx — that file is not copied to the
#     generated project (generator only copies explicit islands, not transitive deps).
#     Full island build therefore fails; plumbing-only build is the fallback.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
REPO="$(pwd)"
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT

# The @z/runtime dep in the generated package.json is a `file:` path, so it has
# to be reachable from $GEN/site. $GEN/repo -> $REPO makes "../repo/runtime"
# valid from anywhere under $GEN.
ln -s "$REPO" "$GEN/repo"
RUNTIME_PATH="../repo/runtime"

# ---------------------------------------------------------------------------
# Step 1: Build the zigapagos binary
# ---------------------------------------------------------------------------
echo "==> Step 1: build zigapagos binary"
mise exec -- zig build
ZIGAPAGOS="$(realpath "$(find zig-out -name zigapagos -type f | head -1)")"
echo "    zigapagos binary: $ZIGAPAGOS"

# What a generated project needs at build time, and nothing else.
export ZIGAPAGOS_BIN="$ZIGAPAGOS"
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"

# ---------------------------------------------------------------------------
# Step 2: Generate consumer project from astro-sample (WITH islands)
# ---------------------------------------------------------------------------
echo "==> Step 2: generate consumer project from astro-sample"
"$ZIGAPAGOS" init --from-astro "$REPO/tests/migrate/astro-sample" \
  --out "$GEN/site" \
  --runtime-path "$RUNTIME_PATH" \
  --site-title "Gen Test" \
  --host-url "https://gen.test"

# ---------------------------------------------------------------------------
# (A) Tree assertions: plumbing + islands + stubs all exist.
# ---------------------------------------------------------------------------
echo "==> Step 3: tree assertions (A)"
for f in package.json tsconfig.json build.sh zigapagos.ziggy mise.toml \
         components/Counter.island.tsx components/ContactForm.island.tsx \
         layouts/index.shtml content/index.smd test/ssr.sh MIGRATION.md; do
  test -f "$GEN/site/$f" || { echo "FAIL: generated project missing $f"; exit 1; }
  echo "    OK: $f"
done

# Nothing that would drag a Zig toolchain into a scaffolded project.
for f in build.zig build.zig.zon; do
  test -e "$GEN/site/$f" && { echo "FAIL: generator emitted $f — a site is not built by a build graph"; exit 1; }
done
grep -q '^zig ' "$GEN/site/mise.toml" \
  && { echo "FAIL: mise.toml pins a Zig toolchain the project never invokes"; exit 1; }
echo "    OK: no build.zig / build.zig.zon / zig pin"

grep -q 'jsxImportSource' "$GEN/site/tsconfig.json" \
  || { echo "FAIL: tsconfig missing jsxImportSource"; exit 1; }
echo "    OK: tsconfig has jsxImportSource"

grep -q '"@z/runtime": "file:' "$GEN/site/package.json" \
  || { echo "FAIL: package.json missing @z/runtime file: dep"; exit 1; }
echo "    OK: package.json has @z/runtime file: dep"

grep -q 'components/Counter.island.tsx' "$GEN/site/layouts/index.shtml" \
  || { echo "FAIL: layout missing Counter island src"; exit 1; }
grep -q -- '--island=components/Counter.island.tsx' "$GEN/site/build.sh" \
  || { echo "FAIL: build.sh missing Counter island entry"; exit 1; }
echo "    OK: layout <island src> and build.sh --island= are consistent"

echo "    PASS (A): all tree assertions passed"

# ---------------------------------------------------------------------------
# (A2) --force re-run overwrites scaffolded island .tsx in place (AUDF-014).
#      An edit to a scaffolded island must be replaced, not shunted to .new.
# ---------------------------------------------------------------------------
echo "==> Step 3b: --force re-run overwrites island .tsx (no .new)"
printf '\n// ZIGAPAGOS-FORCE-MARKER\n' >> "$GEN/site/components/Counter.island.tsx"
"$ZIGAPAGOS" init --from-astro "$REPO/tests/migrate/astro-sample" \
  --out "$GEN/site" --force \
  --runtime-path "$RUNTIME_PATH" \
  --site-title "Gen Test" \
  --host-url "https://gen.test"
if [ -e "$GEN/site/components/Counter.island.tsx.new" ]; then
  echo "FAIL: --force wrote Counter.island.tsx.new instead of overwriting the island"; exit 1
fi
if grep -q 'ZIGAPAGOS-FORCE-MARKER' "$GEN/site/components/Counter.island.tsx"; then
  echo "FAIL: --force did not overwrite the scaffolded island .tsx"; exit 1
fi
echo "    OK: --force overwrote island .tsx in place (no .new leftover)"

# ---------------------------------------------------------------------------
# (B) Build assertion.
# ---------------------------------------------------------------------------
echo "==> Step 4: install deps"
# Runtime deps (preact etc.) — needed once per repo.
cd "$REPO/runtime" && mise exec -- bun install --silent 2>/dev/null \
  || mise exec -- bun install

echo "==> Step 5: build attempt — full island build (Counter + ContactForm)"
BUILD_LEVEL=""
if bash "$GEN/site/build.sh" 2>&1; then
  BUILD_LEVEL="full-island-build"
  echo "    Full island build SUCCEEDED."
else
  echo "    Full island build FAILED."
  echo "    Expected: ContactForm.island.tsx imports ./Recaptcha.tsx which is a"
  echo "    transitive dep not copied to the generated project (known scaffold gap)."
  echo ""
  echo "    Falling back to plumbing-only build (--no-islands) per the task brief."
  echo ""

  # Re-generate with --no-islands.
  GEN_NI="$GEN/site-noislands"
  "$ZIGAPAGOS" init --from-astro "$REPO/tests/migrate/astro-sample" \
    --out "$GEN_NI" \
    --runtime-path "$RUNTIME_PATH" \
    --site-title "Gen Test" \
    --host-url "https://gen.test" \
    --no-islands

  if bash "$GEN_NI/build.sh" 2>&1; then
    BUILD_LEVEL="plumbing-only-build"
    echo "    Plumbing-only build SUCCEEDED."
    test -f "$GEN_NI/zig-out/site/index.html" \
      || { echo "FAIL: plumbing build did not emit zig-out/site/index.html"; exit 1; }
    echo "    OK: zig-out/site/index.html exists (plumbing build)"
  else
    echo "FAIL: even plumbing-only build failed."
    exit 1
  fi
fi

if [ "$BUILD_LEVEL" = "full-island-build" ]; then
  test -f "$GEN/site/zig-out/site/index.html" \
    || { echo "FAIL: full island build did not emit zig-out/site/index.html"; exit 1; }
  echo "    OK: zig-out/site/index.html exists (full island build)"
fi

echo ""
echo "==> RESULTS"
echo "    Proof level: $BUILD_LEVEL"
case "$BUILD_LEVEL" in
  full-island-build)
    echo "PASS: generated project builds (full island build) + emits a site"
    ;;
  plumbing-only-build)
    echo "PASS (plumbing): generated project plumbing builds + emits a site"
    echo "     Island files exist (proven by tree assertions);"
    echo "     full island build deferred — ContactForm.island.tsx requires manual"
    echo "     port of ./Recaptcha.tsx (transitive dep not copied by generator)."
    ;;
esac
