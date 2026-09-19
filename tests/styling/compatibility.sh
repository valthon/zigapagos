#!/usr/bin/env bash
# Build the example through its public invocation, then audit actual output.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
bash examples/styling-site/build.sh
bun runtime/node_modules/typescript/bin/tsc -p examples/styling-site/tsconfig.json
"$BIN" doctor examples/styling-site/zig-out/site --strict
python3 - "$REPO/examples/styling-site/zig-out/site" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
root = Path(sys.argv[1])
class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.scripts = []
        self.styles = []
        self.feed(source)
    def handle_starttag(self, tag, pairs):
        attrs = dict(pairs)
        if tag == 'script': self.scripts.append(attrs)
        if tag == 'link' and attrs.get('rel') == 'stylesheet': self.styles.append(attrs['href'])
for route, css in [('index.html', '/css/plain.css'), ('framework/index.html', '/generated/tailwind.css')]:
    page = Page((root / route).read_text())
    assert not page.scripts, (route, page.scripts)
    assert page.styles == [css], (route, page.styles)
    assert (root / css.lstrip('/')).is_file()
compiled = (root / 'generated/tailwind.css').read_text()
assert '.bg-teal-100' in compiled and '.rounded-xl' in compiled
assert '@source' not in compiled and '@import"tailwindcss"' not in compiled
component_html = (root / 'components/index.html').read_text()
assert 'Save preference' in component_html and 'No preference saved' in component_html, 'missing server-rendered component'
component_page = Page(component_html)
assert component_page.styles == ['/css/components.css']
assert len([s for s in component_page.scripts if s.get('type') == 'importmap']) == 1
for dependency in ['css/plain.css', 'css/tokens.css', 'images/grid.svg', 'fonts/Temml.woff2', 'fonts/LICENSE-Temml.txt', 'fonts/LICENSE-KaTeX.txt']:
    assert (root / dependency).is_file(), dependency
assert (root / 'fonts/Temml.woff2').read_bytes()[:4] == b'wOF2'
print('PASS: plain/Tailwind static routes, compiled utilities, component SSR, imports and font assets')
PY
