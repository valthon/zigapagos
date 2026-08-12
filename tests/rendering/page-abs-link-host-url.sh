#!/usr/bin/env bash
# Regression + design-documentation test for `$page.absLink()` (issue #151)
# and the "host_url unset" requirement from its brief: `Asset.absLink()`
# never added its own host_url-presence check (Asset.zig's `linkImpl` prints
# `site.host_url` unconditionally when it needs to), because `Site.host_url`
# is a REQUIRED zigapagos.ziggy field with no default (src/root.zig) and
# `Config.validate()` rejects an invalid one with a fatal BEFORE any page
# ever renders (src/root.zig, `std.Uri.parse(s.host_url)`). `Page.absLink()`
# is built the same way -- see `linkImpl` in src/context/Page.zig, which has
# no host_url check of its own either -- so this pins that stance rather
# than a new one: an empty/invalid host_url fails the SAME way whether the
# layout calls `$page.link()` or `$page.absLink()`, because the failure
# happens at config-validation time, before either builtin ever runs.
#
# `--format=json` avoids the unrelated Debug-build panic on `fatal.msg`
# (see tests/diagnostics/format-json.sh's header for that mechanism) so this
# test can assert a clean exit code instead of a SIGABRT.
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

mkdir -p "$WORK/content" "$WORK/layouts"

cat >"$WORK/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "index.shtml",
---
Body.
EOF

site_ziggy() { # $1 = host_url literal (already quoted Ziggy string)
  cat >"$WORK/zigapagos.ziggy" <<EOF
Site {
    .title = "Host Url Unset",
    .host_url = $1,
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
}

layout_using() { # $1 = builtin call to put in the canonical href
  cat >"$WORK/layouts/index.shtml" <<EOF
<!DOCTYPE html>
<html>
  <head>
    <title :text="\$page.title"></title>
    <link rel="canonical" href="$1">
  </head>
  <body><div :html="\$page.content()"></div></body>
</html>
EOF
}

run_release() {
  set +e
  ( cd "$WORK" && "$ZIGAPAGOS" release --format=json --force -o out ) \
    >"$WORK/out.log" 2>"$WORK/err.log"
  echo $? >"$WORK/rc"
  set -e
}

EXPECTED='"message":"error: host url '"'"''"'"' in zigapagos.ziggy is invalid: InvalidFormat"'

# --- (1) $page.absLink() with host_url = "" -------------------------------
site_ziggy '""'
layout_using '$page.absLink()'
run_release
[[ "$(cat "$WORK/rc")" -eq 1 ]] || {
  cat "$WORK/err.log"; fail "an empty host_url + \$page.absLink() must fail the build (exit 1)"
}
grep -q '"code":"ZP_FATAL"' "$WORK/err.log" || {
  cat "$WORK/err.log"; fail "expected a ZP_FATAL diagnostic"
}
grep -qF "$EXPECTED" "$WORK/err.log" || {
  cat "$WORK/err.log"; fail "expected the standard invalid-host_url message, got a different one -- absLink() must not carry its own divergent check"
}
echo "PASS (1): \$page.absLink() with host_url=\"\" fails with the standard invalid-host_url ZP_FATAL"

# --- (2) Control: $page.link() with the SAME host_url gets the SAME error -
# The point of this control is negative: if absLink() introduced its own
# host_url check, this cell (which never calls absLink()) would keep
# succeeding while (1) failed, and the two err.log files would diverge.
site_ziggy '""'
layout_using '$page.link()'
run_release
[[ "$(cat "$WORK/rc")" -eq 1 ]] || {
  cat "$WORK/err.log"; fail "control: empty host_url must fail even with plain \$page.link() (no absLink involved)"
}
grep -qF "$EXPECTED" "$WORK/err.log" || {
  cat "$WORK/err.log"; fail "control: message diverged from the absLink() case -- host_url validation is not shared"
}
echo "PASS (2): the same fatal fires for plain \$page.link(), proving absLink() added no separate host_url check"

# --- (3) Control: a valid host_url builds cleanly with $page.absLink() ----
site_ziggy '"https://example.com"'
layout_using '$page.absLink()'
run_release
[[ "$(cat "$WORK/rc")" -eq 0 ]] || {
  cat "$WORK/err.log"; fail "control: a valid host_url must build cleanly"
}
grep -q 'https://example.com/' "$WORK/out/index.html" || {
  cat "$WORK/out/index.html"; fail "control: \$page.absLink() did not resolve to the absolute URL once host_url is valid"
}
echo "PASS (3): a valid host_url builds, and \$page.absLink() resolves to the absolute URL"

echo "PASS: \$page.absLink() relies on the existing host_url config validation instead of a second, divergent check"
