#!/usr/bin/env bash
# Print one version's section of CHANGELOG.md to stdout, for use as a GitHub
# release body (`gh release create --notes-file`).
#
#   scripts/extract-release-notes.sh <version>    # "0.1.0" or "v0.1.0"
#   scripts/extract-release-notes.sh --check <version>   # validate only, no output
#
# WHY NOT `gh release create --generate-notes`: the generated body is a commit
# list plus a compare link. This repo already maintains CHANGELOG.md as the
# curated, human-facing record of what changed, so a generated commit dump both
# duplicates it and contradicts it — the changelog says "TSX islands", the
# generated notes say "Merge pull request #3". The changelog entry IS the
# release notes; anything else is a second, worse answer to the same question.
#
# WHAT HAPPENS WHEN THE SECTION IS MISSING: this exits non-zero and the release
# fails. That is deliberate, and the alternative (fall back to generated notes,
# or publish an empty body) was rejected: a GitHub release is the artifact users
# discover the project through, its body is not regenerated when CHANGELOG.md is
# later fixed, and a tag can only be re-released by deleting a release people may
# already have linked. Failing costs a re-tag; publishing wrong notes costs a
# permanently wrong record. The check is also cheap enough to run in the release
# workflow's fail-fast preamble (`--check`), so the real cost of forgetting the
# section is ~10 seconds, not a wasted build matrix.
#
# FORMAT CONSUMED: `## [<version>]` at column 0, anything after it on the line
# (the assembler writes `## [x.y.z] - YYYY-MM-DD`; the hand-written 0.1.0 entry
# uses an em dash). Only the bracketed version is matched, so either is fine.
#
# Self-tests: tests/release/scripts.sh
set -euo pipefail
cd "$(dirname "$0")/.."

check_only=false
if [ "${1-}" = "--check" ]; then
  check_only=true
  shift
fi

version="${1-}"
if [ -z "$version" ]; then
  echo "usage: scripts/extract-release-notes.sh [--check] <version>" >&2
  exit 1
fi
# Accept a raw tag name.
version="${version#v}"

changelog="CHANGELOG.md"
if [ ! -f "$changelog" ]; then
  echo "::error::$changelog not found" >&2
  exit 1
fi

# Section body = everything after the `## [<version>]` header, up to whichever
# comes first:
#   - the next `## ` heading (the previous release, or `## [Unreleased]` if the
#     sections are ever ordered oldest-first). `### ` sub-headings inside the
#     section must NOT terminate it, hence the trailing space in `^## `.
#   - the Keep-a-Changelog link-reference block (`[0.1.0]: https://…`) that sits
#     at the END of the file. Those definitions belong to the document, not to
#     the last section, and without this the oldest version — which is every
#     version at the point it is released, since new sections are prepended —
#     would ship them as trailing junk in its release body.
# The header line itself is dropped: `gh release create --title` already renders
# the version above the body.
notes="$(
  awk -v ver="$version" '
    found && (/^## / || /^\[[^]]+\]:[[:space:]]/) { exit }
    found { print }
    !found && index($0, "## [" ver "]") == 1 { found = 1 }
    END { if (!found) exit 1 }
  ' "$changelog"
)" || {
  echo "::error::no '## [$version]' section in $changelog — add the release section before tagging" >&2
  exit 1
}

# Drop the blank line that always follows the header (command substitution has
# already eaten the trailing ones). An all-blank section is a defect of the same
# class as a missing one: `--notes-file` with an empty file publishes a release
# with no body at all, so reject it here rather than discovering it on the
# release page.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d')"
if [ -z "${notes//[[:space:]]/}" ]; then
  echo "::error::the '## [$version]' section in $changelog is empty" >&2
  exit 1
fi

if [ "$check_only" = true ]; then
  echo "release notes for $version: $(printf '%s\n' "$notes" | wc -l) line(s)"
  exit 0
fi

printf '%s\n' "$notes"
