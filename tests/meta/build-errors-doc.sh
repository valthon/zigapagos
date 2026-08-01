#!/usr/bin/env bash
# docs/build-errors.md may only quote messages the binary can actually emit.
#
# WHY THIS EXISTS (#39). A "common build errors" page is a document whose whole
# value is that its left-hand column is verbatim. The failure mode is specific
# and silent: someone writes a plausible-sounding message from memory, or an
# emit site is reworded and the page is not, and a reader greps the message they
# actually hit and finds nothing — or worse, finds a row describing a different
# cause. An invented row is worse than no page, because it sends the reader
# looking for something that never happens.
#
# So the page ends with a machine-checked table: fragment, diagnostic code,
# emitting file. This reads it and asserts, for every row, that the fragment is
# STILL a literal substring of that file, and that the code (when there is one)
# is [ACTIVE] in the frozen registry. A reworded message therefore fails CI in
# the same commit that rewords it.
#
# WHAT IT DOES NOT CHECK. That the fragment is reachable at run time, or that
# the surrounding prose is right. The fragments are deliberately the stable
# LITERAL part of a format string (never a `{s}` placeholder), which is what
# makes a plain grep the correct tool; a fragment that spans a placeholder would
# be unfindable and is the row shape to avoid when adding one.
set -euo pipefail
cd "$(dirname "$0")/../.."

DOC=docs/build-errors.md
FROZEN=src/diag-codes.frozen
fail() { echo "FAIL: $*"; exit 1; }

[[ -f "$DOC" ]] || fail "$DOC does not exist"
[[ -f "$FROZEN" ]] || fail "$FROZEN does not exist"

# The ACTIVE section of the frozen registry, one code per line. Everything after
# [RETIRED] is deliberately excluded: a page must not cite a code the binary no
# longer emits.
ACTIVE="$(awk '/^\[ACTIVE\]/{on=1;next} /^\[RETIRED\]/{on=0} on && NF && $0 !~ /^#/ {print}' "$FROZEN")"
[[ -n "$ACTIVE" ]] || fail "no [ACTIVE] codes parsed out of $FROZEN -- this gate would be vacuous"

# Rows of the trailing table: `| \`fragment\` | \`CODE\` | \`file\` |`. The
# leading '| `' is what distinguishes a data row from the header and the
# |---|---| separator, and from every other table on the page (whose first cell
# is prose, not code).
ROWS=0
while IFS= read -r line; do
  # A '|' INSIDE a cell would split that cell in two, and several real messages
  # have one: src/islands/pass.zig emits
  # "unknown island directive 'client:{s}' (expected load|idle|visible|media|only)".
  # Split naively, a row quoting that yields a fragment ending at "load", a CODE
  # cell of "idle" and a FILE cell of "visible" -- three wrong diagnoses of one
  # correct row.
  #
  # A markdown table has no quoting; its one escape is `\|`, which GitHub and
  # cmark-gfm (which renders the site mirror) strip before the cell is read. So:
  # protect the escaped form, split on what is left, restore it in the fields.
  # A row may quote a piped message as long as it escapes it the way markdown
  # requires anyway.
  esc="${line//\\|/$'\001'}"

  # An UNESCAPED pipe still mis-splits, and silently. Catch it by field count
  # rather than by letting it through: `| a | b | c |` is exactly five
  # '|'-separated awk fields (the empty ones outside the leading and trailing
  # delimiters included), so anything else is a cell carrying a raw delimiter.
  nf="$(printf '%s' "$esc" | awk -F'|' '{print NF}')"
  [[ "$nf" -eq 5 ]] \
    || fail "a table row splits into $nf '|'-separated fields, expected 5 -- a cell contains an unescaped '|'; write it as '\\|' (markdown's own escape, which is also what makes the row render): $line"

  # Strip the outer pipes, then split on '|'. Fields keep their backticks until
  # the sed below, so an accidentally unquoted cell fails loudly rather than
  # matching everything.
  frag="$(printf '%s' "$esc" | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]*`//; s/`[[:space:]]*$//')"
  code="$(printf '%s' "$esc" | awk -F'|' '{print $3}' | sed -E 's/^[[:space:]]*`?//; s/`?[[:space:]]*$//')"
  file="$(printf '%s' "$esc" | awk -F'|' '{print $4}' | sed -E 's/^[[:space:]]*`//; s/`[[:space:]]*$//')"
  frag="${frag//$'\001'/|}"
  code="${code//$'\001'/|}"
  file="${file//$'\001'/|}"

  [[ -n "$frag" ]] || fail "a table row has an empty message fragment: $line"
  # A fragment may not begin or end with whitespace INSIDE its backticks. The
  # sed above trims only what is outside them, so such a space is part of what
  # gets grepped -- and it is invisible in review, survives no rewrap, and an
  # editor that strips trailing space on save deletes it. The gate would then
  # fail on a message nobody touched, pointing at the emit site rather than at
  # the whitespace. Every message has an internal span with no edge space; use
  # one.
  case "$frag" in
    ' '*|*' ') fail "row '$frag' has leading or trailing whitespace inside its backticks -- that space is part of the grepped fragment and is invisible in review, so a rewrap or an editor's trim breaks this gate on a message that did not change; quote a span with no edge whitespace" ;;
  esac
  # A fragment may not contain a double quote. Not squeamishness: the emit sites
  # are Zig and TypeScript string literals, where an embedded quote is written
  # `\"`, so a fragment carrying a bare `"` can never match the source no matter
  # how correct it is. Rejecting it here says WHY, instead of failing below with
  # "not in that file" for a row that is in fact accurate.
  case "$frag" in
    *'"'*) fail "row '$frag' contains a double quote -- source literals escape it as \\\", so this fragment can never match; pick a quote-free span of the same message" ;;
  esac
  [[ -n "$file" ]] || fail "row '$frag' names no emitting file"
  [[ -f "$file" ]] || fail "row '$frag' names '$file', which does not exist"

  # -F: the fragments contain quotes, dots, parens and backslashes. A regex
  # match here would quietly succeed on a fragment that no longer appears
  # literally, which is the exact thing being checked.
  grep -qF -- "$frag" "$file" \
    || fail "docs/build-errors.md quotes a message that is NOT in $file: '$frag' -- either the emit site was reworded (update the page) or the row was written from memory (delete it)"

  if [[ "$code" != "-" ]]; then
    printf '%s\n' "$ACTIVE" | grep -qx -- "$code" \
      || fail "row '$frag' cites '$code', which is not [ACTIVE] in $FROZEN"
  fi

  ROWS=$((ROWS + 1))
done < <(grep -E '^\| `' "$DOC")

# A gate over a table is vacuous the moment the table stops being found — a
# renamed heading, a reformatted row, a stray blank line. Assert a floor rather
# than trusting the loop ran.
[[ "$ROWS" -ge 10 ]] \
  || fail "only $ROWS rows parsed out of $DOC's table (expected at least 10) -- the table's shape changed and this gate has gone vacuous"

echo "PASS: $ROWS quoted build-error messages all still present at their emit sites"
