#!/usr/bin/env bash
# Proof for `image_optimize` — build-time WebP variants + <picture> emission
# (issue #132, PR A: docs/superpowers/specs/2026-08-08-image-optimization-design.md).
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
# Checks:
#   (1) ON:  a raster `$image` directive emits <picture><source type=
#            "image/webp" srcset="...">.
#   (2) ON:  the srcset URL resolves to a file that exists and starts with
#            the WebP RIFF/WEBP magic.
#   (3) ON:  the variant's basename is `<stem>.<8 hex>.<width>.webp` — the
#            param-addressed cache key (spec §4).
#   (4) ON:  the fallback <img> still points at the untouched original bytes,
#            which exist on disk unmodified.
#   (5) ON:  a second directive (`$image.siteAsset`) gets its own <picture> —
#            the emission seam works for both directive kinds, not just one.
#   (6) cache: a rebuild of unchanged input does not re-encode (cache-file
#       mtime unchanged) — this is what makes a full rebuild cheap after the
#       first (spec §4's "first build pays the encode cost once").
#   (7) OFF (control): the same content with `image_optimize` absent from
#       `zigapagos.ziggy` emits no <picture> and no `.webp` anywhere — the
#       feature is opt-in, and turning it off is byte-identical to today.
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
    .image_optimize = {},
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

# --- (1)-(6) flag ON ---------------------------------------------------
OUT="$WORK/out"
build "$OUT" "$WORK/build-on.log"

HTML="$OUT/index.html"
[[ -f "$HTML" ]] || fail "flag-ON build did not emit index.html"

# (1) <picture> shape with a webp source.
grep -q '<picture><source type="image/webp" srcset="' "$HTML" || fail "no <picture> emitted"
echo "PASS: (1) <picture><source type=\"image/webp\"...> emitted"

# (2) the variant file the HTML references exists and is really WebP.
VAR_URL=$(grep -o 'srcset="[^"]*"' "$HTML" | head -1 | sed 's/srcset="//;s/"$//')
VAR_PATH="$OUT/${VAR_URL#/}"
[[ -f "$VAR_PATH" ]] || fail "srcset points at missing file: $VAR_URL"
head -c 12 "$VAR_PATH" | grep -q 'WEBP' || fail "variant is not a WebP container"
echo "PASS: (2) srcset '$VAR_URL' resolves to a real WebP file"

# (3) name shape: <stem>.<8hex>.<width>.webp
basename "$VAR_PATH" | grep -Eq '^photo\.[0-9a-f]{8}\.[0-9]+\.webp$' || fail "bad variant name: $(basename "$VAR_PATH")"
echo "PASS: (3) variant basename is param-addressed: $(basename "$VAR_PATH")"

# (4) fallback <img> still points at the untouched original, which exists.
grep -q '<img src="' "$HTML" || fail "fallback <img> missing"
ORIG_URL=$(grep -o '<img src="[^"]*"' "$HTML" | head -1 | sed 's/<img src="//;s/"$//')
[[ -f "$OUT/${ORIG_URL#/}" ]] || fail "fallback original missing"
cmp -s "$OUT/${ORIG_URL#/}" "$WORK/site/content/photo.jpg" || fail "original was modified"
echo "PASS: (4) fallback <img> src='$ORIG_URL' is the untouched original"

# (5) the site-asset image also got a variant (second URL seam).
[[ "$(grep -c '<picture>' "$HTML")" == "2" ]] || fail "expected 2 pictures, got $(grep -c '<picture>' "$HTML")"
echo "PASS: (5) both \$image.asset and \$image.siteAsset directives emitted <picture>"

# (6) cache: entry exists; a rebuild does not re-encode (mtime stable).
CACHE_DIR="$WORK/site/.zigapagos-cache/images"
CACHE=$(ls "$CACHE_DIR" | head -1)
[[ -n "$CACHE" ]] || fail "cache empty after build"
M1=$(mtime "$CACHE_DIR/$CACHE")
sleep 1.1
build "$OUT" "$WORK/build-on-rebuild.log"
M2=$(mtime "$CACHE_DIR/$CACHE")
[[ "$M1" == "$M2" ]] || fail "rebuild re-encoded a cached variant (mtime $M1 -> $M2)"
echo "PASS: (6) rebuild of unchanged input hit the cache (mtime unchanged)"

# --- (7) flag OFF control -----------------------------------------------
# Same content, `image_optimize` simply absent — matches how every existing
# site is configured today (the field defaults to null / off).
sed -i.bak '/\.image_optimize/d' "$WORK/site/zigapagos.ziggy" && rm -f "$WORK/site/zigapagos.ziggy.bak"
OUT_OFF="$WORK/out-off"
build "$OUT_OFF" "$WORK/build-off.log"
HTML_OFF="$OUT_OFF/index.html"
grep -q '<picture>' "$HTML_OFF" && fail "feature off but <picture> emitted"
find "$OUT_OFF" -name '*.webp' | grep -q . && fail "feature off but webp emitted"
echo "PASS: (7) flag OFF (control) — no <picture>, no .webp anywhere"

echo "ALL PROOF CHECKS PASSED (image_optimize)"
