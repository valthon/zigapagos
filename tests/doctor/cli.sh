#!/usr/bin/env bash
# Regression test: `zigapagos doctor`'s CLI surface -- the argument-parsing
# and gate-of-last-resort behaviour that isn't specific to either check.
#
# Two of these pin the "a gate that audits nothing must not report success"
# rule: an unopenable DIR and a DIR with zero .html files both exit non-zero
# with an actionable message, rather than silently reporting a clean run.
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

run() { # $1 = tag, remaining = doctor args
  local tag="$1"; shift
  set +e
  "$ZIGAPAGOS" doctor "$@" >"$WORK/$tag.log" 2>&1
  echo $? >"$WORK/$tag.rc"
  set -e
}

# --- (1) missing DIR --------------------------------------------------------
run missing "$WORK/does-not-exist"
[[ "$(cat "$WORK/missing.rc")" -eq 1 ]] || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/missing.log"
  fail "a missing DIR must exit non-zero"
}
grep -q "cannot open site tree" "$WORK/missing.log" || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/missing.log"
  fail "missing the 'cannot open site tree' diagnostic"
}
grep -q "run 'zigapagos release" "$WORK/missing.log" || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/missing.log"
  fail "missing the 'run zigapagos release ... first' hint (doctor audits a BUILT tree, not source)"
}
echo "PASS (1): a missing DIR fails with an actionable 'build it first' hint"

# --- (2) a tree with no .html files ----------------------------------------
NO_HTML="$WORK/no-html"
mkdir -p "$NO_HTML"
printf 'not html\n' >"$NO_HTML/readme.txt"
run empty "$NO_HTML"
[[ "$(cat "$WORK/empty.rc")" -eq 1 ]] || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/empty.log"
  fail "a tree with zero .html files must exit non-zero -- a gate that audits nothing must not report success"
}
grep -q "no .html files under" "$WORK/empty.log" || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/empty.log"
  fail "missing the 'no .html files under' diagnostic"
}
echo "PASS (2): a tree with zero .html files fails, naming the reason"

# --- (3) --help / --h and the top-level help menu listing doctor ----------
run help --help
[[ "$(cat "$WORK/help.rc")" -eq 0 ]] || {
  echo "--- output ---"; sed -n '1,20p' "$WORK/help.log"
  fail "--help must exit 0"
}
grep -q "Usage: zigapagos doctor" "$WORK/help.log" || {
  echo "--- output ---"; sed -n '1,20p' "$WORK/help.log"
  fail "--help did not print the doctor usage"
}

set +e
"$ZIGAPAGOS" help >"$WORK/top-help.log" 2>&1
TOP_HELP_RC=$?
set -e
[[ "$TOP_HELP_RC" -eq 0 ]] || {
  echo "--- output ---"; sed -n '1,40p' "$WORK/top-help.log"
  fail "'zigapagos help' must exit 0"
}
grep -q '  doctor \[DIR\]' "$WORK/top-help.log" || {
  echo "--- output ---"; sed -n '1,40p' "$WORK/top-help.log"
  fail "'zigapagos help' does not list the doctor command"
}
echo "PASS (3): 'doctor --help' prints its usage, and the top-level help menu lists doctor"

# --- (4) an unknown flag ----------------------------------------------------
run badflag "$WORK/does-not-matter" --bogus-flag
[[ "$(cat "$WORK/badflag.rc")" -eq 1 ]] || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/badflag.log"
  fail "an unknown flag must exit non-zero"
}
grep -q "unknown flag '--bogus-flag'" "$WORK/badflag.log" || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/badflag.log"
  fail "the unknown-flag diagnostic does not name the offending flag"
}
echo "PASS (4): an unknown flag fails, naming the flag"

# --- (5) two positional arguments -------------------------------------------
run twoargs dirA dirB
[[ "$(cat "$WORK/twoargs.rc")" -eq 1 ]] || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/twoargs.log"
  fail "two positional DIRs must exit non-zero"
}
grep -q "unexpected extra argument 'dirB'" "$WORK/twoargs.log" || {
  echo "--- output ---"; sed -n '1,10p' "$WORK/twoargs.log"
  fail "the extra-argument diagnostic does not name the offending argument"
}
echo "PASS (5): a second positional argument fails, naming it"

echo "PASS: doctor's CLI surface -- missing DIR, empty tree, --help, unknown flag, extra positional -- all behave as documented"
