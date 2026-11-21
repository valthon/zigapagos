#!/usr/bin/env bash
# Run explicitly with the no-highlight binary; normal shell e2e has no such binary.
set -euo pipefail
if [[ "${1:-}" != --highlight-off ]]; then
  echo 'highlight-off: exercised by the CI build-option guard'
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/content" "$WORK/layouts" "$WORK/assets"
cat > "$WORK/zigapagos.ziggy" <<'CONFIG'
.site = .simple(.{
.title = "Plain", .host_url = "https://example.com",
.content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets",
})
CONFIG
cat > "$WORK/layouts/index.shtml" <<'LAYOUT'
<!DOCTYPE html><html><head><title>Plain</title></head><body><div :html="$page.content()"></div></body></html>
LAYOUT
printf 'print <&>\n' > "$WORK/content/sample.txt"
cat > "$WORK/content/index.smd" <<'CONTENT'
---
.title = "Plain",
.layout = "index.shtml",
---
```not-a-real-language
print <&>
```

[]($code.asset('sample.txt').language('also-not-real'))
CONTENT
(cd "$WORK" && "$ZIGAPAGOS_BIN" release --output "$WORK/out" --force) > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }
if grep -Ei 'unknown.*language|ZP_UNKNOWN_LANGUAGE' "$WORK/build.log"; then exit 1; fi
python3 - "$WORK/out/index.html" <<'PY'
from pathlib import Path
import sys
html=Path(sys.argv[1]).read_text()
assert html.count('print &lt;&amp;&gt;') == 2,html
assert '<span' not in html,html
PY
"$ZIGAPAGOS_BIN" languages > "$WORK/languages.log" 2>&1
grep -q "every language name is accepted" "$WORK/languages.log"
echo 'PASS: highlighting off accepts arbitrary fenced and directive languages'
