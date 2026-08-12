#!/usr/bin/env bash
# Proof for `image_optimize` — build-time WebP variants + <picture> emission,
# including PR B's full multi-width srcset + sizes (issue #132; design doc:
# docs/superpowers/specs/2026-08-08-image-optimization-design.md).
#
# WHAT IT IS FOR. The pipeline is three separate touchpoints stitched together
# across passes that don't otherwise talk to each other: the analyze pass
# registers a derivation request, `planImageVariants` (src/root.zig) expands
# it into a param-addressed variant name BEFORE the render pass needs it, the
# render pass (src/render/html.zig) prints a <picture> using that name, and a
# worker job (src/image/derive.zig) later decodes/resamples/encodes the bytes
# and writes them under that SAME name. Unit tests cover each piece in
# isolation (test-images); what they CANNOT cover is that all four agree on
# one string, and that the file the HTML links is the file the install phase
# actually wrote with actually-valid WebP bytes. That is a build-time
# integration property, so it needs a real build.
#
# Checks. The fixture sets `.widths = [200, 400, 100000]`: 200 and 400 are
# below the fixture image's 500px intrinsic width and survive; 100000 does
# not (never upscale) and must be filtered out of the srcset entirely.
#   (1) ON:  a raster `$image` directive emits <picture><source type=
#            "image/webp" srcset="...">.
#   (2) ON:  the srcset carries exactly the surviving widths as `w`
#            descriptors (" 200w, " and " 400w"), and does NOT carry the
#            filtered 100000 — the PR A truncation-to-one-variant is gone.
#   (2b) ON: every URL named in that srcset resolves to a file that exists
#            and starts with the WebP RIFF/WEBP magic, and its basename is
#            `<stem>.<8 hex>.<width>.webp` — the param-addressed cache key
#            (spec §4) — for EACH surviving width, not just one.
#   (2c) ON: the `sizes` attribute is emitted verbatim from config
#            (`"100vw"`, the default) — required by the HTML spec once
#            srcset carries `w` descriptors.
#   (3) ON:  the fallback <img> still points at the untouched original bytes,
#            which exist on disk unmodified.
#   (4) ON:  a second directive (`$image.siteAsset`) gets its own <picture> —
#            the emission seam works for both directive kinds, not just one.
#   (5) cache: a rebuild of unchanged input does not re-encode (cache-file
#       mtime unchanged) — this is what makes a full rebuild cheap after the
#       first (spec §4's "first build pays the encode cost once").
#   (6) OFF (control): the same content with `image_optimize` absent from
#       `zigapagos.ziggy` emits no <picture> and no `.webp` anywhere — the
#       feature is opt-in, and turning it off is byte-identical to today.
#   (7) ON, AVIF hatch (Task 12): with `avif_encoder` set to a hermetic stub
#       binary (no real AV1 encoder in CI), `<source type="image/avif">`
#       appears BEFORE the webp source (spec §2 best-first order) and every
#       URL it carries resolves to a file starting with the stub's marker.
#   (8) AVIF encoder missing: the user opted in by naming a binary that does
#       not exist, so the build fails loudly, naming that binary — never a
#       silent fall-back to webp-only (spec §6).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
if [[ -n "${ZIGAPAGOS_BIN:+x}" ]]; then
  ZIGAPAGOS="$ZIGAPAGOS_BIN"
  [[ -x "$ZIGAPAGOS" ]] || {
    echo "FAIL: ZIGAPAGOS_BIN is not executable: $ZIGAPAGOS"
    exit 1
  }
else
  ZIGAPAGOS="$REPO/zig-out/bin/zigapagos"
  if [[ ! -x "$ZIGAPAGOS" ]]; then
    echo "building zigapagos (zig-out/bin/zigapagos missing)..."
    mise exec -- zig build || { echo "FAIL: zig build failed"; exit 1; }
  fi
fi

fail() { echo "FAIL: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Portable mtime-of-file, since this is exactly the kind of check GNU/BSD
# `stat` disagree on (see CLAUDE.md's shell-portability notes).
mtime() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

SOURCE_JPG="$REPO/src/cli/init/content/blog/first-post/retro-cover.jpg"
[[ -f "$SOURCE_JPG" ]] || fail "fixture source image missing: $SOURCE_JPG"

LAYOUT='<!DOCTYPE html>
<html>
  <head><meta charset="UTF-8"><title :text="$site.title"></title></head>
  <body>
    <div :html="$page.content()"></div>
  </body>
</html>'

# Builds the fixture site tree at "$WORK/site". Both the page-asset
# (content/photo.jpg) and site-asset (assets/art/wide.jpg) directives are
# the same source bytes under different filenames — plan.zig hashes SOURCE
# BYTES, not the on-disk name, so this also exercises the two-different-refs-
# same-bytes path (a task-6/7 review finding) without a second fixture image.
scaffold() {
  mkdir -p "$WORK/site/content" "$WORK/site/layouts" "$WORK/site/assets/art"
  cat > "$WORK/site/zigapagos.ziggy" <<EOF
Site {
    .title = "ImageOptimize e2e",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .image_optimize = {
        .widths = [200, 400, 100000],
    },
}
EOF
  printf '%s' "$LAYOUT" > "$WORK/site/layouts/index.shtml"
  cat > "$WORK/site/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

[A test image.](<$image.asset("photo.jpg").alt("test photo")>)

[]($image.siteAsset("art/wide.jpg"))
EOF
  cp "$SOURCE_JPG" "$WORK/site/content/photo.jpg"
  cp "$SOURCE_JPG" "$WORK/site/assets/art/wide.jpg"
}

build() {
  local out="$1" log="$2"
  ( cd "$WORK/site" && "$ZIGAPAGOS" release "--output=$out" --force ) > "$log" 2>&1 ||
    { cat "$log"; fail "build failed (see log above)"; }
}

scaffold

# --- (1)-(5) flag ON -----------------------------------------------------
OUT="$WORK/out"
build "$OUT" "$WORK/build-on.log"

HTML="$OUT/index.html"
[[ -f "$HTML" ]] || fail "flag-ON build did not emit index.html"

# (1) <picture> shape with a webp source.
grep -q '<picture><source type="image/webp" srcset="' "$HTML" || fail "no <picture> emitted"
echo "PASS: (1) <picture><source type=\"image/webp\"...> emitted"

# (2) full srcset: exactly the surviving widths as `w` descriptors, in
# ascending order, with the filtered-out 100000 nowhere in it. This is the
# PR B check — PR A truncated to one variant, so this fails against that code.
SRCSET=$(grep -o 'srcset="[^"]*"' "$HTML" | head -1 | sed 's/srcset="//;s/"$//')
[[ -n "$SRCSET" ]] || fail "no srcset attribute found"
echo "$SRCSET" | grep -q ' 200w, ' || fail "srcset missing ' 200w, ' descriptor: $SRCSET"
echo "$SRCSET" | grep -q ' 400w' || fail "srcset missing ' 400w' descriptor: $SRCSET"
echo "$SRCSET" | grep -q '100000' && fail "srcset carries the filtered-out 100000 width: $SRCSET"
echo "PASS: (2) srcset carries exactly the surviving widths (200w, 400w); 100000 filtered"

# (2b) every URL in that srcset resolves to a real WebP file, param-addressed
# per check (3)'s original name shape — for BOTH surviving widths.
VAR_URLS=$(echo "$SRCSET" | tr ',' '\n' | sed -E 's/^ +//; s/ [0-9]+w *$//')
VAR_COUNT=0
while IFS= read -r u; do
  [[ -n "$u" ]] || continue
  VAR_COUNT=$((VAR_COUNT + 1))
  p="$OUT/${u#/}"
  [[ -f "$p" ]] || fail "srcset points at missing file: $u"
  head -c 12 "$p" | grep -q 'WEBP' || fail "variant is not a WebP container: $u"
  # name shape: <stem>.<8hex>.<width>.webp — the param-addressed cache key.
  basename "$p" | grep -Eq '^photo\.[0-9a-f]{8}\.[0-9]+\.webp$' || fail "bad variant name: $(basename "$p")"
done <<<"$VAR_URLS"
[[ "$VAR_COUNT" == "2" ]] || fail "expected 2 srcset entries (200w, 400w), got $VAR_COUNT"
echo "PASS: (2b) both named variant files exist, are WebP, and are param-addressed"

# (2c) sizes attribute, emitted verbatim from config (default "100vw").
grep -q 'sizes="100vw"' "$HTML" || fail "sizes=\"100vw\" attribute missing"
echo "PASS: (2c) sizes=\"100vw\" emitted"

# (3) fallback <img> still points at the untouched original, which exists.
grep -q '<img src="' "$HTML" || fail "fallback <img> missing"
ORIG_URL=$(grep -o '<img src="[^"]*"' "$HTML" | head -1 | sed 's/<img src="//;s/"$//')
[[ -f "$OUT/${ORIG_URL#/}" ]] || fail "fallback original missing"
cmp -s "$OUT/${ORIG_URL#/}" "$WORK/site/content/photo.jpg" || fail "original was modified"
echo "PASS: (3) fallback <img> src='$ORIG_URL' is the untouched original"

# (4) the site-asset image also got a variant (second URL seam).
[[ "$(grep -c '<picture>' "$HTML")" == "2" ]] || fail "expected 2 pictures, got $(grep -c '<picture>' "$HTML")"
echo "PASS: (4) both \$image.asset and \$image.siteAsset directives emitted <picture>"

# (5) cache: entries exist; a rebuild does not re-encode (mtime stable).
CACHE_DIR="$WORK/site/.zigapagos-cache/images"
CACHE=$(ls "$CACHE_DIR" | head -1)
[[ -n "$CACHE" ]] || fail "cache empty after build"
M1=$(mtime "$CACHE_DIR/$CACHE")
sleep 1.1
build "$OUT" "$WORK/build-on-rebuild.log"
M2=$(mtime "$CACHE_DIR/$CACHE")
[[ "$M1" == "$M2" ]] || fail "rebuild re-encoded a cached variant (mtime $M1 -> $M2)"
echo "PASS: (5) rebuild of unchanged input hit the cache (mtime unchanged)"

# --- (6) flag OFF control -------------------------------------------------
# Same content, `image_optimize` simply absent — matches how every existing
# site is configured today (the field defaults to null / off). The block now
# spans multiple lines (`.widths = [...]`), so the deletion is a range, not
# a single-line match.
sed -i.bak '/\.image_optimize = {/,/},/d' "$WORK/site/zigapagos.ziggy" && rm -f "$WORK/site/zigapagos.ziggy.bak"
grep -q 'image_optimize' "$WORK/site/zigapagos.ziggy" && fail "image_optimize block survived the OFF-control edit"
OUT_OFF="$WORK/out-off"
build "$OUT_OFF" "$WORK/build-off.log"
HTML_OFF="$OUT_OFF/index.html"
grep -q '<picture>' "$HTML_OFF" && fail "feature off but <picture> emitted"
find "$OUT_OFF" -name '*.webp' | grep -q . && fail "feature off but webp emitted"
echo "PASS: (6) flag OFF (control) — no <picture>, no .webp anywhere"

# --- (7)/(8) AVIF hatch (Task 12) -----------------------------------------
# A fresh, independent fixture (own site dir) so the AVIF checks don't
# entangle with the (1)-(6) fixture's already-pinned state/edits above.
#
# The stub is exactly the shape a real `avifenc`-compatible binary is
# spawned with: `<in.png> <out.avif>`. It writes a marker instead of
# actually encoding AV1 — CI has no AV1 encoder, and the pipeline plumbing
# (temp PNG -> spawn -> rename into cache -> install) is what's under test,
# not codec correctness (that's `png.zig`'s round-trip-through-wuffs test).
AVIFENC="$WORK/avifenc-stub"
cat > "$AVIFENC" <<'EOF'
#!/usr/bin/env bash
# argv: <in.png> <out.avif> — writes a marker so the test can verify the
# pipeline without a real AV1 encoder.
printf 'STUBAVIF' > "$2"
cat "$1" >> "$2"
EOF
chmod +x "$AVIFENC"

scaffold_avif() {
  local dir="$1" avif_bin="$2"
  mkdir -p "$dir/content" "$dir/layouts" "$dir/assets"
  cat > "$dir/zigapagos.ziggy" <<EOF
Site {
    .title = "ImageOptimize AVIF e2e",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .image_optimize = {
        .widths = [200, 400, 100000],
        .avif_encoder = "$avif_bin",
    },
}
EOF
  printf '%s' "$LAYOUT" > "$dir/layouts/index.shtml"
  cat > "$dir/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

[A test image.](<$image.asset("photo.jpg").alt("test photo")>)
EOF
  cp "$SOURCE_JPG" "$dir/content/photo.jpg"
}

build_at() {
  local site="$1" out="$2" log="$3"
  ( cd "$site" && "$ZIGAPAGOS" release "--output=$out" --force ) > "$log" 2>&1 ||
    { cat "$log"; fail "build failed (see log above)"; }
}

# --- (7) AVIF ON: stub encoder ---
SITE_AVIF="$WORK/site-avif"
scaffold_avif "$SITE_AVIF" "$AVIFENC"
OUT_AVIF="$WORK/out-avif"
build_at "$SITE_AVIF" "$OUT_AVIF" "$WORK/build-avif.log"
HTML_AVIF="$OUT_AVIF/index.html"
[[ -f "$HTML_AVIF" ]] || fail "AVIF-ON build did not emit index.html"

# avif <source> appears BEFORE the webp <source> (best-first per spec §2).
# (`|| true` on each: absent output, e.g. no avif support yet, otherwise
# kills the script under `set -eo pipefail` before the `fail` below runs.)
AVIF_POS=$(grep -bo '<source type="image/avif"' "$HTML_AVIF" | head -1 | cut -d: -f1) || true
WEBP_POS=$(grep -bo '<source type="image/webp"' "$HTML_AVIF" | head -1 | cut -d: -f1) || true
[[ -n "$AVIF_POS" ]] || fail "no avif <source> emitted with avif_encoder set"
[[ -n "$WEBP_POS" ]] || fail "no webp <source> emitted alongside avif"
[[ "$AVIF_POS" -lt "$WEBP_POS" ]] || fail "avif <source> (byte $AVIF_POS) not before webp <source> (byte $WEBP_POS)"
echo "PASS: (7a) avif <source> appears before webp <source>"

# (7a-sizes) #147: the WebP <source> line's `sizes=` was pinned, the AVIF
# line's never was — the two lines are built by the same
# `writeImageSourceLine` call, once per codec, so a regression that dropped
# `sizes` from only the FIRST (avif) call would have shipped silently.
AVIF_LINE=$(grep -o '<source type="image/avif"[^>]*>' "$HTML_AVIF" | head -1) || true
[[ -n "$AVIF_LINE" ]] || fail "(7a-sizes) no avif <source> line found to check for sizes="
echo "$AVIF_LINE" | grep -q 'sizes="100vw"' || fail "(7a-sizes) avif <source> line missing sizes=\"100vw\": $AVIF_LINE"
echo "PASS: (7a-sizes) avif <source> line carries sizes=\"100vw\""

# Every URL in the avif srcset resolves to a file that exists, is
# param-addressed like the webp variants, and starts with the stub's marker
# (i.e. actually went through the spawn -> rename -> install path, not a
# leftover/misnamed webp file).
AVIF_SRCSET=$(grep -o 'type="image/avif" srcset="[^"]*"' "$HTML_AVIF" | head -1 | sed 's/.*srcset="//;s/"$//') || true
[[ -n "$AVIF_SRCSET" ]] || fail "no avif srcset attribute found"
AVIF_URLS=$(echo "$AVIF_SRCSET" | tr ',' '\n' | sed -E 's/^ +//; s/ [0-9]+w *$//')
AVIF_COUNT=0
while IFS= read -r u; do
  [[ -n "$u" ]] || continue
  AVIF_COUNT=$((AVIF_COUNT + 1))
  p="$OUT_AVIF/${u#/}"
  [[ -f "$p" ]] || fail "avif srcset points at missing file: $u"
  head -c 8 "$p" | grep -q 'STUBAVIF' || fail "avif variant missing the stub encoder's marker: $u"
  basename "$p" | grep -Eq '^photo\.[0-9a-f]{8}\.[0-9]+\.avif$' || fail "bad avif variant name: $(basename "$p")"
done <<<"$AVIF_URLS"
[[ "$AVIF_COUNT" == "2" ]] || fail "expected 2 avif srcset entries (200w, 400w), got $AVIF_COUNT"
echo "PASS: (7b) avif variant files exist, carry the stub's marker, and are param-addressed"

# --- (8) AVIF encoder missing: fatal, naming the binary ---
SITE_AVIF_MISSING="$WORK/site-avif-missing"
scaffold_avif "$SITE_AVIF_MISSING" "/nonexistent/avifenc"
set +e
( cd "$SITE_AVIF_MISSING" && "$ZIGAPAGOS" release "--output=$WORK/out-avif-missing" --force ) \
  >"$WORK/build-avif-missing.log" 2>&1
AVIF_MISSING_STATUS=$?
set -e
[[ "$AVIF_MISSING_STATUS" -ne 0 ]] || fail "build with a missing avif_encoder binary unexpectedly succeeded"
grep -q '/nonexistent/avifenc' "$WORK/build-avif-missing.log" ||
  fail "fatal message does not name the missing avif_encoder binary (log: $WORK/build-avif-missing.log)"
echo "PASS: (8) missing avif_encoder binary fails the build, naming the binary"

# --- (8b) AVIF encoder exits 0 without writing its output ---
# A wrapper script with its arguments reversed exits 0 and writes nothing, so
# the install rename fails with a bare FileNotFound naming a cache entry the
# author never heard of. The build must still fail, but the message has to
# point at the encoder contract rather than at the cache.
AVIFENC_SILENT="$WORK/avifenc-stub-silent"
cat > "$AVIFENC_SILENT" <<'EOF'
#!/usr/bin/env bash
# argv: <in.png> <out.avif> — exits 0, writes nothing (the misconfiguration).
exit 0
EOF
chmod +x "$AVIFENC_SILENT"
SITE_AVIF_SILENT="$WORK/site-avif-silent"
scaffold_avif "$SITE_AVIF_SILENT" "$AVIFENC_SILENT"
set +e
( cd "$SITE_AVIF_SILENT" && "$ZIGAPAGOS" release "--output=$WORK/out-avif-silent" --force ) \
  >"$WORK/build-avif-silent.log" 2>&1
AVIF_SILENT_STATUS=$?
set -e
[[ "$AVIF_SILENT_STATUS" -ne 0 ]] || fail "build with a non-writing avif_encoder unexpectedly succeeded"
grep -q 'without writing its output file' "$WORK/build-avif-silent.log" ||
  fail "fatal message does not diagnose the encoder writing no output (log: $WORK/build-avif-silent.log)"
grep -q "$AVIFENC_SILENT" "$WORK/build-avif-silent.log" ||
  fail "fatal message does not name the encoder (log: $WORK/build-avif-silent.log)"
echo "PASS: (8b) an encoder that exits 0 without writing output is diagnosed as such"

# --- (9) oversized source: silent passthrough, not fatal (#132 final review,
# Fix 1) ---------------------------------------------------------------
# decode.zig rejects anything over 16384px per side (`error.TooLarge`); before
# the fix, planImageVariants didn't share that bound, so it planned a variant
# for an oversized source, the render pass promised that URL in the HTML, and
# derive.zig's decode() then fataled — output tree already partially written,
# HTML pointing at files that would never exist. The fix makes the planner
# apply decode.zig's own `max_dimension` and fall into the SAME silent
# plain-<img> bucket as an undecodable source (spec §7), beside a normal
# image in the same build so the guard is proven to be per-image, not a
# feature-wide kill switch.
SITE_BIG="$WORK/site-big"
mkdir -p "$SITE_BIG/content" "$SITE_BIG/layouts" "$SITE_BIG/assets"
cat > "$SITE_BIG/zigapagos.ziggy" <<EOF
Site {
    .title = "ImageOptimize oversized e2e",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .image_optimize = {
        .widths = [200, 400],
    },
}
EOF
printf '%s' "$LAYOUT" > "$SITE_BIG/layouts/index.shtml"
cat > "$SITE_BIG/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

[A test image.](<$image.asset("photo.jpg").alt("test photo")>)

[](<$image.asset("wide.png")>)
EOF
cp "$SOURCE_JPG" "$SITE_BIG/content/photo.jpg"
# 20000x4 RGBA PNG: past decode.zig's 16384px-per-side cap on width, well
# under it on height, so this is unambiguously the oversized case and not an
# accidental zero-dimension one.
python3 - "$SITE_BIG/content/wide.png" <<'PY'
import struct, sys, zlib
W, H = 20000, 4
path = sys.argv[1]
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
raw = b""
for y in range(H):
    raw += b"\x00" + bytes([(x * 7 + y) % 256 for x in range(W * 4)])
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, 6))
png += chunk(b"IEND", b"")
open(path, "wb").write(png)
PY
OUT_BIG="$WORK/out-big"
build_at "$SITE_BIG" "$OUT_BIG" "$WORK/build-big.log"
HTML_BIG="$OUT_BIG/index.html"
[[ -f "$HTML_BIG" ]] || fail "(9) oversized-source build did not emit index.html"
[[ "$(grep -c '<picture>' "$HTML_BIG")" == "1" ]] ||
  fail "(9) expected exactly 1 <picture> (normal image only), got $(grep -c '<picture>' "$HTML_BIG")"
grep -q '<img src="/wide.png">' "$HTML_BIG" ||
  fail "(9) oversized source did not fall back to a plain <img>: $(cat "$HTML_BIG")"
[[ -f "$OUT_BIG/wide.png" ]] || fail "(9) oversized source's own asset was not installed"
echo "PASS: (9) oversized source (20000x4) is silent passthrough (plain <img>, no fatal); normal image in the same build still gets a <picture>"

# --- (10) whitespace in filename: percent-encoded in srcset, not the file on
# disk (#132 final review, Fix 2) ---------------------------------------
# Per the HTML "parse a srcset attribute" algorithm, a candidate URL
# terminates at the first ASCII whitespace; a raw space in `srcset` silently
# truncates every candidate and the browser falls back to plain <img> with
# optimization off and nothing observable. printVariantUrl must percent-
# encode it; the file itself keeps its literal (space-containing) name.
SITE_SPACE="$WORK/site-space"
mkdir -p "$SITE_SPACE/content" "$SITE_SPACE/layouts" "$SITE_SPACE/assets"
cat > "$SITE_SPACE/zigapagos.ziggy" <<EOF
Site {
    .title = "ImageOptimize space e2e",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .image_optimize = {
        .widths = [200, 400],
    },
}
EOF
printf '%s' "$LAYOUT" > "$SITE_SPACE/layouts/index.shtml"
cat > "$SITE_SPACE/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

[](<$image.asset("my photo.jpg")>)
EOF
cp "$SOURCE_JPG" "$SITE_SPACE/content/my photo.jpg"
OUT_SPACE="$WORK/out-space"
build_at "$SITE_SPACE" "$OUT_SPACE" "$WORK/build-space.log"
HTML_SPACE="$OUT_SPACE/index.html"
[[ -f "$HTML_SPACE" ]] || fail "(10) whitespace-filename build did not emit index.html"
SPACE_SRCSET=$(grep -o 'srcset="[^"]*"' "$HTML_SPACE" | head -1 | sed 's/srcset="//;s/"$//')
[[ -n "$SPACE_SRCSET" ]] || fail "(10) no srcset attribute found"
FIRST_CANDIDATE=$(echo "$SPACE_SRCSET" | sed -E 's/,.*//; s/ [0-9]+w *$//')
[[ "$FIRST_CANDIDATE" != *" "* ]] ||
  fail "(10) srcset's first candidate URL still contains a raw space: '$FIRST_CANDIDATE'"
echo "$FIRST_CANDIDATE" | grep -q '%20' ||
  fail "(10) srcset's first candidate URL has no %20 (space not encoded): '$FIRST_CANDIDATE'"
SPACE_FILE="$OUT_SPACE${FIRST_CANDIDATE//%20/ }"
[[ -f "$SPACE_FILE" ]] || fail "(10) encoded srcset URL does not resolve to a file on disk: $SPACE_FILE"
echo "PASS: (10) whitespace in a source filename is percent-encoded in srcset (%20), file on disk keeps its literal name"

# --- (11) widths.len > 64 is rejected, naming the bound (#132 final review,
# Fix 3; previously untested) --------------------------------------------
SITE_WIDE_LIST="$WORK/site-wide-list"
mkdir -p "$SITE_WIDE_LIST/content" "$SITE_WIDE_LIST/layouts" "$SITE_WIDE_LIST/assets"
WIDTHS_65=$(python3 -c 'print(", ".join(str(100 + i) for i in range(65)))')
cat > "$SITE_WIDE_LIST/zigapagos.ziggy" <<EOF
Site {
    .title = "ImageOptimize widths-cap e2e",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .image_optimize = {
        .widths = [$WIDTHS_65],
    },
}
EOF
printf '%s' "$LAYOUT" > "$SITE_WIDE_LIST/layouts/index.shtml"
cat > "$SITE_WIDE_LIST/content/index.smd" <<'EOF'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.author = "Test",
.layout = "index.shtml",
.draft = false,
---

[A test image.](<$image.asset("photo.jpg").alt("test photo")>)
EOF
cp "$SOURCE_JPG" "$SITE_WIDE_LIST/content/photo.jpg"
set +e
( cd "$SITE_WIDE_LIST" && "$ZIGAPAGOS" release "--output=$WORK/out-wide-list" --force ) \
  >"$WORK/build-wide-list.log" 2>&1
WIDE_LIST_STATUS=$?
set -e
[[ "$WIDE_LIST_STATUS" -ne 0 ]] || fail "(11) build with 65 configured widths unexpectedly succeeded"
grep -q '65 entries' "$WORK/build-wide-list.log" ||
  fail "(11) fatal message does not name the entry count (log: $WORK/build-wide-list.log)"
grep -q 'must be <= 64' "$WORK/build-wide-list.log" ||
  fail "(11) fatal message does not name the 64-entry bound (log: $WORK/build-wide-list.log)"
echo "PASS: (11) more than 64 configured widths fails the build, naming the count and the 64-entry bound"

echo "ALL PROOF CHECKS PASSED (image_optimize)"
