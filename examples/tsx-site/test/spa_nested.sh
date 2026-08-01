#!/usr/bin/env bash
# Nested layout routes: a nested layout route prerenders each child leaf as its
# own <base>/<layout>/<child>/index.html containing BOTH the layout chrome AND
# the child content. Because the sidecar `describe` flattens the nested tree to
# leaf full-paths, this holds with NO change to spa.zig — the prerender loop is
# segment-agnostic and drives the Router at each flattened leaf pathname (the
# Router renders the layout + Outlet-child at SSR). This proves that.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd ../../runtime && mise exec -- bun install)
mise exec -- bun install
bash build.sh

OUT=zig-out/site

# Each child leaf prerenders its own index.html.
test -f "$OUT/app/dash/overview/index.html" || { echo "FAIL: no app/dash/overview/index.html"; exit 1; }
test -f "$OUT/app/dash/settings/index.html" || { echo "FAIL: no app/dash/settings/index.html"; exit 1; }
# A layout with no index child is not itself a prerendered leaf.
! test -f "$OUT/app/dash/index.html" || { echo "FAIL: layout /dash prerendered without an index child"; exit 1; }

# The overview shell holds the layout chrome AND the overview content, and NOT
# the sibling's content.
O="$OUT/app/dash/overview/index.html"
grep -q 'data-dash-chrome'           "$O" || { echo "FAIL: overview shell missing layout chrome"; exit 1; }
grep -q 'data-view="dash-layout"'    "$O" || { echo "FAIL: overview shell missing layout view"; exit 1; }
grep -q 'data-view="dash-overview"'  "$O" || { echo "FAIL: overview shell missing overview content"; exit 1; }
! grep -q 'data-view="dash-settings"' "$O" || { echo "FAIL: overview shell leaked sibling content"; exit 1; }

# The settings shell holds the layout chrome AND the settings content.
S="$OUT/app/dash/settings/index.html"
grep -q 'data-dash-chrome'           "$S" || { echo "FAIL: settings shell missing layout chrome"; exit 1; }
grep -q 'data-view="dash-settings"'  "$S" || { echo "FAIL: settings shell missing settings content"; exit 1; }
! grep -q 'data-view="dash-overview"' "$S" || { echo "FAIL: settings shell leaked sibling content"; exit 1; }

# Manifest routes both child leaves as static routes.
grep -q '"/app/dash/overview/"' "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing /app/dash/overview/"; exit 1; }
grep -q '"/app/dash/settings/"' "$OUT/app/routing-manifest.json" || { echo "FAIL: manifest missing /app/dash/settings/"; exit 1; }

# A GUARDED layout (/members) is fail-closed at prerender: each child leaf still
# gets its own index.html, but the shell holds ONLY the neutral fallback — no
# layout chrome, no gated child content (the guard is client-only, so SSR renders
# the fallback for the whole guarded scope).
for child in profile billing; do
  M="$OUT/app/members/$child/index.html"
  test -f "$M" || { echo "FAIL: no app/members/$child/index.html"; exit 1; }
  grep -q 'data-view="guard-fallback"' "$M" || { echo "FAIL: guarded $child shell is not the neutral fallback"; exit 1; }
  ! grep -q 'data-members-chrome'      "$M" || { echo "FAIL: guarded $child shell leaked layout chrome"; exit 1; }
  ! grep -q 'data-gated="member"'      "$M" || { echo "FAIL: guarded $child shell leaked gated content"; exit 1; }
done

echo "PASS: nested layout routes prerender layout+child per leaf (unguarded) + fail-closed fallback per leaf (guarded), no spa.zig change"
