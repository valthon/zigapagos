#!/usr/bin/env bash
# Self-tests for tests/meta/npm-oidc.sh.
#
# WHY. The gate is text matching over a YAML file, and a text gate's worst failure
# is not being wrong — it is being VACUOUS. A rule that matches nothing (a mistyped
# character class, a file that is not there, a job block that extracted zero lines)
# prints PASS on every tree forever and reads in review as coverage. That is doubly
# bad here: the property it guards is otherwise only tested by cutting a release.
# So every rule is pinned from BOTH sides below — the smallest workflow it must
# reject, and the nearest one it must accept.
#
# Each case is a THROWAWAY GIT REPOSITORY under $TMPDIR with the gate copied in,
# because the gate resolves its target from `git rev-parse --show-toplevel` and a
# repository root is the only handle it takes. Nothing here touches this checkout.
# Same shape as tests/meta/ci-package-pins.test.sh, deliberately.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GATE="$PWD/tests/meta/npm-oidc.sh"
REL=tests/meta/npm-oidc.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
case_n=0
d=""

newcase() {
  case_n=$((case_n + 1))
  d="$TMP/case$case_n"
  mkdir -p "$d/tests/meta"
  cp "$GATE" "$d/$REL"
  git -C "$d" init -q
}

workflow() { # $1 basename; body on stdin
  mkdir -p "$d/.github/workflows"
  cat >| "$d/.github/workflows/$1"
}

# A full release.yml the gate is happy with — two jobs, `needs:`, the lot — so the
# accepting case is a realistic tree rather than the minimum that squeaks through.
good_release() {
  workflow release.yml <<'EOF'
name: Release
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - run: echo release
  publish-npm:
    if: github.event_name == 'push' && vars.NPM_PUBLISH_ENABLED == 'true'
    needs: [npm-package, publish]
    runs-on: ubuntu-latest
    permissions:
      id-token: write
    steps:
      - run: node npm/publish.mjs --publish --provenance
EOF
}

check() { # $1 name, $2 expected exit, $3 required substring ("" = none)
  local name=$1 want=$2 needle=${3:-} out status
  set +e
  out=$(cd "$d" && bash "$REL" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne "$want" ]; then
    echo "FAIL: $name — expected exit $want, got $status"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: $name — exit $status was right but the message never said '$needle'"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
    return
  fi
  pass=$((pass + 1))
}

# ── The shape it must accept ─────────────────────────────────────────────────

newcase
good_release
check "the OIDC shape passes" 0 "PASS"

# ── Rule 1: the OIDC permission ──────────────────────────────────────────────

newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    if: github.event_name == 'push' && vars.NPM_PUBLISH_ENABLED == 'true'
    permissions:
      contents: read
    steps:
      - run: node npm/publish.mjs --publish --provenance
EOF
check "a missing id-token: write is caught" 1 "does not grant"

# Block scoping, from the side that actually matters: `id-token: write` belonging to
# a LATER job must not vouch for this one. Without the block extraction this fixture
# would pass, so it pins the awk rather than the grep.
newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    if: github.event_name == 'push' && vars.NPM_PUBLISH_ENABLED == 'true'
    steps:
      - run: node npm/publish.mjs --publish --provenance
  something-else:
    permissions:
      id-token: write
    steps:
      - run: echo unrelated
EOF
check "a later job's id-token does not satisfy the rule" 1 "does not grant"

# ── Rule 2: the two gating conditions ────────────────────────────────────────

newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    if: github.event_name == 'push'
    permissions:
      id-token: write
    steps:
      - run: node npm/publish.mjs --publish --provenance
EOF
check "dropping the NPM_PUBLISH_ENABLED arming switch is caught" 1 "NPM_PUBLISH_ENABLED"

newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    if: vars.NPM_PUBLISH_ENABLED == 'true'
    permissions:
      id-token: write
    steps:
      - run: node npm/publish.mjs --publish --provenance
EOF
check "dropping the tag-push condition is caught" 1 "github.event_name == 'push'"

newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    permissions:
      id-token: write
    steps:
      - run: node npm/publish.mjs --publish --provenance
EOF
check "no condition at all is caught" 1 "has no 'if:'"

# Both conditions must be ONE expression. Two `if:` lines — a job-level one and a
# step-level one — would satisfy a rule that merely looked for both strings
# somewhere in the block, and would publish on every push.
newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    if: github.event_name == 'push'
    permissions:
      id-token: write
    steps:
      - run: node npm/publish.mjs --publish --provenance
        if: vars.NPM_PUBLISH_ENABLED == 'true'
EOF
check "the two conditions must be one expression, not two if: lines" 1 "NPM_PUBLISH_ENABLED"

# …but a step-level `if:` alongside a complete job-level one is ordinary and fine.
newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-npm:
    if: github.event_name == 'push' && vars.NPM_PUBLISH_ENABLED == 'true'
    permissions:
      id-token: write
    steps:
      - run: echo diagnostics
        if: failure()
      - run: node npm/publish.mjs --publish --provenance
EOF
check "a step-level if: alongside the job-level one is fine" 0 "PASS"

# ── Anti-vacuity ─────────────────────────────────────────────────────────────
# The two ways this gate could quietly stop checking anything: the file it reads
# is not there, or it is there and the job it looks for is not.

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: echo hi
EOF
check "a missing release.yml fails instead of passing quietly" 1 "does not exist"

# A renamed job is a real event with a real consequence — the trusted publishers on
# npmjs.com name the workflow file — so it must be loud rather than a no-op.
newcase
workflow release.yml <<'EOF'
name: Release
jobs:
  publish-to-npm:
    if: github.event_name == 'push' && vars.NPM_PUBLISH_ENABLED == 'true'
    permissions:
      id-token: write
    steps:
      - run: node npm/publish.mjs --publish --provenance
EOF
check "a renamed job fails instead of checking nothing" 1 "has no 'publish-npm:' job"

echo
if [ "$fail" -gt 0 ]; then
  echo "FAIL: $fail of $((pass + fail)) npm-oidc self-tests failed"
  exit 1
fi
echo "PASS: $pass npm-oidc self-tests"
