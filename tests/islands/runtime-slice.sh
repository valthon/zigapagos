#!/usr/bin/env bash
# e2e for the per-SITE islands runtime slice (issue #52).
#
# Every page carrying an island used to load the full shared
# /zigapagos-runtime.js — the whole barrel, including the router, the flags
# client, observability and the entire preact/compat React surface — so a page
# whose one island is a 433-byte counter shipped ~58 KB of runtime it never
# calls. `runtime/scripts/build-islands-runtime.ts` now analyses the BUILT
# island bundles and (when it can prove them safe) emits a sliced
# /islands/_runtime.js, publishing a manifest of the islands it covers.
#
# This script exercises the ZIG half of that end to end — CLI -> root -> Build ->
# worker -> pass — against a HAND-WRITTEN manifest, so it needs no consumer
# `zig build` and stays fast enough for the PR path. The bundler half is covered
# by runtime/scripts/slice-islands.test.ts. There is deliberately no consumer-side
# e2e: driving the real bundles.zig -> slicer wiring needs a full
# `examples/tsx-site` build, which is too slow for the PR path, so that seam is
# exercised by hand before release rather than by a script here.
#
# Four parts, each one able to fail independently:
#   (1) a page whose EVERY island the manifest covers names ONLY the slice —
#       and one of its islands is written `./components/…` while the manifest
#       lists the bare module name, which is what pins the module-name join
#       (a raw-src compare would silently fall back forever and every unit test
#       that hand-writes matching strings would still pass);
#   (2) a page carrying ONE uncovered island names ONLY the shared runtime.
#       Asserting the slice is *absent* matters as much as asserting the shared
#       one is present: emitting both is the two-Preact catastrophe, and a
#       presence-only check passes through it;
#   (3) a `{"fallback":true}` manifest and NO --islands-slice at all produce
#       BYTE-IDENTICAL output trees FROM A CLEAN OUTPUT DIR — the pin that the
#       new flag's inert state is genuinely inert. (They differ on a DIRTY dir,
#       and deliberately: only the manifest-carrying invocation prunes a stale
#       slice. See src/root.zig; part (4) covers that path.)
#   (4) a stale /islands/_runtime.js from a previous SLICED build is pruned when
#       this build's decision is FALLBACK (nothing else prunes the output tree).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

# The real Bun sidecar SSRs the islands. Fail loudly rather than skip — a test
# that silently skips in CI is a test that doesn't exist.
command -v bun >/dev/null 2>&1 || { echo "FAIL: bun not found on PATH (required to run the real island sidecar)"; exit 1; }

if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  echo "runtime/node_modules missing; running 'bun install --frozen-lockfile'..."
  ( cd "$REPO/runtime" && bun install --frozen-lockfile ) \
    || { echo "FAIL: bun install --frozen-lockfile failed in runtime/"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

SITE="$WORK/site"
mkdir -p "$SITE/content" "$SITE/layouts" "$SITE/assets" "$SITE/components"
: > "$SITE/assets/.keep"

cat > "$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Islands Runtime Slice Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF

for c in Clean Also Mixed; do
  cat > "$SITE/components/$c.island.tsx" <<EOF
export interface Props { start: number }
export default function $c({ start }: Props) {
  return \`$c-SSR-\${start}\`;
}
EOF
done

# Page A's layout: only islands the manifest covers. `Clean` is deliberately
# spelled with a `./` prefix — build.zig would declare it as
# "components/Clean.island.tsx", and both must resolve to module name
# `Clean.island` for the manifest join to hit.
cat > "$SITE/layouts/covered.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$site.title"></title>
  </head>
  <body>
    <div :html="$page.content()"></div>
    <island src="./components/Clean.island.tsx" client:load :props='{ .start = 1 }'></island>
    <island src="components/Also.island.tsx" client:load :props='{ .start = 2 }'></island>
  </body>
</html>
EOF

# Page B's layout: one island the manifest does NOT cover.
cat > "$SITE/layouts/uncovered.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$site.title"></title>
  </head>
  <body>
    <div :html="$page.content()"></div>
    <island src="components/Clean.island.tsx" client:load :props='{ .start = 3 }'></island>
    <island src="components/Mixed.island.tsx" client:load :props='{ .start = 4 }'></island>
  </body>
</html>
EOF

write_page() { # PATH LAYOUT
  cat > "$1" <<EOF
---
.title = "P",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "$2",
.draft = false,
---
Prose.
EOF
}
write_page "$SITE/content/index.smd" covered.shtml
write_page "$SITE/content/other.smd" uncovered.shtml

cat > "$WORK/sliced.json" <<'EOF'
{"runtime":"/islands/_runtime.js","islands":["Clean.island","Also.island"]}
EOF
cat > "$WORK/fallback.json" <<'EOF'
{"fallback":true}
EOF

release() { # OUT [EXTRA_ARGS...]
  local out="$1"; shift
  ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$out" --force --bun="$(command -v bun)" \
      "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. "$@" )
}

# --- (1)+(2): the sliced manifest, both pages -------------------------------
OUT_S="$WORK/out-sliced"
release "$OUT_S" "--islands-slice=$WORK/sliced.json" >"$WORK/sliced.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/sliced.log"; fail "the sliced-manifest build failed"; }

A="$OUT_S/index.html"
B="$OUT_S/other/index.html"
[[ -f "$A" ]] || fail "no index.html emitted"
[[ -f "$B" ]] || fail "no other/index.html emitted"

grep -q '"@z/runtime":"/islands/_runtime.js"' "$A" \
  || { cat "$A"; fail "(1) the covered page's import map does not point at the slice"; }
grep -q '<link rel="modulepreload" href="/islands/_runtime.js">' "$A" \
  || { cat "$A"; fail "(1) the covered page does not modulepreload the slice"; }
grep -q '<script type="module" src="/islands/_runtime.js"></script>' "$A" \
  || { cat "$A"; fail "(1) the covered page does not load the slice as its runtime module"; }
if grep -q 'zigapagos-runtime.js' "$A"; then
  cat "$A"
  fail "(1) the SHARED runtime survives on a fully-covered page — a page that loads both gets two Preacts"
fi
echo "PASS: (1) a page whose every island is covered names only /islands/_runtime.js (module-name join incl. a ./-prefixed src)"

grep -q '"@z/runtime":"/zigapagos-runtime.js"' "$B" \
  || { cat "$B"; fail "(2) the uncovered page's import map does not point at the shared runtime"; }
grep -q '<script type="module" src="/zigapagos-runtime.js"></script>' "$B" \
  || { cat "$B"; fail "(2) the uncovered page does not load the shared runtime"; }
if grep -q '_runtime.js' "$B"; then
  cat "$B"
  fail "(2) the SLICE URL survives on a page carrying an uncovered island"
fi
echo "PASS: (2) one uncovered island forces the shared runtime for the whole page"

# --- (3) fallback manifest == no flag at all, byte for byte (clean dirs) ----
OUT_F="$WORK/out-fallback"
OUT_N="$WORK/out-noflag"
release "$OUT_F" "--islands-slice=$WORK/fallback.json" >"$WORK/fallback.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/fallback.log"; fail "the fallback-manifest build failed"; }
release "$OUT_N" >"$WORK/noflag.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/noflag.log"; fail "the no-flag build failed"; }

grep -q '<script type="module" src="/zigapagos-runtime.js"></script>' "$OUT_F/index.html" \
  || fail "(3) the fallback build's page does not load the shared runtime"
if grep -rq '_runtime.js' "$OUT_F"; then
  fail "(3) the fallback build referenced a sliced runtime somewhere"
fi
diff -r "$OUT_F" "$OUT_N" >"$WORK/diff.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/diff.log"; fail "(3) a fallback manifest and an absent --islands-slice produced DIFFERENT output trees"; }
echo "PASS: (3) a fallback manifest and an absent --islands-slice produce byte-identical output"

# --- (4) a stale slice from a previous SLICED build is pruned ---------------
OUT_P="$WORK/out-prune"
mkdir -p "$OUT_P/islands"
echo "stale bytes from a previous sliced build" > "$OUT_P/islands/_runtime.js"
release "$OUT_P" "--islands-slice=$WORK/fallback.json" >"$WORK/prune.log" 2>&1 \
  || { sed -n '1,40p' "$WORK/prune.log"; fail "the prune build failed"; }
if [[ -e "$OUT_P/islands/_runtime.js" ]]; then
  fail "(4) a stale /islands/_runtime.js survived a build whose decision is FALLBACK"
fi
echo "PASS: (4) a stale sliced runtime is pruned when the decision flips to fallback"

echo "ALL PASS: per-page islands runtime slice selection"
