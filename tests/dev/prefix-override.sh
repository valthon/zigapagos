#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX_OVERRIDE_MODE=equals bash "$REPO/tests/dev/dev-prefix.sh"
PREFIX_OVERRIDE_MODE=separate bash "$REPO/tests/dev/dev-prefix.sh"
