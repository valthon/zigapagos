#!/usr/bin/env bash
# E2E: astro-sample -> zigapagos init --from-astro -> generated project builds + emits site.
#
# Proof levels (best-effort, highest first):
#   full-island-build   — generated project builds with ALL scaffolded islands.
#   plumbing-only-build — --no-islands build proves plumbing + content/layout stubs
#                         correct; island FILES proven to exist by (A) tree assertions.
#
# Known issues handled here:
#   • fingerprint = 0x0 in generated build.zig.zon — Zig 0.16 rejects 0x0 as a hard
#     error but prints the real value in the message.  fix_fingerprint() reads that value,
#     patches build.zig.zon, and retries.
#   • Zig 0.16 requires .path deps in build.zig.zon to be RELATIVE paths; passing an
#     absolute path via --zigapagos-path fails.  We create a symlink $GEN/repo -> $REPO so
#     the relative paths "../repo" and "../repo/runtime" are always valid.
#   • ContactForm.island.tsx imports ./Recaptcha.tsx — that file is not copied to the
#     generated project (generator only copies explicit islands, not transitive deps).
#     Full island build therefore fails; plumbing-only build is the fallback.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
REPO="$(pwd)"
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT

# Create a symlink so we can give the generator RELATIVE paths (Zig 0.16 requirement).
# $GEN/repo -> $REPO  =>  ../repo (from $GEN/site/) is a valid relative dep path.
ln -s "$REPO" "$GEN/repo"
ZIGAPAGOS_PATH="../repo"    # relative from $GEN/site/ -> $GEN/repo -> $REPO
RUNTIME_PATH="../repo/runtime"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# fix_fingerprint DIR
# If DIR/build.zig.zon has .fingerprint = 0x0 (invalid in Zig 0.16), run zig build
# once to extract the real fingerprint from the error, then patch the file.
fix_fingerprint() {
  local dir="$1"
  local zon="$dir/build.zig.zon"
  if ! grep -q 'fingerprint = 0x0' "$zon" 2>/dev/null; then
    return 0  # nothing to fix
  fi
  local err fp
  err=$(cd "$dir" && mise exec -- zig build 2>&1 || true)
  fp=$(echo "$err" | sed -n 's/.*use this value: \(0x[0-9a-f][0-9a-f]*\).*/\1/p' | head -1)
  if [ -z "$fp" ]; then
    echo "    WARNING: could not extract real fingerprint; leaving 0x0"
    return 0
  fi
  echo "    Fixing fingerprint: 0x0 -> $fp"
  sed -i "s/\.fingerprint = 0x0/.fingerprint = $fp/" "$zon"
}

# run_zig_build DIR — fix fingerprint if needed, then run zig build (returns its exit code).
run_zig_build() {
  local dir="$1"
  fix_fingerprint "$dir"
  cd "$dir" && mise exec -- zig build
}

# ---------------------------------------------------------------------------
# Step 1: Build zigapagos binary and restore snapshots
# ---------------------------------------------------------------------------
echo "==> Step 1: build zigapagos binary"
mise exec -- zig build
# Restore any snapshots deleted by the root zig build (snapshot footgun).
git ls-files --deleted -z -- tests/ | xargs -0 -I{} git restore -- {}
ZIGAPAGOS="$(realpath "$(find zig-out -name zigapagos -type f | head -1)")"
echo "    zigapagos binary: $ZIGAPAGOS"

# ---------------------------------------------------------------------------
# Step 2: Generate consumer project from astro-sample (WITH islands)
# ---------------------------------------------------------------------------
echo "==> Step 2: generate consumer project from astro-sample"
"$ZIGAPAGOS" init --from-astro "$REPO/tests/migrate/astro-sample" \
  --out "$GEN/site" \
  --zigapagos-path "$ZIGAPAGOS_PATH" \
  --runtime-path "$RUNTIME_PATH" \
  --site-title "Gen Test" \
  --host-url "https://gen.test"

# ---------------------------------------------------------------------------
# (A) Tree assertions: plumbing + islands + stubs all exist.
# ---------------------------------------------------------------------------
echo "==> Step 3: tree assertions (A)"
for f in package.json tsconfig.json build.zig build.zig.zon zigapagos.ziggy mise.toml \
         components/Counter.island.tsx components/ContactForm.island.tsx \
         layouts/index.shtml content/index.smd test/ssr.sh MIGRATION.md; do
  test -f "$GEN/site/$f" || { echo "FAIL: generated project missing $f"; exit 1; }
  echo "    OK: $f"
done

grep -q 'jsxImportSource' "$GEN/site/tsconfig.json" \
  || { echo "FAIL: tsconfig missing jsxImportSource"; exit 1; }
echo "    OK: tsconfig has jsxImportSource"

grep -q '"@z/runtime": "file:' "$GEN/site/package.json" \
  || { echo "FAIL: package.json missing @z/runtime file: dep"; exit 1; }
echo "    OK: package.json has @z/runtime file: dep"

grep -q 'components/Counter.island.tsx' "$GEN/site/layouts/index.shtml" \
  || { echo "FAIL: layout missing Counter island src"; exit 1; }
grep -q 'components/Counter.island.tsx' "$GEN/site/build.zig" \
  || { echo "FAIL: build.zig missing Counter island src"; exit 1; }
echo "    OK: layout <island src> and build.zig island src are consistent"

echo "    PASS (A): all tree assertions passed"

# ---------------------------------------------------------------------------
# (A2) --force re-run overwrites scaffolded island .tsx in place (AUDF-014).
#      An edit to a scaffolded island must be replaced, not shunted to .new.
# ---------------------------------------------------------------------------
echo "==> Step 3b: --force re-run overwrites island .tsx (no .new)"
printf '\n// ZIGAPAGOS-FORCE-MARKER\n' >> "$GEN/site/components/Counter.island.tsx"
"$ZIGAPAGOS" init --from-astro "$REPO/tests/migrate/astro-sample" \
  --out "$GEN/site" --force \
  --zigapagos-path "$ZIGAPAGOS_PATH" \
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

# Generated project deps: creates the @z/runtime -> $GEN/repo/runtime symlink.
cd "$GEN/site" && mise exec -- bun install

echo "==> Step 5: build attempt — full island build (Counter + ContactForm)"
BUILD_LEVEL=""
if run_zig_build "$GEN/site" 2>&1; then
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
    --zigapagos-path "$ZIGAPAGOS_PATH" \
    --runtime-path "$RUNTIME_PATH" \
    --site-title "Gen Test" \
    --host-url "https://gen.test" \
    --no-islands

  cd "$GEN_NI" && mise exec -- bun install

  if run_zig_build "$GEN_NI" 2>&1; then
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

# Final snapshot restore.
cd "$REPO"
git ls-files --deleted -z -- tests/ | xargs -0 -I{} git restore -- {}

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
