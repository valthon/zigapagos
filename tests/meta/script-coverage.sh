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

# A script counts as CI-run when any of these holds:
#   (a) it matches ci.yml's `tests/*/*.sh` discovery glob;
#   (b) a workflow names it literally (tests/branding.sh, scripts/check-allocator-*.sh);
#   (c) a script UNDER tests/ names it — those are themselves CI-run by (a) or (b), so
#       this is what covers the shim pattern (tests/contract/drift.sh runs
#       contract/test/drift.sh; tests/changelog/assemble.sh runs the changelog self-test).
is_ci_run() {
  local path="$1"
  case "$path" in
    tests/*/*) case "${path#tests/*/}" in */*) ;; *) return 0 ;; esac ;;
  esac
  git grep -qF -- "$path" -- '.github/workflows/' && return 0
  git grep -qF -- "$path" -- 'tests/' && return 0
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
