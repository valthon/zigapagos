#!/usr/bin/env bash
# Confidentiality gate: no reference to the author's separate private project
# may appear anywhere in this repository.
#
# This file deliberately contains NO literal instance of any name it searches
# for. Each pattern is assembled from fragments that the shell concatenates at
# runtime — two adjacent single-quoted strings join into one word — so the
# assembled needle never exists as a contiguous string on disk. Do not "tidy"
# the quoting in the pattern constants below, and do not write an assembled
# example in a comment: either turns this file into a hit for its own grep.
# That is what lets this script be searched by its
# own patterns like every other file: there is no ':!tests/confidentiality.sh'
# exclusion, and there must never be one again. An earlier version both spelled
# the names out in its comments AND excluded itself from its own grep, so the
# gate reported a clean tree while being the single largest leak in it.
#
# If you extend the pattern set, keep the fragmentation. A pattern written as a
# plain literal turns this gate into the thing it exists to catch.
set -euo pipefail
cd "$(dirname "$0")/.."

# Word-initial match only: the trailing class rejects ordinary English words
# that merely begin with the same five letters (integer, integration, integrity,
# integrate), which is why this cannot be a plain substring search.
NAME='\bin''teg([^a-zA-Z]|$)'

# Both spellings of a helper package's name.
PKG='shared[-_]l''ite'

# camelCase identifiers built on the project's initialism (cookie and JWT claim
# names). Case-sensitive and anchored on a following capital, so the POSIX
# constant S_IFLNK in the vendored translate-c headers is not a match.
IDENT='\bi''fl[A-Z]'

# A coined internal service name.
SVC='sync-o-m''atic'

# The approved generic replacement scope legitimately contains the package
# spelling above, so a PKG hit is exempt on a line that also carries that scope.
# Every other pattern is checked UNCONDITIONALLY, so a real reference sharing a
# line with the approved token is still caught.
GENERIC='your-org'

name_hits=$(git grep -i -nE "$NAME" || true)
ident_hits=$(git grep -nE "$IDENT" || true)
svc_hits=$(git grep -i -nE "$SVC" || true)
pkg_hits=$(git grep -i -nE "$PKG" | grep -vi "$GENERIC" || true)

matches=$(printf '%s\n%s\n%s\n%s\n' \
  "$name_hits" "$ident_hits" "$svc_hits" "$pkg_hits" | sed '/^$/d' | sort -u)

if [ -n "$matches" ]; then
  echo "FAIL: private references remain:"
  echo "$matches"
  exit 1
fi
echo "PASS: no private references"
