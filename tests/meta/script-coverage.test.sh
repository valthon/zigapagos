#!/usr/bin/env bash
# Self-test for tests/meta/script-coverage.sh, in the shape of
# scripts/check-allocator-contracts.test.sh: every case builds a throwaway git
# repo in $TMPDIR and runs the REAL gate against it, so nothing here reads or
# writes the actual tree.
#
# WHY IT EXISTS NOW. That gate has shipped three real defects already — an
# inventory that vouched for itself, a `pipefail` + `grep -q` SIGPIPE race, and
# a comment filter applied to one rule but not the other — and every one of them
# made it PASS when it should have failed. A gate whose failure mode is a false
# green needs its own tests more than most code does.
#
# The immediate trigger is that tests/meta/unrun-scripts.txt is now EMPTY, and
# emptying it silently removed the only thing pinning the comment filter. That
# filter (`named_outside_comments`) is what stops a script that a workflow merely
# MENTIONS in prose from counting as run. It used to be pinned by accident:
# ci.yml's e2e-dev-loop comment spells out
# examples/tsx-site/test/{hydrate,spa_slice}.sh, and while those two were also
# inventoried, dropping the filter made the gate see them as both CI-run and
# listed, and rule 1 failed loudly by name. Now that they are genuinely run by
# browser-e2e.yml, nothing in the tree is inventoried at all, so removing the
# filter would break NOTHING and the gate would go back to passing vacuously for
# the next script somebody only writes a comment about.
#
# Cases 5 and 6 replace that accident with a real test. Cases 1 and 2 pin the
# empty-inventory state itself: an empty file must pass, and must still fail on a
# script nothing runs.
set -euo pipefail

gate="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/script-coverage.sh"
[ -f "$gate" ] || { echo "FAIL: cannot find script-coverage.sh next to this file" >&2; exit 1; }
failures=0

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

# make_repo <dir> — a minimal tree with the two shapes the gate cares about:
#   tests/e2e/hermetic.sh   matched by ci.yml's `tests/*/*.sh` glob, so the gate's
#                           rule (a) counts it as CI-run with no mention anywhere.
#   proj/test/browser.sh    a per-project script (the site/test and
#                           examples/*/test shape), which rule (a) does NOT cover —
#                           it is CI-run only if a workflow names it. This is the
#                           script the interesting cases move around.
# Nothing is committed: `git add` is enough for both `git ls-files` and
# `git grep`, and skipping the commit keeps the fixture free of any need for a
# configured identity.
make_repo() {
    local d="$1"
    mkdir -p "$d/.github/workflows" "$d/tests/e2e" "$d/tests/meta" "$d/proj/test"
    printf '#!/usr/bin/env bash\necho ok\n' >"$d/tests/e2e/hermetic.sh"
    printf '#!/usr/bin/env bash\necho ok\n' >"$d/proj/test/browser.sh"
    printf 'name: CI\njobs:\n  a:\n    steps:\n      - run: echo hi\n' >"$d/.github/workflows/ci.yml"
    : >"$d/tests/meta/unrun-scripts.txt"
    git -C "$d" init -q
    git -C "$d" add -A
}

# expect <exit-code> <name> <dir>
expect() {
    local want="$1" name="$2" dir="$3" got=0 out
    out="$( cd "$dir" && bash "$gate" 2>&1 )" || got=$?
    if [ "$got" -eq "$want" ]; then
        echo "ok   — $name"
    else
        echo "FAIL — $name (want exit $want, got $got)"
        printf '%s\n' "$out" | sed 's/^/       | /'
        failures=$((failures + 1))
    fi
}

# --- case 1: EMPTY inventory, every script CI-run -> passes ------------------
# The state this repository is now in. An inventory of nothing but comments must
# parse to zero rows and produce a clean pass, not a parse error and not a
# vacuous one.
make_repo "$t/c1"
cat >"$t/c1/.github/workflows/ci.yml" <<'EOF'
name: CI
jobs:
  a:
    steps:
      - run: bash proj/test/browser.sh
EOF
git -C "$t/c1" add -A
expect 0 "empty inventory + every script CI-run passes" "$t/c1"

# --- case 2: EMPTY inventory + a script nothing runs -> fails ---------------
# The gate must still BITE when the inventory is empty. If emptying the file had
# made the LISTED map's absence read as "everything is fine", this is the case
# that would have caught it.
make_repo "$t/c2"
expect 1 "empty inventory + an unrun, unlisted script fails" "$t/c2"

# --- case 3: a row for a script CI ALSO runs -> fails (stale row) -----------
make_repo "$t/c3"
cat >"$t/c3/.github/workflows/ci.yml" <<'EOF'
name: CI
jobs:
  a:
    steps:
      - run: bash proj/test/browser.sh
EOF
printf 'proj/test/browser.sh\tneeds a browser\n' >"$t/c3/tests/meta/unrun-scripts.txt"
git -C "$t/c3" add -A
expect 1 "a row for a script CI runs fails (stale inventory)" "$t/c3"

# --- case 4: a row for a script that does not exist -> fails ---------------
make_repo "$t/c4"
printf 'proj/test/browser.sh\tneeds a browser\ntests/gone/deleted.sh\tdeleted last week\n' \
    >"$t/c4/tests/meta/unrun-scripts.txt"
git -C "$t/c4" add -A
expect 1 "a row for a non-existent script fails" "$t/c4"

# --- case 5: named ONLY in a workflow COMMENT -> NOT CI-run ----------------
# THE PIN. A workflow that explains why it does not run a script must not be
# read as running it. With the inventory empty this is the only thing in the
# repository that fails if `named_outside_comments` loses its comment filter —
# verified by deleting the `grep -v '^[[:space:]]*#'` line and watching this
# case, and only this case, go red.
make_repo "$t/c5"
cat >"$t/c5/.github/workflows/ci.yml" <<'EOF'
name: CI
jobs:
  a:
    steps:
      # Deliberately NOT run here: proj/test/browser.sh needs a browser.
      - run: echo hi
EOF
git -C "$t/c5" add -A
expect 1 "a script named only in a workflow COMMENT is not counted as CI-run" "$t/c5"

# --- case 6: named on a real workflow line -> IS CI-run --------------------
# The other half of case 5: comment-awareness must not have become "never
# believe a workflow". This is the case that browser-e2e.yml's matrix and
# pages.yml's `bash site/test/build.sh` step both rely on.
make_repo "$t/c6"
cat >"$t/c6/.github/workflows/browser.yml" <<'EOF'
name: Browser
on:
  schedule:
    - cron: "27 4 * * *"
jobs:
  b:
    strategy:
      matrix:
        include:
          - script: proj/test/browser.sh
    steps:
      - run: bash "$SCRIPT"
EOF
git -C "$t/c6" add -A
expect 0 "a script named on a NON-comment workflow line counts as CI-run" "$t/c6"

# --- case 7: a row with no reason -> fails --------------------------------
# The inventory's whole value is the written justification; a bare path is a row
# nobody can re-evaluate later.
make_repo "$t/c7"
printf 'proj/test/browser.sh\n' >"$t/c7/tests/meta/unrun-scripts.txt"
git -C "$t/c7" add -A
expect 1 "an inventory row with no reason fails" "$t/c7"

if [ "$failures" -gt 0 ]; then
    echo "" >&2
    echo "$failures case(s) failed." >&2
    exit 1
fi
echo "PASS: script-coverage.sh — 7 cases"
