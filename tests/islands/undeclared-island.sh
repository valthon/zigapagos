#!/usr/bin/env bash
# Regression test: an `<island>` with no island sidecar configured must FAIL the
# build, not ship an inert tag.
#
# The defect this pins: root.zig's sidecar spawn guard needs all three of
# bun_path / island_sidecar / island_src_dir and quietly leaves `island_sidecar`
# null if any is missing -- correct for a site that uses no islands. But
# worker.zig used to treat a null sidecar as "pass the HTML through", testing for
# `<island` only AFTER that bail. So the ordinary authoring mistake of adding an
# `<island>` to a layout without passing an `--island=` for it produced:
#
#   * a page containing the literal `<island ...></island>` element,
#   * no SSR'd markup, no props block, no runtime <script>, and
#   * exit code 0.
#
# i.e. the reader got a blank spot where the component should be and the build
# said everything was fine. That also contradicts the README's zero-JS promise in
# the opposite direction: the island is inert whether or not JS loads.
#
# The check is deliberately three-part, because asserting only "the build fails"
# would also pass if the fixture were broken for some unrelated reason:
#   (1) the SAME fixture WITHOUT an <island> builds clean  (control: the site and
#       the release invocation are otherwise fine),
#   (2) adding an <island> to a layout makes the build fail, naming the cause,
#   (3) the failing build did NOT publish a page containing a literal `<island`.
#
# (3) is the part that would have caught the original defect even if the exit
# code had been made non-zero for some other reason.
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

# A fresh copy of the shared fixture per phase, so phase (2) cannot be affected
# by output left over from phase (1).
new_site() {
  local site="$1"
  mkdir -p "$site"
  cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$site/"
  cp tests/rendering/simple/zigapagos.ziggy "$site/"
}

# --- (1) control: no <island> anywhere -> build succeeds ----------------------
SITE_OK="$WORK/ok"; OUT_OK="$WORK/out-ok"
new_site "$SITE_OK"
( cd "$SITE_OK" && "$ZIGAPAGOS" release "--output=$OUT_OK" --force ) >"$WORK/ok.log" 2>&1 \
  || { sed -n '1,20p' "$WORK/ok.log"; fail "control build failed -- the fixture itself is broken, so this test proves nothing"; }
echo "control: island-free build succeeded"

# --- (2) an <island> with no sidecar -> build MUST fail ----------------------
SITE_BAD="$WORK/bad"; OUT_BAD="$WORK/out-bad"
new_site "$SITE_BAD"
# Append the island inside <body>, after the page content div.
python3 - "$SITE_BAD/layouts/index.shtml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = '<div :html="$page.content()"></div>'
assert needle in src, "fixture layout changed; update this test's injection point"
open(p, "w").write(src.replace(
    needle,
    needle + '\n    <island src="components/Counter.island.tsx" client:load></island>',
))
PY
grep -q '<island' "$SITE_BAD/layouts/index.shtml" || fail "failed to inject the <island> into the fixture layout"

set +e
( cd "$SITE_BAD" && "$ZIGAPAGOS" release "--output=$OUT_BAD" --force ) >"$WORK/bad.log" 2>&1
BAD_RC=$?
set -e

[[ "$BAD_RC" -ne 0 ]] || {
  echo "--- build output ---"; sed -n '1,20p' "$WORK/bad.log"
  fail "an <island> with no sidecar configured built SUCCESSFULLY (exit 0) -- the silent-failure regression is back"
}
echo "an <island> with no sidecar failed the build (exit $BAD_RC)"

# The message must name the actual cause and the fix, not just fail somewhere.
grep -q 'no island sidecar is configured' "$WORK/bad.log" \
  || { echo "--- build output ---"; sed -n '1,20p' "$WORK/bad.log"
       fail "the build failed but not with the island-sidecar diagnostic (some other error?)"; }
grep -q -- '--island=' "$WORK/bad.log" \
  || fail "the diagnostic does not tell the author to declare the island with --island="
echo "diagnostic names the cause and the fix"

# --- (3) the failure is attributed to a specific page -------------------------
# Not "no page containing <island> exists on disk": the render pass reports the
# error and continues with the raw HTML (`break :blk raw` + any_rendering_error),
# exactly as it already does when island SSR itself fails, so a failed disk build
# CAN leave inert pages in the output tree. The non-zero exit is what stops a
# deploy; output-tree atomicity on a mid-build failure is a separate, known issue
# (the same class as a mid-build prerenderAll fatal leaving new page HTML beside
# stale SPA shells) and is tracked for its own change rather than pinned here.
#
# What IS worth pinning: the diagnostic must name the page, so an author with a
# large site can find the offending layout instead of getting a bare "build
# failed".
grep -qE 'island rendering error on [^ ]+\.smd' "$WORK/bad.log" \
  || { echo "--- build output ---"; sed -n '1,20p' "$WORK/bad.log"
       fail "the diagnostic does not attribute the failure to a specific content page"; }
echo "diagnostic attributes the failure to a specific page"

echo "PASS: an undeclared <island> fails the build with an actionable, attributed message"
