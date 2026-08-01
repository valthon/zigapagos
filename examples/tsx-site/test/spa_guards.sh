#!/usr/bin/env bash
# Guarded-route acceptance (b): the prerendered shell for a GUARDED route must
# contain the neutral fallback and NONE of the gated content. Because guards are
# client-only, the build-time SSR renders the fallback for a guarded route, so
# this holds with NO change to spa.zig — the prerender emits a neutral shell
# automatically. This script proves that against a real build.
#
# Acceptance (a) — no gated-content flash on hard-refresh — is a browser
# property; see test/spa_guards_playwright.py (run against this same zig-out/site).
set -euo pipefail
cd "$(dirname "$0")/.."

(cd ../../runtime && mise exec -- bun install)
mise exec -- bun install
bash build.sh

OUT=zig-out/site

# The guarded route (/secret) and its redirect target (/login) prerender as
# ordinary static-route shells.
test -f "$OUT/app/secret/index.html" || { echo "FAIL: no app/secret/index.html"; exit 1; }
test -f "$OUT/app/login/index.html"  || { echo "FAIL: no app/login/index.html"; exit 1; }

# ACCEPTANCE (b): the gated shell holds the neutral fallback, NOT gated content.
grep -q 'data-view="guard-fallback"' "$OUT/app/secret/index.html" || { echo "FAIL: gated shell is not the neutral fallback"; exit 1; }
! grep -q 'data-gated="secret"'      "$OUT/app/secret/index.html" || { echo "FAIL: gated marker leaked into the prerendered shell"; exit 1; }
! grep -q 'TOP SECRET'               "$OUT/app/secret/index.html" || { echo "FAIL: gated text leaked into the prerendered shell"; exit 1; }

# The gated route still boots the client router (import map + mount + bundle),
# so the guard can run and reveal the real content post-auth.
grep -q 'id="z-spa-root"' "$OUT/app/secret/index.html" || { echo "FAIL: gated shell has no mount root"; exit 1; }
grep -q 'mountSpa'        "$OUT/app/secret/index.html" || { echo "FAIL: gated shell has no mountSpa boot"; exit 1; }

# The manifest routes /app/secret and /app/login as static routes.
grep -q '"/app/secret/"' "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing /app/secret/"; exit 1; }
grep -q '"/app/login/"'  "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing /app/login/"; exit 1; }

echo "PASS: gated route prerenders a neutral fallback shell with no gated content (acceptance b)"
