#!/usr/bin/env bash
# Regression test: a failing SPA prerender must NOT have already rewritten the
# page-HTML tree.
#
# The defect this pins: `prerenderAll` used to run AFTER the page-render pass, and
# its failures are converted to a fatal exit. So an SPA failure fataled with the
# whole output tree already rewritten -- new page HTML sitting beside the previous
# build's SPA shells, routing manifests and build assets, with nothing on disk
# marking the tree as half-updated. `zigapagos dev` then printed "rebuild
# FAILED ...; still serving the previous build", which was false: it was serving a
# mix. Measured on the parent commit, a failed build rewrote all 16 pages of this
# fixture before aborting; it now rewrites none.
#
# Trigger: declare an SPA with no island sidecar configured. `prerenderAll` returns
# error.SpaNeedsSidecar at its very top -- before route enumeration and before any
# file is written -- which is exactly the class of failure the reorder is meant to
# make harmless. It also needs no bun, so this test is hermetic.
#
# Phase (3) is the assertion that matters, and phase (4) is what keeps it honest:
# without a control proving the snapshot method can DETECT a rewrite, phase (3)
# would also pass if the build simply never wrote pages at all.
#
# NOT claimed: that the output tree is atomic. It isn't. A failure partway through
# WRITING shells still leaves partial output, and a page-render failure still fails
# after pages are emitted. What is pinned here is narrower and real: an SPA
# failure that occurs before that pass writes anything leaves the previous build's
# pages exactly as they were.
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
mkdir -p "$SITE"
cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"

# `path<TAB>mtime<TAB>sha` per emitted page. mtime alone would miss a rewrite with
# identical content on a coarse clock; the hash alone would miss a rewrite that
# produced the same bytes. Together they detect "this file was written again".
snapshot() {
  find "$OUT" -name '*.html' -printf '%p\t%T@\n' | sort | while IFS=$'\t' read -r p m; do
    printf '%s\t%s\t%s\n' "$p" "$m" "$(sha256sum "$p" | cut -d' ' -f1)"
  done
}

build()      { ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force "$@" ) ; }

# --- (1) a clean full build ---------------------------------------------------
build >"$WORK/1.log" 2>&1 || { sed -n '1,20p' "$WORK/1.log"; fail "the baseline build failed -- fixture broken, test proves nothing"; }
snapshot >"$WORK/before.txt"
NPAGES="$(wc -l < "$WORK/before.txt")"
[[ "$NPAGES" -ge 5 ]] || fail "expected a multi-page fixture (got $NPAGES)"
echo "baseline build emitted $NPAGES pages"

sleep 1.1  # coarse-mtime filesystems: make any fresh mtime observable

# --- (2) a build whose SPA prerender fails ------------------------------------
set +e
build "--spa=app/app.spa.tsx|/app" >"$WORK/2.log" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { sed -n '1,20p' "$WORK/2.log"; fail "declaring an SPA with no sidecar built successfully -- the trigger no longer fails"; }
grep -q 'SPA prerender failed' "$WORK/2.log" \
  || { echo "--- output ---"; sed -n '1,20p' "$WORK/2.log"
       fail "the build failed, but not in the SPA prerender pass (different error -- test is measuring the wrong thing)"; }
echo "SPA prerender failed as intended (exit $RC)"

# --- (3) THE ASSERTION: the failed build left the pages alone -----------------
snapshot >"$WORK/after.txt"
if ! /usr/bin/diff -q "$WORK/before.txt" "$WORK/after.txt" >/dev/null; then
  echo "--- pages the failed build rewrote ---"
  /usr/bin/diff "$WORK/before.txt" "$WORK/after.txt" | sed -n '1,12p'
  N="$(/usr/bin/diff "$WORK/before.txt" "$WORK/after.txt" | grep -c '^>' || true)"
  fail "a FAILED build rewrote $N page(s) before aborting -- the SPA prerender pass has moved back after the page-render pass"
fi
echo "the failed build rewrote 0 of $NPAGES pages"

# --- (4) control: the snapshot method CAN detect a rewrite --------------------
# Without this, phase (3) would pass vacuously if release stopped writing pages.
sleep 1.1
build >"$WORK/4.log" 2>&1 || { sed -n '1,20p' "$WORK/4.log"; fail "the control rebuild failed"; }
snapshot >"$WORK/control.txt"
/usr/bin/diff -q "$WORK/before.txt" "$WORK/control.txt" >/dev/null \
  && fail "a SUCCESSFUL rebuild changed nothing either -- the snapshot cannot detect a rewrite, so phase (3) proved nothing"
echo "control: a successful rebuild does rewrite pages (so phase 3 is a real check)"

echo "PASS: a failing SPA prerender aborts before the page-render pass rewrites anything"
