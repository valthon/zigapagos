#!/usr/bin/env bash
# install.sh must parse and run under a plain POSIX shell.
#
# It is delivered by `curl … | sh`, so the shell that runs it is whatever /bin/sh
# is on the user's machine: dash on Debian and Ubuntu, ash on Alpine, bash in
# POSIX mode on Fedora, zsh's sh emulation on some macOS setups. A bashism costs
# nothing on the machine of whoever wrote it — bash parses it fine — and produces
# a syntax error partway through someone else's install, after files have already
# been written.
#
# So the parse is checked under every POSIX shell the runner happens to have, not
# just the one running this test. bash is deliberately NOT one of them: it would
# accept exactly the constructs this is looking for.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail() { echo "FAIL: $*"; exit 1; }

INSTALL=install.sh
[ -f "$INSTALL" ] || fail "install.sh is missing from the repository root"

# The shebang matters as much as the contents: `#!/usr/bin/env bash` here would
# make a script advertised as `| sh` work only when executed as a file.
head -1 "$INSTALL" | grep -qx '#!/bin/sh' \
  || fail "install.sh's shebang is not '#!/bin/sh'"
[ -x "$INSTALL" ] || fail "install.sh is not executable"

checked=0
for shell in sh dash ash "busybox sh"; do
  # shellcheck disable=SC2086 # "busybox sh" is deliberately two words
  set -- $shell
  command -v "$1" >/dev/null 2>&1 || continue
  "$@" -n "$INSTALL" || fail "install.sh does not parse under '$shell'"
  echo "PASS parses under $shell"
  checked=$((checked + 1))
done
# Anti-vacuity: a loop that found no shell would print nothing and exit 0, which
# reads exactly like a pass.
[ "$checked" -gt 0 ] || fail "no POSIX shell was found to check install.sh with"

# `command -v shellcheck` is not enough to know shellcheck is usable: mise puts a
# SHIM on PATH for every tool it knows about, so the name resolves on a machine
# that has no shellcheck installed and the shim then fails with "No version is set
# for shim". Probing with --version distinguishes "present" from "resolvable".
if shellcheck --version >/dev/null 2>&1; then
  shellcheck -s sh "$INSTALL" || fail "shellcheck found problems in install.sh"
  echo "PASS shellcheck -s sh"
else
  # Not a failure: shellcheck is not in mise.toml, and the parse checks above are
  # the load-bearing half. Said out loud so a green run is not mistaken for a
  # linted one.
  #
  # (A comment whose first word is the tool's own name is read as a DIRECTIVE and
  # fails to parse as one. That is why this sentence is phrased around it.)
  echo "note: shellcheck not installed — skipped the lint, ran the parse checks only"
fi

# `local` is the one non-POSIX construct every candidate shell happens to accept,
# so no parse check would ever catch it. Called out by name because it is the
# bashism most likely to be reached for while editing this file.
if grep -nE '^[[:space:]]*local[[:space:]]' "$INSTALL"; then
  fail "install.sh uses 'local', which is not POSIX (every shell above accepts it, so no parse check catches it)"
fi
echo "PASS no 'local' declarations"

# `[[` and arrays are caught by the parse checks above, but only if a candidate
# shell was actually found. This is the belt to that braces.
if grep -nE '\[\[|\$\{[A-Za-z_]+\[' "$INSTALL"; then
  fail "install.sh uses bash test brackets or arrays"
fi
echo "PASS no bash-only test brackets or arrays"

echo "PASS tests/install/syntax.sh"
