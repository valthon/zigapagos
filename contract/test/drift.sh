#!/usr/bin/env bash
# contract/test/drift.sh — proves the cross-tier type-codegen gate is NOT vacuous.
#
# The gate has two independent halves, and this script breaks each one on purpose
# to show it notices:
#   A. `zig build api-check` catches SCHEMA drift — the committed contract/generated
#      no longer matches a fresh apigen run.
#   B. contract/generated/_assert.ts catches TYPE divergence — Gen and Runtime's
#      ResolvedState stop being mutually assignable, so `tsc --noEmit` fails.
#   C. Both halves pass on a clean tree (the control: without it, A and B would be
#      satisfied by a gate that fails unconditionally).
#   D. The assertions used by A and B are themselves not vacuous — canned "the tool
#      never ran" output must be REJECTED, not accepted.
#
# WHY CASE D EXISTS. Case B used to read, in full:
#
#     (cd contract && mise exec -- bun x tsc --noEmit -p tsconfig.json); EXIT_B=$?
#     if [ "$EXIT_B" -eq 0 ]; then echo "FAIL Case B"; exit 1; fi
#     echo "PASS Case B: tsc correctly caught type divergence"
#
# i.e. it asserted only that the command exited non-zero. contract/ has no
# node_modules, so `bun x tsc` resolved `tsc` off PATH, hit mise's shim, and died with
# `mise ERROR No version is set for shim: tsc` — exit 1, tsc never started, and the
# script printed PASS. A gate written to prove another gate is not vacuous was itself
# vacuous. An exit status alone cannot tell "the compiler found the divergence" from
# "the compiler could not launch", so every case below asserts on the DIAGNOSTIC TEXT
# and treats the status as necessary but not sufficient. That is the same reasoning
# src/islands/props_check.zig's anomaly guard already applies to tsc: a non-zero exit
# with no `): error TS` line in the output is a launch failure, not a finding.
#
# Guarantees: the EXIT trap restores the working tree on EVERY path — success, an
# assertion failure, an unexpected error, SIGINT/SIGTERM — and the trap itself fails
# the script if anything it mutates is still dirty afterwards. CI runs this in a shared
# checkout (via tests/contract/drift.sh, which the `tests/*/*.sh` glob picks up), where
# a leaked mutation would corrupt whatever script runs next.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ── Failure helper ─────────────────────────────────────────────────────────────
fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

# ── Restore + clean-tree guarantee ─────────────────────────────────────────────
# EXACTLY the paths this script mutates, and no others. The restore is a
# `git checkout HEAD --`, which is unconditionally destructive, so widening this list
# "just to be safe" is the opposite of safe: the previous revision restored all of
# `contract/`, which includes THIS FILE — editing drift.sh and running it reverted the
# edit mid-run. Add a path here only when a case above actually writes to it.
MUTATES=(contract/zigbase.openapi.json contract/generated)

dirty_paths() {
  # Untracked files (`??`) are ignored: a stray editor file is not this script's
  # business, and only tracked state can be "restored" in the first place.
  git status --porcelain -- "${MUTATES[@]}" | grep -v '^??' || true
}

restore_tree() {
  # `git checkout HEAD -- <path>` updates BOTH the index and the working tree, so it
  # also undoes the `git add contract/generated` that api-check performs internally.
  git checkout HEAD -- "${MUTATES[@]}" 2>/dev/null || true
  # zig's build cache can delete tests/ snapshot fixtures as a side effect; put back
  # anything that vanished.
  git ls-files --deleted -z -- tests/ 2>/dev/null | xargs -0 -I{} git restore -- {} 2>/dev/null || true
}

on_exit() {
  local rc=$?
  restore_tree
  local leftover
  leftover=$(dirty_paths)
  if [ -n "$leftover" ]; then
    printf 'FAIL: drift.sh could not restore the working tree:\n%s\n' "$leftover" >&2
    rc=1
  fi
  exit "$rc"
}

trap on_exit EXIT
# The signal handlers exist only so the EXIT trap gets a chance to run: bash does not
# fire an EXIT trap for an untrapped fatal signal, so a Ctrl-C without these would
# leave a mutated schema and a regenerated contract/generated behind.
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== drift.sh: proving the cross-tier type-codegen gate is not vacuous ==="
echo ""

# ── Pre-flight: nothing we are about to overwrite may already be dirty ─────────
# On CI the tree is a fresh checkout and this is moot; locally it is the difference
# between a test run and losing uncommitted work on the schema.
PREEXISTING=$(dirty_paths)
if [ -n "$PREEXISTING" ]; then
  fail "these paths are already modified, and drift.sh would discard the changes when it restores:
$PREEXISTING
  Commit or stash them first."
fi

# ── Compiler resolution ────────────────────────────────────────────────────────
# `bun x tsc` is NOT usable here. contract/ has no node_modules, so bun x either
# resolves something off PATH (the shim failure described in the header) or fetches
# `typescript@latest` from npm — and latest is 7.x, the Go rewrite, which this repo
# deliberately caps out (`typescript: ^6.0.3` in runtime/package.json plus the
# `>=7.0.0` ignore rule in .github/dependabot.yml, which explains why: 7.x ships no
# JavaScript compiler API). A gate that silently type-checked with a compiler the repo
# has pinned AWAY from would be worse than no gate.
#
# So run the compiler runtime/ installed, through bun — tsc's shebang is
# `#!/usr/bin/env node` and this toolchain has no node (mise.toml pins zig and bun
# only). Deliberately NOT a contract/package.json of its own: that would be a second
# TypeScript pin free to drift from runtime/package.json's, the same defect CLAUDE.md
# calls out for a repo-level .tool-versions sitting beside mise.toml.
TSC_JS="$PWD/runtime/node_modules/typescript/bin/tsc"
if [ ! -f "$TSC_JS" ]; then
  fail "no TypeScript in runtime/node_modules — run: (cd runtime && bun install --frozen-lockfile)"
fi

# Assert the installed compiler is the LOCKED one. A node_modules populated before a
# lockfile bump keeps working silently, and this gate would then be type-checking with
# a different compiler from the one runtime/ is tested against — the same trap
# .github/dependabot.yml documents for site/ and examples/tsx-site/'s lockfiles.
PINNED_TS=$(sed -n 's/.*"typescript": \["typescript@\([^"]*\)".*/\1/p' runtime/bun.lock | head -n1)
[ -n "$PINNED_TS" ] || fail "could not read the pinned typescript version out of runtime/bun.lock"
ACTUAL_TS=$(mise exec -- bun "$TSC_JS" --version)
if [ "$ACTUAL_TS" != "Version $PINNED_TS" ]; then
  fail "runtime/node_modules has '$ACTUAL_TS' but runtime/bun.lock pins $PINNED_TS — reinstall with --frozen-lockfile"
fi
echo "compiler: $ACTUAL_TS (pinned by runtime/bun.lock)"
echo ""

# ── Runners ────────────────────────────────────────────────────────────────────
# Both capture combined output AND the real exit status. Note `out=$(...) || rc=$?`
# rather than a pipeline: `cmd | tail` reports tail's status, and this whole file
# exists because of an exit status that meant something other than what it looked like.
OUT=""
RC=0

run_api_check() {
  OUT=""
  RC=0
  OUT=$(mise exec -- zig build api-check 2>&1) || RC=$?
}

run_tsc() {
  OUT=""
  RC=0
  # --pretty false keeps diagnostics on the one-line `<path>(L,C): error TSxxxx: <msg>`
  # form the assertions below match. That form is stable across 5.9, 6.0 and 7.0.
  OUT=$(mise exec -- bun "$TSC_JS" --noEmit --pretty false -p contract/tsconfig.json 2>&1) || RC=$?
}

# ── Assertions (written as predicates, so Case D can feed them canned input) ───

# The drift api-check must report is the `experiments` -> `variants` rename showing up
# in the staged diff of contract/generated. Asserting on the diff hunk — not merely on
# a non-zero status — is what separates "the gate caught the drift" from "zig failed to
# configure", "apigen crashed" or "git is missing", all of which are also non-zero.
api_check_drift_ok() {
  local rc="$1" out="$2"
  if [ "$rc" -eq 0 ]; then
    echo "  reject: api-check exited 0" >&2
    return 1
  fi
  # `git diff contract/generated` is the diff step's setName() in build/codegen.zig.
  # Requiring THAT step to be the failing one rules out a failure in apigen or in build
  # configuration masquerading as a caught drift.
  if ! printf '%s\n' "$out" | grep -qF 'git diff contract/generated failure'; then
    echo "  reject: api-check failed somewhere other than the git-diff step" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- '-  experiments: Record<string, string>;'; then
    echo "  reject: staged diff does not drop 'experiments'" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- '+  variants: Record<string, string>;'; then
    echo "  reject: staged diff does not add 'variants'" >&2
    return 1
  fi
  return 0
}

# The divergence _assert.ts is built to catch is structural: Gen declares `variants`,
# Runtime declares `experiments`, so BOTH assignability directions must break.
#   const _a: Gen     = {} as Runtime;   -> Property 'variants' is missing in Runtime
#   const _b: Runtime = {} as Gen;       -> Property 'experiments' is missing in Gen
divergence_diagnostics_ok() {
  local rc="$1" out="$2"
  if [ "$rc" -eq 0 ]; then
    echo "  reject: tsc exited 0" >&2
    return 1
  fi

  # A non-zero tsc with NO diagnostic line is a launch failure, not a finding. This is
  # the single check that would have caught the original defect.
  local errs
  errs=$(printf '%s\n' "$out" | grep -F '): error TS' || true)
  if [ -z "$errs" ]; then
    echo "  reject: non-zero exit but no '): error TS' diagnostic — tsc never ran" >&2
    return 1
  fi

  # Every diagnostic must come from the tripwire. A type error anywhere else means the
  # regenerated output is broken in some other way, and we would be crediting the gate
  # for catching something it was not aimed at.
  local stray
  stray=$(printf '%s\n' "$errs" | grep -vF '_assert.ts' || true)
  if [ -n "$stray" ]; then
    printf '  reject: diagnostics outside _assert.ts:\n%s\n' "$stray" >&2
    return 1
  fi

  if ! printf '%s\n' "$errs" | grep -qF "Property 'variants' is missing"; then
    echo "  reject: the Gen <- Runtime direction did not trip (no missing 'variants')" >&2
    return 1
  fi
  if ! printf '%s\n' "$errs" | grep -qF "Property 'experiments' is missing"; then
    echo "  reject: the Runtime <- Gen direction did not trip (no missing 'experiments')" >&2
    return 1
  fi
  return 0
}

# Rewrites ResolvedState's `experiments` key to `variants` in the schema. Both the
# `required` array entry and the property key move, so apigen regenerates a clean
# rename rather than a malformed document.
mutate_schema() {
  perl -i -pe 's/"experiments"/"variants"/g' contract/zigbase.openapi.json
  grep -qF '"variants"' contract/zigbase.openapi.json ||
    fail "the schema mutation did not apply — contract/zigbase.openapi.json has no \"variants\""
  ! grep -qF '"experiments"' contract/zigbase.openapi.json ||
    fail "the schema mutation was incomplete — \"experiments\" is still present"
}

# ─── Case A: api-check catches schema drift ────────────────────────────────────
echo "--- Case A: api-check catches schema drift ---"

mutate_schema

# api-check regenerates internally, then `git add` + `git diff --cached --exit-code`.
# The committed contract/generated still says `experiments`, so the staged diff is
# non-empty and the step fails.
run_api_check
api_check_drift_ok "$RC" "$OUT" || {
  printf 'api-check exit %s, output:\n%s\n' "$RC" "$OUT" >&2
  fail "Case A: api-check did not reject the schema drift"
}
echo "PASS Case A: api-check rejected the stale generated dir at the git-diff step, showing the experiments->variants hunk (exit $RC)"

restore_tree
echo ""

# ─── Case B: compile tripwire catches type divergence ─────────────────────────
echo "--- Case B: compile tripwire catches ResolvedState divergence ---"

mutate_schema

# Regenerate so contract/generated/types.ts declares `variants`, while
# runtime/src/flags.ts still declares `experiments`.
mise exec -- bun runtime/scripts/apigen.ts \
  --schema contract/zigbase.openapi.json \
  --out contract/generated

# Pre-conditions, not niceties: if apigen quietly produced nothing, tsc would type-check
# an UNCHANGED tree, exit 0, and Case B would report a gate failure that never happened.
grep -qF 'variants: Record<string, string>;' contract/generated/types.ts ||
  fail "Case B: apigen did not put 'variants' into contract/generated/types.ts — nothing to diverge"
grep -qF 'experiments' runtime/src/flags.ts ||
  fail "Case B: runtime/src/flags.ts no longer declares 'experiments' — the fixture rename is stale"

run_tsc
divergence_diagnostics_ok "$RC" "$OUT" || {
  printf 'tsc exit %s, output:\n%s\n' "$RC" "$OUT" >&2
  fail "Case B: tsc did not report the ResolvedState divergence"
}
echo "PASS Case B: tsc reported both assignability directions of the Gen/Runtime divergence, and nothing else (exit $RC)"

restore_tree
echo ""

# ─── Case C: clean state passes both gates ────────────────────────────────────
# The control for A and B. Without it, a gate that failed unconditionally would score
# two passes above.
echo "--- Case C: clean state passes both gates ---"

run_api_check
[ "$RC" -eq 0 ] || {
  printf '%s\n' "$OUT" >&2
  fail "Case C.1: api-check should pass on a clean tree but exited $RC"
}
echo "PASS Case C.1: api-check passes on clean state"

restore_tree

run_tsc
[ "$RC" -eq 0 ] || {
  printf '%s\n' "$OUT" >&2
  fail "Case C.2: tsc should pass on a clean tree but exited $RC"
}
[ -z "$OUT" ] || {
  printf '%s\n' "$OUT" >&2
  fail "Case C.2: tsc exited 0 but printed diagnostics on a clean tree"
}
echo "PASS Case C.2: tsc passes on clean state with no diagnostics"
echo ""

# ─── Case D: the assertions above are themselves not vacuous ──────────────────
# Cases A-C run real tools; this one feeds the two predicates canned output, so it is
# instant and hermetic. It pins the exact regression this file was rewritten for.
echo "--- Case D: the assertions reject a tool that never ran ---"

# The literal output the historical Case B accepted as proof of a caught divergence.
if divergence_diagnostics_ok 1 "mise ERROR No version is set for shim: tsc
Set a global default version with one of the following:
mise use -g node@24.9.0" 2>/dev/null; then
  fail "Case D: the divergence assertion accepted a tsc that never launched"
fi
echo "PASS Case D.1: 'No version is set for shim: tsc' (exit 1) is rejected, not credited"

# A tsc that ran but found something unrelated must not be credited either.
if divergence_diagnostics_ok 2 "generated/types.ts(3,1): error TS1005: ';' expected." 2>/dev/null; then
  fail "Case D: the divergence assertion accepted a diagnostic from outside _assert.ts"
fi
echo "PASS Case D.2: an unrelated diagnostic outside _assert.ts is rejected"

# Only ONE of the two assignability directions tripping means the tripwire is half
# working — e.g. an _assert.ts that lost its second declaration.
if divergence_diagnostics_ok 2 "generated/_assert.ts(5,7): error TS2741: Property 'variants' is missing in type 'X' but required in type 'Y'." 2>/dev/null; then
  fail "Case D: the divergence assertion accepted only one assignability direction"
fi
echo "PASS Case D.3: a single-direction failure is rejected"

# Same treatment for Case A: zig failing before it reaches the diff step is not drift.
if api_check_drift_ok 1 "error: unable to find zig installation directory" 2>/dev/null; then
  fail "Case D: the api-check assertion accepted a build that never reached the diff step"
fi
echo "PASS Case D.4: an api-check that failed before the git-diff step is rejected"

echo ""

# ─── Clean-tree assertion ──────────────────────────────────────────────────────
# Belt-and-braces: the EXIT trap enforces this on every path, including the failure
# paths above. Asserting it here too means a leak is reported as a drift.sh failure
# with the cases named, rather than as a bare trap message.
echo "--- Clean-tree assertion ---"
LEFTOVER=$(dirty_paths)
if [ -n "$LEFTOVER" ]; then
  printf '%s\n' "$LEFTOVER" >&2
  fail "tracked files under ${MUTATES[*]} are dirty after the drift cases"
fi
echo "PASS: working tree is clean (no modified/deleted tracked files under ${MUTATES[*]})"

echo ""
echo "=== All drift cases caught + clean tree verified ==="
