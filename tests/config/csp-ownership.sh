#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
bun test "$REPO/tests/deploy/csp-ownership.test.ts"
