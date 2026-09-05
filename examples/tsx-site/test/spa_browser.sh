#!/usr/bin/env bash
# Read-only browser scenarios share one build; destructive spa_slice stays isolated.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  all) suites=(spa spa_csp spa_guards spa_nested spa_nested_guarded spa_reload spa_scroll spa_split) ;;
  spa|spa_csp|spa_guards|spa_nested|spa_nested_guarded|spa_reload|spa_scroll|spa_split) suites=("$1") ;;
  *) echo "FAIL: expected a supported SPA browser suite" >&2; exit 2 ;;
esac
(cd ../../runtime && bun install --frozen-lockfile)
bash build.sh
status=0
for suite in "${suites[@]}"; do
  echo "::group::SPA browser — $suite"
  if [[ "$suite" == spa_csp ]]; then
    args=(--built)
  else
    args=(zig-out/site)
  fi
  # Run every helper even after a failure, while preserving a failing job status.
  if python3 "test/${suite}_playwright.py" "${args[@]}"; then
    echo "PASS: $suite"
  else
    echo "FAIL: $suite" >&2
    status=1
  fi
  echo "::endgroup::"
done
exit "$status"
