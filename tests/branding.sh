#!/usr/bin/env bash
# Branding gate: the upstream project's name must not appear in first-party
# copy. There are two escape hatches — a FILE ALLOWLIST for documents that are
# wholesale attribution, and an INLINE MARKER for a single legitimate literal
# mention inside a document that is otherwise first-party.
#
# WHY THE MARKER EXISTS (#60). The allowlist is all-or-nothing per file, so the
# only way to write the upstream name once — in a sentence that is *about* the
# fork relationship — was to exempt the whole file or to reword around it. This
# repository's fork-point git tag is NAMED with that word, so a changelog
# passage explaining which tags exist here cannot be written accurately without
# naming it. We reworded, and shipped a vaguer claim than the truth. The gate
# greps tracked files, so it never could see the tag itself: the name is in this
# repository's refs regardless of what this script permits, and refusing to let
# prose say so bought nothing.
#
#   <!-- branding-ok: why -->        exempts THIS line
#   <!-- branding-ok:begin why -->   opens a block; every line through
#   <!-- branding-ok:end -->         ...this one is exempt
#
# Only the `branding-ok:` token and the reason after it are read, so the same
# marker works inside any comment syntax — Markdown, Zig, YAML, shell.
#
# Four properties stop the marker from decaying into a silent allowlist:
#
#   * A REASON IS REQUIRED. `branding-ok:` with nothing after it fails.
#   * AN UNBALANCED BLOCK FAILS. A stray `begin` would otherwise exempt the
#     whole tail of a file, which is the allowlist-a-whole-file hole re-opened
#     by accident.
#   * A MARKER THAT EXEMPTS NOTHING FAILS AS STALE — the same rule
#     tests/meta/unrun-scripts.txt and scripts/allocator-allowlist.txt carry, so
#     one left behind after a rewording gets deleted instead of quietly widening
#     the hole for whatever is written near it next.
#   * EVERY SANCTIONED MENTION IS PRINTED ON SUCCESS. An exemption nobody ever
#     sees is an exemption nobody re-checks.
#
# THE NEEDLE IS ASSEMBLED FROM TWO FRAGMENTS below, so it never exists as a
# contiguous string in this file. That is what lets this gate be searched BY ITS
# OWN GREP: the ':!tests/branding.sh' self-exclusion the previous version needed
# is gone, and must never come back. tests/confidentiality.sh records the
# incident that taught this — a gate that both spelled its needles out in
# comments AND excluded itself from its own search reported a clean tree while
# being the single largest leak in it. Do not "tidy" the quoting below, and do
# not write the word out in a comment here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NEEDLE='zi''ne'
MARKER='branding-ok:'

# Wholesale attribution: these are about the fork relationship end to end.
ALLOWLIST=(
  ':!LICENSE'
  ':!README.md'
  ':!CLAUDE.md'
  ':!docs/upstream'
  ':!src/hacks/CoreFoundation.h.zig'
  ':!zig-pkg'
)

# Marker syntax is NOT interpreted in these two files. The gate has to spell the
# token to implement it and the self-test has to spell it to exercise it, and
# either read as markup would be a pile of unbalanced fragments rather than an
# exemption. Both files are still SEARCHED for the needle like everything else —
# this skips the marker parser, not the gate.
MARKER_SKIP=(
  ':!tests/branding.sh'
  ':!tests/branding.test.sh'
)

fails=0

# ── 1. Parse and validate the markers ────────────────────────────────
# Whole files, NOT `git grep` hit lines, because two of the rules need context a
# per-line grep cannot have:
#
#   * a block `begin` has to be matched against its `end`, and flagged when the
#     file ends without one — which is a fact about the file, not the line;
#   * a marker shown as an EXAMPLE — inside a backtick span, or inside a fenced
#     code block — has to read as documentation rather than as an instruction.
#
# That second rule is not hypothetical. CLAUDE.md, CONTRIBUTING.md and ci.yml
# all spell the marker out in order to
# explain it, and every one of them would otherwise parse as a stray unbalanced
# fragment and fail the gate on its own documentation. Writing a REAL marker
# inside backticks does not work, by the same rule — the mention it was meant to
# cover is then reported as unsanctioned, which says so plainly.
mapfile -t MARKER_FILES < <(git grep -l -F -e "$MARKER" -- "${MARKER_SKIP[@]}" || true)

records=""
if [ "${#MARKER_FILES[@]}" -gt 0 ]; then
  records=$(awk -v marker="$MARKER" '
function clean(s) {
  sub(/[[:space:]]*(-->|\*\/|;;)[[:space:]]*$/, "", s)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}
function flush() {
  if (open_line != 0) {
    printf "ERR\t%s:%d: `%sbegin` is never closed by a `%send`\n", cur, open_line, marker, marker
    open_line = 0
  }
}
FNR == 1 { flush(); cur = FILENAME; fence = 0 }
/^[[:space:]]*(```|~~~)/ { fence = !fence; next }
fence { next }
{
  text = $0
  gsub(/`[^`]*`/, "", text)
  mp = index(text, marker)
  if (mp == 0) next
  file = FILENAME
  lineno = FNR
  tail = substr(text, mp + length(marker))

  if (tail ~ /^begin([^a-zA-Z]|$)/) {
    reason = clean(substr(tail, 6))
    if (open_line != 0) {
      printf "ERR\t%s:%d: nested `%sbegin` — one is already open at line %d\n", file, lineno, marker, open_line
      next
    }
    if (reason !~ /[[:alnum:]]/) {
      printf "ERR\t%s:%d: `%sbegin` with no reason\n", file, lineno, marker
      next
    }
    open_line = lineno; open_reason = reason
    next
  }
  if (tail ~ /^end([^a-zA-Z]|$)/) {
    if (open_line == 0) {
      printf "ERR\t%s:%d: `%send` with no matching `%sbegin`\n", file, lineno, marker, marker
      next
    }
    printf "BLOCK\t%s\t%d\t%d\t%s\n", file, open_line, lineno, open_reason
    open_line = 0
    next
  }
  reason = clean(tail)
  if (reason !~ /[[:alnum:]]/) {
    printf "ERR\t%s:%d: `%s` with no reason\n", file, lineno, marker
    next
  }
  printf "LINE\t%s\t%d\t%s\n", file, lineno, reason
}
END { flush() }
' "${MARKER_FILES[@]}")
fi

declare -a line_file=() line_no=() line_why=() line_used=()
declare -a blk_file=() blk_from=() blk_to=() blk_why=() blk_used=()

while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    ERR)
      echo "FAIL: $a" >&2
      fails=$((fails + 1))
      ;;
    LINE)
      line_file+=("$a"); line_no+=("$b"); line_why+=("$c"); line_used+=(0)
      ;;
    BLOCK)
      blk_file+=("$a"); blk_from+=("$b"); blk_to+=("$c"); blk_why+=("$d"); blk_used+=(0)
      ;;
  esac
done <<< "$records"

# ── 2. Search, then split the hits by whether a marker covers them ───────────
hits=$(git grep -i -n -e "$NEEDLE" -- "${ALLOWLIST[@]}" || true)

declare -a unsanctioned=() sanctioned=()
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=${hit%%:*}
  rest=${hit#*:}
  lineno=${rest%%:*}

  covered=0
  why=""
  for ((i = 0; i < ${#line_file[@]}; i++)); do
    if [ "${line_file[i]}" = "$file" ] && [ "${line_no[i]}" = "$lineno" ]; then
      covered=1; why=${line_why[i]}; line_used[i]=1; break
    fi
  done
  if [ "$covered" -eq 0 ]; then
    for ((i = 0; i < ${#blk_file[@]}; i++)); do
      if [ "${blk_file[i]}" = "$file" ] &&
         [ "$lineno" -ge "${blk_from[i]}" ] && [ "$lineno" -le "${blk_to[i]}" ]; then
        covered=1; why=${blk_why[i]}; blk_used[i]=1; break
      fi
    done
  fi

  if [ "$covered" -eq 1 ]; then
    sanctioned+=("$file:$lineno — $why")
  else
    unsanctioned+=("$hit")
  fi
done <<< "$hits"

if [ "${#unsanctioned[@]}" -gt 0 ]; then
  echo "FAIL: unsanctioned upstream-name references (${#unsanctioned[@]}):" >&2
  printf '  %s\n' "${unsanctioned[@]}" >&2
  echo >&2
  echo "  Use the zigapagos name, or — if naming the upstream project literally is" >&2
  echo "  the accurate thing to do — mark the line with '<!-- $MARKER why -->'." >&2
  fails=$((fails + 1))
fi

# ── 3. A marker that exempts nothing is stale ────────────────────────────────
for ((i = 0; i < ${#line_file[@]}; i++)); do
  if [ "${line_used[i]}" -eq 0 ]; then
    echo "FAIL: ${line_file[i]}:${line_no[i]}: '$MARKER' exempts nothing — delete it" >&2
    fails=$((fails + 1))
  fi
done
for ((i = 0; i < ${#blk_file[@]}; i++)); do
  if [ "${blk_used[i]}" -eq 0 ]; then
    echo "FAIL: ${blk_file[i]}:${blk_from[i]}: '${MARKER}begin' block exempts nothing — delete it" >&2
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  exit 1
fi

if [ "${#sanctioned[@]}" -gt 0 ]; then
  echo "PASS: no unsanctioned upstream-name references (${#sanctioned[@]} marked as legitimate):"
  printf '  %s\n' "${sanctioned[@]}"
else
  echo "PASS: no unsanctioned upstream-name references"
fi
