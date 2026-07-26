#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash test/ssr.sh                 # build the site (asserts SSR + assets)
mise exec -- python3 test/hydrate_playwright.py zig-out/site
# restore footgun-deleted snapshots
git -C ../.. ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C ../.. restore -- {}
