#!/usr/bin/env bash
# e2e for `zigapagos serve` SPA support: the dev server must
# synthesize the same shells + bundles + runtime release produces, so the
# documented SPA dev loop works instead of 404-ing every page and
# 303-redirecting /spa/*.js.
#
# Drives the real dev server against the dogfood SPA (examples/tsx-site,
# app/app.spa.tsx, base "/app": static "/" + "/booking", dynamic "/club/:id")
# and asserts the brief's curl matrix:
#   /app/           -> 200 shell (id="z-spa-root"; importmap BEFORE modulepreload)
#   /app/booking/   -> 200 static shell
#   /app/club/42    -> 200 dynamic shell (the club skeleton, NOT booking's)
#   /app/club/1/, /app/club/2/ -> 200 per-entry staticPaths shells, written to
#                   the serve cache dir (dev/release parity)
#   /app/nope       -> 200 namespace fallback shell (NOT the 404 page)
#   /spa/app.js     -> 200 JS (NOT a 303 redirect — the bug)
#   /zigapagos-runtime.js -> 200 JS
#   a non-SPA path  -> still 404
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
SITE="$REPO/examples/tsx-site"

restore_snapshots() {
  git -C "$REPO" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO" restore -- {}
}

ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
WORK="$(mktemp -d)"
ZLOG="$WORK/zigapagos.log"
ZPID=""

# --- fixture: a real staged file UNDER the SPA base ----------------------------
# examples/tsx-site ships no asset under /app, so we stage one just for this run
# (a genuine installed CSS living under the SPA base "/app") to prove real files
# win over the shell tiers, then restore the fixture on exit so the committed
# dogfood site — and its byte-parity gate — stays untouched.
ZIGGY="$SITE/zigapagos.ziggy"
REAL_ASSET_DIR="$SITE/assets/app"
REAL_ASSET="$REAL_ASSET_DIR/real-asset.css"
REAL_MARKER="zigapagos-real-asset-under-spa-base"

stage_real_asset() {
  mkdir -p "$REAL_ASSET_DIR"
  printf '/* %s */\n.z-real { color: #0f0 }\n' "$REAL_MARKER" > "$REAL_ASSET"
  # Install it unconditionally so the SSG stages it at /app/real-asset.css.
  # Either branch is undone exactly by restore_real_asset's `git restore`.
  if ! grep -q 'static_assets' "$ZIGGY"; then
    # No static_assets field yet: add one right after assets_dir_path.
    awk '{print} /assets_dir_path/ {print "    .static_assets = [\"app/real-asset.css\"],"}' \
      "$ZIGGY" > "$ZIGGY.tmp" && mv "$ZIGGY.tmp" "$ZIGGY"
  elif ! grep -q 'app/real-asset.css' "$ZIGGY"; then
    # A static_assets array already exists: splice our asset in as its first
    # element. The first expression handles an empty `[]`; the `t` branch keeps
    # the second (general `[` case) from re-matching the first's output.
    sed -e 's|\.static_assets = \[\]|.static_assets = ["app/real-asset.css"]|' -e 't' \
        -e 's|\.static_assets = \[|.static_assets = ["app/real-asset.css", |' \
        "$ZIGGY" > "$ZIGGY.tmp" && mv "$ZIGGY.tmp" "$ZIGGY"
  fi
}

restore_real_asset() {
  rm -f "$REAL_ASSET" "$ZIGGY.tmp"
  rmdir "$REAL_ASSET_DIR" 2>/dev/null || true
  git -C "$REPO" restore -- examples/tsx-site/zigapagos.ziggy 2>/dev/null || true
}

cleanup() {
  [[ -n "$ZPID" ]] && kill "$ZPID" 2>/dev/null || true
  rm -rf "$WORK"
  restore_real_asset
  restore_snapshots
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; echo "--- zigapagos log ---"; cat "$ZLOG" 2>/dev/null || true; exit 1; }

free_port() {
  mise exec -- bun -e 'const s=Bun.serve({port:0,fetch(){return new Response("")}});const p=s.port;s.stop();process.stdout.write(String(p))'
}

# --- deps + binary ------------------------------------------------------------
# Runtime deps (preact*) so the Bun sidecar can SSR; consumer deps create the
# node_modules/@z/runtime symlink the SPA bundle + sidecar resolve.
( cd "$REPO/runtime" && mise exec -- bun install ) >/dev/null 2>&1 || fail "runtime bun install failed"
( cd "$SITE" && mise exec -- bun install ) >/dev/null 2>&1 || fail "consumer bun install failed"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
  restore_snapshots
fi

stage_real_asset

PORT="$(free_port)"
BASE="http://127.0.0.1:$PORT"

# --- start the dev server with the SPA flags build.zig serve() emits ----------
# Run under `mise exec` so the zigapagos child can spawn `bun` for the sidecar +
# bundling. These flags mirror build.zig's serve() (deduped island/spa runtime
# flags + --spa-bundle-driver + --spa=<src>|<base>).
( cd "$SITE" && exec mise exec -- "$ZIGAPAGOS" \
    --host 127.0.0.1 --port "$PORT" \
    --bun=bun \
    --island-sidecar="$REPO/runtime/sidecar/render.ts" \
    --island-src-dir=. \
    --island-runtime-entry="$REPO/runtime/src/browser-entry.ts" \
    --spa-bundle-driver="$REPO/runtime/sidecar/bundle-island.ts" \
    "--spa=app/app.spa.tsx|/app" ) > "$ZLOG" 2>&1 &
ZPID=$!

# Startup bundles the runtime + entry (code-split) and SSRs every route, so give
# it generous time to begin listening.
READY=""
for _ in $(seq 1 120); do
  if curl -sf -o /dev/null "$BASE/app/"; then READY=1; break; fi
  kill -0 "$ZPID" 2>/dev/null || fail "zigapagos serve exited during startup"
  sleep 0.5
done
[[ -n "$READY" ]] || fail "zigapagos serve did not become ready at $BASE/app/"
echo "zigapagos serve on $BASE (SPA base /app)"

# --- /app/ : 200 shell, mount root, importmap BEFORE modulepreload ------------
ROOT_BODY="$(curl -s "$BASE/app/")"
grep -q 'id="z-spa-root"'  <<<"$ROOT_BODY" || fail "/app/ missing SPA mount root"
grep -q 'type="importmap"' <<<"$ROOT_BODY" || fail "/app/ missing import map"
grep -q 'mountSpa'         <<<"$ROOT_BODY" || fail "/app/ missing mountSpa boot"
# livereload hook injected exactly like every dev page
grep -q '__zigapagos/zigapagos-reload.js' <<<"$ROOT_BODY" || fail "/app/ missing livereload hook injection"
POS_IM="$(grep -abo 'type="importmap"'      <<<"$ROOT_BODY" | head -1 | cut -d: -f1)"
POS_MP="$(grep -abo 'rel="modulepreload"'   <<<"$ROOT_BODY" | head -1 | cut -d: -f1)"
[[ -n "$POS_IM" && -n "$POS_MP" && "$POS_IM" -lt "$POS_MP" ]] \
  || fail "/app/ import map ($POS_IM) not before first modulepreload ($POS_MP)"
echo "PASS: /app/ -> 200 shell (mount root, importmap before modulepreload, livereload)"

# --- /app/booking/ : 200 static shell -----------------------------------------
BOOK_CODE="$(curl -s -o "$WORK/book.html" -w '%{http_code}' "$BASE/app/booking/")"
[[ "$BOOK_CODE" == "200" ]] || fail "/app/booking/ expected 200, got $BOOK_CODE"
grep -q 'id="z-spa-root"' "$WORK/book.html" || fail "/app/booking/ not a SPA shell"
echo "PASS: /app/booking/ -> 200 static shell"

# --- /app/club/42 : 200 dynamic shell (club skeleton, not booking's) ----------
CLUB_CODE="$(curl -s -o "$WORK/club.html" -w '%{http_code}' "$BASE/app/club/42")"
[[ "$CLUB_CODE" == "200" ]] || fail "/app/club/42 expected 200, got $CLUB_CODE"
grep -q 'id="z-spa-root"' "$WORK/club.html" || fail "/app/club/42 not a SPA shell"
# The dynamic shell must be the CLUB pattern's _shell.html (its own skeleton),
# not the fallback/booking shell — proves dynamic pattern resolution.
grep -q 'data-view="club-skeleton"' "$WORK/club.html" || fail "/app/club/42 served the wrong (non-club) shell"
echo "PASS: /app/club/42 -> 200 dynamic shell (club skeleton)"

# --- /app/club/1/, /app/club/2/ : per-entry staticPaths shells ----------------
# app.spa.tsx's /club/:id declares `staticPaths: () => [{id:"1"},{id:"2"}]`.
# Dev serve must render (and write) each enumerated entry as its own shell —
# not just fall back on the dynamic pattern's _shell.html — mirroring release
# `prerenderAll`. The fixture's ClubSkeleton markup doesn't vary by id, so the
# served HTTP body can't distinguish a per-entry shell from the pattern shell
# by content; the differentiator is the per-entry file actually existing in
# the serve cache dir (before this fix, dev serve never wrote
# app/club/1/index.html / app/club/2/index.html at all).
SPA_CACHE="$SITE/.zig-cache/zigapagos-serve-spa"
CLUB1_CODE="$(curl -s -o "$WORK/club1.html" -w '%{http_code}' "$BASE/app/club/1/")"
[[ "$CLUB1_CODE" == "200" ]] || fail "/app/club/1/ expected 200, got $CLUB1_CODE"
grep -q 'id="z-spa-root"' "$WORK/club1.html" || fail "/app/club/1/ not a SPA shell"
CLUB2_CODE="$(curl -s -o "$WORK/club2.html" -w '%{http_code}' "$BASE/app/club/2/")"
[[ "$CLUB2_CODE" == "200" ]] || fail "/app/club/2/ expected 200, got $CLUB2_CODE"
[[ -f "$SPA_CACHE/app/club/1/index.html" ]] || fail "dev serve did not write a per-entry shell for staticPaths entry /app/club/1/"
[[ -f "$SPA_CACHE/app/club/2/index.html" ]] || fail "dev serve did not write a per-entry shell for staticPaths entry /app/club/2/"
echo "PASS: /app/club/1/ + /app/club/2/ -> per-entry staticPaths shells rendered and cached"

# --- /app/nope : 200 namespace fallback shell (NOT the 404 page) --------------
NOPE_CODE="$(curl -s -o "$WORK/nope.html" -w '%{http_code}' "$BASE/app/nope")"
[[ "$NOPE_CODE" == "200" ]] || fail "/app/nope expected 200 (fallback), got $NOPE_CODE"
grep -q 'id="z-spa-root"' "$WORK/nope.html" || fail "/app/nope not a SPA shell (fell through to 404?)"
echo "PASS: /app/nope -> 200 namespace fallback shell"

# --- a REAL file under the SPA base is served as-is, NOT the shell -------------
# Release routing serves a real staged file ahead of every SPA shell tier
# (nginx `try_files $uri $uri/ …/index.html`; Apache rewrites gated on `!-f`).
# Dev must match: /app/real-asset.css is a genuine installed asset, so it must
# come back as CSS — never the 200 HTML fallback shell that used to swallow it.
RA_CT="$(curl -s -o "$WORK/ra.css" -w '%{content_type}' "$BASE/app/real-asset.css")"
grep -q "$REAL_MARKER" "$WORK/ra.css" || fail "/app/real-asset.css did not serve the real file (got the shell?)"
if grep -q 'id="z-spa-root"' "$WORK/ra.css"; then fail "/app/real-asset.css served the SPA shell, not the real file"; fi
case "$RA_CT" in text/css*) ;; *) fail "/app/real-asset.css content-type expected text/css, got '$RA_CT'";; esac
echo "PASS: /app/real-asset.css -> real file served as-is (not the SPA shell)"

# --- /spa/app.js : 200 JS, NOT a 303 -----------------------------------------
JS_CODE="$(curl -s -o "$WORK/app.js" -w '%{http_code}' "$BASE/spa/app.js")"
[[ "$JS_CODE" == "200" ]] || fail "/spa/app.js expected 200, got $JS_CODE (303 = the bug)"
[[ -s "$WORK/app.js" ]] || fail "/spa/app.js is empty"
echo "PASS: /spa/app.js -> 200 JS (no 303)"

# --- /zigapagos-runtime.js : 200 JS -------------------------------------------
RT_CODE="$(curl -s -o "$WORK/rt.js" -w '%{http_code}' "$BASE/zigapagos-runtime.js")"
[[ "$RT_CODE" == "200" ]] || fail "/zigapagos-runtime.js expected 200, got $RT_CODE"
[[ -s "$WORK/rt.js" ]] || fail "/zigapagos-runtime.js is empty"
echo "PASS: /zigapagos-runtime.js -> 200 JS"

# --- a non-SPA path still 404s ------------------------------------------------
NF_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/this-path-does-not-exist-xyz/")"
[[ "$NF_CODE" == "404" ]] || fail "non-SPA path expected 404, got $NF_CODE"
echo "PASS: non-SPA path -> 404"

echo "PASS: zigapagos serve SPA (shells + dynamic + fallback + /spa/*.js + runtime + 404)"
