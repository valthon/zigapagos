#!/usr/bin/env bash
# CI shim: the site assertion library parses, exports its documented API, and
# passes its own self-test.
#
# site/test/assert.test.sh needs no build, no bun and no network — it works
# entirely on fixtures it writes to $TMPDIR — but it lives outside ci.yml's
# `tests/*/*.sh` discovery glob, and ci.yml's `site` job runs the four site
# gates by name. A test nothing runs decays silently, which is exactly what
# tests/meta/script-coverage.sh exists to prevent; a shim here is the pattern
# that gate documents, and is cheaper than another named workflow step.
#
# This matters more than usual for this particular library. site/test/assert.sh
# is sourced by site/test/links.sh and is meant to be copied into consumer
# projects, so a matcher that silently stops matching turns every test built on
# it green rather than red.
set -euo pipefail
cd "$(dirname "$0")/../.."

# The library is sourced, never executed, so a syntax error in it would surface
# only at the first `.` — inside whichever gate happened to run first, reported
# against that gate. Ask directly.
bash -n site/test/assert.sh || { echo "FAIL: site/test/assert.sh does not parse"; exit 1; }

# The five function names are the library's published API (docs/testing.md).
# Renaming one is a breaking change for every consumer that copied it, and
# nothing else in the tree would notice.
missing=0
for fn in assert_route_emitted assert_element assert_no_script_src \
          assert_internal_links_resolve assert_island_ssr; do
  if ! ( . site/test/assert.sh; declare -F "$fn" >/dev/null ); then
    echo "FAIL: site/test/assert.sh does not define $fn (documented in docs/testing.md)"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

bash site/test/assert.test.sh
