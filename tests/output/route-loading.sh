#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bun test runtime/tooling/route-loading.test.ts
