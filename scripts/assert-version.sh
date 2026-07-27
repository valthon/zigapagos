#!/usr/bin/env bash
# Assert that <expected> matches build.zig.zon's `.version` — the single source
# of truth for the released version number.
#
#   scripts/assert-version.sh <expected-version>   compare; exit non-zero on mismatch
#   scripts/assert-version.sh --print              print build.zig.zon's version
#
# Why this exists as a script rather than a workflow inline: build/release.zig
# already refuses to build when the git tag disagrees with the zon version, but
# it only says so after `zig build release` has configured — on the release
# workflow that is *after* the toolchain install and dependency fetch, and on a
# per-target matrix it is after N runners have each paid for that. Running the
# same comparison as two seconds of bash at the top of every release job fails
# fast with both values side by side. Extracting it also makes it testable
# (tests/release/scripts.sh) and callable from more than one job without the
# copy drifting.
#
# The `--print` mode exists for the release workflow's PR smoke run, which has
# no tag and must synthesise the zon-matching one locally. Keeping the .zon
# parse in exactly one place is the point.
set -euo pipefail
cd "$(dirname "$0")/.."

# `.version = "x.y.z"` in build.zig.zon. `head -1` guards against a future
# dependency block growing its own `.version` field: the package's own version
# is declared before `.dependencies`, so the first match is the right one.
zon_version() {
  local v
  v="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | cut -d'"' -f2)"
  if [ -z "$v" ]; then
    echo "::error::could not parse .version from build.zig.zon" >&2
    exit 1
  fi
  printf '%s\n' "$v"
}

case "${1-}" in
  --print)
    zon_version
    ;;
  "")
    echo "usage: scripts/assert-version.sh <expected-version> | --print" >&2
    exit 1
    ;;
  *)
    # A leading "v" is accepted so callers may pass a raw tag name.
    expected="${1#v}"
    actual="$(zon_version)"
    echo "expected=$expected build.zig.zon=$actual"
    if [ "$expected" != "$actual" ]; then
      echo "::error::version mismatch: tag implies $expected but build.zig.zon has $actual — bump the zon version in the commit you tag" >&2
      exit 1
    fi
    ;;
esac
