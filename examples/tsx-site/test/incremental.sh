#!/usr/bin/env bash
# incremental.sh — proves transitive-dep changes rebundle the island (depfile
# incrementality works) and that no-op rebuilds are stable.
#
# PRIMARY PROOF: editing a transitive dep of Hero (not Hero itself) must cause
# Hero.island.js to change (H1 != H2).  If H1 == H2, the depfile wiring is
# broken and the stale-bundle bug is NOT fixed.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(cd ../.. && pwd)"

# ── 0. Install deps ────────────────────────────────────────────────────────────
cd "$REPO_ROOT/runtime" && mise exec -- bun install >/dev/null
cd - >/dev/null
mise exec -- bun install >/dev/null

# ── 1. Set up transitive dep + inject import into Hero ─────────────────────────
DEP="components/_inc_dep.ts"
HERO="components/Hero.island.tsx"
cp "$HERO" "/tmp/_hero.bak"
trap 'mv -f /tmp/_hero.bak "$HERO" 2>/dev/null || true; rm -f "$DEP"; git -C "$REPO_ROOT" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO_ROOT" restore -- {}' EXIT

printf 'export const INC = "v1";\n' > "$DEP"
# Inject import after the first import line and use INC in the JSX data attribute
# so it appears in the bundled JS output (not tree-shaken away).
perl -0pi -e 's{^(import \{ useState \} from "\@z/runtime";)}{$1\nimport { INC } from "./_inc_dep.ts";}m' "$HERO"
perl -0pi -e 's{<section>}{<section data-inc=\{INC\}>}' "$HERO"

grep -q '_inc_dep' "$HERO" || { echo "FAIL: perl did not inject import into Hero.island.tsx"; exit 1; }
grep -q 'data-inc' "$HERO"  || { echo "FAIL: perl did not inject data-inc into Hero JSX"; exit 1; }
echo "Injection verified:"
grep -E '_inc_dep|data-inc' "$HERO"

# ── 2. Build #1 ───────────────────────────────────────────────────────────────
mise exec -- zig build
git -C "$REPO_ROOT" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO_ROOT" restore -- {}
H1="$(sha256sum zig-out/site/islands/Hero.island.js | cut -d' ' -f1)"
echo "Build #1  H1=$H1"

# ── 3. Edit ONLY the transitive dep (Hero root byte-identical), rebuild ─────────
# INC changes → bundle must contain the new value → different bytes → H2 != H1
printf 'export const INC = "v2-CHANGED";\n' > "$DEP"
mise exec -- zig build
git -C "$REPO_ROOT" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO_ROOT" restore -- {}
H2="$(sha256sum zig-out/site/islands/Hero.island.js | cut -d' ' -f1)"
echo "Build #2  H2=$H2"

[ "$H1" != "$H2" ] || { echo "FAIL: editing a transitive dep did NOT rebundle the island (stale-bundle bug still present)"; exit 1; }
echo "PASS: transitive dep change rebundled the island (depfile incrementality works)"

# ── 4. No-op rebuild → cache hit (hash stable) ──────────────────────────────────
mise exec -- zig build
git -C "$REPO_ROOT" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO_ROOT" restore -- {}
H3="$(sha256sum zig-out/site/islands/Hero.island.js | cut -d' ' -f1)"
echo "Build #3  H3=$H3"

[ "$H2" = "$H3" ] || { echo "FAIL: no-op rebuild changed the bundle (unstable output)"; exit 1; }
echo "PASS: no-op rebuild is stable"
