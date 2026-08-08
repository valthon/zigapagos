#!/usr/bin/env bash
# e2e for `zigapagos dev --background` + `dev stop|status|logs` + the
# build-aware status endpoint (#126). Hermetic via tests/dev/stub-zigbase.ts
# (see its /api/health route, added for scenario (g) below).
#
# Asserts:
#   (a) --background: parent exits 0 printing url+pid; server answers; dev.json
#       + dev.lock exist; dev.log captures the session output
#   (b) status: exit 0 + "pid <N>" + build info while running; --json is
#       parseable and carries "running":true and a numeric build generation;
#       both forms' payload lands on STDOUT specifically (F1: stdout and
#       stderr captured separately, asserting the payload is absent from the
#       stderr capture — diagnostics like the Debug-build banner may still be
#       there)
#   (c) build-aware loop — the agent workflow: a content edit bumps
#       build.generation on the status endpoint and status flips to "ok"; a
#       BROKEN edit (a layout that doesn't exist) flips status to "failed"
#       with a non-empty "error" field, and fixing it flips back to "ok"
#   (d) duplicate start: second --background exits 0 with "already running";
#       plain foreground dev REFUSES (exit != 0) on the same project;
#       --ignore-lock --background is a parse-time error (both flags conflict)
#   (e) logs: dumps the log; logs --follow sees a new rebuild line arrive;
#       the dump's payload lands on STDOUT specifically (F1, same
#       stdout/stderr-separated assert as (b))
#   (f) stop: exit 0, port freed, dev.json gone (dev.lock is NEVER deleted —
#       see dev_control.zig's module doc); second stop exits 0 with
#       "No dev server is running."
#   (g) orphan sweep: kill -9 the dev pid (asserted alive first, so the sweep
#       is proven to do something), stub keeps serving, dev stop reaps it via
#       /api/health verification ("reaping orphaned zigbase"), port freed
#   (h) status endpoint exists and answers under --no-live-reload
#   (i) auto-background: CLAUDECODE=1 (with the opt-out unset) backgrounds
#       without --background; ZIGAPAGOS_DEV_BACKGROUND=0 keeps it foreground
#       even with CLAUDECODE=1 set
#   (j) --force replaces a live session: (j1) `dev --background --force`
#       kills the old pid and starts a new tracked session with a different
#       pid that answers; (j2) foreground `dev --force` does the same and
#       itself reaches "dev: ready" (launched via launch_group, torn down
#       with the group-kill helper)
#   (k) status during the STARTING window (#140 review): with nothing
#       running at all, `dev status` still says "No dev server is running.";
#       holding the flock on .zigbase/dev.lock with no dev.json published
#       (the window stopInstance already knows as `.starting`) makes status
#       exit 1 with a truthful "starting" message / --json "starting":true
#       instead of the pre-fix "No dev server is running." — flock(1) is
#       util-linux, so this leg is skipped (with a note) where it's absent
#       (macOS)
#   (l) control-server bind failure (#140 round 2, P2b): occupying
#       --reload-port before starting makes `dev --background` exit nonzero
#       (the control server's listen() is now synchronous in Server.start(),
#       so a bind conflict is a fatal the PARENT observes, not a background-
#       thread log line) -- the error mentions the port and --reload-port,
#       and dev.json is never written advertising a control plane that was
#       never actually listening
#
# `dev stop` exit codes (dev_control.zig's stopVerb): 0 for both "stopped"
# and "nothing was running" (idempotent success) — 1 ONLY for ".starting",
# a session caught between acquiring its lock and publishing dev.json. None
# of the scenarios below race that window, so every stop here is exit 0.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../.. && pwd)"
# Keep dev foreground unless a scenario opts in: this harness manages the
# process itself, and most scenarios use `--background` explicitly anyway.
export ZIGAPAGOS_DEV_BACKGROUND=0

WORK="$(mktemp -d)"

fail() { echo "FAIL: $*"; exit 1; }

# Tracks pids/dirs a mid-scenario failure could otherwise strand, so the trap
# can clean them up even when the script dies partway through. `dev stop` is
# tried FIRST (idempotent, and it's the real interface for tearing a session
# down — TERM the dev pid, escalate to KILL, sweep the zigbase orphan); the
# pid/pkill fallbacks below exist only for the failure modes `dev stop` can't
# itself recover from (a session it never got to track, or one whose own
# `dev stop` invocation is what's under test and might be broken).
FG_PID=""
cleanup() {
  if [[ -d "$SITE_DIR" ]]; then
    ( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) >/dev/null 2>&1 || true
  fi
  if [[ -n "$FG_PID" ]]; then
    kill -TERM -- "-$FG_PID" 2>/dev/null || true
  fi
  # Catch-all: any stub zigbase (or anything else) whose argv names this
  # run's scratch dir (data dir / served tree, both under $WORK).
  pkill -f "$WORK" 2>/dev/null || true
  sleep 0.2
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- build zigapagos ---------------------------------------------------------
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
fi

# --- put the stub "zigbase" on PATH ------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/zigbase" <<EOF
#!/usr/bin/env bash
# STUB zigbase for tests/dev/background.sh — see tests/dev/stub-zigbase.ts
exec bun "$HERE/stub-zigbase.ts" "\$@"
EOF
chmod +x "$BIN/zigbase"
export PATH="$BIN:$PATH"

# --- minimal site fixture ----------------------------------------------------
SITE_DIR="$WORK/site"
mkdir -p "$SITE_DIR"
cp -r "$REPO/tests/rendering/simple/content" "$REPO/tests/rendering/simple/layouts" "$SITE_DIR/"
cp "$REPO/tests/rendering/simple/zigapagos.ziggy" "$SITE_DIR/"
DEV_JSON="$SITE_DIR/.zigbase/dev.json"

# --- helpers ------------------------------------------------------------------

# Launches "$@" (cwd = $1, log = $2) as its own process-group leader, so
# `kill -- -PID` can take down the whole tree. Only used for scenario (i)'s
# foreground opt-out leg — every other scenario runs `dev --background`,
# which returns control to THIS shell itself once ready (no group needed).
launch_group() {
  local dir=$1 log=$2; shift 2
  if command -v setsid >/dev/null 2>&1; then
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

poll() { # deadline_secs cmd...
  local deadline=$1; shift; local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start < deadline )) || return 1
    sleep 0.3
  done
}

# Reads one integer-valued key out of dev.json, tolerant of the pretty-
# printed (indent_2) form: `"key": 1234,`. `"pid"` vs `"zigbase_pid"` (and
# `"port"` vs `"control_port"`) never collide here — grep -o with the
# leading `"` anchors on the quote that opens the key name, and neither
# short key appears as a suffix of the long one preceded by a quote.
json_field() { # $1 = file, $2 = key
  grep -o "\"$2\": *[0-9]*" "$1" | head -1 | grep -o '[0-9]*$'
}

# The control endpoint's own JSON is compact (std.json.Stringify's default),
# unlike dev.json — no space-tolerant pattern needed here. `--max-time` keeps
# a broken/unreachable control port a fast failure (via generation()'s -1
# sentinel below) rather than a multi-minute hang in a tight poll loop — a
# real risk: an unresponsive loopback port does not always RST immediately.
status_json() { curl -sf --max-time 5 "http://127.0.0.1:$CONTROL_PORT/_zigapagos/status" 2>/dev/null; }
generation() {
  local g
  g="$(status_json | grep -o '"generation":[0-9]*' | head -1 | cut -d: -f2)"
  echo "${g:--1}" # a transient curl/parse miss must look "behind", never "caught up"
}
build_status() { status_json | grep -o '"status":"[a-z]*"' | head -1 | cut -d'"' -f4; }

wait_for_generation_past() {
  local prev="$1" deadline=$((SECONDS + 30))
  while [ "$(generation)" -le "$prev" ]; do
    [ $SECONDS -lt $deadline ] || { echo "FAIL: generation never passed $prev"; exit 1; }
    sleep 0.2
  done
}

echo "running: background.sh e2e (#126)..."

# --- (a) --background lifecycle ----------------------------------------------
( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 ) \
  > "$WORK/bg-out.txt" 2>&1 || { cat "$WORK/bg-out.txt"; fail "--background parent did not exit 0"; }
grep -q 'dev: running in the background at http://' "$WORK/bg-out.txt" \
  || { cat "$WORK/bg-out.txt"; fail "--background parent printed no ready banner"; }
test -f "$DEV_JSON" || fail "dev.json missing after --background"
test -f "$SITE_DIR/.zigbase/dev.lock" || fail "dev.lock missing after --background"
test -f "$SITE_DIR/.zigbase/dev.log" || fail "dev.log missing after --background"

SERVE_PORT="$(json_field "$DEV_JSON" port)"
CONTROL_PORT="$(json_field "$DEV_JSON" control_port)"
DEV_PID="$(json_field "$DEV_JSON" pid)"
[[ -n "$SERVE_PORT" && -n "$CONTROL_PORT" && -n "$DEV_PID" ]] \
  || { cat "$DEV_JSON"; fail "could not parse port/control_port/pid from dev.json"; }
curl -sf --max-time 5 "http://127.0.0.1:$SERVE_PORT/" > /dev/null || fail "background server not answering"
echo "PASS: (a) --background lifecycle"

# --- (b) status ----------------------------------------------------------------
# stdout and stderr are captured SEPARATELY here (not `2>&1`) specifically to
# pin F1: `dev status`'s human answer and its --json body are the PAYLOAD an
# agent pipes/parses, and must be on stdout, not stderr (where
# std.debug.print used to send them). A Debug build's own banner legitimately
# lands on stderr too, so the assert below greps it out before checking the
# payload isn't there, rather than requiring stderr to be empty outright.
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev status ) > "$WORK/status.out" 2> "$WORK/status.err" \
  || { cat "$WORK/status.out" "$WORK/status.err"; fail "'dev status' exited nonzero while a session is running"; }
grep -q "pid $DEV_PID" "$WORK/status.out" || { cat "$WORK/status.out"; fail "status text missing pid on stdout"; }
if grep -q "pid $DEV_PID" "$WORK/status.err"; then
  cat "$WORK/status.err"; fail "'dev status' text payload leaked onto stderr"
fi
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev status --json ) > "$WORK/status.json" 2> "$WORK/status-json.err" \
  || { cat "$WORK/status.json" "$WORK/status-json.err"; fail "'dev status --json' exited nonzero while running"; }
grep -q '"running":true' "$WORK/status.json" || { cat "$WORK/status.json"; fail "status --json missing running:true on stdout"; }
grep -Eq '"generation":[0-9]+' "$WORK/status.json" || { cat "$WORK/status.json"; fail "status --json missing a numeric build generation"; }
if grep -q '"running"' "$WORK/status-json.err"; then
  cat "$WORK/status-json.err"; fail "'dev status --json' JSON body leaked onto stderr"
fi
echo "PASS: (b) dev status + dev status --json (payload on stdout, not stderr)"

# --- (c) build-aware loop: the agent workflow -----------------------------------
# A plain content edit: full rebuild, status flips (back) to "ok".
GEN="$(generation)"
printf '\nBACKGROUND-EDIT-1\n' >> "$SITE_DIR/content/index.smd"
wait_for_generation_past "$GEN"
[ "$(build_status)" = "ok" ] || { status_json; fail "build status not 'ok' after a clean edit"; }

# A BROKEN edit: point the layout at a file that doesn't exist. Verified
# standalone against `zigapagos release` before relying on it here — it is a
# hard content/frontmatter error (missing layout file), not a warning.
GEN="$(generation)"
sed -i.bak 's/\.layout = "index\.shtml"/.layout = "does-not-exist.shtml"/' "$SITE_DIR/content/index.smd" \
  && rm -f "$SITE_DIR/content/index.smd.bak"
wait_for_generation_past "$GEN"
[ "$(build_status)" = "failed" ] || { status_json; fail "build status not 'failed' after the broken edit"; }
status_json | grep -q '"error":"' || { status_json; fail "failed build has no non-null error field"; }
grep -q 'dev: rebuild FAILED' "$SITE_DIR/.zigbase/dev.log" || fail "dev.log missing the rebuild-FAILED line"

# Fix it: status flips back to "ok".
GEN="$(generation)"
sed -i.bak 's/\.layout = "does-not-exist\.shtml"/.layout = "index.shtml"/' "$SITE_DIR/content/index.smd" \
  && rm -f "$SITE_DIR/content/index.smd.bak"
wait_for_generation_past "$GEN"
[ "$(build_status)" = "ok" ] || { status_json; fail "build status did not recover to 'ok' after the fix"; }
echo "PASS: (c) build-aware loop (edit -> generation bump -> ok/failed/ok)"

# --- (d) duplicates --------------------------------------------------------------
( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 ) \
  > "$WORK/dup.txt" 2>&1 || { cat "$WORK/dup.txt"; fail "a duplicate --background start must exit 0 (idempotent)"; }
grep -q 'already running' "$WORK/dup.txt" || { cat "$WORK/dup.txt"; fail "duplicate start did not report 'already running'"; }

if ( cd "$SITE_DIR" && "$ZIGAPAGOS" dev --port=0 ) > "$WORK/fg-dup.txt" 2>&1; then
  cat "$WORK/fg-dup.txt"; fail "foreground dev started over a live background session"
fi
grep -q 'already running' "$WORK/fg-dup.txt" || { cat "$WORK/fg-dup.txt"; fail "foreground refusal did not mention 'already running'"; }

if ( cd "$SITE_DIR" && "$ZIGAPAGOS" dev --ignore-lock --background ) > "$WORK/conflict.txt" 2>&1; then
  cat "$WORK/conflict.txt"; fail "--ignore-lock --background did not conflict"
fi
grep -q 'cannot be combined' "$WORK/conflict.txt" || { cat "$WORK/conflict.txt"; fail "--ignore-lock --background rejection lacks the usage explanation"; }
echo "PASS: (d) duplicate-start handling (--background idempotent, foreground refuses, --ignore-lock conflicts)"

# --- (e) logs ----------------------------------------------------------------
# Same F1 rationale as (b): stdout/stderr captured separately so the log
# dump's payload — what `zigapagos dev logs | grep` reads — is asserted on
# stdout and absent from stderr, not just present somewhere in a merged
# stream.
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev logs ) > "$WORK/logs.out" 2> "$WORK/logs.err" \
  || { cat "$WORK/logs.out" "$WORK/logs.err"; fail "'dev logs' exited nonzero"; }
grep -q 'dev: ready — serving at http://' "$WORK/logs.out" || { cat "$WORK/logs.out"; fail "'dev logs' dump missing the ready banner on stdout"; }
if grep -q 'dev: ready — serving at http://' "$WORK/logs.err"; then
  cat "$WORK/logs.err"; fail "'dev logs' dump payload leaked onto stderr"
fi

GEN="$(generation)"
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev logs --follow ) > "$WORK/follow.txt" 2>&1 &
FOLLOW_PID=$!
poll 10 test -s "$WORK/follow.txt" || { kill "$FOLLOW_PID" 2>/dev/null || true; fail "'dev logs --follow' produced no initial dump"; }
SIZE_BEFORE="$(wc -c < "$WORK/follow.txt")"
printf '\nFOLLOW-MARKER\n' >> "$SITE_DIR/content/index.smd"
wait_for_generation_past "$GEN"
poll 15 bash -c "[ \"\$(wc -c < '$WORK/follow.txt')\" -gt $SIZE_BEFORE ]" \
  || { cat "$WORK/follow.txt"; fail "'dev logs --follow' never saw new output after a rebuild"; }
grep -q 'dev: rebuild OK' "$WORK/follow.txt" || { cat "$WORK/follow.txt"; fail "'dev logs --follow' output missing the new rebuild line"; }
kill "$FOLLOW_PID" 2>/dev/null || true
wait "$FOLLOW_PID" 2>/dev/null || true
echo "PASS: (e) dev logs + dev logs --follow"

# --- (f) stop ------------------------------------------------------------------
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > "$WORK/stop1.txt" 2>&1 \
  || { cat "$WORK/stop1.txt"; fail "'dev stop' on a live session exited nonzero"; }
grep -q 'Stopped\.' "$WORK/stop1.txt" || { cat "$WORK/stop1.txt"; fail "'dev stop' did not report 'Stopped.'"; }
test -f "$DEV_JSON" && fail "dev.json still present after stop"
# dev.lock is NEVER deleted (dev_control.zig's module doc: `remove()` deletes
# dev.json only) — asserting it survives pins that contract, not just leaves
# it unchecked.
test -f "$SITE_DIR/.zigbase/dev.lock" || fail "dev.lock should survive 'dev stop' (it is never deleted) but is gone"
if curl -sf --max-time 2 "http://127.0.0.1:$SERVE_PORT/" > /dev/null 2>&1; then
  fail "port still serving after stop"
fi

( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > "$WORK/stop2.txt" 2>&1 \
  || { cat "$WORK/stop2.txt"; fail "a second (no-op) 'dev stop' must still exit 0"; }
grep -q 'No dev server is running' "$WORK/stop2.txt" || { cat "$WORK/stop2.txt"; fail "second stop did not report 'No dev server is running.'"; }
echo "PASS: (f) dev stop (idempotent, port freed, dev.json gone, dev.lock survives)"

# --- (g) orphan sweep ------------------------------------------------------------
( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 ) \
  > "$WORK/bg2.txt" 2>&1 || { cat "$WORK/bg2.txt"; fail "second --background session did not start"; }
DEV_PID="$(json_field "$DEV_JSON" pid)"
ZB_PID="$(json_field "$DEV_JSON" zigbase_pid)"
SERVE_PORT="$(json_field "$DEV_JSON" port)"
[[ -n "$DEV_PID" && -n "$ZB_PID" && "$ZB_PID" != "0" ]] || { cat "$DEV_JSON"; fail "could not parse pid/zigbase_pid for the orphan-sweep session"; }

kill -9 "$DEV_PID"
poll 10 bash -c "! kill -0 $DEV_PID 2>/dev/null" || fail "kill -9 did not take down the dev pid"
kill -0 "$ZB_PID" 2>/dev/null || fail "zigbase pid $ZB_PID is not alive right after kill -9 — the orphan-sweep scenario proves nothing without a live orphan first"
curl -sf "http://127.0.0.1:$SERVE_PORT/" > /dev/null || fail "orphaned stub zigbase stopped serving (should still be up)"

( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > "$WORK/sweep.txt" 2>&1 \
  || { cat "$WORK/sweep.txt"; fail "'dev stop' on an orphaned session exited nonzero"; }
grep -q 'reaping orphaned zigbase' "$WORK/sweep.txt" || { cat "$WORK/sweep.txt"; fail "'dev stop' did not report reaping the orphaned zigbase"; }
if kill -0 "$ZB_PID" 2>/dev/null; then fail "orphaned zigbase (pid $ZB_PID) survived 'dev stop'"; fi
if curl -sf --max-time 2 "http://127.0.0.1:$SERVE_PORT/" > /dev/null 2>&1; then
  fail "port still serving after the orphan sweep"
fi
echo "PASS: (g) orphan sweep (kill -9 dev pid -> stub survives -> dev stop reaps it via /api/health)"

# --- (h) status endpoint under --no-live-reload -----------------------------------
( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --no-live-reload --port=0 ) \
  > "$WORK/bg3.txt" 2>&1 || { cat "$WORK/bg3.txt"; fail "--background --no-live-reload did not start"; }
CONTROL_PORT="$(json_field "$DEV_JSON" control_port)"
[[ -n "$CONTROL_PORT" ]] || { cat "$DEV_JSON"; fail "no control_port under --no-live-reload"; }
status_json | grep -q '"ok":true' || { status_json; fail "status endpoint did not answer 'ok':true under --no-live-reload"; }
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > /dev/null 2>&1 || fail "'dev stop' failed to tear down the --no-live-reload session"
echo "PASS: (h) status endpoint survives --no-live-reload"

# --- (i) agent auto-detection ------------------------------------------------------
( cd "$SITE_DIR" && env -u ZIGAPAGOS_DEV_BACKGROUND CLAUDECODE=1 "$ZIGAPAGOS" dev --port=0 ) \
  > "$WORK/agent.txt" 2>&1 || { cat "$WORK/agent.txt"; fail "auto-backgrounded agent session did not exit 0"; }
grep -q 'agent environment detected (Claude Code)' "$WORK/agent.txt" || { cat "$WORK/agent.txt"; fail "no agent-detection attribution line"; }
grep -q 'dev: running in the background' "$WORK/agent.txt" || { cat "$WORK/agent.txt"; fail "auto-backgrounded session printed no background banner"; }
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > /dev/null 2>&1 || fail "'dev stop' failed to tear down the auto-backgrounded session"

# Opt-out: ZIGAPAGOS_DEV_BACKGROUND=0 (exported globally, above) must win over
# CLAUDECODE=1 and keep the session in the FOREGROUND — launch it as its own
# process group (this shell manages it directly, like dev.sh/dev-incremental.sh
# do for every foreground session) and tear it down with a group kill.
FG_LOG="$WORK/fg-agent.log"
FG_PID="$(CLAUDECODE=1 launch_group "$SITE_DIR" "$FG_LOG" "$ZIGAPAGOS" dev --port=0)"
poll 60 grep -q 'dev: ready' "$FG_LOG" || { cat "$FG_LOG"; fail "opted-out foreground session never became ready"; }
grep -q 'dev: ready — serving at http://' "$FG_LOG" || { cat "$FG_LOG"; fail "opted-out session's own output has no ready banner"; }
if grep -q 'dev: running in the background' "$FG_LOG"; then
  cat "$FG_LOG"; fail "ZIGAPAGOS_DEV_BACKGROUND=0 did not override CLAUDECODE=1 detection"
fi
kill -TERM -- "-$FG_PID" 2>/dev/null || true
poll 10 bash -c "! kill -0 $FG_PID 2>/dev/null" || fail "opted-out foreground dev process did not exit"
FG_PID=""
echo "PASS: (i) agent auto-detection (CLAUDECODE=1 backgrounds; ZIGAPAGOS_DEV_BACKGROUND=0 opts back out)"

# --- (j) --force replaces a live session ---------------------------------------
# --force has spec-mandated coverage (design doc's Testing section) but had
# NO e2e leg (F2): both real --force paths — the background parent's
# stop-then-spawn and dev.zig's own foreground stop-then-reacquire — compose
# stopInstance() + a re-acquire and are exactly the kind of seam a
# whole-branch review exists to check.

# (j1) background: a live --background session, then `dev --background
# --force` replaces it — old pid dies, new dev.json carries a different pid,
# the replacement answers.
( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 ) \
  > "$WORK/force-bg1.txt" 2>&1 || { cat "$WORK/force-bg1.txt"; fail "(j1) initial --background session did not start"; }
OLD_PID="$(json_field "$DEV_JSON" pid)"
[[ -n "$OLD_PID" ]] || { cat "$DEV_JSON"; fail "(j1) could not parse pid from the initial session"; }

( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --force --port=0 ) \
  > "$WORK/force-bg2.txt" 2>&1 || { cat "$WORK/force-bg2.txt"; fail "(j1) 'dev --background --force' did not exit 0"; }
poll 10 bash -c "! kill -0 $OLD_PID 2>/dev/null" || fail "(j1) old background pid $OLD_PID survived --force"
NEW_PID="$(json_field "$DEV_JSON" pid)"
[[ -n "$NEW_PID" ]] || { cat "$DEV_JSON"; fail "(j1) could not parse pid from the replacement session"; }
[[ "$NEW_PID" != "$OLD_PID" ]] || fail "(j1) --force did not produce a new pid"
NEW_PORT="$(json_field "$DEV_JSON" port)"
[[ -n "$NEW_PORT" ]] || { cat "$DEV_JSON"; fail "(j1) could not parse port from the replacement session"; }
curl -sf --max-time 5 "http://127.0.0.1:$NEW_PORT/" > /dev/null || fail "(j1) replacement background server not answering"
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > /dev/null 2>&1 || fail "(j1) 'dev stop' failed to tear down the --force replacement"
echo "PASS: (j1) 'dev --background --force' replaces a live background session"

# (j2) foreground: a live --background session, then a FOREGROUND `dev
# --force` replaces it and itself reaches readiness — launched via
# launch_group (like (i)'s opt-out leg) since this leg does not return
# control to this shell until it exits or is killed; ZIGAPAGOS_DEV_BACKGROUND=0
# (exported globally, above) keeps it foreground so --force alone drives it,
# with no auto-background/detection in play.
( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 ) \
  > "$WORK/force-fg1.txt" 2>&1 || { cat "$WORK/force-fg1.txt"; fail "(j2) initial --background session did not start"; }
OLD_PID="$(json_field "$DEV_JSON" pid)"
[[ -n "$OLD_PID" ]] || { cat "$DEV_JSON"; fail "(j2) could not parse pid from the initial session"; }

FG_LOG="$WORK/force-fg.log"
FG_PID="$(launch_group "$SITE_DIR" "$FG_LOG" "$ZIGAPAGOS" dev --force --port=0)"
poll 60 grep -q 'dev: ready' "$FG_LOG" || { cat "$FG_LOG"; fail "(j2) foreground 'dev --force' session never became ready"; }
grep -q 'dev: ready — serving at http://' "$FG_LOG" || { cat "$FG_LOG"; fail "(j2) foreground --force session's own output has no ready banner"; }
poll 10 bash -c "! kill -0 $OLD_PID 2>/dev/null" || fail "(j2) old background pid $OLD_PID survived a foreground --force"
kill -TERM -- "-$FG_PID" 2>/dev/null || true
poll 10 bash -c "! kill -0 $FG_PID 2>/dev/null" || fail "(j2) foreground --force dev process did not exit"
FG_PID=""
echo "PASS: (j2) foreground 'dev --force' replaces a live background session"

# --- (k) status during the STARTING window (#140 review) -----------------------
# statusVerb used to key its "is a session running?" answer on `!live or
# lf==null`, which folds the flock-held-but-dev.json-not-yet-written race
# into the same branch as "nothing running at all" -- printing "No dev
# server is running." while a session genuinely holds the lock.
# `stopInstance` already resolves this exact race as `.starting` (it polls
# up to 5s for dev.json before giving up); `status` must agree instead of
# contradicting it, without itself polling (it's a snapshot verb).
( cd "$SITE_DIR" && "$ZIGAPAGOS" dev stop ) > /dev/null 2>&1 || true
rm -f "$DEV_JSON"

# Baseline: nothing running/held at all.
if ( cd "$SITE_DIR" && "$ZIGAPAGOS" dev status ) > "$WORK/status-none.out" 2>&1; then
  cat "$WORK/status-none.out"; fail "(k) 'dev status' with nothing running must exit nonzero"
fi
grep -q 'No dev server is running' "$WORK/status-none.out" \
  || { cat "$WORK/status-none.out"; fail "(k) 'dev status' with nothing running did not say so"; }
echo "PASS: (k0) dev status with nothing running at all"

if command -v flock >/dev/null 2>&1; then
  mkdir -p "$SITE_DIR/.zigbase"
  : > "$SITE_DIR/.zigbase/dev.lock"
  FLOCK_MARKER="$WORK/lock-acquired"
  rm -f "$FLOCK_MARKER"
  # Hold the flock ourselves, from a subshell that owns the fd -- this is
  # exactly dev_lockfile.acquire()'s own primitive, just driven from bash:
  # the lock is live, but (unlike a real session) dev.json is never written.
  (
    exec 9>"$SITE_DIR/.zigbase/dev.lock"
    flock -x 9
    touch "$FLOCK_MARKER"
    sleep 10
  ) &
  FLOCK_BG_PID=$!
  poll 5 test -f "$FLOCK_MARKER" \
    || { kill "$FLOCK_BG_PID" 2>/dev/null || true; fail "(k) could not acquire the flock for the starting-state e2e leg"; }

  if ( cd "$SITE_DIR" && "$ZIGAPAGOS" dev status ) > "$WORK/status-starting.out" 2>&1; then
    kill "$FLOCK_BG_PID" 2>/dev/null || true
    cat "$WORK/status-starting.out"; fail "(k) 'dev status' during the starting window must exit nonzero"
  fi
  grep -q 'is starting' "$WORK/status-starting.out" \
    || { kill "$FLOCK_BG_PID" 2>/dev/null || true; cat "$WORK/status-starting.out"; fail "(k) 'dev status' during the starting window did not report it"; }

  if ( cd "$SITE_DIR" && "$ZIGAPAGOS" dev status --json ) > "$WORK/status-starting.json" 2>&1; then
    kill "$FLOCK_BG_PID" 2>/dev/null || true
    cat "$WORK/status-starting.json"; fail "(k) 'dev status --json' during the starting window must exit nonzero"
  fi
  grep -q '"starting":true' "$WORK/status-starting.json" \
    || { kill "$FLOCK_BG_PID" 2>/dev/null || true; cat "$WORK/status-starting.json"; fail "(k) 'dev status --json' during the starting window missing starting:true"; }

  kill "$FLOCK_BG_PID" 2>/dev/null || true
  wait "$FLOCK_BG_PID" 2>/dev/null || true
  echo "PASS: (k) dev status reports the starting window truthfully (exit 1 + starting message / --json starting:true)"
else
  echo "SKIP: (k) dev status starting-window leg (flock(1) unavailable -- util-linux only, absent on macOS)"
fi

# --- (l) control-server bind failure fatals BEFORE dev.json is written (#140 round 2, P2b) --
# Server.start() used to bind inside its detached accept thread, so a bind
# conflict on --reload-port only ever reached a std.debug.print from that
# thread -- dev.zig had no way to see it, and a healthy-looking dev.json
# could still get written and advertise a control plane that was never
# actually listening. start() now binds synchronously, so dev.zig's existing
# `fatal.msg` on its failure actually fires, and fires before dev.json exists.
rm -f "$DEV_JSON"
OCCUPY_LOG="$WORK/occupy-port.log"
# process.stdout.write (not console.log) sidesteps bun's number colorization,
# which would otherwise embed ANSI escapes ahead of the port digits.
bun -e '
const server = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { open() {}, data() {}, close() {} } });
process.stdout.write(String(server.port) + "\n");
setInterval(() => {}, 60000); // keep the event loop (and the bound socket) alive
' > "$OCCUPY_LOG" 2>&1 &
OCCUPY_PID=$!
poll 5 test -s "$OCCUPY_LOG" \
  || { kill "$OCCUPY_PID" 2>/dev/null || true; cat "$OCCUPY_LOG"; fail "(l) could not start the port-occupier"; }
OCCUPIED_PORT="$(head -1 "$OCCUPY_LOG" | tr -d '[:space:]')"
[[ -n "$OCCUPIED_PORT" ]] || { kill "$OCCUPY_PID" 2>/dev/null || true; fail "(l) could not read the occupied port"; }

if ( cd "$SITE_DIR" && ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 --reload-port="$OCCUPIED_PORT" ) \
  > "$WORK/bindfail.txt" 2>&1; then
  kill "$OCCUPY_PID" 2>/dev/null || true
  cat "$WORK/bindfail.txt"; fail "(l) 'dev --background' must exit nonzero when --reload-port is already bound"
fi
kill "$OCCUPY_PID" 2>/dev/null || true
wait "$OCCUPY_PID" 2>/dev/null || true
grep -q -- "--reload-port" "$WORK/bindfail.txt" \
  || { cat "$WORK/bindfail.txt"; fail "(l) bind-failure error did not mention --reload-port"; }
grep -q "$OCCUPIED_PORT" "$WORK/bindfail.txt" \
  || { cat "$WORK/bindfail.txt"; fail "(l) bind-failure error did not mention the occupied port"; }
test -f "$DEV_JSON" && fail "(l) dev.json must not exist after a control-server bind failure"
echo "PASS: (l) control-server bind failure fatals before dev.json is written, naming the port and --reload-port"

echo "PASS tests/dev/background.sh"
