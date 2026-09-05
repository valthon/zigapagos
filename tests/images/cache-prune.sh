#!/usr/bin/env bash
# A real encoder held at a handshake proves prune cannot remove live temp
# files. A second build must reuse the first build's eventual cache entries.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
first_pid= second_pid=
cleanup() {
  touch "$WORK/continue"
  if [[ -n "$first_pid" ]]; then wait "$first_pid" || true; fi
  if [[ -n "$second_pid" ]]; then wait "$second_pid" || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$WORK/content" "$WORK/layouts"
cat > "$WORK/zigapagos.ziggy" <<EOF
Site {
    .title = "Cache prune",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
    .image_optimize = { .widths = [200], .avif_encoder = "$WORK/encoder" },
}
EOF
cat > "$WORK/layouts/index.shtml" <<'EOF'
<!DOCTYPE html>
<html><head><title>Cache</title></head><body><div :html="$page.content()"></div></body></html>
EOF
cat > "$WORK/content/index.smd" <<'EOF'
---
.title = "Cache",
.date = @date("2020-07-06T00:00:00"),
.layout = "index.shtml",
---
[]($image.asset("photo.jpg"))
EOF
cp "$REPO/src/cli/init/content/blog/first-post/retro-cover.jpg" "$WORK/content/photo.jpg"
cat > "$WORK/encoder" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(dirname "$0")"
echo encode >> "$root/encodes"
touch "$root/ready"
for attempt in $(seq 1 400); do
  if [[ -f "$root/continue" ]]; then
    printf 'stub avif' > "$2"
    exit 0
  fi
  sleep 0.05
done
echo 'encoder handshake timed out' >&2
exit 1
EOF
chmod +x "$WORK/encoder"
(cd "$WORK" && exec "$BIN" release --force -o first) >"$WORK/first.log" 2>&1 &
first_pid=$!
for attempt in $(seq 1 400); do
  [[ -f "$WORK/ready" ]] && break
  if ! kill -0 "$first_pid" 2>/dev/null; then cat "$WORK/first.log"; fail 'build died before encoding'; fi
  sleep 0.05
done
[[ -f "$WORK/ready" ]] || fail 'encoder never became ready'
CACHE="$WORK/.zigapagos-cache/images"
if (cd "$WORK" && "$BIN" cache-prune --max-bytes=0 --apply) >"$WORK/busy.log" 2>&1; then
  fail 'prune acquired the cache while an encoder was active'
fi
grep -q 'image cache is busy' "$WORK/busy.log" || { cat "$WORK/busy.log"; fail 'wrong busy diagnostic'; }
compgen -G "$CACHE/.tmp.*.png" >/dev/null || fail 'active encoder input was removed'
active_temp="$(compgen -G "$CACHE/.tmp.*.png")"
(cd "$WORK" && exec "$BIN" release --force -o second) >"$WORK/second.log" 2>&1 &
second_pid=$!
for attempt in $(seq 1 200); do
  grep -q 'waiting for the image cache' "$WORK/second.log" && break
  if ! kill -0 "$second_pid" 2>/dev/null; then cat "$WORK/second.log"; fail 'second build did not wait'; fi
  sleep 0.05
done
grep -q 'waiting for the image cache' "$WORK/second.log" || fail 'blocked build gave no waiting diagnostic'
touch "$WORK/continue"
wait "$first_pid" || { cat "$WORK/first.log"; fail 'first build failed'; }
first_pid=
wait "$second_pid" || { cat "$WORK/second.log"; fail 'second build failed'; }
second_pid=
[[ "$(wc -l < "$WORK/encodes" | tr -d ' ')" == 1 ]] || fail 'concurrent build encoded twice'
diff -r "$WORK/first" "$WORK/second"
# Preserve unowned files, directories, links and all published/source bytes.
printf notes > "$CACHE/notes"
mkdir "$CACHE/subdir.abcdef01.200.webp"
ln -s ../../content/photo.jpg "$CACHE/link.abcdef01.200.webp"
printf orphan > "$CACHE/.tmp.0.1.2.3.old.abcdef01.200.avif.png"
printf orphan > "$active_temp"
(cd "$WORK" && "$BIN" cache-prune --max-bytes=0) >"$WORK/dry.log" 2>&1
compgen -G "$CACHE/photo.*.webp" >/dev/null || fail 'dry-run deleted variant'
[[ -f "$CACHE/.tmp.0.1.2.3.old.abcdef01.200.avif.png" ]] || fail 'dry-run deleted temp'
[[ -f "$active_temp" ]] || fail 'dry-run deleted v2 temp'
(cd "$WORK" && "$BIN" cache-prune --max-bytes=0 --apply) >"$WORK/apply.log" 2>&1
if compgen -G "$CACHE/photo.*.webp" >/dev/null || compgen -G "$CACHE/photo.*.avif" >/dev/null; then fail 'apply retained variants'; fi
[[ ! -e "$CACHE/.tmp.0.1.2.3.old.abcdef01.200.avif.png" ]] || fail 'apply retained orphan temp'
[[ ! -e "$active_temp" ]] || fail 'apply retained orphan v2 temp'
[[ -f "$CACHE/notes" && -d "$CACHE/subdir.abcdef01.200.webp" && -L "$CACHE/link.abcdef01.200.webp" && -f "$CACHE/.lock" ]] || fail 'cleanup removed unowned entry or lock'
cmp "$WORK/content/photo.jpg" "$REPO/src/cli/init/content/blog/first-post/retro-cover.jpg"
diff -r "$WORK/first" "$WORK/second"
(cd "$WORK" && "$BIN" release --force -o third) >"$WORK/third.log" 2>&1
[[ "$(wc -l < "$WORK/encodes" | tr -d ' ')" == 2 ]] || fail 'pruned variant was not regenerated'
diff -r "$WORK/first" "$WORK/third"
# The build nonce must not consume the remaining NAME_MAX headroom of a
# long source basename. Temporary names carry IDs/width/codec, not the stem.
long_name="$(printf 'long-%0210d.jpg' 0)"
mv "$WORK/content/photo.jpg" "$WORK/content/$long_name"
sed "s/photo.jpg/$long_name/g" "$WORK/content/index.smd" > "$WORK/long.smd"
mv "$WORK/long.smd" "$WORK/content/index.smd"
(cd "$WORK" && "$BIN" release --force -o long) >"$WORK/long.log" 2>&1 || { cat "$WORK/long.log"; fail 'long image basename failed'; }
for arg in --max-bytes= --max-bytes=-1 --max-bytes=+1 --max-bytes=18446744073709551616; do
  if (cd "$WORK" && "$BIN" cache-prune "$arg") >"$WORK/invalid.log" 2>&1; then fail "accepted $arg"; fi
done
mkdir "$WORK/absent"
(cd "$WORK/absent" && "$BIN" cache-prune --max-bytes=0 --apply) >"$WORK/absent.log" 2>&1
[[ ! -e "$WORK/absent/.zigapagos-cache" ]] || fail 'absent cache created'
ln -s ../.zigapagos-cache "$WORK/absent/.zigapagos-cache"
if (cd "$WORK/absent" && "$BIN" cache-prune --max-bytes=0 --apply) >"$WORK/link.log" 2>&1; then fail 'followed cache directory symlink'; fi
echo 'ok: prune respects active builds, budget, dry-run and filesystem boundaries'
