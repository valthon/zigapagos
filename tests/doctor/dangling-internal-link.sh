#!/usr/bin/env bash
# Regression test: `zigapagos doctor`'s `dangling-internal-link` check
# (severity `warn`) on a BUILT output tree.
#
# Unlike abs-url-meta this is `warn`, not `err`: a client-routed SPA URL has
# no file behind it in the tree (the route is served by the SPA shell + the
# runtime router), so treating every dangling root-relative href/src as a
# hard failure would false-positive on every SPA site. The exit-code
# contract this pins: warn-only findings exit 0 by default and 1 under
# `--strict` -- both are asserted below, not just one of them.
#
# Also pins the `--url-prefix` suggestion (the shipped DX-4 symptom): under a
# GitHub Pages project-site prefix, a generator bug can emit href="/guides"
# instead of the correctly-prefixed "/zigapagos/guides" -- physically
# `guides/index.html` exists, so the link isn't a *typo*, it's *missing its
# prefix*, and the diagnostic should say so rather than just "not found".
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

TREE="$WORK/tree"

# $1 = path (under $TREE), $2 = HTML fragment for <body>.
page() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<HTML
<!DOCTYPE html>
<html><head><title>t</title></head><body>
$2
</body></html>
HTML
}

run_doctor() { # $1 = tag, remaining = extra doctor args
  local tag="$1"; shift
  set +e
  "$ZIGAPAGOS" doctor "$TREE" "$@" >"$WORK/$tag.log" 2>&1
  echo $? >"$WORK/$tag.rc"
  set -e
}

# --- shared fixture: two real pages, one asset, one index-less directory --
page "$TREE/guides/index.html" '<p>guides</p>'
page "$TREE/about.html" '<p>about</p>'
printf 'body{}\n' >"$TREE/style.css"
mkdir -p "$TREE/emptydir" # a directory with NO index.html

# --- (1) clean: every legitimate link classification ----------------------
page "$TREE/index.html" '
<a href="/">root</a>
<a href="/guides/">guides, trailing slash</a>
<a href="/guides">guides, bare</a>
<a href="/about">about, extensionless</a>
<a href="/about.html">about, direct file</a>
<a href="/style.css">non-html asset, direct file</a>
<a href="https://example.com/x">absolute -- not root-relative</a>
<a href="#frag">fragment only -- not root-relative</a>
<a href="mailto:a@b">mailto -- not root-relative</a>
<a href="//cdn/x.js">scheme-relative -- not root-relative</a>
<a href="relative.html">page-relative -- not root-relative</a>
'
run_doctor clean
[[ "$(cat "$WORK/clean.rc")" -eq 0 ]] || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/clean.log"
  fail "clean tree: doctor exited non-zero"
}
grep -q 'doctor: 0 error' "$WORK/clean.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/clean.log"
  fail "clean tree: expected 0 errors"
}
grep -q '0 warning' "$WORK/clean.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/clean.log"
  fail "clean tree: expected 0 warnings -- a legitimate link was misdiagnosed as dangling"
}
echo "PASS (1): root+trailing-slash, bare directory, extensionless page, direct" \
     "file, and every non-root-relative scheme all resolve cleanly"

# --- (2) a dangling link + a directory with no index.html -----------------
# The last two pin that a link doctor CANNOT resolve is reported with its own
# cause rather than being silently dropped or misattributed. Both used to
# collapse into one `null` internally: the escaping path was the only one with
# a message, and every other unresolvable path borrowed it.
page "$TREE/index.html" '
<a href="/nope">dangling</a>
<a href="/emptydir">directory with no index.html</a>
<a href="/../outside">climbs above the site root</a>
<a href="/a%zzb">malformed percent-escape</a>
'
run_doctor dirty
[[ "$(cat "$WORK/dirty.rc")" -eq 0 ]] || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty.log"
  fail "warn-only findings must exit 0 WITHOUT --strict"
}
grep -q "warn dangling-internal-link:.*href '/nope' resolves to no file in the tree" "$WORK/dirty.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty.log"
  fail "missing the dangling-link warning for /nope"
}
grep -q "warn dangling-internal-link:.*href '/emptydir' resolves to no file in the tree" "$WORK/dirty.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty.log"
  fail "a directory with no index.html must warn -- a directory is not a regular file"
}
grep -q "warn dangling-internal-link:.*href '/../outside' escapes the site root" "$WORK/dirty.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty.log"
  fail "a link climbing above the site root must say so, not borrow the generic 'no file' message"
}
grep -q "warn dangling-internal-link:.*href '/a%zzb' has a malformed percent-escape" "$WORK/dirty.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty.log"
  fail "a malformed percent-escape must be REPORTED with its own cause -- it used to be skipped in silence"
}
# ...and neither may be misreported as the other's cause.
if grep -q "href '/a%zzb' escapes the site root" "$WORK/dirty.log"; then
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty.log"
  fail "the malformed-escape link was reported as an escape -- the causes are collapsed again"
fi
echo "PASS (2): dangling links, a directory-without-index, an escaping path and a malformed escape each warn with their OWN cause, and doctor still exits 0"

run_doctor dirty-strict --strict
[[ "$(cat "$WORK/dirty-strict.rc")" -eq 1 ]] || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/dirty-strict.log"
  fail "--strict must turn the SAME warnings into a non-zero exit"
}
echo "PASS (3): --strict turns the same warn-only findings into a non-zero exit"

# --- (4) --url-prefix: prefixed link resolves; un-prefixed one warns + ----
#         suggests the prefixed form
page "$TREE/index.html" '
<a href="/zigapagos/guides/">correctly prefixed</a>
<a href="/guides">missing the prefix (DX-4 symptom)</a>
'
run_doctor prefixed --url-prefix=zigapagos
grep -q "warn dangling-internal-link:.*href '/guides' resolves to no file in the tree (did you mean '/zigapagos/guides'?)" "$WORK/prefixed.log" || {
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/prefixed.log"
  fail "missing the --url-prefix 'did you mean' suggestion for /guides"
}
if grep -q "href '/zigapagos/guides/'" "$WORK/prefixed.log"; then
  echo "--- doctor output ---"; sed -n '1,30p' "$WORK/prefixed.log"
  fail "the correctly-prefixed link (/zigapagos/guides/) must NOT be flagged"
fi
echo "PASS (4): --url-prefix strips the prefix before resolving, and suggests it when the link is missing it"

echo "PASS: dangling-internal-link classifies every link kind correctly, warns (not errors) by default, --strict escalates, and --url-prefix resolves + suggests correctly"
