#!/usr/bin/env bash
# tests/contract/rails-drift.sh — proves `zig build rails-check` (the Rails
# manifest JSON Schema drift gate, `build/rails_schema.zig` /
# `src/cli/rails/schema_gen.zig`) is NOT vacuous.
#
# Modeled directly on `contract/test/drift.sh` (read its header first). That
# script's header documents a trap this repo already paid for once:
#
#   A gate written to prove another gate is not vacuous was itself vacuous.
#   contract/ has no node_modules, so `bun x tsc` resolved `tsc` off PATH,
#   hit mise's shim, and died with `mise ERROR No version is set for shim:
#   tsc` — exit 1, tsc never started, and the script printed PASS. An exit
#   status alone cannot tell "the compiler found the divergence" from "the
#   compiler could not launch."
#
# `rails-check` has no external compiler/PATH-shim to be fooled by (it is
# entirely `zig build` steps: regenerate -> `git add` -> `git diff --cached
# --exit-code`, see `build/rails_schema.zig`), but it has the exact same
# SHAPE of risk: a build-graph failure that happens BEFORE the diff step
# (the regenerator itself refusing to run) is also non-zero, also produces
# build output, and an assertion that only checks the exit code cannot tell
# it apart from a genuinely-caught schema drift. So every case below asserts
# on the DIAGNOSTIC TEXT — the specific failing build step, and (where
# relevant) the diff hunk — and treats the exit status as necessary but not
# sufficient.
#
# Cases:
#   A. Schema drift — a manifest.zig TYPE changes (RubyStatus.available ->
#      present); the committed contract/rails-presentation.v1.schema.json
#      does not, so rails-check must fail at the git-diff step and show the
#      rename in the diff hunk.
#   B. Committed-schema drift — contract/rails-presentation.v1.schema.json
#      itself is hand-edited AND committed (a throwaway local commit,
#      reverted before this script exits) without touching manifest.zig, so
#      the regenerated content — correct, and un-mutatable by the hand-edit,
#      since the generator OVERWRITES the working-tree file before `git add`
#      ever sees it — disagrees with what got committed. Needs a real commit
#      because `git diff --cached` compares the index to HEAD: editing only
#      the working tree is silently healed by the regenerate-then-diff
#      order and proves nothing (see the case's own comment below for the
#      empirical trap this avoids).
#   C. Clean-tree control — without this, A and B would both be satisfied by
#      a gate that fails unconditionally, which is exactly as useless as one
#      that passes unconditionally and less obvious.
#   D. Generator launch-failure — the launch-failure shape from drift.sh's
#      header, reproduced for real rather than with canned text: the
#      generator (`schema_gen.zig`'s `main`) is made to exit before writing
#      anything. rails-check must still fail (loud, not a silent pass), and
#      — this is the point — the SAME predicate used to credit Case A/B with
#      "caught the drift" must REJECT this output: a generator that never
#      ran is not evidence of caught drift, and crediting it as such would
#      be exactly the defect drift.sh's header describes, reproduced here.
#
# Guarantees: the EXIT trap restores the working tree AND HEAD on every path
# — success, an assertion failure, an unexpected error, SIGINT/SIGTERM — and
# the trap itself fails the script if anything it mutated is still dirty
# afterwards. CI runs this in a shared checkout, where a leaked mutation (or
# a leaked throwaway commit) would corrupt whatever script runs next.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ── Failure helper ─────────────────────────────────────────────────────────────
fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

# ── Restore + clean-tree guarantee ─────────────────────────────────────────────
# EXACTLY the paths this script mutates, and no others — see drift.sh's identical
# comment on why widening this list "just to be safe" is the opposite of safe.
MUTATES=(
  contract/rails-presentation.v1.schema.json
  src/cli/rails/manifest.zig
  src/cli/rails/schema_gen.zig
)

# Captured before any mutation. Case B commits a throwaway fixture (the only way to
# make a hand-edited, but never-committed, schema file matter to `git diff --cached`,
# which compares the INDEX to HEAD) — the EXIT trap must move HEAD back to this SHA on
# every path, not just restore file content, or a leaked local commit corrupts
# whatever runs next in a shared checkout.
ORIGINAL_HEAD=$(git rev-parse HEAD)

dirty_paths() {
  # Untracked files (`??`) are ignored: a stray editor file is not this script's
  # business, and only tracked state can be "restored" in the first place.
  git status --porcelain -- "${MUTATES[@]}" | grep -v '^??' || true
}

restore_tree() {
  # HEAD first: if Case B's throwaway commit is still current, move HEAD back to
  # ORIGINAL_HEAD via a SOFT reset (touches only the ref, never the index or working
  # tree) BEFORE restoring file content below — otherwise the checkout that follows
  # would restore against the throwaway commit instead of the real one.
  local current_head
  current_head=$(git rev-parse HEAD 2>/dev/null || true)
  if [ -n "$current_head" ] && [ "$current_head" != "$ORIGINAL_HEAD" ]; then
    git reset --soft "$ORIGINAL_HEAD" 2>/dev/null || true
  fi

  # `git checkout HEAD -- <path>` updates BOTH the index and the working tree, so it
  # also undoes the `git add` that rails-check performs internally.
  git checkout HEAD -- "${MUTATES[@]}" 2>/dev/null || true
}

on_exit() {
  local rc=$?
  restore_tree
  local leftover head_now
  leftover=$(dirty_paths)
  head_now=$(git rev-parse HEAD 2>/dev/null || true)
  if [ -n "$leftover" ] || [ "$head_now" != "$ORIGINAL_HEAD" ]; then
    printf 'FAIL: rails-drift.sh could not restore the working tree:\n' >&2
    [ -n "$leftover" ] && printf '%s\n' "$leftover" >&2
    if [ "$head_now" != "$ORIGINAL_HEAD" ]; then
      printf 'HEAD is %s, expected %s -- a fixture commit was not reverted\n' \
        "$head_now" "$ORIGINAL_HEAD" >&2
    fi
    rc=1
  fi
  exit "$rc"
}

trap on_exit EXIT
# The signal handlers exist only so the EXIT trap gets a chance to run: bash does not
# fire an EXIT trap for an untrapped fatal signal, so a Ctrl-C without these would
# leave a mutated schema, a mutated manifest/generator, or a leaked fixture commit
# behind.
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== rails-drift.sh: proving the Rails manifest schema drift gate is not vacuous ==="
echo ""

# ── Pre-flight: nothing we are about to overwrite may already be dirty ─────────
PREEXISTING=$(dirty_paths)
if [ -n "$PREEXISTING" ]; then
  fail "these paths are already modified, and rails-drift.sh would discard the changes when it restores:
$PREEXISTING
  Commit or stash them first."
fi

# ── Runner ───────────────────────────────────────────────────────────────────────
# Captures combined output AND the real exit status. `out=$(...) || rc=$?` rather than
# a pipeline: `cmd | tail` reports tail's status, and this whole file exists because of
# an exit status that meant something other than what it looked like.
OUT=""
RC=0

run_rails_check() {
  OUT=""
  RC=0
  OUT=$(zig build rails-check 2>&1) || RC=$?
}

# ── Assertions (written as predicates, so Case D can feed a real captured failure
#    to the SAME predicate Case A/B use, proving it is not fooled) ─────────────

# The step name zig's build summary renders for the diff step failing is the literal
# below: `build/rails_schema.zig`'s `diff.setName(...)` PLUS zig's own "<name> failure"
# suffix on a failed leaf step -- not a typo'd step name. Requiring THIS exact string
# (not merely present somewhere, but reached as a LEAF failure -- see Case D, where the
# same step instead renders "... transitive failure" because it never got to run) rules
# out a failure anywhere else in the graph masquerading as caught drift.
DIFF_LEAF_FAILURE='git diff contract/rails-presentation.v1.schema.json failure'

# The generator's own Run step failing is rendered with this exact leaf-failure suffix
# by `build/rails_schema.zig`'s `run.setName(...)`.
GEN_LEAF_FAILURE='rails_schema_gen contract/rails-presentation.v1.schema.json failure'

# `removed`/`added` are the exact diff-hunk lines the two real cases below expect.
rails_check_drift_ok() {
  local rc="$1" out="$2" removed="$3" added="$4"
  if [ "$rc" -eq 0 ]; then
    echo "  reject: rails-check exited 0" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "$DIFF_LEAF_FAILURE"; then
    echo "  reject: rails-check failed somewhere other than the git-diff step" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "$removed"; then
    echo "  reject: staged diff is missing the expected removed line: $removed" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "$added"; then
    echo "  reject: staged diff is missing the expected added line: $added" >&2
    return 1
  fi
  return 0
}

# Case D's predicate: the generator's OWN step must be the thing that failed, and —
# the whole point of this case — the drift predicate above's leaf-failure marker must
# NOT appear (it renders "... transitive failure" here instead, since the diff step
# never got to run at all). A launch failure and a caught drift are different SHAPES of
# build output, not just different exit codes, and this predicate is what tells them
# apart.
rails_check_launch_failure_ok() {
  local rc="$1" out="$2"
  if [ "$rc" -eq 0 ]; then
    echo "  reject: rails-check exited 0" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "$GEN_LEAF_FAILURE"; then
    echo "  reject: the generator's own step is not reported as the leaf failure" >&2
    return 1
  fi
  if printf '%s\n' "$out" | grep -qF "$DIFF_LEAF_FAILURE"; then
    echo "  reject: output contains the drift-caught leaf marker -- a launch failure must not look like caught drift" >&2
    return 1
  fi
  return 0
}

# ─── Case A: rails-check catches schema drift (a manifest.zig type change) ────
echo "--- Case A: rails-check catches schema drift (manifest.zig type change) ---"

# `available: bool,` occurs exactly once in manifest.zig (src/cli/rails/manifest.zig's
# RubyStatus -- confirmed via `grep -c` below, not assumed), so this is scoped to the
# one field it is meant to touch without needing a fragile line-number anchor. The
# second edit renames the same field's KEY at its one construction site
# (`.available = d.ruby.available`); the right-hand side is a DIFFERENT type's field
# (`rails.Discovery.ruby.available`, from `RubyInfo` -- not `manifest.RubyStatus`) and
# must not change.
mutate_manifest_type() {
  local count
  count=$(grep -cF 'available: bool,' src/cli/rails/manifest.zig)
  [ "$count" -eq 1 ] ||
    fail "expected exactly one 'available: bool,' in manifest.zig, found $count -- mutate_manifest_type's anchor is no longer unique"
  perl -i -pe 's/\bavailable: bool,/present: bool,/' src/cli/rails/manifest.zig
  perl -i -pe 's/\.available = d\.ruby\.available,/.present = d.ruby.available,/' src/cli/rails/manifest.zig
  grep -qF 'present: bool,' src/cli/rails/manifest.zig ||
    fail "the manifest mutation did not apply -- manifest.zig has no 'present: bool,'"
  grep -qF '.present = d.ruby.available,' src/cli/rails/manifest.zig ||
    fail "the manifest mutation did not apply -- manifest.zig has no '.present = d.ruby.available,'"
}

mutate_manifest_type

run_rails_check
rails_check_drift_ok "$RC" "$OUT" \
  '-            "available": {' \
  '+            "present": {' || {
  printf 'rails-check exit %s, output:\n%s\n' "$RC" "$OUT" >&2
  fail "Case A: rails-check did not reject the manifest type drift"
}
# Second, independent assertion pair: the SAME rename also has to move in the
# schema's `required` array, not just the property key -- a generator that updated
# one occurrence but not the other would still (correctly) be caught here, but this
# nails down that the diagnostic shows BOTH.
if ! printf '%s\n' "$OUT" | grep -qF -- '-            "available",'; then
  fail "Case A: staged diff does not drop 'available' from the required array"
fi
if ! printf '%s\n' "$OUT" | grep -qF -- '+            "present",'; then
  fail "Case A: staged diff does not add 'present' to the required array"
fi
echo "PASS Case A: rails-check rejected the stale generated schema at the git-diff step, showing the available->present hunk in both the property key and the required array (exit $RC)"

restore_tree
echo ""

# ─── Case B: rails-check catches committed-schema drift ───────────────────────
echo "--- Case B: rails-check catches committed-schema drift (hand-edited + committed schema.json) ---"
echo ""
echo "  NOTE: a hand-edit to contract/rails-presentation.v1.schema.json that is only"
echo "  in the WORKING TREE cannot trigger this gate -- rails-check's generator"
echo "  OVERWRITES the working-tree file with fresh output before 'git add' ever runs,"
echo "  so 'git diff --cached' (index vs HEAD) compares the regenerated, CORRECT"
echo "  content against an unchanged, already-correct HEAD, and rails-check passes."
echo "  Verified empirically while writing this script: editing only the working tree"
echo "  produced exit 0 and an empty diff. The only way to make a hand-edit to the"
echo "  generated file actually diverge from what a fresh regen produces is for HEAD"
echo "  itself to hold the bad content -- hence the throwaway commit below, reverted"
echo "  by restore_tree before this script exits on every path."

sed -i '13s/"minimum": 0/"minimum": 999/' contract/rails-presentation.v1.schema.json
grep -qF '"minimum": 999' contract/rails-presentation.v1.schema.json ||
  fail "the schema mutation did not apply -- contract/rails-presentation.v1.schema.json has no '\"minimum\": 999'"

git add contract/rails-presentation.v1.schema.json
git commit --quiet -m "TEMP fixture: tests/contract/rails-drift.sh Case B -- must not survive this script"

run_rails_check
rails_check_drift_ok "$RC" "$OUT" \
  '-      "minimum": 999' \
  '+      "minimum": 0' || {
  printf 'rails-check exit %s, output:\n%s\n' "$RC" "$OUT" >&2
  fail "Case B: rails-check did not reject the committed schema drift"
}
echo "PASS Case B: rails-check rejected the hand-tampered committed schema at the git-diff step, showing the 999->0 reversal (exit $RC)"

restore_tree
echo ""

# ─── Case C: clean state passes ────────────────────────────────────────────────
# The control for A, B and D. Without it, a gate that failed unconditionally would
# score three passes above.
echo "--- Case C: clean state passes ---"

run_rails_check
[ "$RC" -eq 0 ] || {
  printf '%s\n' "$OUT" >&2
  fail "Case C: rails-check should pass on a clean tree but exited $RC"
}
[ -z "$OUT" ] || {
  printf '%s\n' "$OUT" >&2
  fail "Case C: rails-check exited 0 but printed output on a clean tree"
}
echo "PASS Case C: rails-check passes on clean state with no output"
echo ""

# ─── Case D: rails-check notices if the generator itself stopped running ──────
# The launch-failure shape from drift.sh's header, reproduced for real: schema_gen's
# `main` is made to exit before it writes anything, simulating the generator
# crashing / never starting. This proves TWO things at once:
#   1. rails-check does not silently pass when the generator can't run (a "no diff"
#      because nothing regenerated would be indistinguishable from "no drift" to an
#      exit-code-only check).
#   2. The predicate this script uses to credit Case A/B with "caught the drift"
#      (rails_check_drift_ok, keyed on the git-diff leaf-failure marker) correctly
#      REJECTS this output -- i.e. this script itself would not have mistaken a
#      broken generator for a caught drift, which is exactly the defect drift.sh's
#      header describes.
echo "--- Case D: rails-check notices a generator that stops running ---"

MARKER='SIMULATED rails-drift.sh Case D: generator stopped running'
perl -i -pe "s/pub fn main\(init: std\.process\.Init\) !void \{/pub fn main(init: std.process.Init) !void {\n    fatal(\"$MARKER\\\\n\", .{});/" \
  src/cli/rails/schema_gen.zig
grep -qF "$MARKER" src/cli/rails/schema_gen.zig ||
  fail "the generator mutation did not apply -- schema_gen.zig does not contain the Case D marker"

run_rails_check
rails_check_launch_failure_ok "$RC" "$OUT" || {
  printf 'rails-check exit %s, output:\n%s\n' "$RC" "$OUT" >&2
  fail "Case D: rails-check either passed despite the broken generator, or its failure looked like caught drift"
}
if ! printf '%s\n' "$OUT" | grep -qF "$MARKER"; then
  fail "Case D: rails-check's failure output does not contain the injected marker -- the failure may not be caused by this mutation"
fi
echo "PASS Case D: rails-check failed loudly when the generator stopped running (exit $RC), reporting the generator's own step as the leaf failure -- and NOT the git-diff leaf-failure marker Case A/B rely on"

# Cross-check: feed THIS case's real captured output to the Case A/B predicate
# directly (not canned text -- an actual build failure this run produced) and
# confirm it is rejected. This is the recursive check: the predicate that credits
# Case A and Case B with "caught the drift" must not ALSO credit this.
if rails_check_drift_ok "$RC" "$OUT" 'anything' 'anything' 2>/dev/null; then
  fail "Case D: the drift-caught predicate accepted a generator that never ran"
fi
echo "PASS Case D: the Case A/B drift predicate rejects this run's real output, confirming it is not fooled by a launch failure"

restore_tree
echo ""

# ─── Clean-tree assertion ──────────────────────────────────────────────────────
# Belt-and-braces: the EXIT trap enforces this on every path, including the failure
# paths above. Asserting it here too means a leak is reported as a rails-drift.sh
# failure with the cases named, rather than as a bare trap message.
echo "--- Clean-tree assertion ---"
LEFTOVER=$(dirty_paths)
HEAD_NOW=$(git rev-parse HEAD)
if [ -n "$LEFTOVER" ]; then
  printf '%s\n' "$LEFTOVER" >&2
  fail "tracked files under ${MUTATES[*]} are dirty after the drift cases"
fi
if [ "$HEAD_NOW" != "$ORIGINAL_HEAD" ]; then
  fail "HEAD is $HEAD_NOW, expected $ORIGINAL_HEAD -- Case B's fixture commit was not reverted"
fi
echo "PASS: working tree is clean and HEAD is back at $ORIGINAL_HEAD"

echo ""
echo "=== All rails-check drift cases caught + clean tree verified ==="
