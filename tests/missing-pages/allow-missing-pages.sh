#!/usr/bin/env bash
# Regression test for issue #27 / DX-8: `$link.page/sibling/sub` (content) and
# `$site.page(...)` (template) used to HARD-FAIL the build the moment a
# navigation link pointed at a page that hadn't been written yet. A dangling
# internal link is exactly what "site under construction" means, so this cost
# more than any other item in the DX backlog: roughly eight placeholder
# content files were created purely to keep a real, in-progress site green,
# then deleted or overwritten later (one collided with a generated filename
# and had to be untracked separately).
#
# The fix is an explicit opt-in flag, `--allow-missing-pages`, uniform across
# release/serve/dev (NOT mode-dependent -- see root.zig's `Options.allow_missing_pages`
# doc comment for why warn-in-dev/error-in-release was rejected). Under the
# flag, a dangling reference renders as the real, url_prefix-aware href the
# target page WILL have once it exists (a 404 until then), plus a build-log
# warning naming the ref and the computed href.
#
# Trigger fixture: a page whose content has a dangling `$link.page('coming-soon')`,
# and a shared layout whose nav has a dangling `$site.page('coming-soon').link()`.
#
# NOT claimed:
#  - That both failure messages can be observed from a SINGLE build without the
#    flag. They can't: `src/root.zig`'s `analysis_errors` gate aborts the whole
#    build (`build.any_prerendering_error = true; return build;`) BEFORE the
#    page-render pass ever runs, and the content-link failure is an analysis-time
#    error -- so when both defects are present, the render-time `$site.page(...)`
#    lookup never gets a chance to execute at all. Phase (1) below therefore pins
#    each failure mode in ISOLATION: the combined fixture proves the content-link
#    path still hard-fails, and a template-only variant (no dangling content
#    link) proves the `$site.page(...)` path still hard-fails on its own.
#  - That the tolerated href is host-qualified when embedded cross-page/cross-
#    variant (see `worker.zig`'s `missingPageUrl` doc comment for that accepted
#    limitation) -- this fixture never exercises that shape.
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
fail() { echo "FAIL: $*"; exit 1; }

zigapagos_config() {
  cat > "$1/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Missing Pages Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
}

page() {
  # page DIR NAME TITLE BODY
  cat > "$1/content/$2.smd" <<EOF
---
.title = "$3",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "base.shtml",
.draft = false,
---
$4
EOF
}

# The COMBINED fixture: three pages sharing one layout, so the template-side
# warning (phase 3) has more than one page to actually dedup across. Only
# index.smd carries the dangling CONTENT link -- the analysis pass visits each
# page's AST once, so that warning needs no dedup of its own.
write_combined_site() {
  local dir="$1"
  mkdir -p "$dir/content" "$dir/layouts"
  zigapagos_config "$dir"
  cat > "$dir/layouts/base.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head><meta charset="UTF-8"><title :text="$page.title"></title></head>
  <body>
    <nav><a href="$site.page('coming-soon').link()">Coming soon</a></nav>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
  page "$dir" index Home "See the [coming soon page](\$link.page('coming-soon')) for what's next."
  page "$dir" about About "Nothing dangling here."
  page "$dir" contact Contact "Nothing dangling here either."
}

# TEMPLATE-ONLY variant: same dangling nav, but no dangling content link --
# isolates the `$site.page(...)` failure mode so phase (1) can prove it still
# hard-fails on its own (see the header comment on why it can't be observed
# from the combined fixture without the flag).
write_template_only_site() {
  local dir="$1"
  mkdir -p "$dir/content" "$dir/layouts"
  zigapagos_config "$dir"
  cat > "$dir/layouts/base.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head><meta charset="UTF-8"><title :text="$page.title"></title></head>
  <body>
    <nav><a href="$site.page('coming-soon').link()">Coming soon</a></nav>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
  page "$dir" index Home "Nothing dangling in the content here."
}

# ---------------------------------------------------------------------------
# (1) WITHOUT the flag: both failure modes are still hard build errors today.
# ---------------------------------------------------------------------------
COMBINED="$WORK/combined"
write_combined_site "$COMBINED"

set +e
( cd "$COMBINED" && "$ZIGAPAGOS" release "--output=$WORK/combined-out" --force ) \
  >"$WORK/1a.log" 2>"$WORK/1a.err"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { cat "$WORK/1a.log" "$WORK/1a.err"; fail "the combined fixture built successfully WITHOUT --allow-missing-pages -- the dangling \$link.page no longer fails the build"; }
grep -q 'error: unknown page' "$WORK/1a.err" \
  || { cat "$WORK/1a.err"; fail "expected 'error: unknown page' (the content-link failure) in stderr"; }
echo "PASS (1a): a dangling \$link.page still hard-fails the build without the flag (exit $RC)"

TEMPLATE_ONLY="$WORK/template-only"
write_template_only_site "$TEMPLATE_ONLY"

set +e
( cd "$TEMPLATE_ONLY" && "$ZIGAPAGOS" release "--output=$WORK/template-only-out" --force ) \
  >"$WORK/1b.log" 2>"$WORK/1b.err"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { cat "$WORK/1b.log" "$WORK/1b.err"; fail "the template-only fixture built successfully WITHOUT --allow-missing-pages -- a dangling \$site.page(...) no longer fails the build"; }
grep -q "missing page 'coming-soon'" "$WORK/1b.err" \
  || { cat "$WORK/1b.err"; fail "expected \"missing page 'coming-soon'\" (the template-lookup failure) in stderr"; }
echo "PASS (1b): a dangling \$site.page(...) still hard-fails the build without the flag (exit $RC)"

# ---------------------------------------------------------------------------
# (2) WITH the flag: the combined fixture builds clean, and the emitted HTML
#     carries the real would-be href for both the content link and the nav.
# ---------------------------------------------------------------------------
set +e
( cd "$COMBINED" && "$ZIGAPAGOS" release "--output=$WORK/combined-out" --force --allow-missing-pages ) \
  >"$WORK/2.log" 2>"$WORK/2.err"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || { cat "$WORK/2.log" "$WORK/2.err"; fail "--allow-missing-pages did not make the combined fixture build (exit $RC)"; }
echo "PASS (2a): --allow-missing-pages builds the combined fixture clean (exit 0)"

INDEX_HTML="$WORK/combined-out/index.html"
[[ -f "$INDEX_HTML" ]] || fail "expected page not emitted: $INDEX_HTML"
grep -c 'href="/coming-soon/"' "$INDEX_HTML" > "$WORK/href_count.txt" || true
HREF_COUNT="$(cat "$WORK/href_count.txt")"
[[ "$HREF_COUNT" -eq 2 ]] || { cat "$INDEX_HTML"; fail "expected 2 occurrences of href=\"/coming-soon/\" in $INDEX_HTML (nav + content link), got $HREF_COUNT"; }
echo "PASS (2b): index.html carries href=\"/coming-soon/\" for both the nav link and the content link"

grep -q "warning: .*missing page 'coming-soon' -- emitting link to '/coming-soon/' (--allow-missing-pages)" "$WORK/2.err" \
  || { cat "$WORK/2.err"; fail "expected the content-link warning on stderr"; }
echo "PASS (2c): the content-link path prints a warning naming the ref and the computed href"

grep -q "warning: \$site.page('coming-soon'): missing page -- .link() resolves to '/coming-soon/' (--allow-missing-pages)" "$WORK/2.err" \
  || { cat "$WORK/2.err"; fail "expected the template-lookup warning on stderr"; }
echo "PASS (2d): the template-lookup path prints a warning naming the ref and the computed href"

# ---------------------------------------------------------------------------
# (3) The TEMPLATE warning is deduped to ONE line across all 3 pages that
#     render the shared nav (a real assertion: the fixture is multi-page, and
#     a per-page-render warning would print 3 times, not 1).
# ---------------------------------------------------------------------------
for p in about contact; do
  [[ -f "$WORK/combined-out/$p/index.html" ]] || fail "expected page not emitted: $WORK/combined-out/$p/index.html"
  grep -q 'href="/coming-soon/"' "$WORK/combined-out/$p/index.html" \
    || fail "expected href=\"/coming-soon/\" in $p/index.html too (same shared nav)"
done
echo "PASS (3a): all 3 pages (index, about, contact) render the tolerated nav link"

TEMPLATE_WARNING_COUNT="$(grep -c "\$site.page('coming-soon'): missing page" "$WORK/2.err" || true)"
[[ "$TEMPLATE_WARNING_COUNT" -eq 1 ]] \
  || { cat "$WORK/2.err"; fail "expected the template-lookup warning exactly ONCE across 3 pages, got $TEMPLATE_WARNING_COUNT"; }
echo "PASS (3b): the template-lookup warning is deduped to exactly 1 line across 3 pages"

echo "ALL PROOF CHECKS PASSED (--allow-missing-pages tolerates a dangling \$link.page/\$site.page reference, warns once per distinct ref, and still fails without the flag)"
