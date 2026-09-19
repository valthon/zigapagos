#!/usr/bin/env bash
# A release uses one minifier process; the legacy/custom protocol stays unchanged.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/site/"{assets/nested,layouts,content}
cat > "$WORK/site/zigapagos.ziggy" <<'CONFIG'
Site {
 .title = "CSS",
 .host_url = "https://example.com",
 .content_dir_path = "content",
 .layouts_dir_path = "layouts",
 .assets_dir_path = "assets",
 .static_assets = ["one.css", "nested/one.css", "EMPTY.css", "keep.txt"],
 .asset_fingerprint = true,
}
CONFIG
cat > "$WORK/site/layouts/index.shtml" <<'HTML'
<!DOCTYPE html><html><head><title>CSS</title><link rel="stylesheet" href="$site.asset('linked.css').link()"></head><body><div :html="$page.content()"></div></body></html>
HTML
cat > "$WORK/site/content/index.smd" <<'CONTENT'
---
.title = "Home",
.date = @date("2020-07-06T00:00:00"),
.layout = "index.shtml",
---
Home
CONTENT
printf '@import "../reset.css"; .one { color: #ff0000; background: url("/x y.png"); }\n' > "$WORK/site/assets/one.css"
printf '.two { padding: 10px 10px; }\n' > "$WORK/site/assets/nested/one.css"
printf '.linked { color: #ffffff; }\n' > "$WORK/site/assets/linked.css"
: > "$WORK/site/assets/EMPTY.css"
printf 'keep exactly\n' > "$WORK/site/assets/keep.txt"
printf 'unused { color: red; }\n' > "$WORK/site/assets/unused.css"
export CSS_REAL_BUN="$(command -v bun)" CSS_LOG="$WORK/calls"
cat > "$WORK/bun" <<'WRAPPER'
#!/usr/bin/env bash
if [[ "$1" == */minify-css.ts ]]; then printf '%s\n' "$2" >> "$CSS_LOG"; fi
exec "$CSS_REAL_BUN" "$@"
WRAPPER
chmod +x "$WORK/bun"
build() {
  (cd "$WORK/site" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" "$ZIGAPAGOS" release --force "--bun=$WORK/bun" "--output=$1" "${@:2}") > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; return 1; }
}
build "$WORK/legacy" "--css-minify-driver=$REPO/runtime/sidecar/minify-css.ts"
[[ "$(wc -l < "$CSS_LOG")" -eq 4 ]]
: > "$CSS_LOG"
build "$WORK/batch" --css-minify
[[ "$(wc -l < "$CSS_LOG")" -eq 1 ]]
[[ "$(cat "$CSS_LOG")" == --batch ]]
diff -r "$WORK/legacy" "$WORK/batch"
[[ ! -e "$WORK/batch/unused.css" ]]
cmp "$WORK/site/assets/keep.txt" "$WORK/batch/keep.txt"
# Zero CSS must not start a minifier, even when requested.
rm "$WORK/site/assets/"*.css "$WORK/site/assets/nested/one.css"
sed -i.bak 's/ .static_assets = .*/ .static_assets = ["keep.txt"],/' "$WORK/site/zigapagos.ziggy"
printf '<!DOCTYPE html><html><head><title>Empty</title></head><body>Home</body></html>' > "$WORK/site/layouts/index.shtml"
: > "$CSS_LOG"
build "$WORK/empty" --css-minify
[[ ! -s "$CSS_LOG" ]]
# Invalid CSS fails the release and retains the offending filename diagnostic.
printf '@import ;' > "$WORK/site/assets/broken.css"
sed -i.bak 's/ .static_assets = .*/ .static_assets = ["broken.css"],/' "$WORK/site/zigapagos.ziggy"
if build "$WORK/broken" --css-minify; then echo 'FAIL: invalid CSS succeeded'; exit 1; fi
grep -q 'broken.css' "$WORK/build.log"
# Runtime-free/custom invocations do not silently acquire the batch protocol.
if (cd "$WORK/site" && env -u ZIGAPAGOS_RUNTIME_DIR "$ZIGAPAGOS" release --css-minify) > "$WORK/missing.log" 2>&1; then
  echo 'FAIL: missing runtime succeeded'; exit 1
fi
grep -q ZIGAPAGOS_RUNTIME_DIR "$WORK/missing.log"
if build "$WORK/conflict" --css-minify "--css-minify-driver=$REPO/runtime/sidecar/minify-css.ts"; then
  echo 'FAIL: conflicting CSS options succeeded'; exit 1
fi
grep -q 'cannot be combined' "$WORK/build.log"
# More than a pipe buffer of requests, with the first stylesheet invalid.
# The minifier exits early; the parent must report failure instead of hanging.
python3 - "$WORK/site" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
names = [f"{i:04d}-" + "x" * 100 + ".css" for i in range(900)]
for name in names:
    (root / "assets" / name).write_text("@import ;")
p = root / "zigapagos.ziggy"
s = p.read_text()
s = s.replace('.static_assets = ["broken.css"],', '.static_assets = [' + ','.join('"' + n + '"' for n in names) + '],')
p.write_text(s)
PY
if (cd "$WORK/site" && ZIGAPAGOS_RUNTIME_DIR="$REPO/runtime" python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:], timeout=20).returncode)' "$ZIGAPAGOS" release --force --css-minify "--output=$WORK/early-exit") > "$WORK/early.log" 2>&1; then
  echo 'FAIL: large invalid batch succeeded'; exit 1
else
  code=$?
  if grep -q TimeoutExpired "$WORK/early.log"; then echo 'FAIL: large invalid batch hung'; exit 1; fi
fi
grep -q 'CSS\|css' "$WORK/early.log"

echo 'PASS: CSS batch byte parity, process count, paths, pruning, zero CSS and errors'
