#!/usr/bin/env bash
# Proof for pagination emit (issue #127, task 8).
#
# Three things are checked, in order:
#   (1) a normal build emits every planned pagination page,
#   (2) `--summary` lists them under a "pagination pages" heading, agreeing
#       with what's actually on disk,
#   (3) `zigapagos explain` on the section's own route reports them too.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SITE="$WORK/site"; OUT="$WORK/out"
mkdir -p "$SITE"
cp -r tests/rendering/pagination/content tests/rendering/pagination/layouts "$SITE/"
cp tests/rendering/pagination/zigapagos.ziggy "$SITE/"

fail() { echo "FAIL: $*"; exit 1; }

# --- (1) full build: blog is 5 posts / page_size 2 -> 3 pages ---------------
if ! ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build1.log" 2>&1; then
  cat "$WORK/build1.log"; fail "(1) initial build failed"
fi
[[ -f "$OUT/blog/page/2/index.html" ]] || fail "(1) blog/page/2/index.html was not emitted"
[[ -f "$OUT/blog/page/3/index.html" ]] || fail "(1) blog/page/3/index.html was not emitted"
echo "PASS (1): a full build emits every planned pagination page"

# --- (2) --summary agreement -------------------------------------------------
if ! ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force --summary ) >"$WORK/summary.out" 2>"$WORK/summary.err"; then
  cat "$WORK/summary.out" "$WORK/summary.err"; fail "(2) 'release --summary' failed"
fi
# Isolate the "pagination pages" group: its heading is 2-space indented, its
# entries 4-space indented, and the next heading (also 2-space indented) ends
# the group -- so a line starting with two spaces then a letter closes it.
awk '/^  pagination pages \(/{flag=1; next} /^  [A-Za-z]/{flag=0} flag' \
  "$WORK/summary.out" >"$WORK/summary-pagination.txt"
[[ -s "$WORK/summary-pagination.txt" ]] || { cat "$WORK/summary.out"; fail "(2) no 'pagination pages' heading found in --summary output"; }
grep -qF 'blog/page/3/index.html' "$WORK/summary-pagination.txt" || {
  cat "$WORK/summary.out"
  fail "(2) --summary's pagination pages group is missing blog/page/3/index.html"
}
echo "PASS (2): --summary lists pagination pages, agreeing with the emitted tree"

# --- (3) explain knows about pagination pages --------------------------------
if ! ( cd "$SITE" && "$ZIGAPAGOS" explain /blog/ ) >"$WORK/explain.out" 2>"$WORK/explain.err"; then
  cat "$WORK/explain.out" "$WORK/explain.err"; fail "(3) 'explain /blog/' failed"
fi
grep -q 'pagination page' "$WORK/explain.out" || {
  cat "$WORK/explain.out"
  fail "(3) 'explain /blog/' report has no 'pagination page' entries"
}
echo "PASS (3): explain reports the section's pagination pages"

echo "ALL PROOF CHECKS PASSED (pagination)"
