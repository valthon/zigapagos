#!/usr/bin/env bash
# Execute the tutorial's published templates, rather than a hand-copied version.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
doc = Path('site/content/docs/tutorial.smd').read_text()
for path in ['layouts/templates', 'content/guides', 'assets']:
    (root / path).mkdir(parents=True)
blocks = re.findall(r'```html\n(.*?)\n```', doc, re.S)
assert len(blocks) >= 3, 'tutorial must supply base, page and guides layouts'
for path, block in zip(['layouts/templates/base.shtml', 'layouts/page.shtml', 'layouts/guides.shtml'], blocks):
    (root / path).write_text(block + '\n')
index = re.search(r'```\n(---\n.*?\n---\n.*?)\n```', doc, re.S)
assert index, 'tutorial must supply the guides index source'
(root / 'content/guides/index.smd').write_text(index[1] + '\n')
(root / 'zigapagos.ziggy').write_text('''Site {
 .title = "Tutorial",
 .host_url = "https://example.com",
 .content_dir_path = "content",
 .layouts_dir_path = "layouts",
 .assets_dir_path = "assets",
}
''')
(root / 'assets/style.css').write_text('body { color: black; }\n')
for path, title in [('index.smd', 'Home'), ('guides/deploying.smd', 'Deploying'), ('guides/writing.smd', 'Writing')]:
    (root / 'content' / path).write_text(f'---\n.title = "{title}",\n.layout = "page.shtml",\n---\n\n{title}.\n')
PY
(cd "$WORK" && "$BIN" release --force --output public) > "$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log"; exit 1;
}
python3 - "$WORK/public/guides/index.html" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys

class ListItems(HTMLParser):
    def __init__(self):
        super().__init__()
        self.items = []
        self.current = None
    def handle_starttag(self, tag, attrs):
        if tag == 'li':
            self.current = []
        elif tag == 'a' and self.current is not None:
            self.current.append(dict(attrs).get('href'))
    def handle_endtag(self, tag):
        if tag == 'li' and self.current is not None:
            self.items.append(self.current)
            self.current = None

parser = ListItems()
parser.feed(Path(sys.argv[1]).read_text())
assert len(parser.items) == 2, f'expected one list item per guide, got {parser.items}'
assert all(len(item) == 1 for item in parser.items), parser.items
assert {item[0] for item in parser.items} == {'/guides/deploying/', '/guides/writing/'}, parser.items
print('PASS: the published tutorial renders two guides as two separate linked list items')
PY
