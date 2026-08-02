#!/usr/bin/env bash
# Proof for `asset_fingerprint` — content-hashed site-asset filenames (issue #53).
#
# WHAT IT IS FOR. Assets are emitted at stable paths (`/style.css`), so a CDN
# or GitHub Pages can serve a returning visitor a cached stylesheet against
# freshly deployed HTML. `asset_fingerprint = true` puts the content hash in
# the filename, which is what makes a far-future `Cache-Control` on the asset
# tree safe: a changed file is a changed URL.
#
# WHY AN e2e SCRIPT RATHER THAN UNIT TESTS. The naming and the URL formatting
# are unit-tested in `src/fingerprint.zig`. What CANNOT be unit-tested is the
# property that actually matters: that the name a page LINKS and the name the
# install pass WRITES are the same string. Those are produced by different
# passes at different points in `src/root.zig`, and a drift between them is a
# 404 that only appears in a deployed build. So every check below compares the
# emitted HTML against the emitted file tree.
#
# The fixture is generated into a `mktemp -d`, NOT a `tests/rendering/*/`
# directory: `build/snapshot.zig`'s `addRenderSuites` auto-discovers every
# directory under `tests/rendering/` as a snapshot suite, and this is a
# behavioural proof, not a snapshot fixture.
#
# Checks:
#   (1) ON:  a `.link()`ed asset is emitted at `style.<hash>.css`, the HTML
#            points at exactly that name, and the unhashed `/style.css` is
#            NOT in the output.
#   (2) ON:  a `static_assets` entry keeps its verbatim name — something
#            outside the build fetches `favicon.ico` at a fixed path.
#   (3) ON:  a SuperMD `[]($image.siteAsset(...))` directive resolves to the
#            same hashed name as `.link()` does (the second URL-printing seam).
#   (4) ON:  a nested asset keeps its directory and only its basename changes.
#   (5) determinism: rebuilding unchanged input reproduces the same hash;
#       changing one byte of the CSS changes it (this is the cache-busting
#       property itself).
#   (6) OFF (control): the same fixture with the flag absent emits
#       `/style.css` verbatim and no hashed name anywhere.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

fail() { echo "FAIL: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LAYOUT='<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8"><title :text="$site.title"></title>
    <link rel="stylesheet" href="$site.asset('"'"'style.css'"'"').link()">
    <link rel="icon" href="$site.asset('"'"'favicon.ico'"'"').link()">
    <link rel="preload" as="font" href="$site.asset('"'"'fonts/inter.woff2'"'"').link()">
  </head>
  <body>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>'

CONTENT='---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

# Home

[]($image.siteAsset("logo.png"))
'

# Builds a fixture at $1 with the css body $2; $3 = "on"|"off" for the flag.
scaffold() {
  local dir="$1" css="$2" flag="$3"
  mkdir -p "$dir/content" "$dir/layouts" "$dir/assets/fonts"
  {
    echo 'Site {'
    echo '    .title = "Fingerprint",'
    echo '    .host_url = "https://example.com",'
    echo '    .content_dir_path = "content",'
    echo '    .layouts_dir_path = "layouts",'
    echo '    .assets_dir_path = "assets",'
    echo '    .static_assets = ["favicon.ico"],'
    [[ "$flag" == "on" ]] && echo '    .asset_fingerprint = true,'
    echo '}'
  } > "$dir/zigapagos.ziggy"
  printf '%s' "$LAYOUT" > "$dir/layouts/index.shtml"
  printf '%s' "$CONTENT" > "$dir/content/index.smd"
  printf '%s' "$css" > "$dir/assets/style.css"
  printf 'ICO' > "$dir/assets/favicon.ico"
  printf 'PNG-BYTES' > "$dir/assets/logo.png"
  printf 'WOFF2' > "$dir/assets/fonts/inter.woff2"
}

build() {
  local dir="$1" out="$2" log="$3"
  ( cd "$dir" && "$ZIGAPAGOS" release "--output=$out" --force ) > "$log" 2>&1 ||
    { cat "$log"; fail "build of '$dir' failed (see log above)"; }
}

# --- (1)–(4) flag ON -------------------------------------------------------
ON="$WORK/on"; ON_OUT="$WORK/on-out"
scaffold "$ON" 'body{color:red}' on
build "$ON" "$ON_OUT" "$WORK/on.log"

HTML="$ON_OUT/index.html"
[[ -f "$HTML" ]] || fail "flag-ON build did not emit index.html"

# (1) The linked stylesheet is hashed, and it is the SAME name on disk.
HASHED="$(grep -o 'href="/style\.[0-9a-f]\{8\}\.css"' "$HTML" | head -1 |
  sed 's|.*href="/||; s|"$||')" ||
  fail "no fingerprinted stylesheet href in the HTML"
[[ -n "$HASHED" ]] || fail "flag ON did not emit a fingerprinted style.css href"
[[ -f "$ON_OUT/$HASHED" ]] ||
  fail "HTML links '/$HASHED' but the install pass wrote no such file"
[[ ! -f "$ON_OUT/style.css" ]] ||
  fail "flag ON also installed the unhashed style.css — the stable path is what
        makes a stale cache possible, so it must not be written"
echo "PASS: linked css installed at /$HASHED and linked at exactly that name"

# (2) static_assets keep a stable name — something external fetches them.
[[ -f "$ON_OUT/favicon.ico" ]] ||
  fail "a static_assets entry was not installed at its verbatim path"
grep -q 'href="/favicon.ico"' "$HTML" ||
  fail "a static_assets entry was fingerprinted — external fetchers rely on the fixed path"
echo "PASS: static_assets entry kept its verbatim name"

# (3) The SuperMD directive seam agrees with the .link() seam.
IMG="$(grep -o 'src="/logo\.[0-9a-f]\{8\}\.png"' "$HTML" | head -1 |
  sed 's|.*src="/||; s|"$||')" ||
  fail "no fingerprinted image src in the HTML"
[[ -n "$IMG" ]] || fail '$image.siteAsset() did not resolve to a fingerprinted name'
[[ -f "$ON_OUT/$IMG" ]] ||
  fail "HTML embeds '/$IMG' but the install pass wrote no such file"
echo "PASS: \$image.siteAsset() directive resolved to /$IMG and that file exists"

# (4) A nested asset keeps its directory; only the basename is hashed.
FONT="$(grep -o 'href="/fonts/inter\.[0-9a-f]\{8\}\.woff2"' "$HTML" | head -1 |
  sed 's|.*href="/||; s|"$||')" ||
  fail "no fingerprinted nested-asset href in the HTML"
[[ -n "$FONT" ]] || fail "nested asset was not fingerprinted"
[[ -f "$ON_OUT/$FONT" ]] ||
  fail "HTML links '/$FONT' but the install pass wrote no such file"
echo "PASS: nested asset kept its directory: /$FONT"

# --- (5) determinism + cache busting ---------------------------------------
SAME="$WORK/same"; SAME_OUT="$WORK/same-out"
scaffold "$SAME" 'body{color:red}' on
build "$SAME" "$SAME_OUT" "$WORK/same.log"
SAME_HASHED="$(grep -o 'href="/style\.[0-9a-f]\{8\}\.css"' "$SAME_OUT/index.html" |
  head -1 | sed 's|.*href="/||; s|"$||')"
[[ "$SAME_HASHED" == "$HASHED" ]] ||
  fail "identical input produced different names ('$HASHED' vs '$SAME_HASHED') —
        every deploy would then invalidate every asset"
echo "PASS: identical input reproduced /$HASHED"

DIFF="$WORK/diff"; DIFF_OUT="$WORK/diff-out"
scaffold "$DIFF" 'body{color:blue}' on
build "$DIFF" "$DIFF_OUT" "$WORK/diff.log"
DIFF_HASHED="$(grep -o 'href="/style\.[0-9a-f]\{8\}\.css"' "$DIFF_OUT/index.html" |
  head -1 | sed 's|.*href="/||; s|"$||')"
[[ "$DIFF_HASHED" != "$HASHED" ]] ||
  fail "changed CSS kept the name '$HASHED' — that is the stale-cache bug itself"
[[ -f "$DIFF_OUT/$DIFF_HASHED" ]] ||
  fail "changed CSS links '/$DIFF_HASHED' but no such file was installed"
echo "PASS: changed CSS moved to /$DIFF_HASHED"

# --- (6) flag OFF control --------------------------------------------------
OFF="$WORK/off"; OFF_OUT="$WORK/off-out"
scaffold "$OFF" 'body{color:red}' off
build "$OFF" "$OFF_OUT" "$WORK/off.log"

OFF_HTML="$OFF_OUT/index.html"
[[ -f "$OFF_OUT/style.css" ]] ||
  fail "flag OFF did not install style.css at its verbatim path"
grep -q 'href="/style.css"' "$OFF_HTML" ||
  fail "flag OFF did not link /style.css — today's behaviour changed"
grep -Eq '(href|src)="/[^"]*\.[0-9a-f]{8}\.(css|png|woff2)"' "$OFF_HTML" &&
  fail "flag OFF emitted a fingerprinted URL — the feature is not opt-in"
grep -q 'src="/logo.png"' "$OFF_HTML" ||
  fail "flag OFF did not embed /logo.png verbatim"
echo "PASS: flag OFF (control) — verbatim names everywhere, unchanged behaviour"

echo "ALL PROOF CHECKS PASSED (asset_fingerprint)"
