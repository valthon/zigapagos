#!/usr/bin/env bash
# Regression test for issue #46 / DX-27: `zigapagos explain-code [CODE]`.
#
# Pre-fix behaviour (verified before implementing, per the plan): the command
# was not a member of main.zig's `Command` enum, so `args[1]` fell through to
# `cli/serve.zig`'s deprecated-live-server argument parser, which printed
# "error: unexpected cli argument 'explain-code'" and called
# `fatal.helpError()` -- exit 1, no hang. That means every exit-0 assertion
# below fails cleanly pre-fix rather than hanging the test.
#
# The command is `explain-code`, not `explain`: issue #47 shipped `zigapagos
# explain <route>` (route introspection) in the same release cycle. The final
# phase below pins the signpost that keeps the collision navigable -- passing
# a diagnostic code to the ROUTE command must name this one rather than
# complaining that a code does not start with '/'.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

fail() { echo "FAIL: $*"; exit 1; }

# Every command whose exit code is asserted below is captured with errexit
# OFF. With `set -e` on, a non-zero exit aborts the script BEFORE the `RC`
# assertion, so the `fail` message naming what went wrong would never print
# and the failure would read as a bare non-zero exit with no explanation.

echo "=== explain-code ZP_LINK_NOT_A_SECTION ==="
set +e
OUT="$("$ZIGAPAGOS" explain-code ZP_LINK_NOT_A_SECTION 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || fail "explain-code ZP_LINK_NOT_A_SECTION exited $RC, want 0"
echo "$OUT" | grep -q '\$link\.page' || { echo "$OUT"; fail "explanation missing \$link.page"; }
echo "$OUT" | grep -q 'subpage of this section' || { echo "$OUT"; fail "explanation missing 'subpage of this section'"; }
echo "ok"

echo "=== explain-code ZP_NOT_A_REAL_CODE (unknown code) ==="
set +e
OUT="$("$ZIGAPAGOS" explain-code ZP_NOT_A_REAL_CODE 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 1 ]] || { echo "$OUT"; fail "explain-code of an unknown code exited $RC, want 1"; }
echo "$OUT" | grep -q 'unknown diagnostic code' || { echo "$OUT"; fail "missing 'unknown diagnostic code'"; }
echo "ok"

echo "=== explain-code (no args) lists every code ==="
set +e
OUT="$("$ZIGAPAGOS" explain-code 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || fail "explain-code with no args exited $RC, want 0"
echo "$OUT" | grep -q '^ZP_FATAL' || { echo "$OUT"; fail "listing missing ZP_FATAL"; }
echo "$OUT" | grep -q '^ZP_LINK_NOT_A_SECTION' || { echo "$OUT"; fail "listing missing ZP_LINK_NOT_A_SECTION"; }
N_LISTED="$(echo "$OUT" | grep -c '^ZP_' || true)"
[[ "$N_LISTED" -ge 25 ]] || { echo "$OUT"; fail "only $N_LISTED lines start with ZP_, want at least 25"; }
echo "ok ($N_LISTED codes listed)"

echo "=== explain-code --help ==="
set +e
OUT="$("$ZIGAPAGOS" explain-code --help 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 0 ]] || fail "explain-code --help exited $RC, want 0"
echo "ok"

echo "=== cross-check: listing count matches the frozen [ACTIVE] registry ==="
FROZEN="$REPO/src/diag-codes.frozen"
[[ -f "$FROZEN" ]] || fail "src/diag-codes.frozen not found"
# Count ACTIVE lines: everything between "[ACTIVE]" and the next "[" header,
# excluding comments/blanks. Mirrors src/diag.zig's own frozenLines() parser.
N_FROZEN="$(awk '/^\[ACTIVE\]$/{f=1;next} /^\[/{f=0} f && $0!="" && substr($0,1,1)!="#"' "$FROZEN" | wc -l | tr -d ' ')"
[[ "$N_FROZEN" -gt 0 ]] || fail "parsed 0 lines from [ACTIVE] in $FROZEN -- the awk parser or the file format changed"
[[ "$N_LISTED" -eq "$N_FROZEN" ]] || fail "explain-code listed $N_LISTED codes but [ACTIVE] has $N_FROZEN -- a code was added to the enum+frozen file but not reaching the listing path (or vice versa)"
echo "ok ($N_FROZEN active codes, listing agrees)"

echo "=== 'zigapagos explain <CODE>' points at explain-code (issue #46/#47 collision) ==="
# `explain` belongs to issue #47's ROUTE introspection. Its route guard rejects
# anything not starting with '/', so a user who typed the code at the wrong
# command would otherwise get "route must start with '/'" and no way forward.
set +e
OUT="$("$ZIGAPAGOS" explain ZP_LINK_NOT_A_SECTION 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 1 ]] || { echo "$OUT"; fail "explain <CODE> exited $RC, want 1"; }
echo "$OUT" | grep -q 'is a diagnostic code, not a route' || { echo "$OUT"; fail "explain <CODE> did not name the collision"; }
echo "$OUT" | grep -q "zigapagos explain-code ZP_LINK_NOT_A_SECTION" || { echo "$OUT"; fail "explain <CODE> did not point at 'zigapagos explain-code <CODE>'"; }
echo "ok"

echo "PASS: tests/diagnostics/explain-code.sh"
