#!/usr/bin/env bash
# Doc-drift gate (issue #38): the SPA quickstart in docs/spa.md must BUILD.
#
# docs/spa.md is 1,700+ lines and opened with the full spa/routes schema. The
# on-ramp added for #38 is the first thing a new consumer copies, and a
# quickstart that has quietly stopped compiling is worse than none: it is the
# one snippet a reader trusts without checking, and it is exactly the kind of
# code that rots silently, because prose is not compiled.
#
# So this extracts the quickstart's `.spa.tsx` block OUT of the documentation
# and builds a real site from it with the real binary. Doc-code drift then fails
# CI instead of reaching a reader. The tests/*/*.sh glob picks this file up
# automatically.
#
# The extraction is deliberately keyed to prose rather than to a hidden marker
# comment: the block is the first ```tsx fence after the `## Quickstart` heading.
# A marker would survive a rewrite that moved the snippet somewhere it no longer
# reads as the quickstart; the heading is what a reader navigates by, so binding
# to it means the test breaks when the DOCUMENT changes shape, which is the
# drift worth catching. Every failure below therefore names what to fix.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
DOC="docs/spa.md"

fail() { echo "FAIL: $*"; exit 1; }

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || fail "zig build failed"
fi

BUN="$(command -v bun || true)"
[[ -n "$BUN" ]] || fail "bun not found on PATH -- required to spawn the island sidecar"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- (1) extract -------------------------------------------------------------
# awk, not sed: the state machine (seen heading -> inside fence) is clearer than
# a range address, and it lets the two distinct failures (no heading, heading
# but no fence) be told apart below.
awk '
  /^## Quickstart/            { seen = 1; next }
  seen && /^```tsx$/          { infence = 1; next }
  infence && /^```$/          { exit }
  infence                     { print }
' "$DOC" > "$WORK/app.spa.tsx"

grep -qE '^## Quickstart' "$DOC" \
  || fail "$DOC has no '## Quickstart' heading -- the on-ramp added for #38 is gone, or was renamed; update this test's extraction along with it"
[[ -s "$WORK/app.spa.tsx" ]] \
  || fail "$DOC's '## Quickstart' section has no \`\`\`tsx block -- the quickstart must carry the copyable .spa.tsx source"

# Guard against extracting something that is not the quickstart: the two exports
# the build reads are what make a file an SPA entry at all.
grep -q 'export const spa' "$WORK/app.spa.tsx" \
  || fail "the extracted block has no 'export const spa' -- wrong fence extracted, or the quickstart no longer shows the SPA declaration"
grep -q 'export const routes' "$WORK/app.spa.tsx" \
  || fail "the extracted block has no 'export const routes' -- wrong fence extracted, or the quickstart no longer shows the route table"

# --- (2) a site around it ----------------------------------------------------
SITE="$WORK/site"; OUT="$WORK/out"
mkdir -p "$SITE/app" "$SITE/node_modules/@z"
cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"
ln -s "$REPO/runtime" "$SITE/node_modules/@z/runtime"
cp "$WORK/app.spa.tsx" "$SITE/app/app.spa.tsx"
cat > "$SITE/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler",
    "paths": {
      "react/jsx-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"],
      "react/jsx-dev-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"]
    }
  }
}
JSON

# The base is read out of the snippet rather than hardcoded here: the build
# validates that --spa's base matches `export const spa.base`, so hardcoding
# would turn a doc that changed its base into a confusing build failure instead
# of a passing test.
BASE="$(grep -oE 'base:[[:space:]]*"[^"]*"' "$WORK/app.spa.tsx" | head -1 | sed -E 's/.*"(.*)"/\1/')"
[[ -n "$BASE" ]] || fail "the quickstart's 'export const spa' declares no base"

# --- (3) build ---------------------------------------------------------------
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force \
    "--bun=$BUN" \
    "--island-sidecar=$REPO/runtime/sidecar/render.ts" \
    --island-src-dir=. \
    "--spa=app/app.spa.tsx|$BASE" ) >"$WORK/build.log" 2>&1 \
  || { sed -n '1,60p' "$WORK/build.log"; fail "the quickstart in $DOC does not build"; }

# --- (4) assert it produced a working SPA, not just exit 0 -------------------
# A build that emitted nothing would also exit 0, so pin the artifacts and the
# two properties the quickstart's prose actually promises. An existence check
# alone would pass on an empty shell, which is the failure mode #59 records.
SHELL_HTML="$OUT${BASE}/index.html"
[[ -f "$SHELL_HTML" ]] || fail "no prerendered shell at $SHELL_HTML -- the quickstart built but produced no route skeleton"
grep -q 'id="z-spa-root" data-z-spa' "$SHELL_HTML" \
  || fail "$SHELL_HTML carries no data-z-spa hydration root -- it is not an SPA shell"

# "Every route is a real file [with] HTML with the component already rendered
# into it": the index route's own markup must be IN the shell, not just a mount
# point. The h1 comes from the snippet's Home component.
grep -q '<h1>Home</h1>' "$SHELL_HTML" \
  || fail "$SHELL_HTML has an empty hydration root -- the index route was not server-rendered, which is the quickstart's central claim"

# "href on a <Link> is base-relative": the snippet writes href="/about" and the
# emitted shell must carry the composed /app/about. A bare grep for "/about"
# would pass on the unresolved source string, so match the resolved form and
# assert the unresolved one is absent.
grep -q 'href="'"$BASE"'/about"' "$SHELL_HTML" \
  || fail "$SHELL_HTML does not resolve <Link href=\"/about\"> against the SPA base -- a visitor without JavaScript gets a dead link"

# The client bundle is installed by build.zig's asset step, not by the CLI used
# here, so assert what THIS build owns: the shell asking for it by URL.
grep -qE '<link rel="modulepreload" href="/spa/app\.js">' "$SHELL_HTML" \
  || fail "$SHELL_HTML does not reference /spa/app.js -- the shell would never hydrate"
grep -q 'mountSpa' "$SHELL_HTML" \
  || fail "$SHELL_HTML has no mountSpa bootstrap -- nothing would hydrate the prerendered markup"
[[ -f "$OUT${BASE}/routing-manifest.json" ]] \
  || fail "no routing manifest at $OUT${BASE}/routing-manifest.json"

# Every non-index route in the snippet must have its own prerendered shell --
# that is the claim the quickstart makes about what a build gives you, and it is
# what makes a deep link work without JavaScript. Parsed out of the snippet so
# adding a route to the doc extends the assertion for free.
while IFS= read -r route; do
  [[ "$route" == "/" ]] && continue
  [[ -f "$OUT${BASE}${route}/index.html" ]] \
    || fail "route '$route' in the quickstart has no shell at $OUT${BASE}${route}/index.html"
done < <(grep -oE 'path:[[:space:]]*"[^"]*"' "$WORK/app.spa.tsx" | sed -E 's/.*"(.*)"/\1/')

# ...and the converse, which the loop above cannot catch on its own: every
# <Link> the snippet writes must point at a route that was actually emitted.
# Deriving the route assertions from the snippet means deleting a route from the
# snippet also deletes its assertion, so a quickstart that linked to a route it
# no longer declares would stay green -- while showing the reader a dead link.
while IFS= read -r href; do
  [[ "$href" == /* ]] || continue          # base-relative only; external is not ours
  target="$OUT${BASE}${href%/}/index.html"
  [[ "$href" == "/" ]] && target="$OUT${BASE}/index.html"
  [[ -f "$target" ]] \
    || fail "the quickstart's <Link href=\"$href\"> has no emitted target at $target -- the snippet links to a route it does not declare"
done < <(grep -oE '<Link href="[^"]*"' "$WORK/app.spa.tsx" | sed -E 's/.*"(.*)"/\1/')

echo PASS
