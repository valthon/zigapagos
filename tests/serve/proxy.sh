#!/usr/bin/env bash
# e2e for `zigapagos serve --proxy PREFIX=UPSTREAM` (dev-server-api-proxy).
#
# Hardened so the earlier substring-only greps can't mask a regression. Starts a
# mock upstream + a `zigapagos serve` with two proxy rules (/api -> mock, /dead -> a
# port nothing listens on) and asserts:
#   (a) a static path is served locally (proxy NOT entered),
#   (b) GET /api/echo reaches upstream and Set-Cookie + X-Forwarded-For relay,
#  (b2) C1: GET /api/echo?q=a%20b returns 200 and the UPSTREAM observed the RAW
#       still-encoded target "/api/echo?q=a%20b" (a decoded target would 505 and
#       enable header injection),
#   (c) POST /api/echo forwards the body AND the request Cookie round-trips,
#   (d) GET /api/sse streams live — event 1 arrives measurably before event 2,
#  (d2) C2: the client-received SSE body is EXACTLY the two event blocks, with NO
#       leaked chunk-size lines (bare hex),
#   (e) a dead upstream yields 502,
#   (f) an Upgrade: websocket request yields 501.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../.. && pwd)"

restore_snapshots() {
  git -C "$REPO" ls-files --deleted -z -- tests/ | xargs -0 -I{} git -C "$REPO" restore -- {}
}

ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
SITE="$REPO/tests/rendering/simple"
WORK="$(mktemp -d)"
MOCK_LOG="$WORK/mock.log"
ZIGAPAGOS_LOG="$WORK/zigapagos.log"
MOCK_PID=""
ZIGAPAGOS_PID=""

cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
  [[ -n "$ZIGAPAGOS_PID" ]] && kill "$ZIGAPAGOS_PID" 2>/dev/null || true
  rm -rf "$WORK"
  restore_snapshots
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; echo "--- zigapagos log ---"; cat "$ZIGAPAGOS_LOG" 2>/dev/null || true; echo "--- mock log ---"; cat "$MOCK_LOG" 2>/dev/null || true; exit 1; }

# A port that WAS bound then released — nothing is listening on it now, so a
# connect attempt is refused (drives the 502 path).
free_port() {
  mise exec -- bun -e 'const s=Bun.serve({port:0,fetch(){return new Response("")}});const p=s.port;s.stop();process.stdout.write(String(p))'
}

# Build the zigapagos binary if it isn't already there.
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  (cd "$REPO" && mise exec -- zig build) || fail "zig build failed"
  restore_snapshots
fi

# --- start the mock upstream (binds :0, prints PORT=<n>) ----------------------
mise exec -- bun "$HERE/mock-upstream.ts" > "$MOCK_LOG" 2>&1 &
MOCK_PID=$!
UP_PORT=""
for _ in $(seq 1 100); do
  UP_PORT="$(sed -n 's/^PORT=//p' "$MOCK_LOG" | head -1)"
  [[ -n "$UP_PORT" ]] && break
  sleep 0.1
done
[[ -n "$UP_PORT" ]] || fail "mock upstream did not report a port"
echo "mock upstream on 127.0.0.1:$UP_PORT"

DEAD_PORT="$(free_port)"
ZIGAPAGOS_PORT="$(free_port)"
BASE="http://127.0.0.1:$ZIGAPAGOS_PORT"

# --- start `zigapagos serve` with two proxy rules (mock + dead) --------------------
# The dev server is `zigapagos` with NO subcommand (see `zigapagos help`).
( cd "$SITE" && exec "$ZIGAPAGOS" \
    --host 127.0.0.1 --port "$ZIGAPAGOS_PORT" \
    --proxy "/api=http://127.0.0.1:$UP_PORT" \
    --proxy "/dead=http://127.0.0.1:$DEAD_PORT" ) > "$ZIGAPAGOS_LOG" 2>&1 &
ZIGAPAGOS_PID=$!

READY=""
for _ in $(seq 1 150); do
  if curl -sf -o /dev/null "$BASE/"; then READY=1; break; fi
  kill -0 "$ZIGAPAGOS_PID" 2>/dev/null || fail "zigapagos serve exited during startup"
  sleep 0.1
done
[[ -n "$READY" ]] || fail "zigapagos serve did not become ready at $BASE"
echo "zigapagos serve on $BASE (proxy /api -> 127.0.0.1:$UP_PORT, /dead -> :$DEAD_PORT)"

# --- (a) static path served locally (NOT proxied) -----------------------------
STATIC="$(curl -s "$BASE/")"
grep -q '__zigapagos/zigapagos-reload.js' <<<"$STATIC" \
  || fail "static root did not return the locally-rendered page (no livereload injection)"
echo "PASS(a): static / served locally"

# --- (b) GET /api/echo -> upstream body + Set-Cookie relayed -------------------
GET_HEADERS="$WORK/get.h"
GET_BODY="$(curl -s -D "$GET_HEADERS" "$BASE/api/echo")"
grep -q '"path":"/api/echo"' <<<"$GET_BODY" || fail "GET /api/echo body not from upstream: $GET_BODY"
grep -qi '^set-cookie: sid=abc' "$GET_HEADERS" || fail "GET /api/echo did not relay Set-Cookie"
grep -q '"xff":"127.0.0.1"' <<<"$GET_BODY" || fail "GET /api/echo missing X-Forwarded-For seen by upstream: $GET_BODY"
echo "PASS(b): GET /api/echo proxied (body + Set-Cookie + X-Forwarded-For)"

# --- (b2) C1: raw encoded target forwarded verbatim ---------------------------
ENC_CODE="$(curl -s -o "$WORK/enc.body" -w '%{http_code}' "$BASE/api/echo?q=a%20b")"
[[ "$ENC_CODE" == "200" ]] || fail "encoded target got HTTP $ENC_CODE (a decoded '/api/echo?q=a b' makes Bun 505); body: $(cat "$WORK/enc.body")"
grep -qF '"target":"/api/echo?q=a%20b"' "$WORK/enc.body" \
  || fail "upstream did not see the RAW encoded target; got: $(cat "$WORK/enc.body")"
echo "PASS(b2): raw encoded target /api/echo?q=a%20b forwarded verbatim (C1)"

# --- (c) POST /api/echo -> body forwarded + request Cookie round-trips ---------
POST_HEADERS="$WORK/post.h"
POST_BODY="$(curl -s -D "$POST_HEADERS" -X POST \
  -H 'content-type: text/plain' \
  -b 'sid=abc' \
  --data 'hello=proxy' \
  "$BASE/api/echo")"
[[ "$POST_BODY" == "hello=proxy" ]] || fail "POST /api/echo body not echoed: '$POST_BODY'"
grep -qi '^x-echo-cookie: sid=abc' "$POST_HEADERS" || fail "POST /api/echo did not forward the request Cookie upstream"
echo "PASS(c): POST /api/echo proxied (body + request Cookie round-trip)"

# --- (c2) I1: a CHUNKED request upload reaches the upstream intact -------------
# `-T -` uploads stdin whose length is unknown, so curl frames the request with
# Transfer-Encoding: chunked. The proxy must re-frame it (buffer -> Content-Length)
# or the upstream sees a body-less request and echoes nothing.
CHUNKED_BODY="$(printf 'chunky-upload-payload' | curl -s -X POST -H 'content-type: text/plain' -T - "$BASE/api/echo")"
[[ "$CHUNKED_BODY" == "chunky-upload-payload" ]] || fail "chunked request upload not forwarded intact (I1); got: '$CHUNKED_BODY'"
echo "PASS(c2): chunked request upload forwarded intact (I1)"

# --- (c3) keep-alive bodyless POST (no CL, no TE) must NOT crash the server ----
# Raw socket client holds the connection open (no half-close), reproducing a real
# keep-alive client. Pre-fix this aborts the whole dev server (discardBody assert)
# or hangs; post-fix the proxy forwards content-length: 0 and responds. Assert
# (1) we got a valid HTTP response AND (2) the server is still serving afterward.
RAW_STATUS="$(timeout 6 mise exec -- bun "$HERE/raw-post.ts" "$ZIGAPAGOS_PORT" POST || true)"
echo "raw keep-alive bodyless POST -> status line: '${RAW_STATUS}'"
[[ "$RAW_STATUS" == HTTP/*2* ]] || fail "keep-alive bodyless POST did not get a 2xx proxied response (got: '$RAW_STATUS')"
# Server-still-alive proof: a fresh static GET must still succeed.
curl -sf -o /dev/null "$BASE/" || fail "dev server is DEAD after a keep-alive bodyless POST (regression)"
echo "PASS(c3): keep-alive bodyless POST proxied + server still serving"

# --- (d) SSE streams live: event 1 arrives before event 2 ---------------------
SSE_TS="$WORK/sse_ts.txt"
timeout 5 curl -sN "$BASE/api/sse" | while IFS= read -r line; do
  printf '%s\t%s\n' "$(date +%s.%N)" "$line"
done > "$SSE_TS" || true
grep -q 'data: event 1' "$SSE_TS" || fail "SSE: never received event 1 ($(cat "$SSE_TS"))"
grep -q 'data: event 2' "$SSE_TS" || fail "SSE: never received event 2 ($(cat "$SSE_TS"))"
T1="$(awk -F'\t' '/data: event 1/{print $1; exit}' "$SSE_TS")"
T2="$(awk -F'\t' '/data: event 2/{print $1; exit}' "$SSE_TS")"
GAP="$(awk -v a="$T1" -v b="$T2" 'BEGIN{printf "%.3f", b-a}')"
echo "SSE inter-event gap: ${GAP}s (upstream pause is 0.300s)"
awk -v g="$GAP" 'BEGIN{exit !(g>=0.2)}' \
  || fail "SSE arrived buffered, not streamed (gap ${GAP}s < 0.2s)"
echo "PASS(d): SSE streamed live (event 1 arrived ${GAP}s before event 2)"

# --- (d2) C2: client-received SSE body is EXACTLY the two events, no chunk leak-
SSE_BODY="$WORK/sse_body.txt"
timeout 5 curl -sN "$BASE/api/sse" > "$SSE_BODY" || true
printf 'event: msg\ndata: event 1\n\nevent: msg\ndata: event 2\n\n' > "$WORK/sse_expected.txt"
if ! diff -u "$WORK/sse_expected.txt" "$SSE_BODY" > "$WORK/sse.diff" 2>&1; then
  echo "--- expected vs received SSE body ---"; cat "$WORK/sse.diff"
  fail "SSE body is not byte-exact (chunk framing leaked or corrupted)"
fi
# Explicit guard: a leaked chunk-size line would be a bare hex token on its own line.
if grep -qiE '^[0-9a-f]+$' "$SSE_BODY"; then
  echo "--- offending SSE body ---"; cat -A "$SSE_BODY"
  fail "SSE body contains a bare hex line — upstream chunk sizes leaked (C2)"
fi
echo "PASS(d2): SSE body byte-exact, no chunk-size leakage (C2)"
echo "----- exact SSE bytes the client received (cat -A) -----"
cat -A "$SSE_BODY"
echo "--------------------------------------------------------"

# --- (e) dead upstream -> 502 -------------------------------------------------
DEAD_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/dead/whatever")"
[[ "$DEAD_CODE" == "502" ]] || fail "dead upstream expected 502, got $DEAD_CODE"
echo "PASS(e): dead upstream -> 502"

# --- (f) Upgrade: websocket -> 501 --------------------------------------------
WS_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' "$BASE/api/echo")"
[[ "$WS_CODE" == "501" ]] || fail "websocket upgrade expected 501, got $WS_CODE"
echo "PASS(f): Upgrade: websocket -> 501"

echo "PASS: zigapagos serve --proxy (static + GET/cookie + raw-target + POST + SSE stream + SSE byte-exact + 502 + 501)"
