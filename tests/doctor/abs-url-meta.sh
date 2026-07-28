#!/usr/bin/env bash
# Regression test: `zigapagos doctor`'s `abs-url-meta` check (severity `err`)
# on a BUILT output tree.
#
# The defect this pins: Open Graph / Twitter card metadata and
# `<link rel="canonical">` are read by crawlers, which have no notion of
# "this site's root" the way a browser resolving a page-relative link does —
# a root-relative `og:image`/`twitter:image`/canonical URL is simply broken
# there, not merely suboptimal, so this check is `err` severity (build/deploy
# gate), not `warn`.
#
# `err` severity is only safe because the check is an ALLOWLIST of
# known-URL-valued keys (see doctor.zig's `url_meta_keys`), not "everything
# under og:/twitter:". The clean fixture below carries three deliberate
# FALSE-POSITIVE CONTROLS alongside the genuinely-absolute values:
#   - `og:title` content starting with '/' (free text, not a URL — must NOT
#     fire even though the value looks root-relative)
#   - a SCHEME-RELATIVE `og:image` ("//cdn.../og.png" — resolves against the
#     current scheme; not the same defect as a root-relative one, and must
#     NOT fire)
#   - `twitter:card` = "summary" (not URL-valued at all)
# These three are the point of the clean-fixture assertion: they pin the
# guards that make `err` severity safe, not just "the happy path works".
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

run_doctor() { # $1 = tag, $2 = tree dir
  local tag="$1" dir="$2"
  set +e
  "$ZIGAPAGOS" doctor "$dir" >"$WORK/$tag.log" 2>&1
  echo $? >"$WORK/$tag.rc"
  set -e
}

# --- (1) clean: absolute values + the three false-positive controls -------
CLEAN="$WORK/clean"
mkdir -p "$CLEAN"
cat >"$CLEAN/index.html" <<'HTML'
<!DOCTYPE html>
<html>
<head>
<title>home</title>
<meta property="og:image" content="https://example.com/og.png">
<meta property="og:title" content="/dev/null explained">
<meta property="og:image" content="//cdn.example.com/og.png">
<meta name="twitter:card" content="summary">
<link rel="canonical" href="https://example.com/page/">
</head>
<body><p>hello</p></body>
</html>
HTML

run_doctor clean "$CLEAN"
[[ "$(cat "$WORK/clean.rc")" -eq 0 ]] || {
  echo "--- doctor output ---"; sed -n '1,20p' "$WORK/clean.log"
  fail "a tree with only absolute URLs + false-positive controls must exit 0"
}
grep -q 'doctor: 0 error' "$WORK/clean.log" || {
  echo "--- doctor output ---"; sed -n '1,20p' "$WORK/clean.log"
  fail "expected 0 errors on the clean fixture -- a false-positive control fired"
}
echo "PASS (1): absolute URLs pass, and the three false-positive controls (free-text" \
     "og:title, scheme-relative og:image, non-URL twitter:card) do not fire"

# --- (2) dirty: a root-relative og:image + a root-relative canonical ------
DIRTY="$WORK/dirty"
mkdir -p "$DIRTY"
cat >"$DIRTY/index.html" <<'HTML'
<!DOCTYPE html>
<html>
<head>
<title>home</title>
<meta property="og:image" content="/og.png">
<link rel="canonical alternate" href="/">
</head>
<body><p>hello</p></body>
</html>
HTML

run_doctor dirty "$DIRTY"
[[ "$(cat "$WORK/dirty.rc")" -eq 1 ]] || {
  echo "--- doctor output ---"; sed -n '1,20p' "$WORK/dirty.log"
  fail "a root-relative og:image/canonical must exit non-zero (err severity)"
}

[[ "$(grep -c '^error abs-url-meta:' "$WORK/dirty.log")" -eq 2 ]] || {
  echo "--- doctor output ---"; sed -n '1,20p' "$WORK/dirty.log"
  fail "expected exactly two 'error abs-url-meta:' lines (one per finding)"
}

grep -q "error abs-url-meta:.*og:image is root-relative ('/og.png')" "$WORK/dirty.log" || {
  echo "--- doctor output ---"; sed -n '1,20p' "$WORK/dirty.log"
  fail "missing the og:image finding, or it doesn't name the key + offending value"
}

# rel="canonical alternate" (multi-valued, `canonical` is not the only token)
# must still fire -- pins the rel= tokenisation, not a substring match.
grep -q "error abs-url-meta:.*rel=canonical is root-relative ('/')" "$WORK/dirty.log" || {
  echo "--- doctor output ---"; sed -n '1,20p' "$WORK/dirty.log"
  fail "missing the canonical finding, or rel= tokenisation regressed (rel=\"canonical alternate\" must still match)"
}

echo "PASS (2): a root-relative og:image and a multi-valued rel=canonical both fire as errors, naming the key and value"

echo "PASS: abs-url-meta fires only on genuinely URL-valued, root-relative social/canonical metadata"
