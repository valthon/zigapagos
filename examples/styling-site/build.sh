#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
[[ -x "$BIN" ]] || { echo 'Build zigapagos first with zig build, or set ZIGAPAGOS_BIN.' >&2; exit 1; }
bun install --frozen-lockfile
mkdir -p assets/generated assets/fonts
# Reuse the small font already distributed with the repository's sample site.
cp "$REPO/src/cli/init/assets/Temml.woff2" assets/fonts/
cp licenses/LICENSE-Temml.txt licenses/LICENSE-KaTeX.txt assets/fonts/
# Invoke the locked local compiler, never an unpinned bunx download.
bun node_modules/@tailwindcss/cli/dist/index.mjs -i styles/tailwind.css -o assets/generated/tailwind.css --minify
export ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime"
exec "$BIN" release --force --output=zig-out/site \
  --island=components/Preference.island.tsx --island-props-check=error \
  --bun=bun --css-minify "$@"
