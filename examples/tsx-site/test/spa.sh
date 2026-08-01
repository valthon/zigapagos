#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

(cd ../../runtime && mise exec -- bun install)
mise exec -- bun install
bash build.sh

OUT=zig-out/site
# static route shells
test -f "$OUT/app/index.html"          || { echo "FAIL: no app/index.html"; exit 1; }
test -f "$OUT/app/booking/index.html"  || { echo "FAIL: no app/booking/index.html"; exit 1; }
# dynamic pattern shell (param dir sanitized to _shell.html) — the fallback for
# every NON-enumerated :id.
test -f "$OUT/app/club/_shell.html"    || { echo "FAIL: no app/club/_shell.html"; exit 1; }
# staticPaths (getStaticPaths parity): /club/:id enumerates ids 1 & 2,
# so those prerender as REAL static pages ALONGSIDE the pattern shell...
test -f "$OUT/app/club/1/index.html"   || { echo "FAIL: no prerendered club/1"; exit 1; }
test -f "$OUT/app/club/2/index.html"   || { echo "FAIL: no prerendered club/2"; exit 1; }
# ...and NOTHING else: club/ must be EXACTLY {1, 2, _shell.html} — any extra
# entry means a non-enumerated :id leaked into the prerender (the _shell.html
# is the sole fallback for those).
[ "$(ls "$OUT/app/club/" | LC_ALL=C sort)" = "$(printf '1\n2\n_shell.html')" ] \
  || { echo "FAIL: club/ is not exactly {1, 2, _shell.html}: $(ls "$OUT/app/club/" | tr '\n' ' ')"; exit 1; }
# one bundle + shared runtime + 404 + manifest + host config
test -f "$OUT/spa/app.js"              || { echo "FAIL: no spa/app.js"; exit 1; }
test -f "$OUT/zigapagos-runtime.js"    || { echo "FAIL: no runtime bundle"; exit 1; }
test -f "$OUT/404.html"                || { echo "FAIL: no 404.html"; exit 1; }
# explicit 404 owner: build.sh passes `--spa-not-found=app`, so
# the universal 404.html must be byte-identical to the app SPA's "/" shell —
# NOT any of the slices/* SPAs' shells.
cmp -s "$OUT/404.html" "$OUT/app/index.html" || { echo "FAIL: 404.html is not the app SPA's / shell"; exit 1; }
test -f "$OUT/app/routing-manifest.json" || { echo "FAIL: no manifest"; exit 1; }
test -f "$OUT/app/nginx.nginx.conf"    || { echo "FAIL: no nginx config"; exit 1; }

# shells contain the skeleton (loading state), the mount root, import map, preloads, mountSpa boot
grep -q 'data-view="club-skeleton"' "$OUT/app/club/_shell.html" || { echo "FAIL: club shell not skeleton"; exit 1; }
# a staticPaths concrete page is a full shell too: same param-independent skeleton, its own static file.
grep -q 'data-view="club-skeleton"' "$OUT/app/club/1/index.html" || { echo "FAIL: club/1 not a skeleton shell"; exit 1; }
grep -q 'id="z-spa-root"'            "$OUT/app/club/1/index.html" || { echo "FAIL: club/1 no mount root"; exit 1; }
grep -q 'data-view="booking"'       "$OUT/app/booking/index.html" || { echo "FAIL: booking shell wrong"; exit 1; }
grep -q 'id="z-spa-root"'           "$OUT/app/index.html" || { echo "FAIL: no mount root"; exit 1; }
grep -q 'type="importmap"'          "$OUT/app/index.html" || { echo "FAIL: no import map"; exit 1; }
grep -q 'rel="modulepreload" href="/spa/app.js"' "$OUT/app/index.html" || { echo "FAIL: no bundle preload"; exit 1; }
grep -q 'mountSpa'                   "$OUT/app/index.html" || { echo "FAIL: no mountSpa boot"; exit 1; }

# manifest shape
grep -q '"base":"/app"'                         "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest base"; exit 1; }
grep -q '"pattern":"/app/club/:id"'             "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest dynamic"; exit 1; }
# staticPaths concrete pages land in the `static` array (exact-match, consulted before the pattern).
grep -q '"/app/club/1/"'                        "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing static club/1"; exit 1; }
grep -q '"/app/club/2/"'                        "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing static club/2"; exit 1; }
grep -q '"fallback":"/app/index.html"'          "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest fallback"; exit 1; }

# nginx config.
#
# MIND THE QUOTES. emit-host-config.ts runs every interpolated route value through
# nginxQuote(), so the `location` argument and each `try_files` argument are quoted
# single tokens — nginx strips the quotes at parse time, so the directive still sees
# the exact path, but the token can no longer end early on whitespace or a `;`. These
# assertions matched the UNQUOTED spelling and so had matched nothing since nginxQuote
# landed; the script is outside CI's `tests/*/*.sh` glob, so nothing ever noticed.
# Keep them byte-identical to runtime/scripts/emit-host-config.test.ts's expectations
# — that unit test is where the emitter is really pinned, and it does run in CI. What
# these two add is the e2e half the unit test cannot cover: that the emitted bytes
# actually reach $OUT/app/nginx.nginx.conf in a real build.
#
# grep -F, not -q alone: `$uri` and `.` are live in a regex, so a BRE would keep
# matching some near-misses these are meant to reject.
grep -qF 'try_files $uri $uri/ "/app/index.html";' "$OUT/app/nginx.nginx.conf" || { echo "FAIL: nginx try_files"; exit 1; }
grep -qF 'location "/app/club/" {'                 "$OUT/app/nginx.nginx.conf" || { echo "FAIL: nginx dynamic loc"; exit 1; }
# The dynamic location's try_files order is load-bearing: real file, then the route's
# own shell, then the namespace fallback.
grep -qF 'try_files $uri "/app/club/_shell.html" "/app/index.html";' "$OUT/app/nginx.nginx.conf" || { echo "FAIL: nginx dynamic try_files"; exit 1; }

# ZigBase (>= 0.10.0) target: the presence-only `.spa` marker + optional comptime snippet.
# The example builds with deploy_target=nginx, so re-run the emitter with --target zigbase
# against the built tree to exercise the zigbase adapter path.
mise exec -- bun ../../runtime/scripts/emit-host-config.ts --site "$OUT" --target zigbase
test -f "$OUT/app/.spa"                     || { echo "FAIL: no .spa marker"; exit 1; }
test ! -s "$OUT/app/.spa"                   || { echo "FAIL: .spa marker not empty (must be presence-only)"; exit 1; }
! test -f "$OUT/app/zigbase.zigbase.json"   || { echo "FAIL: stale zigbase manifest emitted"; exit 1; }
test -f "$OUT/app/zigbase.static_routes.zig" || { echo "FAIL: no static_routes snippet"; exit 1; }
grep -q '.static_routes = &.{'                                              "$OUT/app/zigbase.static_routes.zig" || { echo "FAIL: snippet missing static_routes"; exit 1; }
grep -qF '.{ .match = "/app/club/:id", .serve = "/app/club/_shell.html" },' "$OUT/app/zigbase.static_routes.zig" || { echo "FAIL: snippet dynamic route"; exit 1; }
grep -qF '.{ .match = "/app/**", .serve = "/app/index.html" },'             "$OUT/app/zigbase.static_routes.zig" || { echo "FAIL: snippet namespace fallback"; exit 1; }

# --- Code splitting: the lazy /heavy route is a SEPARATE chunk ---------------
# The heavy view's marker must NOT be in the entry bundle...
! grep -q 'HEAVY-CHUNK-MARKER' "$OUT/spa/app.js" || { echo "FAIL: heavy code leaked into the entry bundle"; exit 1; }
# ...it must live in its own content-hashed chunk.
HEAVY_CHUNK=$(cd "$OUT/spa" && ls Heavy-*.js 2>/dev/null | head -1)
test -n "$HEAVY_CHUNK" || { echo "FAIL: no Heavy-<hash>.js chunk emitted"; exit 1; }
grep -q 'HEAVY-CHUNK-MARKER' "$OUT/spa/$HEAVY_CHUNK" || { echo "FAIL: heavy marker not in its chunk"; exit 1; }
# The /heavy shell shows the skeleton (not the heavy content) and preloads the chunk.
grep -q 'data-view="heavy-skeleton"' "$OUT/app/heavy/index.html" || { echo "FAIL: heavy shell not the skeleton"; exit 1; }
! grep -q 'HEAVY-CHUNK-MARKER'        "$OUT/app/heavy/index.html" || { echo "FAIL: heavy content in the shell"; exit 1; }
grep -q "rel=\"modulepreload\" href=\"/spa/$HEAVY_CHUNK\"" "$OUT/app/heavy/index.html" || { echo "FAIL: heavy shell does not preload its chunk"; exit 1; }
# A non-lazy route's shell must NOT preload the heavy chunk.
! grep -q "Heavy-" "$OUT/app/booking/index.html" || { echo "FAIL: non-lazy shell preloads a chunk"; exit 1; }
# The manifest maps the lazy route to its chunk.
grep -q "\"/app/heavy/\":\"/spa/$HEAVY_CHUNK\"" "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing /app/heavy chunk map"; exit 1; }

# --- Declarative redirects: { path: "/home", redirect: "/" } -----------------
# A redirect entry still prerenders its own shell (the deep-link/hard-refresh
# entry point)...
test -f "$OUT/app/home/index.html" || { echo "FAIL: no shell for the /home redirect route"; exit 1; }
# ...and that shell carries the TARGET's SSR (the router resolves the redirect
# BEFORE rendering — no throwaway frame, real content in the shell).
grep -q 'data-view="home"' "$OUT/app/home/index.html" || { echo "FAIL: /home redirect shell does not carry the target's SSR"; exit 1; }
# The redirect route is a normal static entry in the manifest.
grep -q '"/app/home/"' "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing static /app/home/"; exit 1; }

# no-npm guardrail over the SPA sources
mise exec -- bun ../../runtime/scripts/lint-island-imports.ts app/app.spa.tsx app/views/*.tsx app/views/*.ts

echo "PASS: SPA prerender + manifest + host config (nginx + zigbase) + code-splitting"
