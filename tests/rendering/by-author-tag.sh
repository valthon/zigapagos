#!/usr/bin/env bash
# Section indexes: arrays, ordering, drafts, empty keys, pagination and locale isolation.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$REPO/tests/rendering/by-author-tag" "$WORK/site"
mkdir -p "$WORK/site/assets"
if ! (cd "$WORK/site" && "$ZIGAPAGOS" release --force "--output=$WORK/out") >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log"; exit 1
fi
python3 - "$WORK/out" <<'PYTEST'
from html.parser import HTMLParser
from pathlib import Path
import sys
class Lists(HTMLParser):
    def __init__(self):
        super().__init__(); self.lists = {}; self.key = None; self.in_li = False
    def handle_starttag(self, tag, attrs):
        if tag == 'ul':
            self.key = dict(attrs)['id']; self.lists[self.key] = []
        if tag == 'li': self.in_li = True
    def handle_endtag(self, tag):
        if tag == 'li': self.in_li = False
        if tag == 'ul': self.key = None
    def handle_data(self, data):
        if self.in_li: self.lists[self.key].append(data)
for loc in ['en', 'it']:
    expected = {'author': [f'{loc} {x}' for x in ['New', 'Z', 'A']],
                'second': [f'{loc} New'],
                'tag': [f'{loc} {x}' for x in ['New', 'Z', 'A', 'None']],
                'noauthor': [], 'notag': []}
    for suffix in ['index.html', 'page/2/index.html', 'page/3/index.html']:
        path = Path(sys.argv[1]) / loc / suffix
        parser = Lists(); parser.feed(path.read_text())
        assert parser.lists == expected, (path, parser.lists, expected)
print('PASS: section author/tag indexes, ordering, drafts, pagination and locales')
PYTEST
# Exercise the incremental early return directly: a selected index must see
# freshly parsed metadata from an unselected child. Dev normally makes content
# edits full rebuilds (the dev harness below pins that classifier separately).
sed -i 's/"ada", "bea"/"new-author"/; s/"topic"/"new-tag"/' "$WORK/site/content/en/new.smd"
if ! (cd "$WORK/site" && ZIGAPAGOS_CHANGED_FILES=content/en/index.smd "$ZIGAPAGOS" release --force "--output=$WORK/out") >"$WORK/incremental.log" 2>&1; then
  cat "$WORK/incremental.log"; exit 1
fi
for suffix in index.html page/2/index.html page/3/index.html; do
  if grep -q 'en New' "$WORK/out/en/$suffix"; then
    echo "FAIL: stale author/tag entry after incremental rebuild ($suffix)"; exit 1
  fi
  grep -q 'en Z' "$WORK/out/en/$suffix"
done
echo 'PASS: incremental render rebuilds indexes after metadata changes'
# Each builtin must error on a leaf rather than silently return an empty list.
for builtin in subpagesByAuthor subpagesByTag; do
  cat > "$WORK/site/layouts/leaf.shtml" <<EOF
<!DOCTYPE html>
<html><head><title>Leaf</title></head><body>
<ul :loop="\$page.$builtin('missing')"><li :text="\$loop.it.title"></li></ul>
</body></html>
EOF
  sed -i 's/post.shtml/leaf.shtml/' "$WORK/site/content/en/new.smd"
  if (cd "$WORK/site" && "$ZIGAPAGOS" release --force "--output=$WORK/out") >"$WORK/leaf.log" 2>&1; then
    echo "FAIL: $builtin on a non-section succeeded"; exit 1
  fi
  grep -q 'not a section' "$WORK/leaf.log"
done
echo 'PASS: both non-section lookups error'
