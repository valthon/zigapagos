#!/usr/bin/env bash
# docs/scripty.md is generated, and this is what keeps it true.
#
# TWO GATES, because a generated artifact has two independent ways of being
# worthless (#37):
#
#   (1) DRIFT. The committed copy is what people read; the generator is what
#       tells the truth. Adding a builtin, renaming one, or changing a
#       `signature`/`docs_description` moves the generated output, and a
#       committed copy that no longer matches is exactly the stale hand-written
#       reference this was supposed to replace. So: regenerate, and diff.
#
#   (2) COVERAGE. A generator that walks the wrong root, or whose supermd half
#       silently produces nothing, still emits a plausible-looking page and
#       still passes a drift check — the committed copy would simply be
#       consistently wrong. So the five builtins issue #37 names by name, each
#       of which cost hours of source-grepping, are asserted present. They span
#       both halves on purpose: String.eql and String.addPath come from this
#       repo's src/context, the three $-directives from the vendored supermd, so
#       losing either half fails here.
#
# Regeneration writes docs/scripty.md IN PLACE (the api-check step has the same
# property). On success that is a no-op. On failure the regenerated file is left
# behind deliberately: it is the thing to commit.
set -euo pipefail
cd "$(dirname "$0")/../.."

DOC=docs/scripty.md
fail() { echo "FAIL: $*"; exit 1; }

[[ -f "$DOC" ]] || fail "$DOC does not exist -- run: zig build docs-reference"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$DOC" "$TMP/committed.md"

zig build docs-reference >"$TMP/gen.log" 2>&1 \
  || { sed -n '1,40p' "$TMP/gen.log"; fail "the generator failed to run"; }

if ! diff -u "$TMP/committed.md" "$DOC" >"$TMP/drift.diff"; then
  sed -n '1,60p' "$TMP/drift.diff"
  fail "$DOC is stale: regenerating it changed it. The regenerated file is now in your working tree -- commit it."
fi

# Coverage. -F because these contain '$' and '(' and a regex match here would be
# a weaker assertion than it looks.
for name in 'String.eql' 'String.addPath' '$link.site' '$heading.id' '$link.page'; do
  grep -qF -- "$name" "$DOC" \
    || fail "$DOC does not mention '$name' -- issue #37 names it as a builtin that cost hours to find by grepping source; if it moved, the generator is not reaching it"
done

# The two halves, asserted structurally rather than by one name each: a page
# whose supermd half produced no sections would still contain the hand-written
# "$link.site()" in its prose above.
SHTML_FNS="$(grep -cE '^#### `[A-Z][A-Za-z]*\.' "$DOC" || true)"
SMD_FNS="$(grep -cE '^#### `\$' "$DOC" || true)"
[[ "$SHTML_FNS" -ge 50 ]] \
  || fail "only $SHTML_FNS .shtml builtins in $DOC (expected >= 50) -- the src/context walk is producing almost nothing"
[[ "$SMD_FNS" -ge 20 ]] \
  || fail "only $SMD_FNS .smd directive functions in $DOC (expected >= 20) -- the supermd walk is producing almost nothing"

echo "PASS: $DOC is freshly generated ($SHTML_FNS .shtml builtins, $SMD_FNS .smd directive functions)"
