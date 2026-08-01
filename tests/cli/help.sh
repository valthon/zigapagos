#!/usr/bin/env bash
# Regression test: the BARE `zigapagos` invocation (issue #56).
#
# `zigapagos` is a standalone executable, so running it with no arguments has
# to behave like every other standalone tool: print the help menu and succeed.
# It used to start the bundled live server instead, which meant `npx zigapagos`
# — the first thing anyone types after installing — either bound a port or died
# on a missing config, and in a directory without a `zigapagos.ziggy` the
# failure named a config file the user had never heard of.
#
# Three properties, each of which has its own failure mode:
#
#   1. bare run prints the help menu and exits 0. Exit 0 matters on its own: a
#      shell that runs `zigapagos || exit 1` as a smoke check must not see a
#      failure from the successful case.
#   2. `zigapagos serve` is an UNKNOWN command with a non-zero exit. The
#      subcommand went with the server it started; it must not linger as an
#      alias that half-works.
#   3. an unknown command exits NON-zero even though it prints the same menu.
#      Sharing the menu but not the exit status is the whole point — a typo'd
#      command in a script has to fail.
#
# This runs against the built binary and needs nothing else: no bun, no
# zigbase, no site directory. It deliberately runs from a temp dir with no
# `zigapagos.ziggy`, because the pre-fix failure was config-dependent and a
# test run from the repo root would not have seen it.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

fail() { echo "FAIL: $*"; exit 1; }

# (1) Bare run: help on stdout/stderr, exit 0.
set +e
BARE_OUT="$("$ZIGAPAGOS" 2>&1)"
BARE_RC=$?
set -e
[[ $BARE_RC -eq 0 ]] || fail "bare 'zigapagos' exited $BARE_RC, expected 0"
grep -q 'Usage: zigapagos' <<<"$BARE_OUT" \
  || fail "bare 'zigapagos' did not print the usage line; got: $BARE_OUT"
grep -q '^  dev  ' <<<"$BARE_OUT" \
  || fail "bare 'zigapagos' help menu is missing the 'dev' command"
grep -q '^  release  ' <<<"$BARE_OUT" \
  || fail "bare 'zigapagos' help menu is missing the 'release' command"

# The help menu must not advertise a bare-command action any more, and must not
# carry a deprecation note about the removed server: the removal is recorded in
# the CHANGELOG, not in the text every user sees.
grep -q '(no command)' <<<"$BARE_OUT" \
  && fail "help menu still documents a '(no command)' action"
grep -qi 'deprecated' <<<"$BARE_OUT" \
  && fail "help menu still carries deprecation language"

# (2) `serve` is gone, not aliased.
set +e
SERVE_OUT="$("$ZIGAPAGOS" serve 2>&1)"
SERVE_RC=$?
set -e
[[ $SERVE_RC -ne 0 ]] || fail "'zigapagos serve' exited 0; the subcommand should be unknown"
grep -q "unknown command 'serve'" <<<"$SERVE_OUT" \
  || fail "'zigapagos serve' did not report an unknown command; got: $SERVE_OUT"
# Same for the `server` spelling that went with it.
set +e
"$ZIGAPAGOS" server >/dev/null 2>&1
SERVER_RC=$?
set -e
[[ $SERVER_RC -ne 0 ]] || fail "'zigapagos server' exited 0; the subcommand should be unknown"

# (3) An unknown command prints the menu but FAILS.
set +e
BOGUS_OUT="$("$ZIGAPAGOS" definitely-not-a-command 2>&1)"
BOGUS_RC=$?
set -e
[[ $BOGUS_RC -ne 0 ]] || fail "an unknown command exited 0"
grep -q 'Usage: zigapagos' <<<"$BOGUS_OUT" \
  || fail "an unknown command did not print the help menu"

# (4) The conventional flags survive alongside the words (decision: -h/--help
# and -v/--version are universal CLI expectations, not redundant aliases).
for flag in -h --help help; do
  set +e
  "$ZIGAPAGOS" "$flag" >/dev/null 2>&1
  RC=$?
  set -e
  [[ $RC -eq 0 ]] || fail "'zigapagos $flag' exited $RC, expected 0"
done
for flag in -v --version version; do
  set +e
  V_OUT="$("$ZIGAPAGOS" "$flag" 2>&1)"
  RC=$?
  set -e
  [[ $RC -eq 0 ]] || fail "'zigapagos $flag' exited $RC, expected 0"
  [[ -n "$V_OUT" ]] || fail "'zigapagos $flag' printed nothing"
done

echo "PASS: tests/cli/help.sh"
