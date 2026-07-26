#!/usr/bin/env bash
# Proof for incremental site render.
#
# `zigapagos release` re-renders + re-emits ONLY the pages named in
# `ZIGAPAGOS_CHANGED_FILES` (the env var `zigapagos dev` sets for a content-only
# edit), leaving the rest of the previously-built output tree untouched. A
# normal release with the var unset renders the whole site as before.
#
# The check is by-filename mtime comparison of the emitted *.html tree:
#   (1) a full build emits every page,
#   (2) an incremental build (ONE changed page) re-emits ONLY that page,
#   (3) a subsequent full build re-emits every page again (control: the tree
#       IS normally rewritten wholesale, so (2)'s single-file result is real).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SITE="$WORK/site"; OUT="$WORK/out"
mkdir -p "$SITE"
cp -r tests/rendering/simple/content tests/rendering/simple/layouts "$SITE/"
cp tests/rendering/simple/zigapagos.ziggy "$SITE/"

fail() { echo "FAIL: $*"; exit 1; }

# `path<TAB>mtime` for every emitted page, sorted by path (join key).
snapshot() { find "$OUT" -name '*.html' -printf '%p\t%T@\n' | sort; }
# Paths whose mtime differs between two snapshot files (both sorted by path).
changed_between() { join -t $'\t' "$1" "$2" | awk -F'\t' '$2 != $3 {print $1}'; }

build()      { ( cd "$SITE" && "$ZIGAPAGOS" release "--output=$OUT" --force ) >/dev/null; }
build_incr() { ( cd "$SITE" && ZIGAPAGOS_CHANGED_FILES="$1" "$ZIGAPAGOS" release "--output=$OUT" --force ) >/dev/null; }

# --- (1) full build ----------------------------------------------------------
build || fail "full build failed"
snapshot > "$WORK/a.txt"
NPAGES="$(wc -l < "$WORK/a.txt")"
echo "full build: $NPAGES html pages emitted"
[[ "$NPAGES" -ge 5 ]] || fail "expected a multi-page site (got $NPAGES)"

# --- (2) incremental rebuild of ONE page -------------------------------------
sleep 1.1  # coarse-mtime filesystems: make a fresh mtime observable
printf '\nINCREMENTAL-54-MARKER\n' >> "$SITE/content/syntax.smd"
build_incr "content/syntax.smd" || fail "incremental build failed"
snapshot > "$WORK/b.txt"

CHANGED="$(changed_between "$WORK/a.txt" "$WORK/b.txt")"
echo "incremental edit re-emitted: ${CHANGED:-<nothing>}"
[[ "$CHANGED" == "$OUT/syntax/index.html" ]] || fail "expected ONLY syntax/index.html, got: ${CHANGED:-<nothing>}"
grep -q 'INCREMENTAL-54-MARKER' "$OUT/syntax/index.html" || fail "marker missing from the re-rendered page"
echo "PASS: incremental rebuild re-emitted ONLY the edited page (1 of $NPAGES)"

# --- (3) control: a full rebuild re-emits everything -------------------------
sleep 1.1
build || fail "control full build failed"
snapshot > "$WORK/c.txt"
FULL_CHANGED="$(changed_between "$WORK/b.txt" "$WORK/c.txt" | wc -l)"
echo "control: a plain full rebuild re-emitted $FULL_CHANGED / $NPAGES pages"
[[ "$FULL_CHANGED" -eq "$NPAGES" ]] || fail "full rebuild should re-emit all $NPAGES pages (got $FULL_CHANGED)"
echo "PASS: full rebuild re-emits the whole tree — incremental is measurably narrower"

echo "ALL PROOF CHECKS PASSED (incremental render)"
