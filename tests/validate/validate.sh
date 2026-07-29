#!/usr/bin/env bash
# Regression test: `zigapagos validate` (issue #45) -- a fast, in-memory,
# no-Bun subset of `zigapagos release`'s checks.
#
# (H1) IMPORTANT CONTEXT for every case below: on unpatched `main`, `validate`
# is not a recognized subcommand at all. `zigapagos validate ...` falls
# through to the top-level `serve` argument parser, which rejects "validate"
# as an unexpected cli argument and exits 1 with the full help menu. That
# means EVERY plain "bad input -> exit 1" assertion below is, by itself,
# VACUOUS -- it would pass identically on unpatched main. Verified by hand
# against the pre-change binary (git stash the src/ changes, rebuild):
#
#   $ zigapagos validate
#   error: unexpected cli argument 'validate'
#   Usage: zigapagos [COMMAND] [OPTIONS]
#   ...
#   $ echo $?
#   1
#
# So every expect-failure case here ALSO asserts the SPECIFIC diagnostic text
# and asserts stderr does NOT contain "unexpected cli argument". Every
# expect-SUCCESS (exit 0) case is inherently discriminating (today validate
# always exits 1), and V5 additionally asserts on the ABSENCE of a specific
# log line (H2) -- proven to fail without the fix by temporarily flipping
# `island_sidecar_optional` to `false` in validate.zig; see the PR body for
# that captured failure output.
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

# Every case runs with a minimal PATH (no bun) to prove the no-toolchain claim.
# stdout and stderr are captured SEPARATELY, then concatenated in a
# deterministic (script-controlled) order into `.log`: `zigapagos`'s Debug-
# build banner (stderr, unbuffered `std.debug.print`) and validate's own
# buffered-stdout "validate: OK" summary otherwise race for the same file
# position when both are redirected with a bare `2>&1` -- reproduced
# identically with `zigapagos doctor`, so it predates this PR, but grep
# assertions against a corrupted merge would be flaky. See tests/explain/
# explain.sh's `run()` for the fuller explanation.
run() { # $1 = tag, $2 = site dir, remaining = validate args
  local tag="$1" dir="$2"; shift 2
  set +e
  (cd "$dir" && env PATH=/usr/bin:/bin "$ZIGAPAGOS" validate "$@") >"$WORK/$tag.out" 2>"$WORK/$tag.err"
  echo $? >"$WORK/$tag.rc"
  set -e
  cat "$WORK/$tag.out" "$WORK/$tag.err" >"$WORK/$tag.log"
}

assert_no_cli_error() { # $1 = tag -- (H1)
  grep -q "unexpected cli argument" "$WORK/$1.log" && {
    echo "--- output ---"; cat "$WORK/$1.log"
    fail "($1) validate must be a recognized subcommand, not fall through to the top-level parser (H1)"
  }
  return 0
}

# ============================================================================
# V1 -- clean site, no islands: exit 0, "validate: OK" on stdout, public/
# is never created (H3: Build.load() DOES createDirPathOpen on layouts/
# assets unconditionally, so the assertion must be specifically about the
# OUTPUT dir, not "nothing touched the filesystem").
# ============================================================================
V1="$WORK/v1"
mkdir -p "$V1/content" "$V1/layouts"
cat >"$V1/zigapagos.ziggy" <<'EOF'
Site {
    .title = "V1",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
cat >"$V1/layouts/index.shtml" <<'EOF'
<!DOCTYPE html><html><body :html="$page.content()"></body></html>
EOF
cat >"$V1/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "index.shtml",
---
Home page.
EOF
mkdir -p "$V1/content/about"
cat >"$V1/content/about/index.smd" <<'EOF'
---
.title = "About",
.layout = "index.shtml",
---
About page, linking to [home]($link.site()).
EOF
mkdir -p "$V1/content/contact"
cat >"$V1/content/contact/index.smd" <<'EOF'
---
.title = "Contact",
.layout = "index.shtml",
---
Contact page.
EOF

run v1 "$V1"
[[ "$(cat "$WORK/v1.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/v1.log"
  fail "(V1) a clean 3-page site must validate with exit 0"
}
grep -q "validate: OK" "$WORK/v1.log" || {
  echo "--- output ---"; cat "$WORK/v1.log"
  fail "(V1) missing 'validate: OK' summary"
}
[[ -d "$V1/public" ]] && fail "(V1) validate must never create the output directory (H3)"
echo "PASS (V1): clean site -> exit 0, 'validate: OK', no public/ created"

# ============================================================================
# V2 -- a dangling \$link.page reference: exit 1, stderr names 'unknown page'.
# ============================================================================
V2="$WORK/v2"
mkdir -p "$V2/content" "$V2/layouts"
cp "$V1/zigapagos.ziggy" "$V2/zigapagos.ziggy"
cp "$V1/layouts/index.shtml" "$V2/layouts/index.shtml"
cat >"$V2/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "index.shtml",
---
Dangling link: [nope]($link.page('nope')).
EOF

run v2 "$V2"
assert_no_cli_error v2
[[ "$(cat "$WORK/v2.rc")" -eq 1 ]] || {
  echo "--- output ---"; cat "$WORK/v2.log"
  fail "(V2) a dangling \$link.page reference must fail validate"
}
grep -q "unknown page" "$WORK/v2.log" || {
  echo "--- output ---"; cat "$WORK/v2.log"
  fail "(V2) missing the 'unknown page' diagnostic"
}
echo "PASS (V2): dangling \$link.page -> exit 1, 'unknown page' diagnostic"

# ============================================================================
# V3 -- V2's fixture + --allow-missing-pages: exit 0.
# ============================================================================
run v3 "$V2" --allow-missing-pages
[[ "$(cat "$WORK/v3.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/v3.log"
  fail "(V3) --allow-missing-pages must tolerate V2's dangling link"
}
echo "PASS (V3): --allow-missing-pages tolerates the dangling link -> exit 0"

# ============================================================================
# V4 -- a LAYOUT (template) referencing \$site.page('nope'): exit 1, stderr
# has 'SCRIPT RESULT TYPE MISMATCH' and 'missing page'. This pins the
# "full memory build, do not stop at the pre-render gate" design decision: a
# render-time template failure is only caught because validate runs root.run
# to completion rather than returning right after the aggregate
# any_prerendering_error gate. If that design ever regresses (an early
# return added after the gate), this case goes red.
# ============================================================================
V4="$WORK/v4"
mkdir -p "$V4/content" "$V4/layouts"
cp "$V1/zigapagos.ziggy" "$V4/zigapagos.ziggy"
cat >"$V4/layouts/index.shtml" <<'EOF'
<!DOCTYPE html><html><body>
<a href="$site.page('nope').link()">nope</a>
<div :html="$page.content()"></div>
</body></html>
EOF
cat >"$V4/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "index.shtml",
---
Home page.
EOF

run v4 "$V4"
assert_no_cli_error v4
[[ "$(cat "$WORK/v4.rc")" -eq 1 ]] || {
  echo "--- output ---"; cat "$WORK/v4.log"
  fail "(V4) a template-side \$site.page('nope') render failure must fail validate"
}
grep -q "SCRIPT RESULT TYPE MISMATCH" "$WORK/v4.log" || {
  echo "--- output ---"; cat "$WORK/v4.log"
  fail "(V4) missing 'SCRIPT RESULT TYPE MISMATCH' -- validate must run the FULL memory build (render pass included), not stop at the pre-render gate"
}
grep -q "missing page 'nope'" "$WORK/v4.log" || {
  echo "--- output ---"; cat "$WORK/v4.log"
  fail "(V4) missing \"missing page 'nope'\""
}
echo "PASS (V4): template \$site.page('nope') -> exit 1, full render-pass diagnostic (pins the full-memory-build design)"

# ============================================================================
# V5 -- a layout mounting a real <island>, no bun on PATH, no sidecar
# configured: exit 0 AND stderr does NOT contain the "no island sidecar is
# configured" line. The grep-absence is the ONLY discriminating half (H2):
# with or without the fix, this build exits 0 (a memory build with an
# unconfigured sidecar is not itself a build error). Proven to fail without
# the fix by temporarily setting `.island_sidecar_optional = false` in
# validate.zig and re-running -- see the PR body for the captured red output.
# ============================================================================
V5="$WORK/v5"
mkdir -p "$V5/content" "$V5/layouts"
cp "$V1/zigapagos.ziggy" "$V5/zigapagos.ziggy"
cat >"$V5/layouts/index.shtml" <<'EOF'
<!DOCTYPE html><html><body>
<island src="components/Widget.island.tsx" client:load></island>
<div :html="$page.content()"></div>
</body></html>
EOF
cat >"$V5/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "index.shtml",
---
Home page with an island.
EOF

run v5 "$V5"
[[ "$(cat "$WORK/v5.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/v5.log"
  fail "(V5) an island page with no configured sidecar must NOT fail validate"
}
grep -q "no island sidecar is configured" "$WORK/v5.log" && {
  echo "--- output ---"; cat "$WORK/v5.log"
  fail "(V5) validate must suppress the 'no island sidecar is configured' diagnostic (island_sidecar_optional, H2)"
}
echo "PASS (V5): island page, no sidecar -> exit 0, diagnostic suppressed"

# ============================================================================
# V6 -- a \$build.asset('logo') content reference: without --build-asset,
# exit 1 + 'missing build asset'; with --build-asset=logo <real file>,
# exit 0. Pins the release-parity reason --build-asset is threaded through
# at all (worker.zig's analysis-time build_assets.get(ba.ref) check).
# ============================================================================
V6="$WORK/v6"
mkdir -p "$V6/content" "$V6/layouts" "$V6/build-assets"
cp "$V1/zigapagos.ziggy" "$V6/zigapagos.ziggy"
cp "$V1/layouts/index.shtml" "$V6/layouts/index.shtml"
cat >"$V6/content/index.smd" <<'EOF'
---
.title = "Home",
.layout = "index.shtml",
---
[]($image.buildAsset('logo'))
EOF
printf '<svg></svg>' >"$V6/build-assets/logo.svg"

run v6-missing "$V6"
assert_no_cli_error v6-missing
[[ "$(cat "$WORK/v6-missing.rc")" -eq 1 ]] || {
  echo "--- output ---"; cat "$WORK/v6-missing.log"
  fail "(V6) a \$build.asset reference with no --build-asset declaration must fail"
}
grep -q "missing build asset" "$WORK/v6-missing.log" || {
  echo "--- output ---"; cat "$WORK/v6-missing.log"
  fail "(V6) missing the 'missing build asset' diagnostic"
}

run v6-declared "$V6" --build-asset=logo build-assets/logo.svg --install=logo.svg
[[ "$(cat "$WORK/v6-declared.rc")" -eq 0 ]] || {
  echo "--- output ---"; cat "$WORK/v6-declared.log"
  fail "(V6) --build-asset=logo <path> must resolve the \$build.asset reference"
}
echo "PASS (V6): --build-asset parity with release (missing -> exit 1, declared -> exit 0)"

# ============================================================================
# V7 -- an unrecognized flag: exit 1, names the bad flag, and the output
# contains NO 'panic' (H4: fatal.usageError, never fatal.msg -- the Debug
# binary these tests run panics with a stack trace on fatal.msg).
# ============================================================================
run v7 "$V1" --nonsense
[[ "$(cat "$WORK/v7.rc")" -eq 1 ]] || {
  echo "--- output ---"; cat "$WORK/v7.log"
  fail "(V7) an unrecognized flag must exit 1"
}
grep -q -- "--nonsense" "$WORK/v7.log" || {
  echo "--- output ---"; cat "$WORK/v7.log"
  fail "(V7) the diagnostic must name the offending flag"
}
grep -qi "panic" "$WORK/v7.log" && {
  echo "--- output ---"; cat "$WORK/v7.log"
  fail "(V7) argument validation must use fatal.usageError, not fatal.msg (H4: msg panics in Debug builds)"
}
echo "PASS (V7): bad flag -> exit 1, names it, no panic (fatal.usageError)"

echo "ALL PASS: tests/validate/validate.sh"
