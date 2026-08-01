#!/usr/bin/env bash
# Structural parity gate (v1 self-consistency demo): build, capture the build as the
# golden, then check the same build against it — must PASS. With a real Astro dist as
# `reference`, the same flow becomes the actual cutover gate.
set -euo pipefail
cd "$(dirname "$0")/.."
bash test/ssr.sh >/dev/null            # produces zig-out/site/index.html
mise exec -- bun ../../runtime/scripts/parity.ts capture --config parity.config.json
mise exec -- bun ../../runtime/scripts/parity.ts check   --config parity.config.json
echo "parity.sh: PASS"
