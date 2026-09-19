#!/usr/bin/env bash
# The rendered TOC must explicitly balance list tags across heading jumps.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${ZIGAPAGOS_BIN:-$PWD/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
(cd "$WORK" && "$BIN" init --minimal) >/dev/null
python3 - "$WORK" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
(root / 'layouts/page.shtml').write_text('''<!doctype html><html><head><title :text="$page.title"></title></head><body><nav :html="$page.toc()"></nav><main :html="$page.content()"></main></body></html>''')
cases = {'index': [], 'one': [1], 'siblings': [1,1,1], 'deep': [3], 'descend': [1,2,4], 'ascend': [4,2,1], 'mixed': [2,4,3,2,5]}
for name, levels in cases.items():
    body = '\n\n'.join('#'*level + f' []($heading.id("item-{i}")) Item {i}' for i, level in enumerate(levels))
    (root / 'content' / (name+'.smd')).write_text('---\n.title = "Outline",\n.layout = "page.shtml",\n---\n'+body+'\n')
PY
(cd "$WORK" && "$BIN" release) >/dev/null
python3 - "$WORK/public" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
class Outline(HTMLParser):
    def __init__(self):
        super().__init__(); self.active=False; self.stack=[]; self.links=[]
    def handle_starttag(self, tag, attrs):
        if tag == 'nav': self.active=True; return
        if not self.active: return
        if tag in ('ul','li','a'): self.stack.append(tag)
        if tag == 'a': self.links.append(dict(attrs)['href'])
    def handle_endtag(self, tag):
        if tag == 'nav':
            assert not self.stack, self.stack
            self.active=False; return
        if self.active and tag in ('ul','li','a'):
            assert self.stack and self.stack[-1] == tag, (tag,self.stack)
            self.stack.pop()
counts={'index.html':0,'one/index.html':1,'siblings/index.html':3,'deep/index.html':1,'descend/index.html':3,'ascend/index.html':3,'mixed/index.html':5}
root=Path(sys.argv[1])
for filename,count in counts.items():
    outline=Outline(); outline.feed((root/filename).read_text())
    assert not outline.active and not outline.stack, filename
    assert outline.links == [f'#item-{i}' for i in range(count)], (filename,outline.links)
print('PASS: empty, single, sibling, deep and changing-level TOCs have explicit balanced tags and ordered links')
PY
