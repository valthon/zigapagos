#!/usr/bin/env bash
# Proof for `auto_heading_ids` (issue #29).
#
# SuperMD only stores a heading id when the author writes an explicit
# `$heading.id(...)`. Markdown authored for GitHub relies on GitHub's own
# IMPLICIT heading-anchor slugs instead, so a same-page `#anchor` link written
# against such a doc is an `unknown ref` build error — unless the site opts
# into `auto_heading_ids`, which injects a GitHub-compatible slug id into
# every heading that doesn't already have one (`src/heading_slugs.zig`).
#
# This fixture is generated into a `mktemp -d`, NOT a `tests/rendering/*/`
# directory: `build/snapshot.zig`'s `addRenderSuites` auto-discovers every
# directory under `tests/rendering/` as a snapshot suite, and this is a
# behavioural e2e proof, not a snapshot fixture.
#
# Checks:
#   (1) flag ON: duplicate headings get `id="foo"` / `id="foo-1"`, an em-dash
#       heading gets GitHub's double hyphen, an explicit `$heading.id(...)`
#       override wins over what auto-slugging would have produced, and both
#       an in-page `[t](#slug)` link and a cross-page `[t](/other#slug)` link
#       build clean with the right `href`.
#   (2) flag OFF (control, using content WITHOUT the anchor links — those
#       would fail regardless of this feature, so they'd defeat the point of
#       a control): today's behaviour is unchanged — no `id="..."` is emitted
#       on any heading.
#
# NOT checked here: that the SAME fixture fails with `unknown ref` on the
# parent commit (this feature's absence). That is a one-time regression proof
# done by hand (`git stash` + rebuild against the parent commit) rather than
# wired into this script, which would otherwise need to build a second,
# stale zigapagos binary on every CI run.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

fail() { echo "FAIL: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LAYOUT='<!DOCTYPE html>
<html>
  <head><meta charset="UTF-8"><title :text="$site.title"></title></head>
  <body>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>'

FRONTMATTER_HOME='---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---'

FRONTMATTER_OTHER='---
.title = "Other",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---'

# --- (1) flag ON: duplicates, em dash, explicit override, both link kinds --
ON="$WORK/on"; ON_OUT="$WORK/on-out"
mkdir -p "$ON/content" "$ON/layouts"
cat > "$ON/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Auto Heading Ids (on)",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
    .auto_heading_ids = true,
}
EOF
printf '%s' "$LAYOUT" > "$ON/layouts/index.shtml"

{
  printf '%s\n' "$FRONTMATTER_HOME"
  cat <<'MD'

# Foo

Text A.

# Foo

Text B.

# []($heading.id('explicit-id')) Should Not Auto Slug

Explicit id heading text.

# Calling the backend — apiFetch

Em dash heading.

[in-page link](#foo)

[directive link]($link.ref('foo-1'))

[cross-page link](/other#bar)
MD
} > "$ON/content/index.smd"

{
  printf '%s\n' "$FRONTMATTER_OTHER"
  cat <<'MD'

# Bar

Some text.
MD
} > "$ON/content/other.smd"

( cd "$ON" && "$ZIGAPAGOS" release "--output=$ON_OUT" --force ) > "$WORK/on.log" 2>&1 ||
  { cat "$WORK/on.log"; fail "flag-ON build failed (see log above)"; }

INDEX_HTML="$ON_OUT/index.html"
OTHER_HTML="$ON_OUT/other/index.html"
[[ -f "$INDEX_HTML" ]] || fail "flag-ON build did not emit index.html"
[[ -f "$OTHER_HTML" ]] || fail "flag-ON build did not emit other/index.html"

grep -q 'id="foo"' "$INDEX_HTML" || fail "first 'Foo' heading missing id=\"foo\""
grep -q 'id="foo-1"' "$INDEX_HTML" || fail "duplicate 'Foo' heading missing id=\"foo-1\""
grep -q 'id="calling-the-backend--apifetch"' "$INDEX_HTML" ||
  fail "em-dash heading missing GitHub's double-hyphen id"
grep -q 'id="explicit-id"' "$INDEX_HTML" || fail "explicit \$heading.id override missing"
grep -q 'id="should-not-auto-slug"' "$INDEX_HTML" &&
  fail "explicit id override was NOT respected — auto slug leaked through"
grep -q 'href="#foo"' "$INDEX_HTML" || fail "in-page anchor link did not build with the expected href"
grep -q 'href="#foo-1"' "$INDEX_HTML" || fail "\$link.ref to a generated id did not render its href"
grep -Eq 'href="[^"]*other[^"]*#bar"' "$INDEX_HTML" ||
  fail "cross-page anchor link did not build with the expected href"
grep -q 'id="bar"' "$OTHER_HTML" || fail "'Bar' heading in other.smd missing id=\"bar\""

echo "PASS: flag ON — duplicates, em dash, explicit override, both link kinds all correct"

# --- (2) flag OFF control: same headings, NO anchor links, NO id= emitted --
# The anchor links are dropped here on purpose: with the flag off they would
# fail with 'unknown ref' regardless of this feature (that's the whole
# problem this issue fixes), which would defeat the point of a control that
# is supposed to show "today's behaviour, unchanged".
OFF="$WORK/off"; OFF_OUT="$WORK/off-out"
mkdir -p "$OFF/content" "$OFF/layouts"
cat > "$OFF/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Auto Heading Ids (off)",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
printf '%s' "$LAYOUT" > "$OFF/layouts/index.shtml"

{
  printf '%s\n' "$FRONTMATTER_HOME"
  cat <<'MD'

# Foo

Text A.

# Foo

Text B.

# Calling the backend — apiFetch

Em dash heading.
MD
} > "$OFF/content/index.smd"

( cd "$OFF" && "$ZIGAPAGOS" release "--output=$OFF_OUT" --force ) > "$WORK/off.log" 2>&1 ||
  { cat "$WORK/off.log"; fail "flag-OFF (control) build failed (see log above)"; }

OFF_INDEX_HTML="$OFF_OUT/index.html"
[[ -f "$OFF_INDEX_HTML" ]] || fail "flag-OFF build did not emit index.html"
grep -q 'id="' "$OFF_INDEX_HTML" &&
  fail "flag OFF emitted an id= attribute — today's (pre-feature) behaviour changed"

echo "PASS: flag OFF (control) — no id= attributes, matching today's unchanged behaviour"

echo "ALL PROOF CHECKS PASSED (auto_heading_ids)"
