#!/usr/bin/env bash
# Gate: CHANGELOG.md's preamble may only document version strings the binary can
# actually print.
#
# WHY THIS EXISTS. `zigapagos version` prints, verbatim, the string build/config.zig
# stamped into the binary at configure time. Its `getVersion` runs
# `git describe --match '*.*.*' --tags` and then REFORMATS the untagged case into a
# semver version behind the tag's own `v` prefix — the commit height becomes a
# `-dev.<n>` pre-release, the abbreviated hash becomes `+<sha>` build metadata, and
# describe's conventional `g` prefix is stripped (config.zig panics if that `g` is
# absent, so it can never reach the output). The changelog preamble documented
# describe's own raw spelling, `v0.1.1-<n>-g<sha>`, as if that were what the tool
# prints — a shape `getVersion` cannot emit. CHANGELOG.md is mirrored to the published
# docs site by site/scripts/gen-docs-mirror.ts (registry slug `changelog`), so the
# false shape was live on the site. See issue #43.
#
# WHAT IT PINS. The preamble lists the emittable shapes as a bullet list, one example
# per bullet, each bullet opening with the example in backticks. This script extracts
# those examples and requires every one of them to be a string `getVersion` can produce.
# The dev-stamp grammar is the SAME regex tests/npm/packaging.sh pins the real binary's
# output against, and this script asserts that literal still appears there — the two
# assertions describe one grammar, so they must not be able to drift apart silently.
#
# It also asserts build/config.zig still assembles the dev stamp the documented way, so
# a change to the emitter fails the document rather than quietly outdating it.
#
# Cost: a handful of greps over three files. No toolchain, no build, no temp trees.
# Picked up by CI's `tests/*/*.sh` glob, like tests/changelog/assemble.sh beside it.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The preamble is everything above the first `## ` section heading. Slicing it out
# rather than grepping the whole file matters: the released sections below quote plenty
# of version-shaped strings that are not version stamps.
PREAMBLE="$(awk 'NR > 1 && /^## / { exit } { print }' CHANGELOG.md)"
[[ -n "$PREAMBLE" ]] || fail "CHANGELOG.md has no preamble above its first '## ' heading"

# Byte-identical to tests/npm/packaging.sh's version_stamp_re, which pins the same
# grammar from the other side (the string the installed binary actually prints).
# `{4,40}`: git widens the abbreviation as the object count grows and core.abbrev can
# narrow it to 4. The sha's LENGTH is not what is pinned — that it is non-empty hex is.
version_stamp_re='^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]{4,40}$'
grep -qF -- "version_stamp_re='$version_stamp_re'" tests/npm/packaging.sh \
  || fail "tests/npm/packaging.sh no longer carries this exact dev-stamp regex — the
  binary-side and document-side assertions have drifted apart; reconcile them"

# `.tag` returns `git describe`'s output verbatim, and this repo's release tags are
# v-prefixed semver (build/release.zig compares `version.tag[1..]` with the zon version
# and refuses to build a release when they disagree).
version_tag_re='^v[0-9]+\.[0-9]+\.[0-9]+$'

# True for a string build/config.zig's getVersion can emit — its three branches, and
# nothing else.
emittable() {
  [[ "$1" == unknown ]] && return 0
  [[ "$1" =~ $version_tag_re ]] && return 0
  [[ "$1" =~ $version_stamp_re ]]
}

# The matcher's own self-test. A matcher that accepts everything passes this suite
# exactly as a correct one does, so only driving it with strings that must be REJECTED
# can tell the two apart. The first two rejects are the defect this gate was written
# for: describe's raw spelling, with a concrete height/sha and with the placeholders the
# preamble actually carried.
for good in v0.2.0 v0.1.1-dev.85+e1d7033 v0.11.2-dev.0+0123456789abcdef0123 unknown; do
  emittable "$good" || fail "the matcher rejected the emittable shape '$good'"
done
for bad in 'v0.1.1-7-ge1d7033' 'v0.1.1-<n>-g<sha>' 'v0.2.0-dev.7+' 'v0.2.0-dev.+e1d7033' \
           'v0.2.0-dev.7+E1D7033' '0.2.0' 'v0.2' 'Unknown' ''; do
  ! emittable "$bad" || fail "the matcher accepted the non-emittable shape '$bad'"
done

# Each documented shape is a bullet whose first token is the example, in backticks.
# Requiring exactly three is half the assertion: a rewrite that dropped the list would
# otherwise leave this script checking an empty set and passing vacuously.
EXAMPLES=()
while IFS= read -r line; do
  EXAMPLES+=("$line")
done < <(printf '%s\n' "$PREAMBLE" | sed -n 's/^ *- `\([^`]*\)` — .*/\1/p')

(( ${#EXAMPLES[@]} == 3 )) || fail "expected CHANGELOG.md's preamble to document exactly
  three version-string shapes as '- \`<example>\` — <explanation>' bullets, found
  ${#EXAMPLES[@]}${EXAMPLES[0]+: ${EXAMPLES[*]}}"

for example in "${EXAMPLES[@]}"; do
  emittable "$example" \
    || fail "CHANGELOG.md documents '$example' as a string \`zigapagos version\` prints,
  but build/config.zig's getVersion cannot emit it (its branches are describe's tag
  verbatim, '<tag>-dev.<height>+<sha>', or 'unknown')"
done

# The document describes a reformat, so pin the reformat itself: if this format string
# changes, the preamble is stale and this gate — not a reader — should be what notices.
grep -qF -- '"{s}-dev.{s}+{s}"' build/config.zig \
  || fail "build/config.zig no longer assembles the dev stamp as '{tag}-dev.{height}+{sha}';
  CHANGELOG.md's preamble documents that spelling and must be updated with it"

echo "ok: CHANGELOG.md documents ${#EXAMPLES[@]} version shapes, all emittable by build/config.zig"
