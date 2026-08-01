#!/usr/bin/env bash
# e2e for the incremental render path + AUD-016: the `zigapagos dev` rebuild
# classifier.
#
# Drives a real `zigapagos dev` (rebuild command = a direct `zigapagos release`,
# so no bun/zig-build toolchain is needed) with the hermetic stub "zigbase" on
# PATH (see tests/dev/stub-zigbase.ts), against a site whose content and
# assets dirs are SEPARATE.
#
# AUD-016: a content-page edit must trigger a FULL rebuild, not a single-page
# incremental one. A page's frontmatter (title/date) is embedded in OTHER pages
# via $page.subpages()/nextPage()/prevPage() and section listings, and the dev
# classifier has no content model to know which — re-rendering only the edited
# page left listing/prev-next pages showing stale data (the dev preview then
# disagreed with a release build). Only island-source-only edits stay
# incremental (see dev-island-incremental.sh).
#
# Asserts:
#   (a) a single content-page edit logs a FULL rebuild and the change reaches
#       the served output,
#   (b) that rebuild re-emitted the WHOLE tree (more than just the edited page),
#   (c) a shared-input edit (a layout) also falls back to a FULL rebuild,
#   (d) teardown leaves no orphans.
set -euo pipefail
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

# --- stub zigbase on PATH ----------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/zigbase" <<EOF
#!/usr/bin/env bash
exec bun "$HERE/stub-zigbase.ts" "\$@"
EOF
chmod +x "$BIN/zigbase"
export PATH="$BIN:$PATH"

# --- site fixture: content and assets in SEPARATE dirs -----------------------
SRC="$WORK/site"; OUT="$WORK/out"; DATA="$WORK/data"
mkdir -p "$SRC/assets"
cp -r "$REPO/tests/rendering/simple/content" "$REPO/tests/rendering/simple/layouts" "$SRC/"
: > "$SRC/assets/.keep"
cat > "$SRC/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Incremental Dev Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF

REBUILD=("$ZIGAPAGOS" release "--output=$OUT" --force)

launch_group() { # dir log cmd...
  local dir=$1 log=$2; shift 2
  if command -v setsid >/dev/null 2>&1; then
    ( cd "$dir" && exec setsid "$@" ) > "$log" 2>&1 & echo $!
  else
    set -m; ( cd "$dir" && exec "$@" ) > "$log" 2>&1 & local pid=$!; set +m; echo "$pid"
  fi
}
origin_from_log() { grep -o 'serving at http://[0-9.]*:[0-9]*' "$1" | head -1 | sed 's/serving at //'; }
serves() { curl -sf "$1/$2" | grep -q "$3"; }

LOG="$WORK/dev.log"
DEV_PID="$(launch_group "$SRC" "$LOG" "$ZIGAPAGOS" dev --site="$OUT" --port=0 --data-dir="$DATA" -- "${REBUILD[@]}")"
poll 60 grep -q 'dev: ready' "$LOG" || { cat "$LOG"; fail "dev never became ready"; }
ORIGIN="$(origin_from_log "$LOG")"
[[ -n "$ORIGIN" ]] || fail "no origin parsed"

# snapshot every emitted page's mtime, keyed by path
snap() { find "$OUT" -name '*.html' -printf '%p\t%T@\n' | sort; }
snap > "$WORK/before.txt"
NPAGES="$(wc -l < "$WORK/before.txt")"
[[ "$NPAGES" -ge 5 ]] || fail "expected a multi-page site (got $NPAGES)"

# --- (a) content-page edit -> FULL rebuild (AUD-016), served -----------------
sleep 1.1  # coarse mtime
printf '\nDEV-INC-54\n' >> "$SRC/content/syntax.smd"
poll 60 serves "$ORIGIN" "syntax/" "DEV-INC-54" || { cat "$LOG"; fail "edit never reached the served output"; }
# AUD-016: a content edit must NOT be classified incremental — its frontmatter
# can be embedded in listing/prev-next pages the classifier can't localize.
if grep -q "incremental rebuild of content/syntax.smd" "$LOG"; then
  cat "$LOG"; fail "a content-page edit must fall back to a FULL rebuild, not incremental (AUD-016)"
fi
grep -q "change detected, rebuilding\.\.\." "$LOG" \
  || { cat "$LOG"; fail "expected a FULL rebuild log line for the edited content page"; }
echo "PASS: content-page edit logged a full rebuild and reached the served output"

# --- (b) the whole tree was re-emitted (not just the edited page) ------------
snap > "$WORK/after.txt"
NCHANGED="$(join -t $'\t' "$WORK/before.txt" "$WORK/after.txt" | awk -F'\t' '$2 != $3 {print $1}' | wc -l)"
[[ "$NCHANGED" -gt 1 ]] \
  || fail "a full rebuild should re-emit more than the edited page, got $NCHANGED changed"
echo "PASS: the full dev rebuild re-emitted the tree ($NCHANGED of $NPAGES pages)"

# --- (c) shared-input (layout) edit -> FULL rebuild --------------------------
LINES_BEFORE="$(grep -c "change detected" "$LOG" || true)"
sleep 1.1
printf '\n<!-- dev-inc-54-layout -->\n' >> "$SRC/layouts/index.shtml"
poll 60 bash -c "grep -c 'change detected' '$LOG' | grep -qv '^$LINES_BEFORE\$'" \
  || { cat "$LOG"; fail "layout edit did not trigger a rebuild"; }
# A layout edit must NOT be classified incremental (it can affect many pages).
if grep -q "incremental rebuild of layouts/" "$LOG"; then
  cat "$LOG"; fail "a layout edit must fall back to a FULL rebuild, not incremental"
fi
grep -q "change detected, rebuilding\.\.\." "$LOG" \
  || { cat "$LOG"; fail "expected a FULL rebuild log line after the layout edit"; }
echo "PASS: a shared-input (layout) edit fell back to a full rebuild"

# --- (d) teardown ------------------------------------------------------------
kill -TERM -- "-$DEV_PID" 2>/dev/null || true
poll 10 bash -c "! kill -0 $DEV_PID 2>/dev/null" || fail "dev did not exit"
curl -sf --max-time 2 -o /dev/null "$ORIGIN/" && fail "server still answering after teardown" || true
pgrep -f "stub-zigbase.ts.*$WORK" >/dev/null && fail "stub zigbase left behind" || true
echo "PASS: teardown clean"

echo "ALL PASS: dev incremental loop"
