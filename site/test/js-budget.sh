#!/usr/bin/env bash
# site/test/js-budget.sh — pins the zero-JS claim the landing page makes.
#
# Docs pages must reference no script bundle at all. The landing page may, but
# not without bound: a ceiling that fails the build is the only thing stopping
# "zero JS by default" from quietly becoming false.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=zig-out/site
# Keep the existing 60 KiB landing-page ceiling, enforced in exact bytes.
# A deliberate limit catches growth without confusing whole-tree inventory
# with the bundles that this particular page directly references.
LANDING_CEILING_B=$((60 * 1024))
# The s-zerojs section states a byte figure for the inline theme scripts that
# every page carries. A stated number that drifts is worse than none on a page
# that invites devtools scrutiny, so it is pinned here.
INLINE_SCRIPT_CEILING_B=1400

FAILED=0

# Whole-release inventory includes lazy and unreferenced bundles. These are raw
# file bytes, separate from the landing page's directly referenced JS below;
# neither metric claims compressed transfer size or runtime performance.
REPO="$(cd .. && pwd)"
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
if ! "$ZIGAPAGOS" inspect-output "$OUT" --format=json \
  --max-html-bytes=2500000 --max-css-bytes=20000 --max-js-bytes=180000 \
  > zig-out/output-budget.ndjson; then
  cat zig-out/output-budget.ndjson >&2
  exit 1
fi
python3 - <<'PYREPORT'
import json
from pathlib import Path
reports = [json.loads(line) for line in Path("zig-out/output-budget.ndjson").read_text().splitlines()]
summary = next(report for report in reports if report["type"] == "summary")
print("whole-release raw bytes:", summary["raw_bytes"])
PYREPORT

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
  if [ ! -f "$f" ]; then
    echo "FAIL: landing page references missing JavaScript: $src"
    FAILED=1
    continue
  fi
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

echo "landing page directly referenced JavaScript: ${total} B (ceiling ${LANDING_CEILING_B} B)"
if [ "$total" -gt "$LANDING_CEILING_B" ]; then
  echo "FAIL: landing page JS budget exceeded"
  FAILED=1
fi

[ "$FAILED" -eq 0 ] || exit 1
echo PASS
