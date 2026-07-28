#!/usr/bin/env bash
# Proof for the relative-artifact-alias warning (issue #21).
#
# A content page once aliased `"404.html"` meaning to override a SPA's
# site-wide fallback. `.aliases` entries without a leading `/` are joined to
# the page's own output directory (inherited upstream semantics, and
# this change does NOT alter that) — so the alias landed at
# `<page-dir>/404.html` instead of `/404.html`, and the demo app kept
# owning the real site root. The build passed silently.
#
# `src/root.zig`'s alias-intern loop now warns, on stderr only, when a
# relative alias's basename is one of `404.html` / `robots.txt` /
# `sitemap.xml` AND the page is not itself at the site root. Three cases:
#
#   1. non-root page, relative "404.html"      -> warns; file still lands
#      at <page-dir>/404.html (resolution UNCHANGED — that's the point).
#   2. control: same page, "/404.html"         -> no warning; file at
#      $OUT/404.html.
#   3. control: site-root page, relative
#      "404.html"                              -> no warning (prefix.len==0
#      exclusion: relative and root-absolute resolve identically there).
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

layout_shtml() {
  cat <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$page.title"></title>
  </head>
  <body>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
}

site_ziggy() {
  cat <<'EOF'
Site {
    .title = "Alias Warning Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
}

# gen_site DIR ALIASES_FRONTMATTER_LINE
#
# Builds a two-page site: content/index.smd (site root, no aliases) and
# content/sub.smd (a non-root page, output dir "sub/") carrying
# ALIASES_FRONTMATTER_LINE verbatim in its frontmatter.
gen_site() {
  local dir="$1" aliases_line="$2"
  mkdir -p "$dir/content" "$dir/layouts"
  layout_shtml > "$dir/layouts/page.shtml"
  site_ziggy > "$dir/zigapagos.ziggy"

  cat > "$dir/content/index.smd" <<EOF
---
.title = "Homepage",
.date = @date("2020-01-01T00:00:00"),
.author = "Test Author",
.layout = "page.shtml",
.draft = false,
---
Homepage content.
EOF

  cat > "$dir/content/sub.smd" <<EOF
---
.title = "Sub Page",
.date = @date("2020-01-01T00:00:00"),
.author = "Test Author",
.layout = "page.shtml",
.draft = false,
$aliases_line
---
Sub page content.
EOF
}

# gen_root_site DIR ALIASES_FRONTMATTER_LINE
#
# Builds a single-page site where the aliasing page IS the site root
# (content/index.smd), to exercise the prefix.len == 0 exclusion.
gen_root_site() {
  local dir="$1" aliases_line="$2"
  mkdir -p "$dir/content" "$dir/layouts"
  layout_shtml > "$dir/layouts/page.shtml"
  site_ziggy > "$dir/zigapagos.ziggy"

  cat > "$dir/content/index.smd" <<EOF
---
.title = "Homepage",
.date = @date("2020-01-01T00:00:00"),
.author = "Test Author",
.layout = "page.shtml",
.draft = false,
$aliases_line
---
Homepage content.
EOF
}

build() {
  local site="$1" out="$2" log="$3"
  ( cd "$site" && "$ZIGAPAGOS" release "--output=$out" --force ) >"$log" 2>&1
}

# --- (1) non-root page, relative "404.html" -> warns, resolution unchanged --
SITE1="$WORK/site1"; OUT1="$WORK/out1"; LOG1="$WORK/log1.txt"
gen_site "$SITE1" '.aliases = ["404.html"],'
build "$SITE1" "$OUT1" "$LOG1" || fail "case 1 build failed (should be a warning, not an error):
$(cat "$LOG1")"

grep -q "warning: alias '404.html'" "$LOG1" \
  || fail "case 1: expected a relative-artifact-alias warning in build output, got:
$(cat "$LOG1")"
echo "PASS (1a): relative alias '404.html' on a non-root page warns"

[[ -f "$OUT1/sub/404.html" ]] \
  || fail "case 1: resolution behaviour changed — expected the alias to still land at sub/404.html (relative-to-page-dir, unchanged), but it is missing. Tree:
$(find "$OUT1" -type f)"
echo "PASS (1b): the alias still resolves relative to the page's own output directory (unchanged)"

# --- (2) control: same page, root-absolute "/404.html" -> no warning -------
SITE2="$WORK/site2"; OUT2="$WORK/out2"; LOG2="$WORK/log2.txt"
gen_site "$SITE2" '.aliases = ["/404.html"],'
build "$SITE2" "$OUT2" "$LOG2" || fail "case 2 build failed:
$(cat "$LOG2")"

if grep -q "warning: alias" "$LOG2"; then
  fail "case 2: root-absolute alias '/404.html' must NOT warn, got:
$(cat "$LOG2")"
fi
echo "PASS (2a): root-absolute alias '/404.html' does not warn"

[[ -f "$OUT2/404.html" ]] \
  || fail "case 2: expected the root-absolute alias to land at \$OUT/404.html. Tree:
$(find "$OUT2" -type f)"
echo "PASS (2b): root-absolute alias lands at the site root"

# --- (3) control: site-root page, relative "404.html" -> no warning --------
SITE3="$WORK/site3"; OUT3="$WORK/out3"; LOG3="$WORK/log3.txt"
gen_root_site "$SITE3" '.aliases = ["404.html"],'
build "$SITE3" "$OUT3" "$LOG3" || fail "case 3 build failed:
$(cat "$LOG3")"

if grep -q "warning: alias" "$LOG3"; then
  fail "case 3: a relative alias on the site-root page itself (prefix.len == 0) must NOT warn — relative and root-absolute resolve identically there. Got:
$(cat "$LOG3")"
fi
echo "PASS (3): relative alias on the site-root page does not warn (prefix.len == 0 exclusion)"

echo "ALL PROOF CHECKS PASSED (alias root-artifact warning)"
