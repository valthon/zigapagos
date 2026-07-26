#!/usr/bin/env bash
# Smoke-test the Zigapagos dev server island-preview: start serve, assert routes, kill.
# Usage: bash examples/tsx-site/test/serve.sh
# Requires: mise (zig, bun in PATH), git.
set -euo pipefail
set -m   # Enable job control so background jobs run in their own process group,
         # allowing `kill -- -$SERVE_PID` to terminate the whole tree (zig + zigapagos).

cd "$(dirname "$0")/.."   # cd to examples/tsx-site/

PORT=1990   # Default zigapagos-serve port (build.zig does not thread --port through).

# ── Cleanup on exit ──────────────────────────────────────────────────────────
SERVE_PID=""
cleanup() {
    if [ -n "$SERVE_PID" ]; then
        # Kill the entire process group (zig build + its zigapagos child).
        kill -- -"$SERVE_PID" 2>/dev/null || kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi
    # Restore tests/**/snapshot baselines deleted by every zig configure step.
    git -C ../.. ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C ../.. restore -- {} 2>/dev/null || true
}
trap cleanup EXIT

# ── (1) Install deps (same preamble as ssr.sh) ───────────────────────────────
# (1a) Runtime deps (preact, preact-render-to-string) so the Bun sidecar can render.
cd ../../runtime && mise exec -- bun install
cd - >/dev/null
# (1b) Consumer deps — creates node_modules/@z/runtime symlink to ../../runtime.
mise exec -- bun install

# ── (2) Build the site + compile the zigapagos binary ─────────────────────────
# This compiles the zigapagos binary (cache hit on subsequent runs) and SSRs the site
# to zig-out/site so any ssr-level assertion failures surface early.
# The root build.zig rm -rf's tests/**/snapshot at configure time; restore after.
mise exec -- zig build
git -C ../.. ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C ../.. restore -- {}

# ── (3) Start the dev server in the background ───────────────────────────────
# With job control (set -m) this gets its own process group (PGID == SERVE_PID);
# cleanup() kills the whole group so the zigapagos subprocess is not orphaned.
mise exec -- zig build serve &
SERVE_PID=$!

# ── (4) Poll until the server is listening (max 30 s) ────────────────────────
echo "serve.sh: waiting for server on port $PORT ..."
TIMEOUT=30
UP=0
for i in $(seq 1 "$TIMEOUT"); do
    if curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then
        echo "serve.sh: server up after ${i}s"
        UP=1
        break
    fi
    sleep 1
done
if [ "$UP" -eq 0 ]; then
    echo "FAIL: server did not start within ${TIMEOUT}s"
    exit 1
fi

# ── (5) GET / → 200 + islands SSR'd into the page ────────────────────────────
INDEX=$(curl -sf "http://localhost:$PORT/")
echo "$INDEX" | grep -q 'data-z-island' \
    || { echo "FAIL: GET / did not contain data-z-island"; exit 1; }

# ── (6) GET /zigapagos-runtime.js → 200 + javascript content-type ────────────
RT_CT=$(curl -sI "http://localhost:$PORT/zigapagos-runtime.js" \
    | grep -i '^content-type:' | tr -d '\r')
echo "$RT_CT" | grep -qi 'javascript' \
    || { echo "FAIL: /zigapagos-runtime.js wrong content-type (got: $RT_CT)"; exit 1; }

# ── (7) GET /islands/Hero.island.js → 200, @z/runtime external, no Preact ────
# The dev bundle must keep @z/runtime external (import-map wires the one shared
# Preact) and must NOT inline Preact internals (one-instance invariant; mirrors ssr.sh).
HERO_JS=$(curl -sf "http://localhost:$PORT/islands/Hero.island.js")
echo "$HERO_JS" | grep -q '"@z/runtime"' \
    || { echo "FAIL: Hero.island.js did not keep @z/runtime external"; exit 1; }
if echo "$HERO_JS" | grep -qE 'preact|__H|hookState'; then
    echo "FAIL: Hero.island.js inlined Preact (one-instance invariant broken)"
    exit 1
fi

echo "serve.sh: PASS"
