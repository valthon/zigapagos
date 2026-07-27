#!/usr/bin/env bash
# Self-tests for the two release-workflow gate scripts:
#   scripts/assert-version.sh         tag <-> build.zig.zon version
#   scripts/extract-release-notes.sh  CHANGELOG.md section -> release body
#
# Both are exit-code gates that run exactly once per release — on a tag push,
# where a false PASS publishes a wrong release and a false FAIL is only noticed
# by whoever is tagging. They are never exercised by an ordinary CI run, so
# without these tests their failure paths would first be executed for real
# during a release. That is the same reasoning as
# scripts/check-allocator-contracts.test.sh.
#
# WHY IT LIVES HERE AND NOT IN scripts/: CI discovers `tests/*/*.sh` by glob, so
# a new tests/<area>/ directory is run the day it is added; scripts/*.test.sh is
# named explicitly in .github/workflows/ci.yml and would need that file edited
# too. Nothing here builds or spawns a server — it is pure bash over temporary
# fixtures and takes well under a second.
#
# Both scripts resolve their inputs relative to their OWN directory's parent
# (`cd "$(dirname "$0")/.."`), so a test fixture is just a temp directory with a
# scripts/ copy plus a fake build.zig.zon / CHANGELOG.md. That keeps the
# production scripts free of test-only override knobs.
set -euo pipefail
cd "$(dirname "$0")/../.."

repo="$PWD"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0

# Runs a command, captures combined output, and asserts on the exit status.
# `want` is "ok" (exit 0) or "fail" (any non-zero). Sets `out` for the caller.
out=""
expect() {
  local want="$1" name="$2"
  shift 2
  local rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$want" = ok ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $name — expected exit 0, got $rc"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
    return 0
  fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: $name — expected non-zero exit, got 0"
    printf '%s\n' "$out" | sed 's/^/    /'
    failures=$((failures + 1))
    return 0
  fi
  echo "ok: $name"
}

contains() {
  local name="$1" needle="$2"
  case "$out" in
    *"$needle"*) echo "ok: $name" ;;
    *)
      echo "FAIL: $name — output does not contain '$needle'"
      printf '%s\n' "$out" | sed 's/^/    /'
      failures=$((failures + 1))
      ;;
  esac
}

lacks() {
  local name="$1" needle="$2"
  case "$out" in
    *"$needle"*)
      echo "FAIL: $name — output unexpectedly contains '$needle'"
      printf '%s\n' "$out" | sed 's/^/    /'
      failures=$((failures + 1))
      ;;
    *) echo "ok: $name" ;;
  esac
}

# Builds a fixture "repo root" at $tmp/$1 holding copies of both scripts.
fixture() {
  local dir="$tmp/$1"
  mkdir -p "$dir/scripts"
  cp "$repo/scripts/assert-version.sh" "$repo/scripts/extract-release-notes.sh" "$dir/scripts/"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# assert-version.sh — against the real build.zig.zon
# ---------------------------------------------------------------------------

real_version="$(scripts/assert-version.sh --print)"

expect ok "assert-version: --print emits a version" scripts/assert-version.sh --print
contains "assert-version: --print emits ONLY the version" "$real_version"
if [ "$out" != "$real_version" ]; then
  echo "FAIL: assert-version --print printed extra output: '$out'"
  failures=$((failures + 1))
fi

expect ok "assert-version: matching version passes" scripts/assert-version.sh "$real_version"
contains "assert-version: reports both values side by side" "build.zig.zon=$real_version"

expect ok "assert-version: leading 'v' is stripped" scripts/assert-version.sh "v$real_version"

expect fail "assert-version: mismatched version fails" scripts/assert-version.sh 0.0.0-nope
contains "assert-version: mismatch names both versions" "0.0.0-nope"

expect fail "assert-version: no argument fails" scripts/assert-version.sh

# A prefix of the real version must NOT satisfy the check: this is an equality
# gate, and `0.1` passing for `0.1.0` would publish a mis-versioned release.
expect fail "assert-version: a prefix of the version is not a match" \
  scripts/assert-version.sh "${real_version%.*}"

# The .zon parse takes the FIRST `.version` field. A dependency block with its
# own `.version` (a plausible future edit) must not shadow the package's.
d="$(fixture zon-deps)"
cat >"$d/build.zig.zon" <<'ZON'
.{
    .name = .zigapagos,
    .version = "1.2.3",
    .dependencies = .{
        .example = .{
            .version = "9.9.9",
        },
    },
}
ZON
expect ok "assert-version: package .version wins over a dependency's" \
  "$d/scripts/assert-version.sh" 1.2.3
expect fail "assert-version: a dependency's .version is not accepted" \
  "$d/scripts/assert-version.sh" 9.9.9

# A .zon with no .version at all must fail loudly rather than compare "" == "".
d="$(fixture zon-missing)"
printf '.{ .name = .zigapagos }\n' >"$d/build.zig.zon"
expect fail "assert-version: missing .version fails" "$d/scripts/assert-version.sh" 1.2.3
contains "assert-version: missing .version says so" "could not parse .version"
expect fail "assert-version: --print with no .version fails" "$d/scripts/assert-version.sh" --print

# ---------------------------------------------------------------------------
# extract-release-notes.sh — against the real CHANGELOG.md
# ---------------------------------------------------------------------------

expect ok "extract: the released version is present" scripts/extract-release-notes.sh "$real_version"
real_notes="$out"
lacks "extract: the '## [x.y.z]' header line is dropped" "## ["
lacks "extract: the link-reference block is not swallowed" "]: https://github.com/valthon/zigapagos/compare"
if [ -z "$real_notes" ]; then
  echo "FAIL: extract produced an empty body for $real_version"
  failures=$((failures + 1))
fi

expect ok "extract: leading 'v' is stripped" scripts/extract-release-notes.sh "v$real_version"
if [ "$out" != "$real_notes" ]; then
  echo "FAIL: extract 'v$real_version' differs from '$real_version'"
  failures=$((failures + 1))
fi

expect fail "extract: an absent version fails" scripts/extract-release-notes.sh 9.9.9
contains "extract: names the missing section" "no '## [9.9.9]' section"

expect fail "extract: no argument fails" scripts/extract-release-notes.sh
expect ok "extract: --check validates without printing the body" \
  scripts/extract-release-notes.sh --check "$real_version"
lacks "extract: --check does not print the body" "###"
expect fail "extract: --check fails on an absent version" \
  scripts/extract-release-notes.sh --check 9.9.9

# ---------------------------------------------------------------------------
# extract-release-notes.sh — fixture CHANGELOGs
# ---------------------------------------------------------------------------

# The assembler this consumes writes `## [x.y.z] - YYYY-MM-DD`; the hand-written
# 0.1.0 entry uses an em dash. Both must parse, sub-headings must stay inside the
# section, and the next `## [` must end it.
d="$(fixture changelog-shape)"
cat >"$d/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

Nothing yet.

## [0.2.0] - 2026-08-01

### Added

- dash-form heading.

### Fixed

- a thing.

## [0.1.0] — 2026-07-26

em-dash-form heading.

[0.2.0]: https://example.invalid/compare/a...b
[0.1.0]: https://example.invalid/compare/c...d
MD

expect ok "extract: hyphen-dated heading (assembler format)" \
  "$d/scripts/extract-release-notes.sh" 0.2.0
contains "extract: keeps ### sub-headings" "### Fixed"
contains "extract: keeps the last entry of the section" "- a thing."
lacks "extract: stops before the next version" "em-dash-form heading."
lacks "extract: does not leak the Unreleased section" "Nothing yet."

expect ok "extract: em-dash-dated heading (hand-written format)" \
  "$d/scripts/extract-release-notes.sh" 0.1.0
contains "extract: em-dash section body" "em-dash-form heading."
lacks "extract: last section drops the link-reference block" "example.invalid"

# `## [0.1]` must not match `## [0.1.0]` — the bracket is part of the pattern.
expect fail "extract: a version prefix does not match a longer section" \
  "$d/scripts/extract-release-notes.sh" 0.1

# A header with nothing under it publishes an empty release body; reject it.
d="$(fixture changelog-empty)"
cat >"$d/CHANGELOG.md" <<'MD'
# Changelog

## [0.3.0] - 2026-09-01

## [0.2.0] - 2026-08-01

- something.
MD
expect fail "extract: an empty section fails" "$d/scripts/extract-release-notes.sh" 0.3.0
contains "extract: says the section is empty" "is empty"

# A missing CHANGELOG.md must be a clear error, not an empty body.
d="$(fixture changelog-absent)"
expect fail "extract: a missing CHANGELOG.md fails" "$d/scripts/extract-release-notes.sh" 0.1.0
contains "extract: names the missing file" "CHANGELOG.md not found"

# ---------------------------------------------------------------------------

if [ "$failures" -ne 0 ]; then
  echo
  echo "FAIL: $failures release-script assertion(s) failed"
  exit 1
fi
echo
echo "PASS: release scripts"
