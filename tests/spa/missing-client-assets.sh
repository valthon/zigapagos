#!/usr/bin/env bash
# Regression test for issue #203: an explicit SPA release must not succeed when
# its emitted shell and routing manifest would reference client scripts that
# this invocation neither built nor registered.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

fail() { echo "FAIL: $*"; exit 1; }

if [[ ! -x "$ZIGAPAGOS" ]]; then
  mise exec -- zig build || fail "zig build failed"
fi
BUN="$(command -v bun || true)"
[[ -n "$BUN" ]] || fail "bun not found on PATH -- required for SPA prerendering"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SITE="$WORK/site"
OUT="$WORK/out"
mkdir -p "$SITE/app" "$SITE/node_modules/@z"
cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"
ln -s "$REPO/runtime" "$SITE/node_modules/@z/runtime"

cat > "$SITE/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler"
  }
}
JSON

cat > "$SITE/app/app.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";
export const spa = { base: "/app", title: "Missing assets", head: [] };
function Home() { return <div>home</div>; }
export const routes = [{ path: "/", component: Home }];
export default function App() { return <Router base={spa.base} routes={routes} />; }
TSX

# Control the environment explicitly: a developer shell that happens to carry
# the variable must not turn this into the npm self-bundling path. Seed both
# browser scripts to prove --force cannot mistake stale output for assets the
# current invocation actually registered.
mkdir -p "$OUT/spa"
printf 'stale entry\n' > "$OUT/spa/app.js"
printf 'stale runtime\n' > "$OUT/zigapagos-runtime.js"
set +e
( cd "$SITE" && env -u ZIGAPAGOS_RUNTIME_DIR "$ZIGAPAGOS" release \
    --force "--output=$OUT" "--bun=$BUN" \
    "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. \
    "--spa=app/app.spa.tsx|/app" ) >"$WORK/missing.log" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "release succeeded without either SPA client asset"
grep -q "references '/spa/app.js'" "$WORK/missing.log" \
  || { cat "$WORK/missing.log"; fail "diagnostic does not name the missing SPA entry"; }
grep -q 'ZIGAPAGOS_RUNTIME_DIR' "$WORK/missing.log" \
  || fail "diagnostic does not explain how to enable self-bundling"
grep -q -- '--install' "$WORK/missing.log" \
  || fail "diagnostic does not explain that external build assets need install paths"
[[ ! -e "$OUT/app/routing-manifest.json" ]] \
  || fail "stale client assets masked the incomplete release under --force"

# External orchestrators remain supported: if this invocation registers both
# scripts it references, release succeeds without ZIGAPAGOS_RUNTIME_DIR. Use
# ordinary --install (rc=0 at parse time) to prove the generated SPA shell is
# counted as the reference that makes each asset install.
printf 'export default function App(){}\n' > "$WORK/app.js"
printf 'export function mountSpa(){}\n' > "$WORK/runtime.js"
( cd "$SITE" && env -u ZIGAPAGOS_RUNTIME_DIR "$ZIGAPAGOS" release \
    --force "--output=$OUT" "--bun=$BUN" \
    "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. \
    "--spa=app/app.spa.tsx|/app" \
    --build-asset=app "$WORK/app.js" --install=spa/app.js \
    --build-asset=runtime "$WORK/runtime.js" --install=zigapagos-runtime.js ) \
  >"$WORK/control.log" 2>&1 || { cat "$WORK/control.log"; fail "registered-assets control failed"; }
[[ -f "$OUT/spa/app.js" ]] || fail "registered SPA entry was not installed"
[[ -f "$OUT/zigapagos-runtime.js" ]] || fail "registered runtime was not installed"
cmp -s "$WORK/app.js" "$OUT/spa/app.js" \
  || fail "ordinary --install left the stale SPA entry in place"
cmp -s "$WORK/runtime.js" "$OUT/zigapagos-runtime.js" \
  || fail "ordinary --install left the stale runtime in place"
[[ -f "$OUT/app/routing-manifest.json" ]] || fail "valid SPA release emitted no manifest"

echo "PASS: incomplete SPA releases fail, while registered external client assets succeed"
