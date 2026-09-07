#!/usr/bin/env bash
# Regression test: an author's `spa` export with a wrong-typed field must be
# reported as a bad response SHAPE, not as a corrupt sidecar.
#
# The sidecar puts the module's `spa` export straight on the wire
# (runtime/sidecar/render.ts's `JSON.stringify({ id, spa, routes })`), so
# `export const spa = { base: 42 }` produces a response line that is perfectly
# well-formed JSON and simply does not fit the Zig-side response struct.
#
# Both failure modes reach the same `catch` in sidecar.zig, and collapsing them
# into one name is a real cost now that the name is user-facing (it is what a
# `--format=json` island diagnostic carries when the sidecar supplied no
# message). `SidecarBadResponse` means the NDJSON channel itself is corrupt —
# an island wrote to stdout — and sends the author to debug the sidecar. This
# failure is in their own module, so it must say so.
#
# The counterpart assertion, that a genuinely corrupt channel still reports
# `SidecarBadResponse`, lives in tests/diagnostics/island-render.sh.
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

# `base` must be a string. 42 is valid JSON and the wrong type: the response
# line parses as JSON and fails to fit the struct.
cat > "$SITE/app/app.spa.tsx" <<'TSX'
import { Router } from "@z/runtime";
export const spa = { base: 42, title: "Bad shape", head: [] };
function Home() { return <div>home</div>; }
export const routes = [{ path: "/", component: Home }];
export default function App() { return <Router base="/app" routes={routes} />; }
TSX

# ZIGAPAGOS_RUNTIME_DIR must be SET here, unlike missing-client-assets.sh which
# unsets it on purpose: without it the release stops at the client-asset check
# in src/cli/release.zig long before it ever asks the sidecar to describe the
# module, and the test would pass on the wrong failure.
set +e
( cd "$SITE" && env ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" "$ZIGAPAGOS" release \
    --force "--output=$OUT" "--bun=$BUN" \
    "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=. \
    "--spa=app/app.spa.tsx|/app" ) >"$WORK/shape.log" 2>&1
rc=$?
set -e

# Guard against exactly that: the failure must be the prerender, not the
# earlier asset gate.
grep -q 'SPA prerender failed' "$WORK/shape.log" || {
  echo "--- build output ---"; sed -n '1,20p' "$WORK/shape.log"
  fail "the build failed before the SPA prerender, so this test proves nothing"
}

[[ "$rc" -ne 0 ]] || {
  sed -n '1,20p' "$WORK/shape.log"
  fail "a wrong-typed spa.base built successfully"
}

grep -q 'SidecarBadResponseShape' "$WORK/shape.log" || {
  echo "--- build output ---"; sed -n '1,20p' "$WORK/shape.log"
  fail "the failure is not reported as a response-shape problem"
}
# The corrupt-channel name must NOT appear: that is the misattribution this
# test exists to prevent. Match it on its own so the Shape suffix cannot satisfy
# the check.
grep -qE 'SidecarBadResponse([^S]|$)' "$WORK/shape.log" && {
  echo "--- build output ---"; sed -n '1,20p' "$WORK/shape.log"
  fail "an author's wrong-typed spa export is blamed on a corrupt sidecar channel"
}

echo "PASS: a wrong-typed spa export is reported as a response-shape failure, not a corrupt sidecar"
