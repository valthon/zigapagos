#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Install deps (same as ssr.sh): runtime's own deps first, then this fixture's.
cd ../../runtime && mise exec -- bun install >/dev/null
cd - >/dev/null
mise exec -- bun install >/dev/null

# Safety trap: always restore the layout on exit so the working tree stays clean.
trap 'git restore layouts/index.shtml 2>/dev/null || true' EXIT

# --- (A) NEGATIVE: inject a type-wrong prop and expect the build to FAIL. ---
# Hero.island.tsx declares `export interface Props { headline: string }`.
# Passing a number literal (5) triggers TS2322 ("Type 'number' is not
# assignable to type 'string'"), which the props-check gate remaps to a
# "props mismatch" diagnostic and fails the build (build.sh passes
# --island-props-check=error).
perl -0pi -e \
  's{</body>}{<island src="components/Hero.island.tsx" client:load :props=\x27{ .headline = 5 }\x27></island>\n  </body>}' \
  layouts/index.shtml

# Verify the injection was applied before spending time building.
grep -q '.headline = 5' layouts/index.shtml \
  || { echo "FAIL: injection did not apply to layouts/index.shtml"; exit 1; }

# Capture both stdout and stderr; do NOT let a non-zero exit abort the script.
set +e
OUT="$(bash build.sh 2>&1)"
CODE=$?
set -e

# Restore BEFORE asserting so the layout is clean regardless of what follows.
git restore layouts/index.shtml

if [ "$CODE" -eq 0 ]; then
  echo "FAIL: build succeeded despite a type-wrong island prop"
  echo "$OUT"
  exit 1
fi

echo "$OUT" | grep -q "props mismatch" \
  || { echo "FAIL: 'props mismatch' not found in build output"; echo "$OUT"; exit 1; }

echo "$OUT" | grep -q "Hero.island.tsx" \
  || { echo "FAIL: 'Hero.island.tsx' not found in build output"; echo "$OUT"; exit 1; }

echo "PASS: bad props failed the build with the remapped diagnostic"

# --- (B) POSITIVE: the unmodified good site must build clean under =error. ---
bash build.sh

test -f zig-out/site/index.html \
  || { echo "FAIL: good build produced no index.html"; exit 1; }

echo "PASS: good site builds clean with props-check=error"
