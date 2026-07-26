#!/usr/bin/env bash
# e2e for `zigapagos dev` island-source incremental re-SSR.
#
# Drives a real `zigapagos dev` (rebuild command = a direct `zigapagos release`
# with the island sidecar, so island SSR is real but no bun-bundling toolchain
# runs — a prebuilt dummy bundle file stands in for the island's build asset)
# with the hermetic stub "zigbase" on PATH, against a site where exactly ONE
# page mounts the island.
#
# Asserts:
#   (a) the initial build writes the dev island-usage manifest into the data
#       dir, mapping the island src to the mounting page,
#   (b) an island-source edit is resolved through the manifest: the log names
#       the island and the mounting page, ONLY that page's HTML is re-emitted,
#       the served page shows the new SSR output, and the (touched) prebuilt
#       bundle is re-installed (the incremental build-asset install),
#   (c) a NON-island file added under the watch dir (a helper module) falls
#       back to a FULL rebuild (it is not a manifest key),
#   (d) a deleted manifest falls back to a FULL rebuild — and that rebuild
#       re-creates the manifest,
#   (e) a plain content-page edit falls back to a FULL rebuild (AUD-016:
#       its frontmatter can be embedded in listing/prev-next pages),
#   (f) teardown leaves no orphans.
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

# --- site fixture: one page mounts the island, the others don't ---------------
SRC="$WORK/site"; OUT="$WORK/out"; DATA="$WORK/data"
mkdir -p "$SRC/content" "$SRC/layouts" "$SRC/assets" "$SRC/components"
: > "$SRC/assets/.keep"
cat > "$SRC/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Island Incremental Dev Test",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
}
EOF
cat > "$SRC/layouts/plain.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <title :text="$site.title"></title>
  </head>
  <body>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </body>
</html>
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
page() { # path title layout
  cat > "$1" <<EOF
---
.title = "$2",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "$3",
.draft = false,
---
Body of $2.
EOF
}
page "$SRC/content/index.smd" "Home" "plain.shtml"
page "$SRC/content/island.smd" "Island Page" "island.shtml"
page "$SRC/content/other.smd" "Other Page" "plain.shtml"
cat > "$SRC/components/Counter.island.tsx" <<'EOF'
export default function Counter() { return "ISLAND-SSR-V1"; }
EOF

# Prebuilt dummy bundle (stands in for the zig-build bun bundling step; the
# test "rebundles" by rewriting it).
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
origin_from_log() { grep -o 'serving at http://[0-9.]*:[0-9]*' "$1" | head -1 | sed 's/serving at //'; }
serves() { curl -sf "$1/$2" | grep -q "$3"; }
inc_count() { grep -c "incremental rebuild of" "$LOG" || true; }
full_count() { grep -c "change detected, rebuilding\.\.\." "$LOG" || true; }

LOG="$WORK/dev.log"
MANIFEST="$DATA/islands-manifest.json"
DEV_PID="$(launch_group "$SRC" "$LOG" "$ZIGAPAGOS" dev --site="$OUT" --port=0 --data-dir="$DATA" --watch-dir=components -- "${REBUILD[@]}")"
poll 60 grep -q 'dev: ready' "$LOG" || { cat "$LOG"; fail "dev never became ready"; }
ORIGIN="$(origin_from_log "$LOG")"
[[ -n "$ORIGIN" ]] || fail "no origin parsed"
serves "$ORIGIN" "island/" "ISLAND-SSR-V1" || { cat "$LOG"; fail "island page not SSR'd on the initial build"; }

# --- (a) initial build wrote the manifest -------------------------------------
[[ -f "$MANIFEST" ]] || fail "initial build did not write $MANIFEST"
grep -q "components/Counter.island.tsx" "$MANIFEST" || fail "manifest missing the island src key"
grep -q "content/island.smd" "$MANIFEST" || fail "manifest missing the mounting page"
if grep -q "content/index.smd" "$MANIFEST"; then
  fail "manifest must not list a page that mounts no island"
fi
echo "PASS: initial build wrote the island-usage manifest (island -> mounting page only)"

# snapshot every emitted page's mtime, keyed by path
snap() { find "$OUT" -name '*.html' -printf '%p\t%T@\n' | sort; }
snap > "$WORK/before.txt"
NPAGES="$(wc -l < "$WORK/before.txt")"
[[ "$NPAGES" -ge 3 ]] || fail "expected at least 3 pages (got $NPAGES)"

# --- (b) island-source edit -> incremental re-SSR of ONLY the mounting page ---
sleep 1.1  # coarse mtime
sed -i.bak 's/ISLAND-SSR-V1/ISLAND-SSR-V2/' "$SRC/components/Counter.island.tsx" && rm -f "$SRC/components/Counter.island.tsx.bak"
printf 'BUNDLE-V2\n' > "$WORK/prebundle/Counter.island.js"  # simulate the rebundle
poll 60 serves "$ORIGIN" "island/" "ISLAND-SSR-V2" || { cat "$LOG"; fail "island edit never reached the served output"; }
grep -q "dev: island source components/Counter.island.tsx -> 1 mounting page(s)" "$LOG" \
  || { cat "$LOG"; fail "expected the manifest-resolution log line"; }
grep -q "incremental rebuild of content/island.smd" "$LOG" \
  || { cat "$LOG"; fail "expected an INCREMENTAL rebuild of the mounting page"; }
snap > "$WORK/after.txt"
CHANGED="$(join -t $'\t' "$WORK/before.txt" "$WORK/after.txt" | awk -F'\t' '$2 != $3 {print $1}')"
[[ "$CHANGED" == "$OUT/island/index.html" ]] \
  || fail "island edit should re-emit ONLY island/index.html, got: ${CHANGED:-<nothing>}"
grep -q "BUNDLE-V2" "$OUT/islands/Counter.island.js" \
  || fail "the incremental rebuild did not reinstall the island bundle"
# Hot-swap wiring: an island-ONLY change broadcasts an island hot-swap over
# the SSE channel (srv.notifyIslands) instead of a full reload.
grep -q "hot-swapping 1 island module(s)" "$LOG" \
  || { cat "$LOG"; fail "island-only change should broadcast an island hot-swap, not a full reload"; }
echo "PASS: island edit re-SSR'd ONLY the mounting page (1 of $NPAGES), reinstalled the bundle, and hot-swapped"

# --- (c) a non-island file under the watch dir -> FULL rebuild ----------------
INC_BEFORE="$(inc_count)"; FULL_BEFORE="$(full_count)"
sleep 1.1
printf 'export const helper = 1;\n' > "$SRC/components/helper.ts"
poll 60 bash -c "grep -c 'change detected, rebuilding\.\.\.' '$LOG' | grep -qv '^$FULL_BEFORE\$'" \
  || { cat "$LOG"; fail "helper-file edit did not trigger a full rebuild"; }
poll 60 grep -q "dev: rebuild OK" "$LOG" || true
[[ "$(inc_count)" == "$INC_BEFORE" ]] \
  || { cat "$LOG"; fail "a helper-file edit must NOT be classified incremental"; }
echo "PASS: a non-island watch-dir file fell back to a full rebuild"

# --- (d) missing manifest -> FULL rebuild fallback + regeneration -------------
poll 30 test -f "$MANIFEST" || { cat "$LOG"; fail "full rebuild did not (re)write the manifest"; }
rm -f "$MANIFEST"
INC_BEFORE="$(inc_count)"; FULL_BEFORE="$(full_count)"
sleep 1.1
sed -i.bak 's/ISLAND-SSR-V2/ISLAND-SSR-V3/' "$SRC/components/Counter.island.tsx" && rm -f "$SRC/components/Counter.island.tsx.bak"
poll 60 bash -c "grep -c 'change detected, rebuilding\.\.\.' '$LOG' | grep -qv '^$FULL_BEFORE\$'" \
  || { cat "$LOG"; fail "island edit with no manifest did not trigger a full rebuild"; }
poll 60 serves "$ORIGIN" "island/" "ISLAND-SSR-V3" || { cat "$LOG"; fail "V3 never reached the served output"; }
[[ "$(inc_count)" == "$INC_BEFORE" ]] \
  || { cat "$LOG"; fail "a manifest-less island edit must NOT be classified incremental"; }
poll 30 test -f "$MANIFEST" || { cat "$LOG"; fail "the fallback full rebuild did not re-create the manifest"; }
echo "PASS: deleted manifest -> full-rebuild fallback, and the rebuild re-created it"

# --- (e) content-page edit -> FULL rebuild (AUD-016) --------------------------
sleep 1.1
printf '\nDEV-INC-61\n' >> "$SRC/content/other.smd"
poll 60 serves "$ORIGIN" "other/" "DEV-INC-61" || { cat "$LOG"; fail "content edit never reached the served output"; }
# AUD-016: a content edit must NOT be incremental — its frontmatter can be
# embedded in listing/prev-next pages the classifier can't localize.
if grep -q "incremental rebuild of content/other.smd" "$LOG"; then
  cat "$LOG"; fail "a content-page edit must fall back to a FULL rebuild, not incremental (AUD-016)"
fi
echo "PASS: plain content edit classified as a full rebuild (AUD-016)"

# --- (f) island entry referenced by ANOTHER watched source -> FULL rebuild ----
# (review follow-up): the manifest can't see bundle-level imports, so when
# some other watched source references the edited entry, the classifier must
# fall back to a full rebuild instead of under-re-SSRing the referencing
# island's pages.
poll 30 test -f "$MANIFEST" || { cat "$LOG"; fail "manifest missing before the cross-reference scenario"; }
FULL_BEFORE="$(full_count)"
sleep 1.1
printf 'import Counter from "./Counter.island.tsx";\nexport const wrapped = Counter;\n' > "$SRC/components/Wrapper.island.tsx"
# The new file is not a manifest key -> this change itself full-rebuilds.
poll 60 bash -c "grep -c 'change detected, rebuilding\.\.\.' '$LOG' | grep -qv '^$FULL_BEFORE\$'" \
  || { cat "$LOG"; fail "adding Wrapper.island.tsx did not trigger a full rebuild"; }
poll 60 grep -q "dev: rebuild OK" "$LOG" || true
# Now edit the REFERENCED entry: it IS a manifest key, but Wrapper imports it.
INC_BEFORE="$(inc_count)"; FULL_BEFORE="$(full_count)"
sleep 1.1
sed -i.bak 's/ISLAND-SSR-V3/ISLAND-SSR-V4/' "$SRC/components/Counter.island.tsx" && rm -f "$SRC/components/Counter.island.tsx.bak"
poll 60 serves "$ORIGIN" "island/" "ISLAND-SSR-V4" || { cat "$LOG"; fail "V4 never reached the served output"; }
grep -q "referenced by another watched source" "$LOG" \
  || { cat "$LOG"; fail "expected the cross-reference full-rebuild log line"; }
[[ "$(inc_count)" == "$INC_BEFORE" ]] \
  || { cat "$LOG"; fail "an entry referenced by another watched source must NOT be classified incremental"; }
echo "PASS: an island entry referenced by another watched source forces a full rebuild"

# --- (g) teardown --------------------------------------------------------------
kill -TERM -- "-$DEV_PID" 2>/dev/null || true
poll 10 bash -c "! kill -0 $DEV_PID 2>/dev/null" || fail "dev did not exit"
curl -sf --max-time 2 -o /dev/null "$ORIGIN/" && fail "server still answering after teardown" || true
pgrep -f "stub-zigbase.ts.*$WORK" >/dev/null && fail "stub zigbase left behind" || true
echo "PASS: teardown clean"

echo "ALL PASS: dev island incremental loop"
