#!/usr/bin/env bash
# Proof for pagination emit + stale-output prune (issue #127, task 8).
#
# Pagination is the FIRST feature whose output set shrinks as a function of
# content: a section with 5 posts at page_size=2 emits 3 pages, and a later
# rebuild with only 2 posts emits 1 -- but `zigapagos release --force` always
# writes into the SAME output tree, so nothing else in the build ever deletes
# a file it isn't about to rewrite. Without a dedicated prune, the orphaned
# `page/2/`, `page/3/` dirs from the earlier, bigger build are served
# forever.
#
# Five things are checked, in order:
#   (1) a normal build emits every planned pagination page,
#   (2) `--summary` lists them under a "pagination pages" heading, agreeing
#       with what's actually on disk,
#   (3) `zigapagos explain` on the section's own route reports them too,
#   (4) shrinking the section's content and rebuilding --force PRUNES the
#       pages that fell out of the plan (this is the assertion that fails
#       before the prune is implemented -- see the PR body for the captured
#       RED output),
#   (5) a section that shrinks AND simultaneously gains a real subpage whose
#       name collides with a pagination-shaped path (a subpage literally
#       named "2" under a `.plain_dir` section, at the exact path pagination
#       page 2 used to occupy) is NOT swept away by the prune: the prune
#       checks `Variant.urls` before deleting anything, and a real page's
#       registration there wins.
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

# --- plant a foreign output nested under a soon-to-be-stale pagination dir --
# blog/page/3 is about to fall out of the plan when blog shrinks below. A
# file nested UNDER that directory at a DIFFERENT path than the pagination
# page's own index.html (the prune's protection check,
# Variant.isPruneCandidateProtected, is exact-path only) proves the prune
# deletes just the pagination page's own output file and never recurses --
# an SPA shell prerendered under a stale pagination dir (e.g.
# blog/page/2/app/index.html) is a real, reachable shape a recursive
# deleteTree would silently destroy.
mkdir -p "$OUT/blog/page/3/keep"
echo '<p>keep me</p>' >"$OUT/blog/page/3/keep/note.html"

# --- (4) shrink blog to 2 posts (1 page) and rebuild --force: the prune -----
rm "$SITE/content/blog/post1.smd" "$SITE/content/blog/post2.smd" "$SITE/content/blog/post3.smd"
if ! ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build2.log" 2>&1; then
  cat "$WORK/build2.log"; fail "(4) rebuild after shrinking blog failed"
fi
[[ -f "$OUT/blog/index.html" ]] || fail "(4) blog/index.html (page 1) is missing after the shrink"
# blog/page/2 only ever contained its own index.html, so the whole dir must
# be gone (file deleted, then the now-empty dir rmdir'd).
[[ -e "$OUT/blog/page/2" ]] && fail "(4) blog/page/2 survived the shrink -- stale pagination output was not pruned"
# blog/page/3's own pagination output must be gone...
[[ -f "$OUT/blog/page/3/index.html" ]] && fail "(4) blog/page/3/index.html survived the shrink -- stale pagination output was not pruned"
# ...but the foreign file nested under it must survive: a recursive delete
# of blog/page/3 would have taken it down too.
[[ -f "$OUT/blog/page/3/keep/note.html" ]] || fail "(4) blog/page/3/keep/note.html (a foreign output nested under a stale pagination dir) was deleted -- the prune must never recurse"
echo "PASS (4): a rebuild after content shrinks prunes the stale pagination pages without recursing into unrelated nested output"

# --- (5) news shrinks to 1 post AND gains a real subpage named "2" ----------
# news is .plain_dir: 3 posts / page_size 2 -> 2 pages, page 2 at
# 'news/2/index.html' -- the EXACT path a real subpage named "2" would also
# claim. Shrinking to 1 post drops page 2 from the plan; adding the real
# subpage in the same edit proves the prune's probe of that now-unplanned
# path finds a REGISTERED page there and skips it instead of deleting it.
rm "$SITE/content/news/n2.smd" "$SITE/content/news/n3.smd"
cat >"$SITE/content/news/2.smd" <<'EOF'
---
.title = "Real News Two",
.date = @date("2024-04-01T00:00:00"),
.layout = "post.shtml",
---
# Real News Two

A real subpage whose name collides with pagination page 2's old path.
EOF
if ! ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build3.log" 2>&1; then
  cat "$WORK/build3.log"; fail "(5) rebuild after the news shrink+collision failed"
fi
[[ -f "$OUT/news/2/index.html" ]] || fail "(5) news/2/index.html (the real subpage) is missing"
grep -q 'Real News Two' "$OUT/news/2/index.html" || {
  cat "$OUT/news/2/index.html"
  fail "(5) news/2/index.html does not contain the real subpage's title -- the prune deleted or ignored a real page"
}
echo "PASS (5): a real subpage registered at a pagination-shaped path survives the prune"

echo "ALL PROOF CHECKS PASSED (pagination)"
