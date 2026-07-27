#!/usr/bin/env bash
# Assemble the changelog fragments in changelog.d/ into a new release section of CHANGELOG.md.
#
# Why fragments exist: a PR that records a change drops changelog.d/<slug>.md instead of
# editing CHANGELOG.md, so two branches open at once never touch the same lines of the
# shared file. Two PRs each adding their own fragment merge cleanly; two PRs each appending
# to a shared `## [Unreleased]` block do not. See changelog.d/README.md.
#
# At release this script aggregates the bullets per `### <Section>` across ALL fragments,
# emits each non-empty section in canonical order under one new `## [<version>] - <date>`
# heading, inserts that above the most recent released version (i.e. just below the
# `## [Unreleased]` pointer, which it deliberately leaves alone), fixes up the
# reference-style links at the foot of the file, and deletes the consumed fragments.
#
# The heading format is an INTERFACE, not decoration: scripts/extract-release-notes.sh
# locates a section by matching `## [<version>]` at the start of a line and prints through
# to the next `## [`, and the v* release workflow uses that as the GitHub release body. A
# malformed heading fails nothing and silently yields empty or run-on release notes, which
# is why the version/date are validated here rather than trusted.
#
# There is no site mirror to update: site/ has no generated changelog page (checked), so
# CHANGELOG.md is the only target.
#
# Usage: scripts/assemble-changelog.sh [<version> [<date>]] [--dry-run]
#   <version>  defaults to build.zig.zon's .version (the single source of truth).
#   <date>     defaults to today (UTC), YYYY-MM-DD.
#   --dry-run  print the assembled section and the fragments that would be removed; write
#              nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAG_DIR="changelog.d"
CANONICAL="CHANGELOG.md"

usage() {
  echo "Usage: scripts/assemble-changelog.sh [<version> [<date>]] [--dry-run]"
}

# Scalars rather than an args array: `${ARGS[0]:-x}` on an empty array is an "unbound
# variable" under `set -u` in bash 3.2, which is what macOS still ships.
DRY_RUN=0
VERSION=""
DATE=""
positional=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "::error::unknown option '$a'" >&2
      usage >&2
      exit 2
      ;;
    *)
      case "$positional" in
        0) VERSION="$a" ;;
        1) DATE="$a" ;;
        *)
          echo "::error::unexpected extra argument '$a'" >&2
          usage >&2
          exit 2
          ;;
      esac
      positional=$((positional + 1))
      ;;
  esac
done

[ -n "$VERSION" ] || VERSION="$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | cut -d'"' -f2)"
# Accept a leading "v" so `assemble-changelog.sh v0.2.0` works, but strip it: the heading
# carries the bare semver, matching build.zig.zon and what extract-release-notes.sh looks up.
VERSION="${VERSION#v}"
[ -n "$DATE" ] || DATE="$(date -u +%Y-%m-%d)"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::version '$VERSION' is not semver x.y.z — the release-notes extractor" >&2
  echo "matches the heading literally, so a malformed one yields empty release notes." >&2
  exit 1
fi
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "::error::date '$DATE' is not YYYY-MM-DD." >&2
  exit 1
fi

[ -f "$CANONICAL" ] || {
  echo "::error::changelog not found: $CANONICAL" >&2
  exit 1
}

# A second `## [<version>]` heading would shadow the first for extract-release-notes.sh
# (it stops at the next `## [`), so re-running the assembler for a shipped version is a
# hard error rather than a silent duplicate.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "## [$VERSION]"*)
      echo "::error::$CANONICAL already has a '## [$VERSION]' section." >&2
      echo "Pass a different version, or drop the existing section first." >&2
      exit 1
      ;;
  esac
done < "$CANONICAL"

# Canonical sections, in emission order. 1-6 are Keep a Changelog's set, which the preamble
# of CHANGELOG.md commits this project to. `Known limitations` is the standing list 0.1.0
# already carries; `Internal` is contributor-facing and renders last. Anything else in a
# fragment is a typo and fails the build.
SECTIONS=(Added Changed Deprecated Removed Fixed Security "Known limitations" Internal)
is_section() {
  for s in "${SECTIONS[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Section bucket file names must be filesystem-safe: "Known limitations" has a space.
bucket_for() {
  printf '%s' "$WORK/section_${1// /_}"
}

# Collect fragments. A fragment is changelog.d/<slug>.md; README.md documents the
# convention and is not one.
shopt -s nullglob
FRAGMENTS=()
for f in "$FRAG_DIR"/*.md; do
  [ "${f##*/}" = "README.md" ] && continue
  FRAGMENTS+=("$f")
done
shopt -u nullglob

if [ "${#FRAGMENTS[@]}" -eq 0 ]; then
  echo "::error::no fragments in $FRAG_DIR/ — nothing to assemble for $VERSION." >&2
  echo "A release with no recorded changes is almost always a mistake; add" >&2
  echo "$FRAG_DIR/<slug>.md fragments first (see $FRAG_DIR/README.md)." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Parse each fragment into per-section buckets. A fragment is a sequence of `### <Section>`
# headings, each followed by its bullet/body lines.
#
# Blank-line handling: blanks are buffered and only flushed once a section chunk has emitted
# a non-blank line. That trims the leading blank after a heading and the trailing blank at
# end of file — so bullets from different fragments aggregate into one tight list — while
# preserving a blank *between* two lines of the same chunk, which is what a bullet with an
# indented follow-up paragraph needs.
for f in "${FRAGMENTS[@]}"; do
  current=""
  chunk_started=0
  pending=0
  saw_section=0
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      "### "*)
        name="${line#"### "}"
        name="${name%"${name##*[![:space:]]}"}" # rstrip trailing whitespace
        if ! is_section "$name"; then
          echo "::error::fragment '$f' line $lineno: unknown section '### $name'." >&2
          printf 'Recognized sections: %s\n' "$(
            IFS='|'
            echo "${SECTIONS[*]}"
          )" >&2
          exit 1
        fi
        current="$name"
        chunk_started=0
        pending=0
        saw_section=1
        ;;
      "")
        [ "$chunk_started" -eq 1 ] && pending=$((pending + 1))
        ;;
      *)
        if [ -z "$current" ]; then
          echo "::error::fragment '$f' line $lineno: content before any '### <Section>' heading:" >&2
          echo "  $line" >&2
          exit 1
        fi
        bucket="$(bucket_for "$current")"
        while [ "$pending" -gt 0 ]; do
          echo "" >> "$bucket"
          pending=$((pending - 1))
        done
        printf '%s\n' "$line" >> "$bucket"
        chunk_started=1
        ;;
    esac
  done < "$f"
  if [ "$saw_section" -eq 0 ]; then
    echo "::error::fragment '$f' has no '### <Section>' heading (see $FRAG_DIR/README.md)." >&2
    exit 1
  fi
done

# Build the assembled block: the version heading, then every non-empty section in canonical
# order.
SECTION="$WORK/__section__"
nonempty=0
{
  echo "## [${VERSION}] - ${DATE}"
  for s in "${SECTIONS[@]}"; do
    file="$(bucket_for "$s")"
    [ -s "$file" ] || continue
    nonempty=$((nonempty + 1))
    echo
    echo "### $s"
    echo
    cat "$file"
  done
} > "$SECTION"

if [ "$nonempty" -eq 0 ]; then
  echo "::error::the ${#FRAGMENTS[@]} fragment(s) declared sections but contained no bullets." >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== assembled section for ${VERSION} (${DATE}) ==="
  cat "$SECTION"
  echo "=== would remove ${#FRAGMENTS[@]} fragment(s) ==="
  printf '  %s\n' "${FRAGMENTS[@]}"
  exit 0
fi

# One awk pass does both edits:
#
#  1. Insert the assembled section immediately before the first *released* version heading
#     (`## [<digit>`), i.e. below the `## [Unreleased]` pointer, which is left untouched
#     because it is a static pointer to changelog.d/ and has nothing to reset.
#  2. Rewrite the reference-style links at the foot of the file: `[Unreleased]` is
#     re-pointed at `v<version>...HEAD`, and the endpoint it used to carry becomes the start
#     of the new version's compare link. A missing `[Unreleased]:` definition is a warning,
#     not a failure — the section is the part that matters and a bad link is visible.
tmp="$(mktemp "$WORK/insert.XXXXXX")" # under $WORK so the EXIT trap reaps it on interrupt
awk -v sectionfile="$SECTION" -v version="$VERSION" '
  BEGIN { inserted = 0; linked = 0; newtag = "v" version }
  !inserted && /^## \[[0-9]/ {
    while ((getline l < sectionfile) > 0) print l
    print ""
    inserted = 1
  }
  !linked && /^\[Unreleased\]: .*\/compare\/.*\.\.\.HEAD$/ {
    i = index($0, "/compare/")
    head = substr($0, 1, i + 8)            # through the literal "/compare/"
    sub(/^\[Unreleased\]: /, "", head)     # ... minus the label, leaving just the URL prefix
    rest = substr($0, i + 9)               # "<prev>...HEAD"
    prev = substr(rest, 1, index(rest, "...") - 1)
    printf "[Unreleased]: %s%s...HEAD\n", head, newtag
    printf "[%s]: %s%s...%s\n", version, head, prev, newtag
    linked = 1
    next
  }
  { print }
  END {
    if (!inserted) {
      print "::error::no released-version heading (## [<digit>) found to anchor the insert" > "/dev/stderr"
      exit 3
    }
    if (!linked)
      print "::warning::no `[Unreleased]: .../compare/<ref>...HEAD` link definition found; add the compare link for " newtag " by hand" > "/dev/stderr"
  }
' "$CANONICAL" > "$tmp"
mv "$tmp" "$CANONICAL"
echo "inserted the ${VERSION} section into $CANONICAL"

# Remove the consumed fragments. `git rm` when tracked, plain `rm` otherwise, so the script
# also works on an untracked scratch copy (which is how its self-test drives it).
for f in "${FRAGMENTS[@]}"; do
  if git ls-files --error-unmatch "$f" > /dev/null 2>&1; then
    git rm -q "$f"
  else
    rm -f "$f"
  fi
done
echo "removed ${#FRAGMENTS[@]} consumed fragment(s) from $FRAG_DIR/"
