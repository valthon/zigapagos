#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
BIN="${ZIGAPAGOS_BIN:-$ROOT/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
check() { if ! "$@"; then echo "FAIL: $*"; fail=1; fi; }
mkdir -p "$WORK/"{content,layouts,assets}
cat > "$WORK/layouts/page.shtml" <<'HTML'
<!doctype html><html><head><title :text="$site.title"></title></head><body><p id="custom" :text="$site.custom.getOr('brand', '')"></p><p id="authors" :text="$page.authors.join(', ')"></p><p id="date" :text="$page.date.format('2006-01-02')"></p><main :html="$page.content()"></main></body></html>
HTML
cat > "$WORK/content/index.smd" <<'SMD'
---
.title = "Home",
.layout = "page.shtml",
.authors = ["Jane", "Joe"],
.date = .unix(1704067200),
---
- [external](https://example.net/)
SMD
cp "$WORK/content/index.smd" "$WORK/content/leaf.smd"
python3 - "$WORK/content/leaf.smd" <<'PYTHON'
import sys
from pathlib import Path
p = Path(sys.argv[1]); p.write_text(p.read_text().replace('.unix(1704067200)', '.date("2024-01-01T00:00:00")'))
PYTHON
config() {
  cat > "$WORK/zigapagos.ziggy" <<CONFIG
.site = .simple(.{
 .title = "Test", .host_url = "https://example.com",
 .content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets",
 .custom = { "brand": "Round trip" },
 $1
})
CONFIG
}
release() { (cd "$WORK" && "$BIN" release --force --output "$WORK/public") > "$WORK/log" 2>&1; }
config ''
release
check grep -q '>Round trip<' "$WORK/public/index.html"
check grep -q '>Jane, Joe<' "$WORK/public/index.html"
check grep -q '>2024-01-01<' "$WORK/public/index.html"
check grep -q 'target="_blank"' "$WORK/public/index.html"
check grep -q 'target="_blank"' "$WORK/public/leaf/index.html"
config '.supermd = .{ .auto_target_blank = false },'
release
if grep -q 'target="_blank"' "$WORK/public/index.html" "$WORK/public/leaf/index.html"; then echo 'false still adds target blank'; exit 1; fi
config '.supermd = .{ .auto_target_blank = true },'
release
check grep -q 'target="_blank"' "$WORK/public/index.html"
check grep -q 'target="_blank"' "$WORK/public/leaf/index.html"
(cd "$WORK" && "$BIN" install-schemas) > "$WORK/log" 2>&1
check cmp "$ROOT/src/schemas/zigapagos.ziggy-schema" "$WORK/.zigapagos.ziggy-schema"
check cmp "$ROOT/src/schemas/page.ziggy-schema" "$WORK/content/.smd.ziggy-schema"
# install-schemas finds the project from a subdirectory and overwrites stale copies.
printf 'stale' > "$WORK/content/.smd.ziggy-schema"
(cd "$WORK/content" && "$BIN" install-schemas) > "$WORK/log" 2>&1
check cmp "$ROOT/src/schemas/page.ziggy-schema" "$WORK/content/.smd.ziggy-schema"
# CRLF config and frontmatter both report the repair command.
cp "$WORK/zigapagos.ziggy" "$WORK/config.lf"
python3 - "$WORK/zigapagos.ziggy" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); p.write_bytes(p.read_bytes().replace(b'\n', b'\r\n'))
PY
if release; then echo 'CRLF config accepted'; exit 1; fi
check grep -q 'carriage returns' "$WORK/log"
check grep -q 'scripts/upgrade-ziggy.py' "$WORK/log"
cp "$WORK/config.lf" "$WORK/zigapagos.ziggy"
cp "$WORK/content/index.smd" "$WORK/page.lf"
python3 - "$WORK/content/index.smd" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); p.write_bytes(p.read_bytes().replace(b'\n', b'\r\n'))
PY
if release; then echo 'CRLF frontmatter accepted'; exit 1; fi
check grep -q 'carriage returns' "$WORK/log"
check grep -q 'scripts/upgrade-ziggy.py' "$WORK/log"
cp "$WORK/page.lf" "$WORK/content/index.smd"
# Old forms are intentional test inputs: these users need upgrade instructions.
printf 'Site { .title = "old" }\n' > "$WORK/zigapagos.ziggy"
if release; then echo 'old config accepted'; exit 1; fi
check grep -q 'old Ziggy syntax' "$WORK/log"
check grep -q 'scripts/upgrade-ziggy.py' "$WORK/log"
cp "$WORK/config.lf" "$WORK/zigapagos.ziggy"
printf '%s\n' '---' '.title = "Home", .layout = "page.shtml", .author = "old",' '---' 'Body' > "$WORK/content/index.smd"
if release; then echo 'old author accepted'; exit 1; fi
check grep -q 'old Ziggy syntax' "$WORK/log"
check grep -q 'scripts/upgrade-ziggy.py' "$WORK/log"
# Legacy string dates were valid before 0.3; both advice and conversion matter.
printf '%s\n' '---' '.title = "Home", .layout = "page.shtml", .date = "2024-01-01",' '---' 'Body' > "$WORK/content/index.smd"
if release; then echo 'legacy string date accepted'; exit 1; fi
check grep -q 'old Ziggy syntax' "$WORK/log"
check grep -q 'scripts/upgrade-ziggy.py' "$WORK/log"
python3 "$ROOT/scripts/upgrade-ziggy.py" "$WORK/content/index.smd" > "$WORK/conversion.log"
(cd "$WORK" && "$BIN" validate --format=json) > "$WORK/log" 2>&1
cp "$WORK/content/index.smd" "$WORK/converted.smd"
python3 "$ROOT/scripts/upgrade-ziggy.py" "$WORK/content/index.smd" > "$WORK/conversion.log"
check cmp "$WORK/converted.smd" "$WORK/content/index.smd"
# A normal parser error must stay a parser error even when a string mentions
# an old spelling. This also exercises reporting after the page arena moves.
printf '%s\n' '---' '.title = "Site {", .layout = "page.shtml"' '.tags = [],' '---' 'Body' > "$WORK/content/index.smd"
if release; then echo 'malformed frontmatter accepted'; exit 1; fi
check grep -q 'missing token' "$WORK/log"
if grep -q 'old Ziggy syntax' "$WORK/log"; then echo 'string contents misclassified as old syntax'; exit 1; fi
# Leading whitespace is accepted by parsing; analysis diagnostics must use
# that same fence offset rather than assuming the document starts at byte 3.
printf '%s\n' '  ' '---' '.title = "Leading space",' '.layout = "missing.shtml",' '---' 'Body' > "$WORK/content/index.smd"
rc=0
(cd "$WORK" && "$BIN" release --force --format=json) > "$WORK/log" 2>&1 || rc=$?
if [[ $rc != 1 ]]; then cat "$WORK/log"; echo "FAIL: leading frontmatter diagnostic exited $rc"; exit 1; fi
python3 - "$WORK/log" <<'PYTHON'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert len(rows) == 1, rows
assert rows[0]['code'] == 'ZP_MISSING_LAYOUT' and rows[0]['line'] == 4 and rows[0]['col'] == 11, rows
PYTHON
# Minimal pages omit slices, dictionaries, optionals, and date.
printf '%s\n' '---' '.title = "Home", .layout = "page.shtml",' '---' 'Body' > "$WORK/content/index.smd"
release
check grep -q '>1970-01-01<' "$WORK/public/index.html"
# init embeds exactly the same schemas, rather than maintaining a template copy.
mkdir "$WORK/init"
(cd "$WORK/init" && "$BIN" init --minimal) > "$WORK/log" 2>&1
check cmp "$ROOT/src/schemas/zigapagos.ziggy-schema" "$WORK/init/.zigapagos.ziggy-schema"
check cmp "$ROOT/src/schemas/page.ziggy-schema" "$WORK/init/content/.smd.ziggy-schema"
# Multilingual schemas go into every configured content directory.
cat > "$WORK/zigapagos.ziggy" <<'CONFIG'
.site = .multilingual(.{
 .host_url = "https://example.com", .layouts_dir_path = "layouts", .assets_dir_path = "assets", .i18n_dir_path = "i18n",
 .locales = [
  .{ .code = "en-US", .name = "English", .site_title = "English", .content_dir_path = "en/content" },
  .{ .code = "it-IT", .name = "Italiano", .site_title = "Italiano", .content_dir_path = "it/content" },
 ],
})
CONFIG
(cd "$WORK" && "$BIN" install-schemas) > "$WORK/log" 2>&1
check cmp "$ROOT/src/schemas/page.ziggy-schema" "$WORK/en/content/.smd.ziggy-schema"
check cmp "$ROOT/src/schemas/page.ziggy-schema" "$WORK/it/content/.smd.ziggy-schema"
mkdir -p "$WORK/i18n"
printf '{ "hello": }\n' > "$WORK/i18n/en-US.ziggy"
printf '{}\n' > "$WORK/i18n/it-IT.ziggy"
cp "$WORK/content/index.smd" "$WORK/en/content/index.smd"
cp "$WORK/content/index.smd" "$WORK/it/content/index.smd"
if release; then echo 'malformed i18n accepted'; exit 1; fi
check grep -q 'i18n/en-US.ziggy' "$WORK/log"
check grep -q 'missing\|unexpected' "$WORK/log"
test "$fail" -eq 0
echo 'PASS: Ziggy config, frontmatter, diagnostics, link defaults, schemas and init'
