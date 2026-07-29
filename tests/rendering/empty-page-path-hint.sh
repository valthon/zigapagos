#!/usr/bin/env bash
# Regression test for issue #32: `$link.page('')` looks like it should work
# because `$site.page('')` does (base.shtml's own nav uses it for the home
# link) -- but supermd rejects an empty path with the bare message
# "path is empty", which never mentions that the right builtin for "link to
# the site's home page" is `$link.site()`. That hint DOES exist in supermd's
# own `page` builtin DESCRIPTION -- it just never reaches the error text,
# only docgen. This pins the in-repo enrichment added in printSuperMdErrors
# (src/root.zig): when the message is exactly "path is empty" and the
# offending source line contains `.page(`, append a note naming $link.site().
#
# NOT claimed: that `sub('')`/`sibling('')` get the same hint. They
# deliberately don't (see the scope cut in root.zig's comment at the site) --
# $link.site() is not what those mean.
#
# This test depends on matching an exact upstream SuperMD string ("path is
# empty"), which is a genuine dependency the comment at the fix site names
# explicitly: a release-tag sync that rewords it makes the hint silently stop
# firing, and THIS test is what is supposed to catch that at sync time.
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

SITE="$WORK/site"; OUT="$WORK/out"
mkdir -p "$SITE/content" "$SITE/layouts"

cat > "$SITE/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Empty page path hint test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF

cat > "$SITE/layouts/index.shtml" <<'EOF'
<html><body><super/></body></html>
EOF

cat > "$SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---

[home]($link.page(''))
EOF

# The build is EXPECTED to fail (an empty path is genuinely invalid --
# $link.site() is the fix, not making '' a valid page path), so this can't be
# `set -e`'d through normally: wrap it so a non-zero exit doesn't abort the
# script before the assertions below run.
set +e
( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >"$WORK/build.log" 2>"$WORK/build.err"
RC=$?
set -e

[[ "$RC" -ne 0 ]] || { cat "$WORK/build.log"; fail "an empty \$link.page('') built successfully -- the trigger no longer fails"; }
echo "build failed as expected (exit $RC)"

grep -q 'path is empty' "$WORK/build.err" \
  || { echo "--- stderr ---"; cat "$WORK/build.err"; fail "the build failed, but not with supermd's 'path is empty' -- test is measuring the wrong thing (see the comment at the fix site about matching this exact upstream string)"; }

grep -q '\$link.site()' "$WORK/build.err" \
  || { echo "--- stderr ---"; cat "$WORK/build.err"; fail "expected a note pointing at \$link.site() in stderr"; }

echo "PASS: an empty \$link.page('') fails with a note pointing at \$link.site()"

# --- the OTHER half of the `.page(` guard -----------------------------------
# The hint is gated on three things: a `.scripty` error, the exact message
# "path is empty", and `.page(` on the offending source line. The first two are
# pinned above; this pins the third, which is the half that decides where the
# hint must NOT appear. `$image.asset('')` raises the identical upstream
# message from the identical validator, so without the `.page(` guard it would
# be hinted too -- and "to link to the site homepage, use $link.site()" is
# actively wrong advice for a missing image.
#
# This needs its OWN build: in a single build containing both directives the
# hint fires for the $link.page('') line, so a grep over the shared stderr
# could not tell which line produced it.
ASSET_SITE="$WORK/asset-site"
mkdir -p "$ASSET_SITE/content" "$ASSET_SITE/layouts"
cp "$SITE/zigapagos.ziggy" "$ASSET_SITE/zigapagos.ziggy"
cp "$SITE/layouts/index.shtml" "$ASSET_SITE/layouts/index.shtml"

cat > "$ASSET_SITE/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Sample Author",
.layout = "index.shtml",
.draft = false,
---

[]($image.asset(''))
EOF

set +e
( cd "$ASSET_SITE" && "$ZIGAPAGOS" release "--output=$WORK/asset-out" --force ) \
  >"$WORK/asset.log" 2>"$WORK/asset.err"
ASSET_RC=$?
set -e

[[ "$ASSET_RC" -ne 0 ]] || { cat "$WORK/asset.log"; fail "an empty \$image.asset('') built successfully -- this control no longer exercises the same validator"; }

grep -q 'path is empty' "$WORK/asset.err" \
  || { echo "--- stderr ---"; cat "$WORK/asset.err"; fail "the asset control did not produce supermd's 'path is empty' -- it is no longer the same error the guard has to discriminate, so it proves nothing"; }

grep -q '\$link.site()' "$WORK/asset.err" \
  && { echo "--- stderr ---"; cat "$WORK/asset.err"; fail "\$image.asset('') was hinted toward \$link.site() -- the \`.page(\` guard is not discriminating, and the hint is now wrong advice on an asset error"; }

echo "PASS: an empty \$image.asset('') gets the same 'path is empty' error WITHOUT the \$link.site() note"
