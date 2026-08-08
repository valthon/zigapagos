#!/usr/bin/env bash
# Proof for `speculation_rules` (issue #128).
#
# When a site opts into `speculation_rules`, every rendered HTML page gets a
# browser-native `<script type="speculationrules">` block spliced in before
# `</head>` (`src/islands/pass.zig`'s `speculationRulesTag` +
# `injectBeforeHeadEnd`, called from `src/worker.zig`'s `renderPage`). It is
# pure build-time HTML: no runtime JS, and browsers without Speculation Rules
# support just see an unrecognized `<script>` type and ignore it.
#
# This fixture is generated into a `mktemp -d`, NOT a `tests/rendering/*/`
# directory: `build/snapshot.zig`'s `addRenderSuites` auto-discovers every
# directory under `tests/rendering/` as a snapshot suite, and this is a
# behavioural e2e proof, not a snapshot fixture.
#
# Checks:
#   (1) flag ON: every emitted page contains the exact block, unprefixed
#       (`href_matches":"/*"`).
#   (2) flag ON + `url_path_prefix`: the block's `href_matches` is prefixed
#       (`"/myrepo/*"`), reusing `pass.prefixed`'s normalization.
#   (3) flag OFF (control): no `speculationrules` string appears anywhere in
#       the output — today's (pre-feature) behaviour is unchanged.
#
# One-time regression proof (done by hand, not wired into CI per the
# `auto-heading-ids.sh` precedent, which would otherwise need a second stale
# zigapagos binary built on every run): this script's case (1) was run
# against a zigapagos binary built from the parent commit (`git stash` on
# src/root.zig, src/islands/pass.zig, src/worker.zig, then `zig build`) and
# confirmed to FAIL (`grep -c speculationrules` found 0 matches, script exit
# 1) — see the commit message for the exact transcript.
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

FRONTMATTER='---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---'

OTHER_FRONTMATTER='---
.title = "Other",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---'

EXPECTED_TAG='<script type="speculationrules">{"prefetch":[{"where":{"href_matches":"/*"},"eagerness":"moderate"}]}</script>'
EXPECTED_TAG_PREFIXED='<script type="speculationrules">{"prefetch":[{"where":{"href_matches":"/myrepo/*"},"eagerness":"moderate"}]}</script>'

# --- (1) flag ON, unprefixed: exact block on every page --------------------
ON="$WORK/on"; ON_OUT="$WORK/on-out"
mkdir -p "$ON/content" "$ON/layouts"
cat > "$ON/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Speculation Rules (on)",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
    .speculation_rules = true,
}
EOF
printf '%s' "$LAYOUT" > "$ON/layouts/index.shtml"
{
  printf '%s\n' "$FRONTMATTER"
  echo
  echo 'Home page text.'
} > "$ON/content/index.smd"
{
  printf '%s\n' "$OTHER_FRONTMATTER"
  echo
  echo 'Other page text.'
} > "$ON/content/other.smd"

( cd "$ON" && "$ZIGAPAGOS" release "--output=$ON_OUT" --force ) > "$WORK/on.log" 2>&1 ||
  { cat "$WORK/on.log"; fail "flag-ON build failed (see log above)"; }

INDEX_HTML="$ON_OUT/index.html"
OTHER_HTML="$ON_OUT/other/index.html"
[[ -f "$INDEX_HTML" ]] || fail "flag-ON build did not emit index.html"
[[ -f "$OTHER_HTML" ]] || fail "flag-ON build did not emit other/index.html"

grep -qF "$EXPECTED_TAG" "$INDEX_HTML" || fail "index.html missing the exact unprefixed speculationrules block"
grep -qF "$EXPECTED_TAG" "$OTHER_HTML" || fail "other/index.html missing the exact unprefixed speculationrules block"
grep -qF '</head>' "$INDEX_HTML" || fail "index.html has no </head> — fixture is malformed"
# the tag must land BEFORE </head>, not after
BEFORE_HEAD="$(sed -n '1,/<\/head>/p' "$INDEX_HTML")"
grep -qF "$EXPECTED_TAG" <<<"$BEFORE_HEAD" || fail "speculationrules block was not spliced before </head>"

echo "PASS: flag ON (unprefixed) — exact block present on every page, before </head>"

# --- (2) flag ON + url_path_prefix: prefixed href_matches ------------------
PFX="$WORK/pfx"; PFX_OUT="$WORK/pfx-out"
mkdir -p "$PFX/content" "$PFX/layouts"
cat > "$PFX/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Speculation Rules (prefixed)",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
    .speculation_rules = true,
    .url_path_prefix = "myrepo",
}
EOF
printf '%s' "$LAYOUT" > "$PFX/layouts/index.shtml"
{
  printf '%s\n' "$FRONTMATTER"
  echo
  echo 'Home page text.'
} > "$PFX/content/index.smd"

( cd "$PFX" && "$ZIGAPAGOS" release "--output=$PFX_OUT" --force ) > "$WORK/pfx.log" 2>&1 ||
  { cat "$WORK/pfx.log"; fail "flag-ON+prefix build failed (see log above)"; }

PFX_INDEX_HTML="$PFX_OUT/index.html"
[[ -f "$PFX_INDEX_HTML" ]] || fail "flag-ON+prefix build did not emit index.html"
grep -qF "$EXPECTED_TAG_PREFIXED" "$PFX_INDEX_HTML" ||
  fail "index.html missing the prefixed speculationrules block (\"/myrepo/*\")"
grep -qF "$EXPECTED_TAG" "$PFX_INDEX_HTML" &&
  fail "index.html contains the UNPREFIXED block — url_path_prefix was not applied"

echo "PASS: flag ON + url_path_prefix — href_matches is \"/myrepo/*\""

# --- (3) flag OFF (control): no speculationrules anywhere ------------------
OFF="$WORK/off"; OFF_OUT="$WORK/off-out"
mkdir -p "$OFF/content" "$OFF/layouts"
cat > "$OFF/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Speculation Rules (off)",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
printf '%s' "$LAYOUT" > "$OFF/layouts/index.shtml"
{
  printf '%s\n' "$FRONTMATTER"
  echo
  echo 'Home page text.'
} > "$OFF/content/index.smd"

( cd "$OFF" && "$ZIGAPAGOS" release "--output=$OFF_OUT" --force ) > "$WORK/off.log" 2>&1 ||
  { cat "$WORK/off.log"; fail "flag-OFF (control) build failed (see log above)"; }

OFF_INDEX_HTML="$OFF_OUT/index.html"
[[ -f "$OFF_INDEX_HTML" ]] || fail "flag-OFF build did not emit index.html"

COUNT="$(grep -c speculationrules "$OFF_INDEX_HTML" || true)"
[[ "$COUNT" -eq 0 ]] || fail "flag OFF emitted 'speculationrules' — today's (pre-feature) behaviour changed"

echo "PASS: flag OFF (control) — no speculationrules block, matching today's unchanged behaviour"

echo "ALL PROOF CHECKS PASSED (speculation_rules)"
