#!/usr/bin/env bash
# CI hook for the changelog assembler's self-test.
#
# The tests themselves live at scripts/assemble-changelog.test.sh, next to their subject,
# matching scripts/check-allocator-contracts.test.sh. That one is named explicitly in
# .github/workflows/ci.yml; this shim exists so this gate is picked up by CI's
# `tests/*/*.sh` glob instead, which needs no workflow edit — and therefore cannot go
# unrun because two branches touched ci.yml at the same time.
#
# It costs nothing: the self-test is pure bash/awk over throwaway trees in $TMPDIR, needs
# no toolchain, and never touches the repo's own CHANGELOG.md.
set -euo pipefail
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/assemble-changelog.test.sh"
