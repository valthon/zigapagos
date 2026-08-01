#!/usr/bin/env bash
# e2e for the `zigapagos dev` zigbase-backed dev loop: build the release
# output, serve it with "zigbase", watch the inputs, rebuild on change into
# the served tree, keep the data dir PERSISTENT across sessions, tear down
# with no orphans.
#
# Hermetic: uses tests/dev/stub-zigbase.ts (honoring the real `zigbase serve
# --http-host … --http-port … --data-dir … --serve-static …` contract) placed
# on PATH as `zigbase`, so no real ZigBase binary is needed. Set
# REAL_ZIGBASE=/path/to/zigbase to ALSO run the boot + edit-rebuild scenario
# against a real binary.
#
# Asserts:
#   (a) zero-config: `zigapagos dev` with NO arguments builds, serves and
#       defaults --site/--rebuild/watch-dirs correctly,
#   (b) foot-gun guard: --site inside a watched dir is refused,
#   (c) boot + readiness on a minimal site; a content edit triggers a rebuild
#       that changes the SERVED output (polled, no server restart),
#   (c2) live-reload: the served HTML carries the dev-only reload
#       snippet, a rebuild pushes a `data: reload` SSE event, and a plain
#       release build of the same site is free of the snippet,
#   (d) teardown leaves no orphans (dev process, watcher, zigbase) AND leaves
#       the data dir intact (persistent),
#   (e) a second run REUSES the same data dir (sentinel survives, the server
#       touches it again),
#   (f) the default data dir is `.zigbase/` under the site root,
#   (g) the real consumer surface: `zigapagos dev` over examples/tsx-site with
#       that project's own build.sh as the rebuild command — four islands and
#       five SPAs, not the toy fixture (a)-(f) use — boots, serves the islands
#       page and a SPA shell, rebuilds on a content edit, and tears down
#       cleanly,
#   (h) [opt-in] the same loop against a REAL zigbase binary (REAL_ZIGBASE=…).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../.. && pwd)"
SITE="$REPO/examples/tsx-site"

WORK="$(mktemp -d)"

restore_snapshots() {
  # `-I{}` instead of GNU-only `-r`: BSD/macOS xargs has no -r, and with a
  # placeholder it already skips empty input (the same portable idiom used by
  # the other e2e scripts here).
  git -C "$REPO" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO" restore -- {}
}

cleanup() {
  # Kill anything from THIS run (argv always carries $WORK or the tsx-site
  # marker), then sweep.
  pkill -f "$WORK" 2>/dev/null || true
  pkill -f "zigapagos dev --site=$SITE" 2>/dev/null || true
  sleep 0.2
  git -C "$REPO" checkout -- examples/tsx-site/content 2>/dev/null || true
  restore_snapshots
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

# Polls a command until it succeeds or the deadline (seconds) passes.
poll() {
  local deadline=$1; shift
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start < deadline )) || return 1
    sleep 0.5
  done
}

# --- build zigapagos --------------------------------------------------------------
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
  restore_snapshots
fi

# --- put the stub "zigbase" on PATH ------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/zigbase" <<EOF
#!/usr/bin/env bash
# STUB zigbase for tests/dev/dev.sh — see tests/dev/stub-zigbase.ts
exec bun "$HERE/stub-zigbase.ts" "\$@"
EOF
chmod +x "$BIN/zigbase"
export PATH="$BIN:$PATH"

# --- minimal site fixture -----------------------------------------------------------
SRC="$WORK/site"
mkdir -p "$SRC"
cp -r "$REPO/tests/rendering/simple/content" "$REPO/tests/rendering/simple/layouts" "$SRC/"
cp "$REPO/tests/rendering/simple/zigapagos.ziggy" "$SRC/"
printf '\nDEVLOOP-MARKER-V1\n' >> "$SRC/content/index.smd"
OUT="$WORK/out"
DATA="$WORK/data"
REBUILD=("$ZIGAPAGOS" release "--output=$OUT" --force)

# Launches "$@" (cwd = $1, log = $2) as its own process-group leader so
# `kill -- -PID` nukes the whole tree (dev + zigbase + any in-flight rebuild).
# setsid(1) is util-linux-only (absent on macOS); the fallback uses bash job
# control (`set -m`), which also runs a background job in its own process
# group with PGID = its PID. DEV_SH_NO_SETSID=1 forces the fallback so the
# macOS path is testable on Linux.
launch_group() {
  local dir=$1 log=$2; shift 2
  if [[ -z "${DEV_SH_NO_SETSID:-}" ]] && command -v setsid >/dev/null 2>&1; then
    ( cd "$dir" && exec setsid "$@" ) > "$log" 2>&1 &
    echo $!
  else
    set -m
    ( cd "$dir" && exec "$@" ) > "$log" 2>&1 &
    local pid=$!
    set +m
    echo "$pid"
  fi
}

# Starts the dev loop in its own process group (see launch_group).
# $1 = log file; extra args are appended before `--`.
start_dev() {
  local log=$1; shift
  launch_group "$SRC" "$log" "$ZIGAPAGOS" dev --site="$OUT" --port=0 "$@" -- "${REBUILD[@]}"
}

# Extracts the origin from a dev log's ready line.
origin_from_log() {
  grep -o 'serving at http://[0-9.]*:[0-9]*' "$1" | head -1 | sed 's/serving at //'
}

# $1 = log, $2 = pid (optional). With a pid, a dev that DIES is reported as a
# death -- with its wait status -- instead of being polled at for the full 60s
# and then called a timeout.
#
# The distinction is not cosmetic. A crashed dev and a slow dev produce the same
# "never became ready" line, and the log of a process that died on its first
# instruction is one line long, so the message is all the reader gets. That cost
# a real diagnosis: a SIGILL on the zero-config leg read as a readiness timeout,
# and the only clue that it was a crash at all was `Illegal instruction` sitting
# in the dumped log, which is easy to skim past under a FAIL that says otherwise.
#
# `wait` reports the status of a child of THIS shell, so it works on the pid
# launch_group returned even though that pid leads a process group.
wait_ready() { # $1 = log, $2 = pid (optional)
  local log=$1 pid=${2:-}
  local start=$SECONDS
  until grep -q 'dev: ready' "$log" 2>/dev/null; do
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      local status=0
      wait "$pid" 2>/dev/null || status=$?
      echo "--- $log ---"; cat "$log"; echo "--- end $log ---"
      # 128+N is a signal death; name the signal, since SIGILL/SIGSEGV/SIGABRT
      # mean a zigapagos bug while SIGKILL usually means the runner OOMed.
      if (( status > 128 )); then
        fail "dev DIED before becoming ready: killed by SIG$(kill -l $((status - 128)) 2>/dev/null || echo "?($((status - 128)))") (status $status) -- this is a crash, not a timeout"
      fi
      fail "dev DIED before becoming ready: exited $status -- this is a crash, not a timeout"
    fi
    (( SECONDS - start < 60 )) || { echo "--- $log ---"; cat "$log"; echo "--- end $log ---"; fail "dev never became ready (60s timeout; process still alive)"; }
    sleep 0.5
  done
}

stop_dev() { # $1 = pid
  kill -TERM -- "-$1" 2>/dev/null || true
  poll 10 bash -c "! kill -0 $1 2>/dev/null" || fail "dev process $1 did not exit"
}

serves() { # $1 = origin, $2 = marker
  curl -sf "$1/" | grep -q "$2"
}

# --- (a) zero-config: NO arguments at all boots and serves ---------------------------
# `--site` used to be REQUIRED, and `zigapagos dev` with no arguments fataled
# with usage. Zero-config is the whole point of issue #56's dev change, so the
# no-argument invocation is the scenario worth pinning: it must default the
# output tree to `public/`, default the rebuild to this binary's own `release`,
# discover its own watch dirs, and reach `dev: ready`.
#
# The stub zigbase is already on PATH (see above), so nothing is downloaded —
# which is itself part of the contract: the implicit fetch only fires when the
# locator comes up empty.
echo "running: zigapagos dev (no arguments at all)..."
ZC_LOG="$WORK/zeroconf.log"
ZC_PID=$(launch_group "$SRC" "$ZC_LOG" "$ZIGAPAGOS" dev --port=0)
wait_ready "$ZC_LOG" "$ZC_PID"
ZC_ORIGIN=$(origin_from_log "$ZC_LOG")
[[ -n "$ZC_ORIGIN" ]] || { cat "$ZC_LOG"; fail "zero-config dev printed no origin"; }
serves "$ZC_ORIGIN" DEVLOOP-MARKER-V1 || { cat "$ZC_LOG"; fail "zero-config dev did not serve the built site"; }
# The default output tree is `public/` under the site root -- release's own
# default, so `dev` and a bare `release` agree on where the site lands.
test -f "$SRC/public/index.html" || { cat "$ZC_LOG"; fail "zero-config dev did not build into <site root>/public/"; }
# The default rebuild command is THIS binary by absolute path, not `zig build`.
grep -q "dev: initial build: $ZIGAPAGOS release --output=public --force" "$ZC_LOG" \
  || { cat "$ZC_LOG"; fail "zero-config dev did not default the rebuild to this binary's own release"; }
stop_dev "$ZC_PID"
rm -rf "$SRC/public"
echo "PASS: zero-config 'zigapagos dev' (no arguments) builds, serves and defaults correctly"

# --- (b) foot-gun guard: --site inside a watched dir ---------------------------------
echo "running: zigapagos dev --site=<inside content/> (guard)..."
if ( cd "$SRC" && "$ZIGAPAGOS" dev --site="$SRC/content/out" -- true ) > "$WORK/guard.log" 2>&1; then
  cat "$WORK/guard.log"; fail "a --site inside a watched dir should be refused"
fi
grep -q "is inside the watched dir" "$WORK/guard.log" || { cat "$WORK/guard.log"; fail "guard failure lacks the loop explanation"; }
echo "PASS: --site inside a watched dir is refused (rebuild-loop guard)"

# --- (c) boot + readiness + edit-triggered rebuild -----------------------------------
echo "running: zigapagos dev (boot + edit -> rebuild)..."
DEV_PID="$(start_dev "$WORK/dev1.log" --data-dir="$DATA")"
wait_ready "$WORK/dev1.log" "$DEV_PID"
ORIGIN="$(origin_from_log "$WORK/dev1.log")"
[[ -n "$ORIGIN" ]] || fail "could not parse the origin from the ready line"
serves "$ORIGIN" "DEVLOOP-MARKER-V1" || fail "initial build not served at $ORIGIN"
echo "PASS: boot + readiness (initial build served at $ORIGIN)"

test -f "$DATA/stub-zigbase.touch" || fail "--data-dir was not threaded to the server"
echo "sentinel" > "$DATA/devloop-sentinel"
TOUCH1="$(cat "$DATA/stub-zigbase.touch")"

sed -i.bak 's/DEVLOOP-MARKER-V1/DEVLOOP-MARKER-V2/' "$SRC/content/index.smd" && rm -f "$SRC/content/index.smd.bak"
poll 60 serves "$ORIGIN" "DEVLOOP-MARKER-V2" || { cat "$WORK/dev1.log"; fail "edited content never reached the served output"; }
grep -q "dev: rebuild OK" "$WORK/dev1.log" || { cat "$WORK/dev1.log"; fail "no rebuild-OK line after the edit"; }
echo "PASS: a source edit triggered a rebuild that changed the served output"

# --- (c2) live-reload: injected snippet + SSE reload on rebuild ----------------------
echo "running: live-reload (snippet injection + SSE notify)..."
# The served HTML carries the dev-only reload snippet (injected post-build).
serves "$ORIGIN" 'data-zigapagos-live-reload' || { cat "$WORK/dev1.log"; fail "served HTML missing the injected live-reload snippet"; }
RELOAD_URL="$(grep -o 'live-reload: http://[0-9.]*:[0-9]*' "$WORK/dev1.log" | head -1 | sed 's/live-reload: //')"
[[ -n "$RELOAD_URL" ]] || { cat "$WORK/dev1.log"; fail "no live-reload URL in the ready banner"; }
# Hold the SSE stream open, confirm the greeting, then trigger a rebuild; a
# `data: reload` event must arrive on the stream. Edit a comment (not the V2
# marker) so scenarios (e)/(f) still see DEVLOOP-MARKER-V2.
curl -sN --max-time 25 "$RELOAD_URL/" > "$WORK/sse.log" 2>/dev/null &
SSE_PID=$!
poll 10 grep -q ': connected' "$WORK/sse.log" || { cat "$WORK/sse.log"; fail "SSE greeting never arrived on $RELOAD_URL"; }
printf '\nLIVE-RELOAD-TOUCH\n' >> "$SRC/content/index.smd"
poll 30 grep -q '^data: reload' "$WORK/sse.log" || { cat "$WORK/sse.log"; cat "$WORK/dev1.log"; fail "no SSE reload event after a rebuild"; }
kill "$SSE_PID" 2>/dev/null || true
echo "PASS: live-reload snippet injected + SSE reload event fired on rebuild"

# The reload snippet is a DEV-ONLY post-build inject — a plain release build of
# the same site must be free of it.
( cd "$SRC" && "$ZIGAPAGOS" release "--output=$WORK/clean" --force ) >/dev/null 2>&1 || fail "clean release build failed"
if grep -rq 'data-zigapagos-live-reload' "$WORK/clean"; then
  fail "release output contains the dev-only live-reload snippet"
fi
echo "PASS: release output is free of the dev-only live-reload snippet"

# --- (d) teardown: no orphans, data dir SURVIVES -------------------------------------
stop_dev "$DEV_PID"
if curl -sf --max-time 2 -o /dev/null "$ORIGIN/"; then
  fail "server still answering at $ORIGIN after teardown"
fi
pgrep -f "stub-zigbase.ts.*$WORK" >/dev/null && fail "stub zigbase left behind (teardown)"
pgrep -f "dev --site=$OUT" >/dev/null && fail "zigapagos dev (watcher) left behind (teardown)"
test -d "$DATA" || fail "teardown deleted the data dir (must be persistent)"
test -f "$DATA/devloop-sentinel" || fail "teardown lost data-dir contents"
echo "PASS: teardown (origin dead, no dev/zigbase/watcher orphans, data dir intact)"

# --- (e) second run reuses the persistent data dir -----------------------------------
echo "running: zigapagos dev (second session, same --data-dir)..."
sleep 1.1 # the stub's touch payload is a ms timestamp; make strictly-newer observable
DEV_PID="$(start_dev "$WORK/dev2.log" --data-dir="$DATA")"
wait_ready "$WORK/dev2.log" "$DEV_PID"
ORIGIN2="$(origin_from_log "$WORK/dev2.log")"
serves "$ORIGIN2" "DEVLOOP-MARKER-V2" || fail "second session does not serve the tree"
test -f "$DATA/devloop-sentinel" || fail "second session lost the data-dir sentinel (state not persistent)"
TOUCH2="$(cat "$DATA/stub-zigbase.touch")"
[[ "$TOUCH2" != "$TOUCH1" ]] || fail "server did not re-open the same data dir"
stop_dev "$DEV_PID"
echo "PASS: persistent data dir reused across two dev sessions"

# --- (f) default data dir is .zigbase/ under the site root ---------------------------
echo "running: zigapagos dev (default --data-dir)..."
DEV_PID="$(start_dev "$WORK/dev3.log")"
wait_ready "$WORK/dev3.log" "$DEV_PID"
test -f "$SRC/.zigbase/stub-zigbase.touch" || fail "default data dir .zigbase/ not created at the site root"
stop_dev "$DEV_PID"
echo "PASS: default data dir is <site root>/.zigbase/"

# --- (g) the real consumer surface: `zigapagos dev` over examples/tsx-site ------------
# (a)-(f) run against a three-page fixture. This runs the same loop against the
# real example — four islands and five SPAs — with that project's own build.sh
# after `--`, which is exactly what a user types. It is the only scenario that
# proves the rebuild command and the served tree agree on a site big enough for
# them to disagree.
echo "running: zigapagos dev (tsx-site + its build.sh, stub zigbase on PATH)..."
( cd "$REPO/runtime" && mise exec -- bun install ) >/dev/null 2>&1 || fail "runtime bun install failed"
( cd "$SITE" && mise exec -- bun install ) >/dev/null 2>&1 || fail "consumer bun install failed"
# ZIGAPAGOS_BIN keeps build.sh from compiling a second binary; the dev loop
# passes its own environment through to the rebuild command, so this reaches it.
TSX_PID="$(launch_group "$SITE" "$WORK/tsx-dev.log" \
  env "ZIGAPAGOS_BIN=$ZIGAPAGOS" "$ZIGAPAGOS" dev --site=zig-out/site -- bash build.sh)"
# The first rebuild bundles five .spa.tsx entries and four islands through bun
# from a cold `.zigapagos-cache`. Overridable so a constrained runner can raise
# it without editing this file.
poll "${ZIGAPAGOS_E2E_TSX_DEV_TIMEOUT:-900}" grep -q 'dev: ready' "$WORK/tsx-dev.log" \
  || { tail -50 "$WORK/tsx-dev.log"; fail "tsx-site zigapagos dev never became ready"; }
TSX_ORIGIN="$(origin_from_log "$WORK/tsx-dev.log")"
curl -sf "$TSX_ORIGIN/" | grep -q 'data-z-island' || fail "tsx-site / missing islands SSR"
curl -sf "$TSX_ORIGIN/app/" | grep -q 'id="z-spa-root"' || fail "tsx-site /app/ not a SPA shell"
echo "PASS: zigapagos dev boots tsx-site and serves the islands page + SPA shell"

# A content edit must flow through build.sh into the served tree.
printf '\nDEVLOOP-TSX-MARKER\n' >> "$SITE/content/index.smd"
poll 180 bash -c "curl -sf '$TSX_ORIGIN/' | grep -q DEVLOOP-TSX-MARKER" \
  || { tail -50 "$WORK/tsx-dev.log"; fail "tsx-site edit never reached the served output"; }
echo "PASS: tsx-site edit rebuilt via its own build.sh"

kill -TERM -- "-$TSX_PID" 2>/dev/null || true
poll 15 bash -c "! kill -0 $TSX_PID 2>/dev/null" || fail "tsx-site zigapagos dev did not exit"
if curl -sf --max-time 2 -o /dev/null "$TSX_ORIGIN/"; then
  fail "tsx-site server still answering after teardown"
fi
pgrep -f "stub-zigbase.ts" >/dev/null && fail "stub zigbase left behind after tsx-site run"
git -C "$REPO" checkout -- examples/tsx-site/content
restore_snapshots
echo "PASS: tsx-site teardown clean"

# --- (h) opt-in: the same loop against a REAL zigbase binary -------------------------
if [[ -n "${REAL_ZIGBASE:-}" && -x "${REAL_ZIGBASE:-}" ]]; then
  echo "running: zigapagos dev against the REAL zigbase ($REAL_ZIGBASE)..."
  sed -i.bak 's/DEVLOOP-MARKER-V2/DEVLOOP-MARKER-V1/' "$SRC/content/index.smd" && rm -f "$SRC/content/index.smd.bak"
  RDATA="$WORK/real-data"
  DEV_PID="$(start_dev "$WORK/real.log" --data-dir="$RDATA" --zigbase="$REAL_ZIGBASE")"
  wait_ready "$WORK/real.log" "$DEV_PID"
  RORIGIN="$(origin_from_log "$WORK/real.log")"
  serves "$RORIGIN" "DEVLOOP-MARKER-V1" || { tail -30 "$WORK/real.log"; fail "real zigbase does not serve the tree"; }
  curl -s "$RORIGIN/api/health" >/dev/null || true # API surface exists (same origin)
  test -e "$RDATA" || fail "real zigbase did not use the data dir"
  sed -i.bak 's/DEVLOOP-MARKER-V1/DEVLOOP-MARKER-V2/' "$SRC/content/index.smd" && rm -f "$SRC/content/index.smd.bak"
  poll 60 serves "$RORIGIN" "DEVLOOP-MARKER-V2" || { tail -30 "$WORK/real.log"; fail "real-zigbase run: edit never reached the served output"; }
  stop_dev "$DEV_PID"
  if curl -sf --max-time 2 -o /dev/null "$RORIGIN/"; then
    fail "real zigbase still answering after teardown"
  fi
  echo "PASS: real-zigbase dev loop (boot + rebuild-on-edit + teardown)"
else
  echo "SKIP: real-zigbase scenario (set REAL_ZIGBASE=/path/to/zigbase to enable)"
fi

echo "PASS: dev loop (boot + readiness + rebuild-on-edit + persistent data dir + teardown + tsx-site)"
