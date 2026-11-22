#!/usr/bin/env bash
# Assert that <expected> matches build.zig.zon's `.version` — the single source
# of truth for the released version number.
#
#   scripts/assert-version.sh <expected-version>   compare; exit non-zero on mismatch
#   scripts/assert-version.sh --print              print build.zig.zon's version
#
# This is release.yml's tag-versus-manifest guard. Run it before building any
# release artifacts: the spawn-free configure phase does not inspect tags.
# --print also lets scripts query the manifest version without a Zig toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

# `.version = "x.y.z"` in build.zig.zon. Taking the first match guards against a future
# dependency block growing its own `.version` field: the package's own version
# is declared before `.dependencies`, so the first match is the right one.
zon_version() {
  local v
  # Stop at the first match without an early-closing pipeline: many dependency
  # versions could otherwise SIGPIPE grep and fail the script under pipefail.
  v="$(awk 'match($0, /\.version = "[^"]+"/) {
    v = substr($0, RSTART, RLENGTH)
    sub(/^[^"]*"/, "", v)
    sub(/"$/, "", v)
    print v
    exit
  }' build.zig.zon)"
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
