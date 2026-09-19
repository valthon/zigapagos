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
<a href="about.html">document-relative page</a>
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

# Document-relative links must be checked from each emitted HTML directory,
# not the working directory or the tree root. Also exercise non-HTML assets.
printf 'export {};\n' >"$TREE/guides/app.js"
printf 'image\n' >"$TREE/guides/my image.png"
page "$TREE/index.html" '<a href="guides/">guides</a>'
page "$TREE/guides/index.html" '
<link href="../style.css?v=1&amp;theme=dark" rel="stylesheet">
<script src="./app.js?mode=x:y"></script>
<img src="my%20image.png#preview">
<a href="../about.html?x=1#intro">about</a>
<a href="./">self</a>
<a href="?query=1">query</a>
<a href="data:text/plain,hello">data</a>
<a href="tel:123">tel</a>
'
run_doctor relative-clean --strict
grep -q '0 warnings' "$WORK/relative-clean.log" || { cat "$WORK/relative-clean.log"; fail 'valid relative links warned'; }
[[ "$(cat "$WORK/relative-clean.rc")" -eq 0 ]] || fail 'valid relative links failed'
run_doctor relative-prefix --strict --url-prefix=project/nested
[[ "$(cat "$WORK/relative-prefix.rc")" -eq 0 ]] || { cat "$WORK/relative-prefix.log"; fail 'relative prefix links failed'; }

page "$TREE/guides/index.html" '
<img src="missing.png?cache=1#preview">
<script src="./missing.js"></script>
<link rel="stylesheet" href="../missing.css">
<a href="../missing.html">missing page</a>
<a href="../../style.css">leaves deployment prefix</a>
'
run_doctor relative-dirty --strict --url-prefix=project --format=json
[[ "$(cat "$WORK/relative-dirty.rc")" -eq 1 ]] || fail 'relative missing files must fail strict'
python3 - "$WORK/relative-dirty.log" <<'PYCHECK'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows[-1]['warnings'] == 5, rows
assert rows[-1]['errors'] == 0, rows
assert all(r['file'] == 'guides/index.html' for r in rows[:-1]), rows
assert any("../../style.css" in r['message'] for r in rows[:-1]), rows
PYCHECK

# A base changes URL semantics. Unsupported coverage must fail even without
# --strict, and must be visible to JSON consumers through skipped.
page "$TREE/guides/index.html" '<base href="https://cdn.example/assets/"><img src="external.png">'
run_doctor base --format=json
[[ "$(cat "$WORK/base.rc")" -eq 1 ]] || fail 'base must not return a clean audit'
python3 - "$WORK/base.log" <<'PYCHECK'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows[-1]['skipped'] == 1, rows
assert rows[-1]['warnings'] == 1, rows
assert '<base href>' in rows[0]['message'], rows
PYCHECK
# target-only bases do not change URL resolution.
page "$TREE/guides/index.html" '<base target="_blank"><img src="my%20image.png">'
run_doctor base-target --strict
[[ "$(cat "$WORK/base-target.rc")" -eq 0 ]] || fail 'target-only base must allow link checks'

# Symlinks must not make files outside the tree look like deployed output.
printf 'outside\n' >"$WORK/outside.png"
ln -s "$WORK/outside.png" "$TREE/guides/outside.png"
mkdir "$WORK/external-assets"
printf 'outside\n' >"$WORK/external-assets/file.png"
ln -s "$WORK/external-assets" "$TREE/guides/linked-assets"
page "$TREE/guides/index.html" '<img src="outside.png"><img src="linked-assets/file.png">'
run_doctor symlink --strict
grep -q '2 warnings' "$WORK/symlink.log" || { cat "$WORK/symlink.log"; fail 'symlink-backed files must not pass'; }
[[ "$(cat "$WORK/symlink.rc")" -eq 1 ]] || fail 'symlink files must fail strict'
echo 'PASS: document-relative assets, prefix traversal, base coverage, and symlinks'

# Unsupported spellings must produce explicit diagnostics, not false success.
page "$TREE/guides/index.html" '<img src="%2Fstyle.css"><img src="a&amp;b.png"><img src="bad%zz.png">'
run_doctor unsupported --strict
grep -q '3 warnings' "$WORK/unsupported.log" || { cat "$WORK/unsupported.log"; fail 'unsupported URL paths must warn'; }
[[ "$(cat "$WORK/unsupported.rc")" -eq 1 ]] || fail 'unsupported paths must fail strict'
for base in /assets/ ../assets/; do
  page "$TREE/guides/index.html" "<base href=\"$base\"><img src=\"image.png\">"
  run_doctor local-base
  [[ "$(cat "$WORK/local-base.rc")" -eq 1 ]] || fail 'local base must report incomplete coverage'
  grep -q '1 file skipped' "$WORK/local-base.log" || fail 'local base must count skipped coverage'
done
echo 'PASS: unsupported spellings and local bases report coverage limits'

# Colons only introduce a scheme after a valid ASCII scheme name. These
# spellings are ordinary document-relative filenames in a browser.
page "$TREE/guides/index.html" '
<a href="2026:missing.html">numeric prefix</a>
<a href=":missing.html">no prefix</a>
<img src="report name:missing.png">
<a href="web+demo.v2-test:asset">custom scheme</a>
'
run_doctor colon-missing --strict
grep -q '3 warnings' "$WORK/colon-missing.log" || { cat "$WORK/colon-missing.log"; fail 'missing colon paths must warn'; }
[[ "$(cat "$WORK/colon-missing.rc")" -eq 1 ]] || fail 'missing colon paths must fail strict'
printf '<!DOCTYPE html><html><head><title>Numeric</title></head><body>page</body></html>' > "$TREE/guides/2026:missing.html"
printf '<!DOCTYPE html><html><head><title>Colon</title></head><body>page</body></html>' > "$TREE/guides/:missing.html"
printf 'image\n' > "$TREE/guides/report name:missing.png"
run_doctor colon-present --strict
[[ "$(cat "$WORK/colon-present.rc")" -eq 0 ]] || { cat "$WORK/colon-present.log"; fail 'existing colon paths must pass'; }
grep -q '0 warnings' "$WORK/colon-present.log" || fail 'existing colon paths warned'
echo 'PASS: only valid ASCII scheme names exclude colon URLs from local audit'
