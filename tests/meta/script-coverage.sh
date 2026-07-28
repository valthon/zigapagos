#!/usr/bin/env bash
# Every test script is either RUN by CI, or listed — with a reason — as knowingly not.
#
# WHY THIS EXISTS. Two separate assertions in this repository were found rotted in one
# session, and both had the same cause: nothing ran the file, so nothing noticed.
#
#   contract/test/drift.sh   Case B asserted only a non-zero exit. `bun x tsc` could not
#                            launch (no node_modules in contract/), which is also
#                            non-zero, so it printed PASS while type-checking nothing.
#   examples/tsx-site/test/spa.sh
#                            asserted the UNQUOTED nginx spelling
#                            `try_files $uri $uri/ /app/index.html;`. emit-host-config.ts
#                            has emitted the nginxQuote()d form since that helper landed,
#                            so the grep had matched nothing for as long as it existed.
#
# Neither is a hard problem to fix once seen. The problem is seeing it. A test outside
# CI does not stay correct — it decays silently, and its green-looking source is worse
# than no test, because a reader counts it as coverage.
#
# So this gate makes the coverage boundary EXPLICIT and reviewed. Adding a test script
# that nothing runs is no longer something that can happen by accident: it fails here
# until someone either wires it into CI or writes down why it is not. That is the same
# shape as scripts/allocator-allowlist.txt + scripts/check-allocator-contracts.sh — an
# inventory with a written justification per row, enforced by a gate that fails on a new
# unlisted entry.
#
# It is a pure `git ls-files` + `grep` over tracked text: no toolchain, no build, no
# network, sub-second. It runs in CI's `tests/*/*.sh` glob like everything else here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

INVENTORY=tests/meta/unrun-scripts.txt

# The candidate set is scripts whose PURPOSE is to assert: the tests/ tree, the
# per-project test/ directories, and scripts/*.test.sh. Production gate scripts
# (scripts/assert-version.sh and friends) are deliberately out of scope — they are
# invoked by the thing they gate, and their own self-tests ARE in the set.
mapfile -t CANDIDATES < <(
  git ls-files -- 'tests/*.sh' 'tests/**/*.sh' '*/test/*.sh' '*/*/test/*.sh' 'scripts/*.test.sh' | sort
)
[ "${#CANDIDATES[@]}" -gt 0 ] || { echo "FAIL: found no test scripts at all — the globs or the layout changed" >&2; exit 1; }

# True when $1 appears on a NON-COMMENT line of some file matching the pathspecs in
# $2… . Two details in here are load-bearing rather than tidy:
#
# COMMENT-AWARE. A file that MENTIONS a script in prose does not run it. Several
# scripts under tests/ cite siblings in their headers, this very file names the two
# rotted scripts in its own, and ci.yml's e2e-dev-loop step names
# examples/tsx-site/test/{hydrate,spa_slice}.sh in a comment explaining why they are
# NOT in its list. Without the filter each of those would vouch for a script nothing
# executes.
#
# That last one also PINS the filter, which is why the paths there are spelled in
# full: those two scripts are inventoried as knowingly unrun, so the moment this
# function stops skipping comments they are read as both CI-run and inventoried and
# rule 1 below fails the gate by name. The regression is loud and immediate rather
# than latent — verified by reverting the filter and watching it go red.
#
# CAPTURED INTO VARIABLES, not piped into `grep -q`. Under `set -o pipefail`,
# `git grep … | grep -q …` is a RACE: grep -q exits at its first match, SIGPIPEs
# git grep, and pipefail then reports 141 for the whole pipeline. It happens to
# succeed when the output is small enough to be written before grep leaves, which is
# why it passed by hand and failed in the loop. Command substitution drains the
# output, so there is no early reader and nothing to race.
named_outside_comments() {
  local path="$1"; shift
  local hits noncomment
  hits=$(git grep -hF -- "$path" -- "$@" 2>/dev/null || true)
  [ -n "$hits" ] || return 1
  noncomment=$(printf '%s\n' "$hits" | grep -v '^[[:space:]]*#' || true)
  [ -n "$noncomment" ]
}

# A script counts as CI-run when any of these holds:
#   (a) it matches ci.yml's `tests/*/*.sh` discovery glob;
#   (b) a workflow RUNS it by name (tests/branding.sh, scripts/check-allocator-*.sh,
#       and the eleven examples/tsx-site/test/*.sh listed in e2e-dev-loop);
#   (c) a SHELL SCRIPT under tests/ names it — those are themselves CI-run by (a) or (b),
#       so this is what covers the shim pattern (tests/contract/drift.sh runs
#       contract/test/drift.sh; tests/changelog/assemble.sh runs the changelog self-test).
#
# Rule (c) is scoped to `*.sh` on purpose, and that is load-bearing rather than tidy.
# The inventory file lives under tests/ and consists of exactly these paths, so a bare
# `-- tests/` pathspec makes every listed script look CI-run BY BEING LISTED — the gate
# then passes vacuously, which is the precise failure mode it was written to stop. It did
# not show up while the inventory was untracked (git grep only searches tracked files)
# and appeared the instant it was committed. Keep the pathspec restricted to scripts.
is_ci_run() {
  local path="$1"
  case "$path" in
    tests/*/*) case "${path#tests/*/}" in */*) ;; *) return 0 ;; esac ;;
  esac
  named_outside_comments "$path" '.github/workflows/' && return 0
  named_outside_comments "$path" 'tests/*.sh' 'tests/**/*.sh' && return 0
  return 1
}

# Inventory rows are `<path><TAB or spaces><reason>`; blank lines and # comments ignored.
declare -A LISTED=()
if [ -f "$INVENTORY" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    local_path=${line%%[[:space:]]*}
    reason=${line#"$local_path"}
    reason=${reason#"${reason%%[![:space:]]*}"}
    [ -n "$reason" ] || { echo "FAIL: $INVENTORY row for '$local_path' has no reason" >&2; exit 1; }
    LISTED["$local_path"]=1
  done < "$INVENTORY"
fi

fails=0

# 1. Every candidate is CI-run or inventoried — never neither.
for path in "${CANDIDATES[@]}"; do
  if is_ci_run "$path"; then
    if [ -n "${LISTED[$path]:-}" ]; then
      echo "FAIL: $path IS run by CI but is also listed in $INVENTORY — drop the row" >&2
      fails=$((fails + 1))
    fi
    continue
  fi
  if [ -z "${LISTED[$path]:-}" ]; then
    echo "FAIL: $path is a test script that NOTHING runs, and it is not in $INVENTORY." >&2
    echo "      Either wire it into CI (a tests/<area>/*.sh shim is picked up by the glob)" >&2
    echo "      or add a row to $INVENTORY saying why it is knowingly not run." >&2
    fails=$((fails + 1))
  fi
done

# 2. No stale inventory rows — a row for a script that was deleted or has since been
#    wired up is exactly the stale-doc defect this gate exists to prevent.
for path in "${!LISTED[@]}"; do
  found=0
  for c in "${CANDIDATES[@]}"; do [ "$c" = "$path" ] && { found=1; break; }; done
  if [ "$found" -eq 0 ]; then
    echo "FAIL: $INVENTORY lists '$path', which is not a tracked test script — delete the row" >&2
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "" >&2
  echo "$fails problem(s). See the header of $0 for why this gate exists." >&2
  exit 1
fi

ci_count=0
for path in "${CANDIDATES[@]}"; do is_ci_run "$path" && ci_count=$((ci_count + 1)); done
echo "PASS: ${#CANDIDATES[@]} test scripts — $ci_count run by CI, $((${#CANDIDATES[@]} - ci_count)) inventoried as knowingly unrun"
