#!/usr/bin/env bash
# Gate for issue #131 item 3 (and Stage 5 Task 4's second skill): each
# skill's references/ are byte-copies of their canonical docs/migration/*
# files (the canonical spec, published to the site). A skill must be
# self-contained when installed into a consumer project, so the files are
# duplicated on purpose -- and this gate is what turns drift between the two
# from a silent lie into a red test. Fix drift by copying the canonical file
# over the reference copy, never the other way.
#
# One skill name and one file list used to be hardcoded here (astro only).
# Adding zigapagos-rails-migration restructured the single check into a loop
# over a table of skill -> file-list pairs below, rather than appending a
# second hand-copied block -- every skill added after this one only needs a
# new table row.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail=0

# skill directory name : space-separated reference files (relative to both
# $SKILL/references/ and docs/migration/)
declare -A SKILL_FILES=(
  [zigapagos-astro-migration]="astro-to-zigapagos.md recipes.md react-spa-bridge.md"
  [zigapagos-rails-migration]="rails-to-zigapagos.md"
)

for name in "${!SKILL_FILES[@]}"; do
  SKILL="skills/$name"

  [[ -f "$SKILL/SKILL.md" ]] || { echo "FAIL: $SKILL/SKILL.md does not exist"; fail=1; continue; }

  for f in ${SKILL_FILES[$name]}; do
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
  grep -q "^name: $name\$" "$SKILL/SKILL.md" \
    || { echo "FAIL: $SKILL/SKILL.md 'name' must be exactly '$name' (the directory name)"; fail=1; }
  grep -q '^description: ' "$SKILL/SKILL.md" \
    || { echo "FAIL: $SKILL/SKILL.md needs a 'description' frontmatter field"; fail=1; }

  # Progressive-disclosure budget: the spec recommends a body under 500 lines.
  lines="$(wc -l < "$SKILL/SKILL.md")"
  [[ "$lines" -le 500 ]] || { echo "FAIL: $SKILL/SKILL.md is $lines lines (spec recommends <=500)"; fail=1; }
done

[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: tests/skills/sync.sh"
