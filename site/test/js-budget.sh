#!/usr/bin/env bash
# site/test/js-budget.sh — pins the zero-JS claim the landing page makes.
#
# Docs pages must reference no script bundle at all. The landing page may, but
# not without bound: a ceiling that fails the build is the only thing stopping
# "zero JS by default" from quietly becoming false.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=zig-out/site
# Measured at write time: zigapagos-runtime.js (58452 B) + Counter.island.js
# (433 B) + CodeTabs.island.js (908 B) = 59793 B = 58.39 KB, rounded up to the
# next 10. This ceiling's job is to catch a regression, not to be
# aspirational — it is deliberately tight, so a real increase in landing-page
# JS is expected to fail it and require a conscious bump, not silent drift.
LANDING_CEILING_KB=60
# The s-zerojs section states a byte figure for the inline theme scripts that
# every page carries. A stated number that drifts is worse than none on a page
# that invites devtools scrutiny, so it is pinned here.
INLINE_SCRIPT_CEILING_B=1400

FAILED=0

# 1. No docs page may reference a module script. A bare substring grep for
# 'zigapagos-runtime.js' would false-positive on the docs pages that mention
# the filename in prose/code samples (see site/test/build.sh's islands-doc
# assertion for the same issue) — match the actual module-script tag shape.
while IFS= read -r html; do
  if grep -qE '<script[^>]+type="module"' "$html"; then
    echo "FAIL: docs page ships a module script: $html"
    FAILED=1
  fi
done < <(find "$OUT/docs" -name 'index.html')

# 2. The landing page's referenced bundles must fit the ceiling. An island
# bundle is referenced by `data-z-module="..."`, not `src="..."` — pass.zig
# emits it as a plain attribute on the island's wrapper div, not a <script
# src>, so a scan for `src=` alone sees only zigapagos-runtime.js and stays
# flat as islands are added to the page, which defeats the gate. `sort -u`
# so an island used twice on one page (same bundle URL) is only billed once,
# matching how the browser actually fetches it.
total=0
while IFS= read -r src; do
  rel="${src#/zigapagos/}"
  f="$OUT/$rel"
  [ -f "$f" ] || continue
  total=$(( total + $(wc -c < "$f") ))
done < <(grep -oE 'src="/zigapagos/[^"]+\.js"|data-z-module="/zigapagos/[^"]+\.js"' "$OUT/index.html" \
  | sed -E 's/^(src|data-z-module)="//; s/"$//' | sort -u)

# 3. The inline theme scripts must stay near the figure the landing copy states.
inline=$(grep -o '<script>' "$OUT/docs/overview/index.html" | wc -l)
[ "$inline" -ge 1 ] || { echo "FAIL: docs page has no inline theme script — copy claims it does"; FAILED=1; }
bytes=$(python3 -c "
import re,sys
h=open('$OUT/docs/overview/index.html',encoding='utf8').read()
print(sum(len(m.encode()) for m in re.findall(r'<script>.*?</script>', h, re.S)))
")
echo "inline theme script: ${bytes} B (ceiling ${INLINE_SCRIPT_CEILING_B} B)"
if [ "$bytes" -gt "$INLINE_SCRIPT_CEILING_B" ]; then
  echo "FAIL: inline script grew past the figure the landing page states"
  FAILED=1
fi

kb=$(( total / 1024 ))
echo "landing page JavaScript: ${kb} KB (ceiling ${LANDING_CEILING_KB} KB)"
if [ "$kb" -gt "$LANDING_CEILING_KB" ]; then
  echo "FAIL: landing page JS budget exceeded"
  FAILED=1
fi

[ "$FAILED" -eq 0 ] || exit 1
echo PASS
