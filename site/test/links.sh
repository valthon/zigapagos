#!/usr/bin/env bash
# site/test/links.sh — every internal link resolves to an emitted file.
#
# The failure this catches is specific: under url_path_prefix, a hand-written
# href works in local preview and 404s in production. Checking the built tree
# is the only place that distinction is visible.
#
# The loop that used to live here is now `assert_internal_links_resolve` in
# assert.sh (#59), and this script is its first consumer — which is the point of
# converting it. The shared version is the one with a self-test
# (assert.test.sh), a documented contract (docs/testing.md), and a hard failure
# on a missing or empty input instead of a silently-empty iteration.
#
# NOT changed by the conversion: the no-SPA-exemption rule. Pages emitted BY the
# embedded demo SPA (under demos/app/) used to be exempted from the prefix rule,
# because their <Link> hrefs were resolved against the SPA's own unprefixed
# `base` and the prefix only reappeared inside the click handler. Issue #26
# composes url_path_prefix into the Router's base, so a prerendered SPA nav href
# is now the same fully-prefixed, file-backed address as any other internal link
# — and holding it to the same rule is the point: an unprefixed one is a 404 for
# a visitor without JavaScript.
set -euo pipefail
cd "$(dirname "$0")/.."
. test/assert.sh

OUT=zig-out/site
PREFIX=/zigapagos

test -d "$OUT" || { echo "FAIL: no build output — run zig build first"; exit 1; }

# A floor on the page count, which the old inline loop did not have. Without it
# this gate is green on an output tree that emitted nothing: `find` over an
# empty directory iterates zero times and the script reports success. That is
# the "assertion that passed before the code existed" failure mode one level up
# from the individual assertions, and it is worth pinning here because this
# script's whole job is a loop.
PAGES=0
while IFS= read -r html; do
  assert_internal_links_resolve "$OUT" "$html" "$PREFIX"
  PAGES=$((PAGES + 1))
done < <(find "$OUT" -name '*.html')

[ "$PAGES" -ge 20 ] || { echo "FAIL: only $PAGES HTML pages in $OUT — the site did not build"; exit 1; }

echo "PASS: $PAGES pages, every internal link resolves under $PREFIX"
