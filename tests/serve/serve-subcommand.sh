#!/usr/bin/env bash
# E2E: `zigapagos serve` starts the preview server, and says nothing about being
# deprecated.
#
# Issue #56. Two separate defects met here:
#
#   1. `serve` was a recognised command that refused to serve. It printed
#      "error: run zigapagos without any subcommand to start the deprecated live
#      server", dumped the help menu and exited 1 — while docs/spa.md,
#      docs/islands.md, docs/observability.md and this directory's own
#      proxy.sh/spa.sh all call the thing `zigapagos serve`. The documented
#      spelling was the one spelling the binary rejected.
#   2. The server it refused to start was the one `zigapagos init` tells a new
#      user to run, and the tool called that deprecated on every startup. `dev`
#      is not a drop-in: it requires --site, a rebuild command (default
#      `zig build`, and `init` scaffolds no build.zig) and a zigbase binary it
#      never downloads without --download-zigbase.
#
# So this asserts the resolution from both ends: the subcommand serves, and the
# startup output carries no deprecation warning.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"

ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
SITE="$REPO/tests/rendering/simple"
WORK="$(mktemp -d)"
LOG="$WORK/zigapagos.log"
PID=""

restore_snapshots() {
  git -C "$REPO" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO" restore -- {}
}

cleanup() {
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
  rm -rf "$WORK"
  restore_snapshots
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; echo "--- zigapagos log ---"; cat "$LOG" 2>/dev/null || true; exit 1; }

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
  restore_snapshots
fi

free_port() {
  mise exec -- bun -e 'const s=Bun.serve({port:0,fetch(){return new Response("")}});const p=s.port;s.stop();process.stdout.write(String(p))'
}

# --- 1. `zigapagos serve` actually serves -------------------------------------
PORT="$(free_port)"
BASE="http://127.0.0.1:$PORT"
( cd "$SITE" && exec "$ZIGAPAGOS" serve --host 127.0.0.1 --port "$PORT" ) > "$LOG" 2>&1 &
PID=$!

READY=""
for _ in $(seq 1 100); do
  if curl -sf -o /dev/null "$BASE/"; then READY=1; break; fi
  # An exited child is the pre-fix failure mode: `serve` printed the help menu
  # and exited 1 instead of listening. Report it as such rather than waiting out
  # the whole readiness budget.
  if ! kill -0 "$PID" 2>/dev/null; then
    wait "$PID" 2>/dev/null && rc=0 || rc=$?
    fail "'zigapagos serve' exited with status $rc instead of serving"
  fi
  sleep 0.1
done
[[ -n "$READY" ]] || fail "'zigapagos serve' never became ready at $BASE/"

curl -sf "$BASE/" | grep -qi '<html' \
  || fail "'zigapagos serve' answered / with something that is not a page"

# --- 2. the startup output is not a deprecation notice ------------------------
# grep -i over the whole log: the banner said "DEPRECATED: this bundled live
# server is deprecated and will be removed in a future release", so any casing of
# either word is the regression.
! grep -qiE 'deprecat|will be removed' "$LOG" \
  || fail "the preview server still announces itself as deprecated"

# It must still point at the full-fidelity loop — dropping the warning without
# saying when to use 'dev' would make the banner quieter, not more honest.
grep -q 'zigapagos dev' "$LOG" \
  || fail "the startup banner no longer points at 'zigapagos dev'"

# --- 3. the bare command is unchanged -----------------------------------------
# `serve` is an alias for it, not a replacement, and the npm README documents the
# bare form. If this ever diverges, one of the two is a trap.
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""

PORT2="$(free_port)"
BARE_LOG="$WORK/bare.log"
( cd "$SITE" && exec "$ZIGAPAGOS" --host 127.0.0.1 --port "$PORT2" ) > "$BARE_LOG" 2>&1 &
PID=$!
READY=""
for _ in $(seq 1 100); do
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT2/"; then READY=1; break; fi
  kill -0 "$PID" 2>/dev/null || fail "the bare command exited during startup"
  sleep 0.1
done
[[ -n "$READY" ]] || fail "the bare command never became ready"

echo "PASS: 'zigapagos serve' serves, announces no deprecation, points at 'zigapagos dev', and the bare command still works"
