#!/usr/bin/env bash
# e2e for the `zig build e2e` harness: build the RELEASE output,
# serve it with "zigbase", probe readiness, export ZIGAPAGOS_ORIGIN, run the
# child, tear down, propagate the exit code — driven through the real consumer
# surface (examples/tsx-site's `e2e` step → the public `zigapagos.e2e()` build
# API → the `zigapagos e2e` CLI).
#
# Hermetic: uses tests/serve/stub-zigbase.ts (a clearly-labeled stub honoring
# the VERIFIED `zigbase serve --http-host … --http-port … --data-dir …
# --serve-static …` invocation contract, space-separated values like the real
# parser) placed on PATH as `zigbase`, so no real ZigBase binary is needed.
#
# Asserts:
#   (a) `zig build e2e`: the child runs with ZIGAPAGOS_ORIGIN exported and —
#       with NO polling of its own — immediately fetches the islands page and
#       prerendered SPA shells from the RELEASE tree,
#   (b) teardown on success: origin dead + no stub process left,
#  (a2) direct CLI (`zigapagos e2e --site=… --data-dir=…`): the `.spa`-marker
#       fallback serves non-enumerated SPA routes, and the harness threads the
#       data dir through to the server,
#   (c) a failing child fails the step (exit-code propagation) and teardown
#       still happens,
#   (d) no command after `--` fails fast with usage guidance,
#   (e) locator: with no zigbase anywhere, the harness fails with actionable
#       instructions (skipped when a real zigbase or a cached pin exists).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../.. && pwd)"
SITE="$REPO/examples/tsx-site"

restore_snapshots() {
  git -C "$REPO" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO" restore -- {}
}

WORK="$(mktemp -d)"

cleanup() {
  pkill -f "stub-zigbase.ts" 2>/dev/null || true
  rm -rf "$WORK"
  restore_snapshots
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

# --- deps (sidecar needs preact; consumer needs the @z/runtime symlink) --------
( cd "$REPO/runtime" && mise exec -- bun install ) >/dev/null 2>&1 || fail "runtime bun install failed"
( cd "$SITE" && mise exec -- bun install ) >/dev/null 2>&1 || fail "consumer bun install failed"

# --- (e) locator: nothing anywhere -> clear instructions ------------------------
# Run FIRST, before the stub goes on PATH. Skipped when the machine has a real
# zigbase (PATH) or the pinned release in the cache — the locator would find it.
CACHE_PIN="${XDG_CACHE_HOME:-$HOME/.cache}/zigapagos/zigbase/v0.11.0/zigbase"
if command -v zigbase >/dev/null 2>&1 || [[ -x "$CACHE_PIN" ]]; then
  echo "SKIP: locator-missing case (a zigbase exists on this machine: $(command -v zigbase || echo "$CACHE_PIN"))"
else
  echo "running: zig build e2e -- true (no zigbase anywhere)..."
  if ( cd "$SITE" && mise exec -- zig build e2e -- true ) > "$WORK/nozb.log" 2>&1; then
    cat "$WORK/nozb.log"; fail "e2e without any zigbase should fail"
  fi
  restore_snapshots
  grep -q "zigbase binary not found" "$WORK/nozb.log" || { cat "$WORK/nozb.log"; fail "locator failure lacks the not-found message"; }
  grep -q -- "--zigbase=" "$WORK/nozb.log" || { cat "$WORK/nozb.log"; fail "locator failure lacks the --zigbase= option"; }
  grep -q -- "--download-zigbase" "$WORK/nozb.log" || { cat "$WORK/nozb.log"; fail "locator failure lacks the --download-zigbase option"; }
  grep -q "v0.11.0" "$WORK/nozb.log" || { cat "$WORK/nozb.log"; fail "locator failure lacks the pinned version"; }
  echo "PASS: locator failure is actionable (PATH / --zigbase= / pinned cache instructions)"
fi

# --- put the stub "zigbase" on PATH ---------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/zigbase" <<EOF
#!/usr/bin/env bash
# STUB zigbase for tests/serve/e2e.sh — see tests/serve/stub-zigbase.ts
exec bun "$HERE/stub-zigbase.ts" "\$@"
EOF
chmod +x "$BIN/zigbase"
export PATH="$BIN:$PATH"

# --- (a) success path through `zig build e2e` -----------------------------------
# The child asserts from INSIDE the harness. No readiness polling in here — the
# harness's contract is that the origin already answers when the child starts.
ORIGIN_FILE="$WORK/origin"
CHILD="$WORK/child.sh"
cat > "$CHILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${ZIGAPAGOS_ORIGIN:-}" ]] || { echo "child: ZIGAPAGOS_ORIGIN not set"; exit 1; }
echo "$ZIGAPAGOS_ORIGIN" > "$ORIGIN_FILE"
# islands page, SSR'd into the RELEASE tree
curl -sf "$ZIGAPAGOS_ORIGIN/" | grep -q 'data-z-island' \
  || { echo "child: / missing islands SSR"; exit 1; }
# prerendered SPA shells (static files in the release output)
curl -sf "$ZIGAPAGOS_ORIGIN/app/" | grep -q 'id="z-spa-root"' \
  || { echo "child: /app/ not a SPA shell"; exit 1; }
curl -sf "$ZIGAPAGOS_ORIGIN/app/booking/" | grep -q 'data-view="booking"' \
  || { echo "child: /app/booking/ shell wrong"; exit 1; }
echo "child: all assertions passed"
EOF
chmod +x "$CHILD"

echo "running: zig build e2e -- bash child.sh (success case, stub zigbase on PATH)..."
( cd "$SITE" && ORIGIN_FILE="$ORIGIN_FILE" mise exec -- zig build e2e -- bash "$CHILD" ) \
  > "$WORK/ok.log" 2>&1 || { cat "$WORK/ok.log"; fail "success-case zig build e2e failed"; }
grep -q 'child: all assertions passed' "$WORK/ok.log" || { cat "$WORK/ok.log"; fail "child assertions did not run"; }
restore_snapshots
echo "PASS: child ran after readiness with ZIGAPAGOS_ORIGIN against the release tree"

# --- (b) teardown on success -----------------------------------------------------
ORIGIN="$(cat "$ORIGIN_FILE")"
[[ -n "$ORIGIN" ]] || fail "child did not record the origin"
if curl -sf --max-time 2 -o /dev/null "$ORIGIN/"; then
  fail "server still answering at $ORIGIN after the harness exited (teardown)"
fi
pgrep -f "stub-zigbase.ts" >/dev/null && fail "stub zigbase process left behind (teardown)"
echo "PASS: teardown on success ($ORIGIN is dead, no stub process)"

# --- (a2) direct CLI: .spa-marker fallback + data-dir threading ------------------
# The tsx-site dogfood builds with deploy_target=nginx, so re-run the emitter
# with --target zigbase against the installed tree (exactly like test/spa.sh)
# to plant the `.spa` markers the stock server reads, then drive `zigapagos
# e2e` directly with an observable --data-dir.
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
  restore_snapshots
fi
OUT="$SITE/zig-out/site"
[[ -d "$OUT" ]] || fail "release tree $OUT missing (scenario (a) should have installed it)"
( cd "$SITE" && mise exec -- bun "$REPO/runtime/scripts/emit-host-config.ts" --site "$OUT" --target zigbase ) \
  >/dev/null || fail "emit-host-config --target zigbase failed"
test -f "$OUT/app/.spa" || fail "no .spa marker after the zigbase emitter run"

DATA="$WORK/zb-data"
DIRECT_CHILD="$WORK/direct_child.sh"
cat > "$DIRECT_CHILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# a non-enumerated SPA route: only the .spa-marker fallback can serve it
curl -sf "$ZIGAPAGOS_ORIGIN/app/nope" | grep -q 'id="z-spa-root"' \
  || { echo "child: /app/nope did not hit the .spa fallback shell"; exit 1; }
echo "child: spa fallback OK"
EOF
chmod +x "$DIRECT_CHILD"

echo "running: zigapagos e2e --site=... --data-dir=... (direct CLI)..."
mise exec -- "$ZIGAPAGOS" e2e --site="$OUT" --data-dir="$DATA" -- bash "$DIRECT_CHILD" \
  > "$WORK/direct.log" 2>&1 || { cat "$WORK/direct.log"; fail "direct-CLI e2e failed"; }
grep -q 'child: spa fallback OK' "$WORK/direct.log" || { cat "$WORK/direct.log"; fail "direct child did not run"; }
test -f "$DATA/stub-zigbase.touch" || fail "--data-dir was not threaded to the server"
echo "PASS: direct CLI (.spa-marker fallback served /app/nope; data dir threaded)"

# --- (c) failing child: exit code propagates, teardown still happens -------------
ORIGIN_FILE2="$WORK/origin2"
echo "running: zig build e2e -- bash -c 'record origin; exit 7' (failure case)..."
if ( cd "$SITE" && mise exec -- zig build e2e -- \
       bash -c "echo \"\$ZIGAPAGOS_ORIGIN\" > '$ORIGIN_FILE2'; exit 7" ) > "$WORK/fail.log" 2>&1; then
  cat "$WORK/fail.log"; fail "a child exiting 7 did not fail the e2e step"
fi
restore_snapshots
grep -q 'exited with code 7' "$WORK/fail.log" || { cat "$WORK/fail.log"; fail "harness did not report the child's exit code"; }
ORIGIN2="$(cat "$ORIGIN_FILE2" 2>/dev/null || true)"
[[ -n "$ORIGIN2" ]] || fail "failing child never ran (no origin recorded)"
if curl -sf --max-time 2 -o /dev/null "$ORIGIN2/"; then
  fail "server still answering at $ORIGIN2 after a FAILING child (teardown)"
fi
pgrep -f "stub-zigbase.ts" >/dev/null && fail "stub zigbase left behind after a failing child (teardown)"
echo "PASS: failing child fails the step, teardown still happens"

# --- (d) no command: fail fast with usage guidance -------------------------------
echo "running: zig build e2e (no command)..."
if ( cd "$SITE" && mise exec -- zig build e2e ) > "$WORK/nocmd.log" 2>&1; then
  cat "$WORK/nocmd.log"; fail "zig build e2e without a command should fail"
fi
restore_snapshots
grep -q "e2e mode needs a command" "$WORK/nocmd.log" \
  || { cat "$WORK/nocmd.log"; fail "no-command failure lacks usage guidance"; }
echo "PASS: no-command invocation fails fast with usage guidance"

echo "PASS: e2e harness (release build + zigbase serve + readiness + ZIGAPAGOS_ORIGIN + teardown + exit codes + locator)"
