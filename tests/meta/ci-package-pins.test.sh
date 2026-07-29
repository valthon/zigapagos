#!/usr/bin/env bash
# Self-tests for tests/meta/ci-package-pins.sh.
#
# WHY. The gate is a regex over workflow text, and a regex gate has one failure
# mode worse than being wrong: being VACUOUS. A pattern that matches nothing —
# because a character class was mistyped, or because the file list went empty —
# prints PASS on every tree forever, and reads in review as coverage. Both
# assertions tests/meta/script-coverage.sh's header records rotted exactly that
# way. So every rule is pinned from both sides here: the smallest workflow the
# gate must reject, and the nearest one it must accept.
#
# Each case is a THROWAWAY GIT REPOSITORY under $TMPDIR with the gate copied in,
# because the gate is `git ls-files` + awk over tracked workflow files and there
# is no other way to hand it a fixture. Nothing here touches this checkout.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GATE="$PWD/tests/meta/ci-package-pins.sh"
REL=tests/meta/ci-package-pins.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
case_n=0
d=""
declare -a FIXTURES=()

newcase() {
  case_n=$((case_n + 1))
  d="$TMP/case$case_n"
  mkdir -p "$d/tests/meta"
  cp "$GATE" "$d/$REL"
  git -C "$d" init -q
  FIXTURES=("$REL")
}

workflow() { # $1 basename; body on stdin
  mkdir -p "$d/.github/workflows"
  cat >| "$d/.github/workflows/$1"
  FIXTURES+=(".github/workflows/$1")
}

check() { # $1 name, $2 expected exit, $3 required substring ("" = none)
  local name=$1 want=$2 needle=${3:-} out status
  git -C "$d" add -- "${FIXTURES[@]}"
  set +e
  out=$( cd "$d" && bash "$REL" 2>&1 )
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

# ── The runners it must catch ────────────────────────────────────────────────

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: bunx serve -l 8080 out
EOF
check "an unpinned bunx is caught" 1 "bunx serve"

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx some-tool --flag
EOF
check "an unpinned npx is caught" 1 "npx some-tool"

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: bun x some-tool
EOF
check "the spaced 'bun x' spelling is caught" 1 "bun x"

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: pnpm dlx some-tool
EOF
check "pnpm dlx is caught" 1 "pnpm dlx"

# ── What it must NOT flag ────────────────────────────────────────────────────

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: bunx serve@14.2.4 -l 8080 out
EOF
check "a pinned runner passes" 0 "PASS"

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: npx --yes some-tool@1 --flag
EOF
check "a pinned runner behind a flag passes" 0 "PASS"

# This is the case the gate's own subject depends on: browser-e2e.yml now
# carries a comment naming `bunx serve` to explain why it no longer runs it.
newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      # python3's stdlib server, and NOT `bunx serve` — see #50.
      - run: python3 -m http.server 8080 --directory out
EOF
check "a comment naming the runner is not a hit" 0 "PASS"

newcase
workflow ci.yml <<'EOF'
jobs:
  a:
    steps:
      - run: bun install --frozen-lockfile
      - run: bun run scripts/gen-docs-mirror.ts
      - run: bun test
EOF
check "bun install/run/test are not package runners" 0 "PASS"

# ── Anti-vacuity ─────────────────────────────────────────────────────────────
# The single most likely way for this gate to stop working is for its input set
# to become empty without anyone noticing.

newcase
check "an empty workflow set fails instead of passing quietly" 1 "no tracked workflow files"

echo
if [ "$fail" -gt 0 ]; then
  echo "FAIL: $fail of $((pass + fail)) ci-package-pins self-tests failed"
  exit 1
fi
echo "PASS: $pass ci-package-pins self-tests"
