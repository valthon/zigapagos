#!/usr/bin/env bash
# e2e for `zigapagos dev` serving a `url_path_prefix` site (issue #152).
#
# A site with `url_path_prefix` set emits every href/asset/island-module URL
# under `/<prefix>/…`, but the built tree itself carries no prefix directory
# (see docs/spa.md). Before the fix, `dev` mounted the tree at the server
# root, so every one of those URLs 404'd. The fix stages a served root that
# mounts the tree at `/<prefix>/` (see `stageServedRoot` in src/cli/e2e.zig)
# and points zigbase at THAT instead — so this script drives the real thing
# end to end with the hermetic stub "zigbase" on PATH.
#
# Uses a NESTED prefix ("docs/v2") so a passing run also proves nested
# prefixes work, not just single-segment ones.
#
# Asserts:
#   (a) the ready banner's URL and the log's readiness line carry the prefix
#       (not bare "/"),
#   (a2) the PERSISTED url too: .zigbase/dev.json's `url` field and
#       GET /_zigapagos/status's `url` field both carry the prefix — not just
#       the terminal banner. dev_control.zig prints this same string
#       verbatim for `dev --background`'s ready summary and `dev
#       stop`/`status`'s "already running at" line, and --background is the
#       DEFAULT flow under agent auto-detection, so this is the URL an agent
#       actually acts on (issue #152, review round 2),
#   (b) the staged served root actually has a `<prefix>/` directory (parsed
#       from the "dev: zigbase = …; serving <path>" log line) containing the
#       built page,
#   (c) GET / 404s (by design: the staged root has no content outside the
#       prefix) while GET /docs/v2/ serves the page,
#   (d) an island module URL resolves under the staged root
#       (/docs/v2/islands/Counter.island.js), matching the hot-swap URL
#       `islandModuleUrl` already computes,
#   (e) a content edit triggers a rebuild that refreshes the STAGED copy
#       (not just the underlying site_abs tree),
#   (f) teardown leaves no orphans.
set -euo pipefail
export ZIGAPAGOS_DEV_BACKGROUND=0 # keep dev foreground: this harness manages the process itself
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../.. && pwd)"
WORK="$(mktemp -d)"

cleanup() {
  pkill -f "$WORK" 2>/dev/null || true
  sleep 0.2
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

poll() { # deadline_secs cmd...
  local deadline=$1; shift; local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start < deadline )) || return 1
    sleep 0.4
  done
}

# --- build zigapagos ---------------------------------------------------------
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  ( cd "$REPO" && mise exec -- zig build ) || fail "zig build failed"
fi

# --- runtime deps (the sidecar needs preact from runtime/node_modules) --------
if [[ ! -d "$REPO/runtime/node_modules" ]]; then
  ( cd "$REPO/runtime" && bun install ) >/dev/null 2>&1 \
    || { echo "SKIP: runtime/node_modules missing and bun install failed (offline?)"; exit 0; }
fi

# --- stub zigbase on PATH ----------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/zigbase" <<EOF
#!/usr/bin/env bash
exec bun "$HERE/stub-zigbase.ts" "\$@"
EOF
chmod +x "$BIN/zigbase"
export PATH="$BIN:$PATH"

# --- site fixture: url_path_prefix = "docs/v2" (nested), one island ----------
SRC="$WORK/site"; OUT="$WORK/out"; DATA="$WORK/data"
mkdir -p "$SRC/content" "$SRC/layouts" "$SRC/assets" "$SRC/components"
: > "$SRC/assets/.keep"
cat > "$SRC/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Prefix Dev Test",
    .host_url = "https://example.com",
    .url_path_prefix = "docs/v2",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF
cat > "$SRC/layouts/island.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$site.title"></title>
  </head>
  <body>
    <h1 :text="$page.title"></h1>
    <island src="components/Counter.island.tsx" client:load></island>
    <div :html="$page.content()"></div>
  </body>
</html>
EOF
cat > "$SRC/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "island.shtml",
.draft = false,
---
PREFIX-DEV-MARKER-V1
EOF
cat > "$SRC/components/Counter.island.tsx" <<'EOF'
export default function Counter() { return "ISLAND-SSR-V1"; }
EOF

# Prebuilt dummy bundle (stands in for the zig-build bun bundling step, same
# approach as tests/dev/dev-island-incremental.sh — the sidecar SSR is real,
# the esbuild-style bundling is not what's under test here).
mkdir -p "$WORK/prebundle"
printf 'BUNDLE-V1\n' > "$WORK/prebundle/Counter.island.js"

REBUILD=("$ZIGAPAGOS" release "--output=$OUT" --force
  --bun=bun "--island-sidecar=$REPO/runtime/sidecar/render.ts" --island-src-dir=.
  --build-asset=island_Counter.island "$WORK/prebundle/Counter.island.js"
  --install-always=islands/Counter.island.js)

launch_group() { # dir log cmd...
  local dir=$1 log=$2; shift 2
  if command -v setsid >/dev/null 2>&1; then
    ( cd "$dir" && exec setsid "$@" ) > "$log" 2>&1 & echo $!
  else
    set -m; ( cd "$dir" && exec "$@" ) > "$log" 2>&1 & local pid=$!; set +m; echo "$pid"
  fi
}
# Same regex as tests/dev/dev.sh's origin_from_log: it stops at the first
# non [0-9.:] character, so it still extracts the bare origin even though the
# banner now has a path suffix after it.
origin_from_log() { grep -o 'serving at http://[0-9.]*:[0-9]*' "$1" | head -1 | sed 's/serving at //'; }
http_code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

LOG="$WORK/dev.log"
DEV_PID="$(launch_group "$SRC" "$LOG" "$ZIGAPAGOS" dev --site="$OUT" --port=0 --data-dir="$DATA" --watch-dir=components -- "${REBUILD[@]}")"
poll 60 grep -q 'dev: ready' "$LOG" || { cat "$LOG"; fail "dev never became ready"; }
ORIGIN="$(origin_from_log "$LOG")"
[[ -n "$ORIGIN" ]] || { cat "$LOG"; fail "no origin parsed from the ready line"; }

# --- (a) ready banner + readiness probe carry the prefix ----------------------
grep -q "dev: ready — serving at http://[0-9.]*:[0-9]*/docs/v2/$" "$LOG" \
  || { cat "$LOG"; fail "ready banner did not default to /docs/v2/ (the site's url_path_prefix)"; }
echo "PASS: (a) ready banner defaults to /docs/v2/ (the readiness probe already used it to get here)"

# --- (a2) the persisted url (lockfile + status endpoint) also carries the prefix
# Regression coverage for review round 2: the terminal banner alone isn't
# enough — dev_control.zig prints dev.json's `url` field verbatim in the
# --background ready summary and the "already running at" line, and
# /_zigapagos/status echoes the same string, so all three have to resolve to
# a real page too, not just what's printed to this foreground terminal.
DEV_JSON="$DATA/dev.json"
test -f "$DEV_JSON" || fail "dev.json missing"
# dev.json is pretty-printed (std.json .indent_2), so tolerate an optional
# space after the colon; /_zigapagos/status below is compact, no space.
LOCK_URL="$(grep -o '"url": *"[^"]*"' "$DEV_JSON" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
[[ "$LOCK_URL" == */docs/v2/ ]] \
  || { cat "$DEV_JSON"; fail "dev.json's url field does not carry /docs/v2/ (got: '$LOCK_URL')"; }
CONTROL_PORT="$(grep -o '"control_port": *[0-9]*' "$DEV_JSON" | head -1 | grep -o '[0-9]*$')"
[[ -n "$CONTROL_PORT" ]] || { cat "$DEV_JSON"; fail "could not parse control_port from dev.json"; }
STATUS_URL="$(curl -sf --max-time 5 "http://127.0.0.1:$CONTROL_PORT/_zigapagos/status" \
  | grep -o '"url":"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
[[ "$STATUS_URL" == */docs/v2/ ]] \
  || fail "/_zigapagos/status url field does not carry /docs/v2/ (got: '$STATUS_URL')"
echo "PASS: (a2) dev.json + /_zigapagos/status url fields carry /docs/v2/, not a bare 404ing origin"

# --- (b) the staged served root has a docs/v2/ directory ----------------------
STAGED="$(grep -o -- '--serve-static [^ ]*' "$LOG" | head -1 | awk '{print $2}')"
[[ -n "$STAGED" ]] || { cat "$LOG"; fail "could not parse the --serve-static argument from the log"; }
[[ "$STAGED" != "$OUT" ]] || fail "zigbase was pointed at the raw site tree ($OUT), not a staged prefix mount"
test -f "$STAGED/docs/v2/index.html" || fail "staged root missing docs/v2/index.html (nested prefix not mounted)"
grep -q 'PREFIX-DEV-MARKER-V1' "$STAGED/docs/v2/index.html" || fail "staged docs/v2/index.html is not the built page"
echo "PASS: (b) staged served root '$STAGED' has a real docs/v2/ directory carrying the built page"

# --- (c) GET / 404s; GET /docs/v2/ serves the page ----------------------------
[[ "$(http_code "$ORIGIN/")" == "404" ]] || fail "GET / did not 404 on a prefixed site (staged root has no root content)"
curl -sf "$ORIGIN/docs/v2/" | grep -q 'PREFIX-DEV-MARKER-V1' \
  || { cat "$LOG"; fail "GET /docs/v2/ did not serve the built page"; }
echo "PASS: (c) GET / 404s by design; GET /docs/v2/ serves the built page"

# --- (d) an island module URL resolves under the staged root ------------------
# Matches dev.zig's islandModuleUrl / islands/pass.zig's SSR data-z-module:
# with url_path_prefix "docs/v2" the module lives at /docs/v2/islands/<stem>.js.
curl -sf "$ORIGIN/docs/v2/islands/Counter.island.js" | grep -q 'BUNDLE-V1' \
  || { cat "$LOG"; fail "island module URL /docs/v2/islands/Counter.island.js did not resolve"; }
echo "PASS: (d) island module URL resolves under the staged prefix root"

# --- (e) a content edit refreshes the STAGED copy, not just site_abs ----------
sleep 1.1
sed -i.bak 's/PREFIX-DEV-MARKER-V1/PREFIX-DEV-MARKER-V2/' "$SRC/content/index.smd" && rm -f "$SRC/content/index.smd.bak"
poll 60 bash -c "curl -sf '$ORIGIN/docs/v2/' | grep -q PREFIX-DEV-MARKER-V2" \
  || { cat "$LOG"; fail "edited content never reached the served (staged) output"; }
grep -q 'PREFIX-DEV-MARKER-V2' "$STAGED/docs/v2/index.html" \
  || fail "the staged copy on disk was not refreshed by the rebuild"
echo "PASS: (e) a rebuild refreshes the staged served-root mirror"

# --- (f) teardown --------------------------------------------------------------
kill -TERM -- "-$DEV_PID" 2>/dev/null || true
poll 10 bash -c "! kill -0 $DEV_PID 2>/dev/null" || fail "dev did not exit"
curl -sf --max-time 2 -o /dev/null "$ORIGIN/docs/v2/" && fail "server still answering after teardown" || true
pgrep -f "stub-zigbase.ts.*$WORK" >/dev/null && fail "stub zigbase left behind" || true
echo "PASS: (f) teardown clean"

echo "ALL PASS: dev serves a url_path_prefix site correctly (issue #152)"
