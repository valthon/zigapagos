#!/usr/bin/env bash
# Baked-flag-defaults acceptance on the emitted shells: every shell of a SPA
# that declares `spa.flags` carries the baked-defaults snapshot as a JSON DATA
# BLOCK, and the SSR'd skeleton itself is rendered WITH those defaults (the
# sidecar seeds its flag store from `spa.flags`), so the default-ON branch is
# in the prerendered HTML — no false-while-loading flash to begin with.
#
# The browser-side half (first client render seeds from the snapshot and
# reconciles with real state) is spa_playwright.py's steps 2 and 5.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd ../../runtime && mise exec -- bun install)
mise exec -- bun install
bash build.sh

OUT=zig-out/site
SNAPSHOT='<script type="application/json" data-z-flags>{"flags":{"bookAsGuest":true,"promoBanner":false},"experiments":{}}</script>'

# Every shell of the flag-declaring SPA carries the snapshot (static routes,
# dynamic pattern shells, and staticPaths concrete pages alike).
for shell in app/index.html app/booking/index.html app/club/_shell.html app/club/1/index.html; do
  grep -qF "$SNAPSHOT" "$OUT/$shell" || { echo "FAIL: $shell is missing the data-z-flags snapshot"; exit 1; }
done

# The SSR'd booking skeleton rendered WITH the defaults: guest branch ON.
grep -q 'data-guest-booking="on"' "$OUT/app/booking/index.html" || { echo "FAIL: booking shell was not SSR'd with bookAsGuest ON"; exit 1; }
grep -q 'data-guest-cta'          "$OUT/app/booking/index.html" || { echo "FAIL: flag-gated CTA missing from the SSR'd booking shell"; exit 1; }

# A SPA that declares NO flags emits NO data block (byte-identical shells).
! grep -q 'data-z-flags' "$OUT/public/index.html" || { echo "FAIL: flag-less SPA shell grew a data-z-flags block"; exit 1; }

# clientInit: the SSR sidecar never calls it, so its DOM marker
# must NOT be in any prerendered shell — it appears only in the live browser
# (spa_playwright.py asserts that half). The bootstrap passes the module
# namespace to mountSpa so the hook is reachable client-side.
! grep -q 'data-client-init' "$OUT/app/index.html" || { echo "FAIL: clientInit marker leaked into the prerendered shell (SSR called clientInit?)"; exit 1; }
grep -q 'mountSpa(m.default,"#z-spa-root",m)' "$OUT/app/index.html" || { echo "FAIL: shell bootstrap does not pass the module namespace to mountSpa"; exit 1; }

echo "PASS: baked flag defaults are snapshotted into shells and SSR'd into skeletons; clientInit stays client-only"
