#!/usr/bin/env bash
# contract/test/drift.sh — proves the cross-tier type-codegen gate is NOT vacuous.
#
# Three cases:
#   A. api-check catches schema drift (committed generated dir no longer matches regen)
#   B. _assert.ts compile tripwire catches a real type divergence (tsc --noEmit fails)
#   C. Clean state passes both gates
#
# Guarantees: the EXIT trap restores the working tree even on early failure.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ── Restore helper ─────────────────────────────────────────────────────────────
# Called both explicitly in the script and by the EXIT trap.
restore_tree() {
  # Reset index + working tree for contract/ and runtime/src/flags.ts to HEAD.
  # git checkout HEAD -- <path> updates BOTH the index (unstages) and working
  # tree, so a prior "git add contract/generated" from api-check is fully undone.
  git checkout HEAD -- contract/ runtime/src/flags.ts 2>/dev/null || true
  # Restore any tests/ snapshot files that zig build api-check deletes as a
  # side effect of the build system's cache management.
  git ls-files --deleted -z -- tests/ 2>/dev/null | xargs -0 -I{} git restore -- {} 2>/dev/null || true
}

trap restore_tree EXIT

echo "=== drift.sh: proving the cross-tier type-codegen gate is not vacuous ==="
echo ""

# ─── Case A: api-check catches schema drift ────────────────────────────────────
echo "--- Case A: api-check catches schema drift ---"

# Mutate the schema: rename 'experiments' → 'variants' in ResolvedState.
# This changes both the required array entry and the property key, producing a
# clean rename that apigen will pick up and regenerate with 'variants'.
perl -i -pe 's/"experiments"/"variants"/g' contract/zigbase.openapi.json

# Run api-check WITHOUT manually regenerating first.  api-check internally
# reruns apigen (now sees 'variants') then does git add + git diff --cached
# --exit-code.  Since the committed generated dir has 'experiments', the diff
# is non-empty → NON-ZERO exit.
set +e
mise exec -- zig build api-check 2>&1
EXIT_A=$?
set -e

if [ "$EXIT_A" -eq 0 ]; then
  echo "FAIL Case A: api-check should have failed on schema drift but exited 0"
  exit 1
fi
echo "PASS Case A: api-check correctly rejected stale generated dir (exit $EXIT_A)"

# Restore: git checkout HEAD resets both index (unstages api-check's git add)
# and working tree.  Then restore any tests/ snapshots deleted by the build.
git checkout HEAD -- contract/
git ls-files --deleted -z -- tests/ | xargs -0 -I{} git restore -- {}

echo ""

# ─── Case B: compile tripwire catches type divergence ─────────────────────────
echo "--- Case B: compile tripwire catches ResolvedState divergence ---"

# Mutate the schema again (same rename).
perl -i -pe 's/"experiments"/"variants"/g' contract/zigbase.openapi.json

# Regenerate from the mutated schema so contract/generated/types.ts now
# declares  variants: Record<string, string>  instead of  experiments.
mise exec -- bun runtime/scripts/apigen.ts \
  --schema contract/zigbase.openapi.json \
  --out contract/generated 2>&1

# Run the compile tripwire.  contract/generated/_assert.ts does:
#   const _a: Gen     = {} as Runtime;   // Gen.variants ≠ Runtime.experiments → ERROR
#   const _b: Runtime = {} as Gen;       // Runtime.experiments ≠ Gen.variants  → ERROR
# tsc --noEmit must exit NON-ZERO.
set +e
(cd contract && mise exec -- bun x tsc --noEmit -p tsconfig.json 2>&1)
EXIT_B=$?
set -e

if [ "$EXIT_B" -eq 0 ]; then
  echo "FAIL Case B: tsc should have failed on type divergence but exited 0"
  exit 1
fi
echo "PASS Case B: tsc correctly caught type divergence between Gen and Runtime (exit $EXIT_B)"

# Restore: reset mutated schema + regenerated generated files.
git checkout HEAD -- contract/
git ls-files --deleted -z -- tests/ | xargs -0 -I{} git restore -- {}

echo ""

# ─── Case C: clean state passes both gates ────────────────────────────────────
echo "--- Case C: clean state passes both gates ---"

set +e
mise exec -- zig build api-check 2>&1
EXIT_C1=$?
set -e

if [ "$EXIT_C1" -ne 0 ]; then
  echo "FAIL Case C: api-check should pass on clean state but exited $EXIT_C1"
  exit 1
fi
echo "PASS Case C.1: api-check passes on clean state"

# Restore any tests/ snapshots deleted by zig build api-check.
git ls-files --deleted -z -- tests/ | xargs -0 -I{} git restore -- {}

set +e
(cd contract && mise exec -- bun x tsc --noEmit -p tsconfig.json 2>&1)
EXIT_C2=$?
set -e

if [ "$EXIT_C2" -ne 0 ]; then
  echo "FAIL Case C: tsc should pass on clean state but exited $EXIT_C2"
  exit 1
fi
echo "PASS Case C.2: tsc passes on clean state"

echo ""

# ─── Clean-tree assertion ──────────────────────────────────────────────────────
echo "--- Clean-tree assertion ---"

# Verify no TRACKED files under contract/ or runtime/ were left modified or
# deleted by the drift test cases.  Untracked files (??  lines) are ignored
# because this script and the docs created alongside it are legitimately
# untracked until the parent commit lands.
DIRTY=$(git status --short -- contract/ runtime/src/flags.ts | grep -v '^??' || true)
if [ -n "$DIRTY" ]; then
  echo "FAIL: tracked files under contract/ or runtime/ are dirty after drift.sh:"
  echo "$DIRTY"
  exit 1
fi
echo "PASS: working tree is clean (no modified/deleted tracked files under contract/ or runtime/)"

echo ""
echo "=== All drift cases caught + clean tree verified ==="
