#!/usr/bin/env bash
# Proof for the pruned-site-asset report (issue #54).
#
# WHAT IT IS FOR. A site asset installs only when its refcount is non-zero —
# bumped by a `.link()`/directive reference or forced by a `static_assets`
# entry. Anything else is dropped from the output. That behaviour is correct
# and stays; what cost a real debugging session is that it happened in
# SILENCE. A hand-authored SVG vanished from a build when a change removed its
# last reference, and finding out why meant reading the refcount logic in
# `src/root.zig`.
#
# So the build now names what it dropped. Everything below asserts on the
# build LOG, which is the artifact the feature actually produces — and each
# case pairs the warning with the corresponding output-tree state, so a
# warning that fired for the wrong reason cannot pass.
#
# Generated into a `mktemp -d` rather than `tests/rendering/*/`, which
# `build/snapshot.zig` would auto-discover as a snapshot suite.
#
# Checks:
#   (1) an unreferenced asset is named, with a count, and is genuinely absent
#       from the output tree;
#   (2) a `.link()`ed asset is neither named nor dropped;
#   (3) a `static_assets` asset is neither named nor dropped;
#   (4) the list is capped and reports the true total (a big `assets/` tree
#       must not bury the build log);
#   (5) the listing is deterministic — two builds of the same input produce
#       byte-identical warning text, `site_assets` being a hash map;
#   (6) a `.keep` placeholder is not reported (git cannot track an empty
#       directory, so every scaffolded site has one);
#   (7) the report is silent when `assets_dir_path` doubles as the content
#       dir, where every page source would otherwise be named;
#   (8) an asset consumed by a build-time READ builtin (`.bytes()`/`.size()`/
#       `.sriHash()`/`.ziggy()`) is neither reported nor installed — it was
#       inlined, which is a correct outcome, not a pruning;
#   (9) a build whose render pass FAILED prints no report at all, because its
#       refcounts are incomplete by construction.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"

if [[ ! -x "$ZIGAPAGOS" ]]; then
  echo "building zigapagos (zig-out/bin/zigapagos missing)..."
  mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
fi

fail() { echo "FAIL: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LAYOUT='<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8"><title :text="$site.title"></title>
    <link rel="stylesheet" href="$site.asset('"'"'linked.css'"'"').link()">
  </head>
  <body><h1 :text="$page.title"></h1></body>
</html>'

CONTENT='---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

# Home
'

# $1 = dir, $2 = assets_dir_path, $3… = static_assets entries
scaffold() {
  local dir="$1" assets_dir="$2"; shift 2
  local statics=""
  for s in "$@"; do statics="$statics\"$s\", "; done
  mkdir -p "$dir/content" "$dir/layouts"
  {
    echo 'Site {'
    echo '    .title = "Pruned",'
    echo '    .host_url = "https://example.com",'
    echo '    .content_dir_path = "content",'
    echo '    .layouts_dir_path = "layouts",'
    echo "    .assets_dir_path = \"$assets_dir\","
    echo "    .static_assets = [$statics],"
    echo '}'
  } > "$dir/zigapagos.ziggy"
  printf '%s' "$LAYOUT" > "$dir/layouts/index.shtml"
  printf '%s' "$CONTENT" > "$dir/content/index.smd"
}

build() {
  local dir="$1" out="$2" log="$3"
  ( cd "$dir" && "$ZIGAPAGOS" release "--output=$out" --force ) > "$log" 2>&1 ||
    { cat "$log"; fail "build of '$dir' failed (see log above)"; }
}

# --- (1)(2)(3) named vs. not named, cross-checked against the output tree ---
A="$WORK/a"; A_OUT="$WORK/a-out"
scaffold "$A" assets favicon.ico
mkdir -p "$A/assets/img"
printf 'body{}'      > "$A/assets/linked.css"     # referenced by the layout
printf 'ICO'         > "$A/assets/favicon.ico"    # forced via static_assets
printf '<svg/>'      > "$A/assets/img/orphan.svg" # referenced by nothing
build "$A" "$A_OUT" "$WORK/a.log"

grep -q "were not installed because nothing references them" "$WORK/a.log" ||
  { cat "$WORK/a.log"; fail "no pruned-asset warning for an unreferenced asset"; }
grep -q -- "- img/orphan.svg" "$WORK/a.log" ||
  { cat "$WORK/a.log"; fail "the unreferenced asset was not named in the report"; }
grep -q "^warning: 1 asset(s) under 'assets'" "$WORK/a.log" ||
  { cat "$WORK/a.log"; fail "the report did not count exactly one pruned asset"; }
[[ ! -f "$A_OUT/img/orphan.svg" ]] ||
  fail "the reported asset WAS installed — the report is describing the wrong thing"
echo "PASS: an unreferenced asset is named, counted, and genuinely absent"

grep -q -- "- linked.css" "$WORK/a.log" &&
  fail "a .link()ed asset was reported as pruned"
[[ -f "$A_OUT/linked.css" ]] || fail "the .link()ed asset was not installed"
echo "PASS: a .link()ed asset is neither reported nor dropped"

grep -q -- "- favicon.ico" "$WORK/a.log" &&
  fail "a static_assets entry was reported as pruned"
[[ -f "$A_OUT/favicon.ico" ]] || fail "the static_assets entry was not installed"
echo "PASS: a static_assets entry is neither reported nor dropped"

# --- (4) the list is capped, the total is not ------------------------------
B="$WORK/b"; B_OUT="$WORK/b-out"
scaffold "$B" assets
mkdir -p "$B/assets"
printf 'body{}' > "$B/assets/linked.css"
for i in $(seq -w 1 25); do printf 'x' > "$B/assets/orphan-$i.txt"; done
build "$B" "$B_OUT" "$WORK/b.log"

grep -q "^warning: 25 asset(s) under 'assets'" "$WORK/b.log" ||
  { cat "$WORK/b.log"; fail "the report did not state the true total of 25"; }
LISTED="$(grep -c '^  - ' "$WORK/b.log")"
[[ "$LISTED" -eq 10 ]] ||
  fail "the report listed $LISTED entries; the cap is 10, so a large assets/ tree would bury the log"
grep -q '^  \.\.\. and 15 more$' "$WORK/b.log" ||
  { cat "$WORK/b.log"; fail "the report did not say how many entries it elided"; }
echo "PASS: 25 pruned assets -> 10 listed + '... and 15 more', total reported"

# --- (5) deterministic ordering --------------------------------------------
# `Build.site_assets` is a hash map, so as-found order varies run to run. Two
# builds of the SAME input must still produce the same warning text, or the
# build log is not diffable and this repo's snapshot tests would flap.
build "$B" "$WORK/b-out2" "$WORK/b2.log"
diff <(grep -E '^(warning: [0-9]+ asset|  [-.])' "$WORK/b.log") \
     <(grep -E '^(warning: [0-9]+ asset|  [-.])' "$WORK/b2.log") ||
  fail "the pruned-asset report is not deterministic across builds of identical input"
# The two-build diff alone is weak evidence: same machine, same filesystem
# order, so an UNSORTED report would very likely agree with itself and still
# differ on someone else's box. What actually makes the output portable is the
# sort, so assert on that directly — the listed entries must already be in
# lexicographic order. `orphan-01…orphan-25` sort the same under any locale,
# and only the first 10 are listed, so the expected set is exact.
LIST="$(grep '^  - ' "$WORK/b.log" | sed 's/^  - //')"
diff <(printf '%s\n' "$LIST") <(printf '%s\n' "$LIST" | LC_ALL=C sort) ||
  fail "the report's listing is not sorted; its order would vary by machine"
diff <(printf '%s\n' "$LIST") <(for i in $(seq -w 1 10); do echo "orphan-$i.txt"; done) ||
  fail "the capped listing is not the 10 lexicographically smallest pruned assets"
echo "PASS: the report is sorted, capped at the 10 smallest, and stable across builds"

# --- (6) .keep is a git artifact, not an asset -----------------------------
C="$WORK/c"; C_OUT="$WORK/c-out"
scaffold "$C" assets
mkdir -p "$C/assets"
printf 'body{}' > "$C/assets/linked.css"
: > "$C/assets/.keep"
build "$C" "$C_OUT" "$WORK/c.log"
grep -q "were not installed because nothing references them" "$WORK/c.log" &&
  { cat "$WORK/c.log"; fail "a .keep placeholder was reported as a pruned asset"; }
echo "PASS: a .keep placeholder is not reported"

# --- (7) assets_dir_path doubling as the content dir -----------------------
# Several of this repo's own fixtures do this; there every `.smd` page source
# is also scanned as a site asset, so the report would name the whole content
# tree. It is switched off instead.
D="$WORK/d"; D_OUT="$WORK/d-out"
mkdir -p "$D/content" "$D/layouts"
cat > "$D/zigapagos.ziggy" <<'EOF'
Site {
    .title = "Pruned (aliased dirs)",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
EOF
printf '%s' '<!DOCTYPE html><html><head><meta charset="UTF-8"><title :text="$site.title"></title></head><body><h1 :text="$page.title"></h1></body></html>' \
  > "$D/layouts/index.shtml"
printf '%s' "$CONTENT" > "$D/content/index.smd"
build "$D" "$D_OUT" "$WORK/d.log"
grep -q "were not installed because nothing references them" "$WORK/d.log" &&
  { cat "$WORK/d.log"; fail "the report fired where assets_dir_path IS the content dir — it would name every page"; }
echo "PASS: the report is silent when assets_dir_path doubles as the content dir"

# --- (8) build-time reads are a use, not a pruning -------------------------
# `.bytes()`, `.size()`, `.sriHash()` and `.ziggy()` inline an asset into the
# page instead of publishing it, so they deliberately do NOT bump the install
# refcount. Keying the report off that refcount alone therefore accused a
# correctly-inlined data file of being unreferenced, on every build, and
# offered two remedies that are both wrong — `static_assets` would PUBLISH it.
# The orphan in the same tree is what proves the report is still on: it must
# name exactly one asset, and not the read ones.
E="$WORK/e"; E_OUT="$WORK/e-out"
scaffold "$E" assets
mkdir -p "$E/assets"
printf 'body{}'       > "$E/assets/linked.css"
printf 'HELLO-INLINE' > "$E/assets/inline.txt"   # read via .bytes()
printf '{"a":1}'      > "$E/assets/data.json"    # read via .size()
printf 'SRI'          > "$E/assets/hashed.txt"   # read via .sriHash()
printf '<svg/>'       > "$E/assets/orphan.svg"   # referenced by nothing
# Extend the shared layout with the three read builtins.
cat > "$E/layouts/index.shtml" <<'EOF'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8"><title :text="$site.title"></title>
    <link rel="stylesheet" href="$site.asset('linked.css').link()">
  </head>
  <body>
    <h1 :text="$page.title"></h1>
    <div id="b" :text="$site.asset('inline.txt').bytes()"></div>
    <div id="s" :text="$site.asset('data.json').size()"></div>
    <div id="h" :text="$site.asset('hashed.txt').sriHash()"></div>
  </body>
</html>
EOF
build "$E" "$E_OUT" "$WORK/e.log"

# The reads really happened — otherwise "not reported" would be vacuous.
grep -q 'HELLO-INLINE' "$E_OUT/index.html" ||
  { cat "$E_OUT/index.html"; fail ".bytes() did not inline the asset, so check (8) proves nothing"; }
grep -q '>7<' "$E_OUT/index.html" ||
  { cat "$E_OUT/index.html"; fail ".size() did not inline the byte count, so check (8) proves nothing"; }
grep -q 'sha384-' "$E_OUT/index.html" ||
  { cat "$E_OUT/index.html"; fail ".sriHash() did not inline a hash, so check (8) proves nothing"; }

for a in inline.txt data.json hashed.txt; do
  grep -q -- "- $a" "$WORK/e.log" &&
    { cat "$WORK/e.log"; fail "'$a' was read at build time but reported as pruned"; }
  [[ ! -f "$E_OUT/$a" ]] ||
    fail "'$a' was only READ, never linked — it must not be installed"
done
grep -q "^warning: 1 asset(s) under 'assets'" "$WORK/e.log" ||
  { cat "$WORK/e.log"; fail "the report should still name the one real orphan"; }
grep -q -- "- orphan.svg" "$WORK/e.log" ||
  { cat "$WORK/e.log"; fail "the genuinely unreferenced asset was not named"; }
echo "PASS: build-time reads suppress the report without installing the asset"

# --- (9) a failed render pass reports nothing ------------------------------
# `run()` does not stop at a page-render error: it marks the build and carries
# on through the install pass to the report, and only `cli/release.zig` checks
# the flag once `run()` has returned. So every asset whose only `.link()` sat
# on a page that died looks unreferenced. Two states of the SAME tree pin it:
# broken -> silent, fixed -> the warning is back.
F="$WORK/f"; F_OUT="$WORK/f-out"
scaffold "$F" assets
mkdir -p "$F/assets"
printf 'body{}' > "$F/assets/linked.css"
printf '<svg/>' > "$F/assets/orphan.svg"
cat > "$F/layouts/broken.shtml" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title :text="$site.title"></title></head>
<body><h1 :text="$page.nonexistent_field"></h1></body></html>
EOF
cat > "$F/content/broken.smd" <<'EOF'
---
.title = "Broken",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "broken.shtml",
.draft = false,
---

# Broken
EOF
( cd "$F" && "$ZIGAPAGOS" release "--output=$F_OUT" --force ) > "$WORK/f.log" 2>&1 &&
  { cat "$WORK/f.log"; fail "the broken-layout fixture built successfully — check (9) proves nothing"; }
grep -q "script_eval_not_string_or_int" "$WORK/f.log" ||
  { cat "$WORK/f.log"; fail "the build failed for some other reason than the intended render error"; }
grep -q "were not installed because nothing references them" "$WORK/f.log" &&
  { cat "$WORK/f.log"; fail "a FAILED build reported pruned assets; those refcounts are incomplete"; }
echo "PASS: a build with a render error prints no pruned-asset report"

# …and the same tree with the broken page removed does report, so the silence
# above is the render-error gate and not the fixture being unreportable.
rm "$F/content/broken.smd" "$F/layouts/broken.shtml"
build "$F" "$WORK/f-out2" "$WORK/f2.log"
grep -q -- "- orphan.svg" "$WORK/f2.log" ||
  { cat "$WORK/f2.log"; fail "the fixture does not report even when it builds — check (9) is vacuous"; }
echo "PASS: the same tree DOES report once it builds — the gate is the render error"

echo "ALL PROOF CHECKS PASSED (pruned-asset report)"
