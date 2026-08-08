#!/usr/bin/env bash
# Gate for issue #131 item 3: the skill's references/ are byte-copies of
# docs/migration/* (the canonical spec, published to the site). A skill must
# be self-contained when installed into a consumer project, so the files are
# duplicated on purpose -- and this gate is what turns drift between the two
# from a silent lie into a red test. Fix drift by copying the canonical file
# over the reference copy, never the other way.
set -euo pipefail
cd "$(dirname "$0")/../.."
SKILL="skills/zigapagos-astro-migration"
fail=0

[[ -f "$SKILL/SKILL.md" ]] || { echo "FAIL: $SKILL/SKILL.md does not exist"; exit 1; }

for f in astro-to-zigapagos.md recipes.md react-spa-bridge.md; do
  if [[ ! -f "$SKILL/references/$f" ]]; then
    echo "FAIL: $SKILL/references/$f is missing"
    fail=1
  elif ! diff -u "docs/migration/$f" "$SKILL/references/$f"; then
    echo "FAIL: $SKILL/references/$f drifted from docs/migration/$f -- run: cp docs/migration/$f $SKILL/references/$f"
    fail=1
  fi
done

# Frontmatter sanity per the agentskills.io spec: name is required and must
# equal the parent directory name; description is required.
grep -q '^name: zigapagos-astro-migration$' "$SKILL/SKILL.md" \
  || { echo "FAIL: SKILL.md 'name' must be exactly 'zigapagos-astro-migration' (the directory name)"; fail=1; }
grep -q '^description: ' "$SKILL/SKILL.md" \
  || { echo "FAIL: SKILL.md needs a 'description' frontmatter field"; fail=1; }

# Progressive-disclosure budget: the spec recommends a body under 500 lines.
lines="$(wc -l < "$SKILL/SKILL.md")"
[[ "$lines" -le 500 ]] || { echo "FAIL: SKILL.md is $lines lines (spec recommends <=500)"; fail=1; }

[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: tests/skills/sync.sh"
