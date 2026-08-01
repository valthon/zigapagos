#!/usr/bin/env bash
# rebundle.sh — the island bundle follows its transitive imports, and a rebuild
# with nothing changed reproduces it byte for byte.
#
# PRIMARY PROOF: editing a transitive dep of Hero — not Hero itself — must change
# Hero.island.js (H1 != H2). That pins that the dep is genuinely IN the bundle
# and that a rebuild picks the edit up; if H1 == H2 the bundler either never
# followed the import or served something stale.
#
# SECONDARY PROOF: a third build with no source change must reproduce H2 exactly
# (H2 == H3). `zigapagos release` wipes .zigapagos-cache/bundles and re-runs
# every bundler on every build, so this is not a cache-hit assertion — it is a
# DETERMINISM one, and it is the stronger of the two claims: nothing about a
# published site should depend on how many times it was built.
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
trap 'mv -f /tmp/_hero.bak "$HERO" 2>/dev/null || true; rm -f "$DEP"' EXIT

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
bash build.sh
H1="$(sha256sum zig-out/site/islands/Hero.island.js | cut -d' ' -f1)"
echo "Build #1  H1=$H1"

# ── 3. Edit ONLY the transitive dep (Hero root byte-identical), rebuild ─────────
# INC changes → bundle must contain the new value → different bytes → H2 != H1
printf 'export const INC = "v2-CHANGED";\n' > "$DEP"
bash build.sh
H2="$(sha256sum zig-out/site/islands/Hero.island.js | cut -d' ' -f1)"
echo "Build #2  H2=$H2"

[ "$H1" != "$H2" ] || { echo "FAIL: editing a transitive dep did NOT change the island bundle — the import was never followed"; exit 1; }
echo "PASS: a transitive dep change reaches the island bundle"

# ── 4. Rebuild with no change → byte-identical output ─────────────────────────
bash build.sh
H3="$(sha256sum zig-out/site/islands/Hero.island.js | cut -d' ' -f1)"
echo "Build #3  H3=$H3"

[ "$H2" = "$H3" ] || { echo "FAIL: a no-change rebuild produced different bytes (non-deterministic build)"; exit 1; }
echo "PASS: a no-change rebuild is byte-identical"
