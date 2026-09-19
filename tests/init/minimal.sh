#!/usr/bin/env bash
# A fresh minimal scaffold builds without a runtime or CSS framework. Test the
# emitted page and its referenced asset, not just template strings.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"
if [[ ! -x "$ZIGAPAGOS" ]]; then
  mise exec -- zig build
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir "$WORK/minimal" "$WORK/default" "$WORK/invalid"
(cd "$WORK/minimal" && "$ZIGAPAGOS" init --minimal) >"$WORK/init.log" 2>&1
[[ -f "$WORK/minimal/content/index.smd" ]] || fail "missing homepage"
[[ ! -d "$WORK/minimal/content/blog" ]] || fail "minimal includes demo blog"
[[ ! -d "$WORK/minimal/content/devlog" ]] || fail "minimal includes demo devlog"
[[ ! -f "$WORK/minimal/package.json" ]] || fail "minimal requires npm setup"
cmp "$REPO/src/cli/init/AGENTS.md" "$WORK/minimal/AGENTS.md"
cmp "$REPO/src/cli/init/CLAUDE.md" "$WORK/minimal/CLAUDE.md"
grep -q 'public/' "$WORK/minimal/.gitignore" || fail "build output is not ignored"
(cd "$WORK/minimal" && "$ZIGAPAGOS" release && "$ZIGAPAGOS" doctor public --strict)
python3 - "$WORK/minimal" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
root = Path(sys.argv[1])
assert len(list((root / 'content').rglob('*.smd'))) == 1
assert [p.name for p in (root / 'assets').iterdir()] == ['style.css']
class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []
        self.css = []
    def handle_starttag(self, tag, attrs):
        self.tags.append(tag)
        attrs = dict(attrs)
        if tag == 'link' and attrs.get('rel') == 'stylesheet':
            self.css.append(attrs['href'])
page = Page()
html = (root / 'public/index.html').read_text()
page.feed(html)
assert 'Make something yours' in html
assert page.tags.count('h1') == 1 and 'main' in page.tags
assert 'script' not in page.tags, 'minimal page ships a script'
assert len(page.css) == 1
assert page.css[0].startswith('/')
assert (root / 'public' / page.css[0].lstrip('/')).read_bytes() == (root / 'assets/style.css').read_bytes()
assert not list((root / 'public').rglob('*.js')), 'minimal output includes JS'
assert not list((root / 'public').rglob('*.woff2')), 'minimal output includes fonts'
PY
# Rerunning init preserves the author's changes, including the chosen layout.
printf '\n/* my styles */\n' >> "$WORK/minimal/assets/style.css"
cp "$WORK/minimal/assets/style.css" "$WORK/saved.css"
(cd "$WORK/minimal" && "$ZIGAPAGOS" init --minimal) >"$WORK/rerun.log" 2>&1
cmp "$WORK/saved.css" "$WORK/minimal/assets/style.css"
(cd "$WORK/default" && "$ZIGAPAGOS" init && "$ZIGAPAGOS" release) >"$WORK/default.log" 2>&1
[[ -f "$WORK/default/content/blog/first-post/index.smd" ]] || fail "default lost sample blog"
[[ -f "$WORK/default/assets/temml.min.js" ]] || fail "default lost math support"
grep -q '<script' "$WORK/default/public/index.html" || fail "default changed its output"
for flags in '--minimal --multilingual' '--minimal --from-astro missing' '--from-astro missing --minimal' '--minmal'; do
  # Each case contains only fixed, space-delimited CLI flags.
  read -r -a args <<< "$flags"
  if (cd "$WORK/invalid" && "$ZIGAPAGOS" init "${args[@]}") >"$WORK/invalid.log" 2>&1; then
    fail "invalid flags succeeded: $flags"
  fi
  grep -Eq 'cannot be combined|unknown init option' "$WORK/invalid.log" || fail "missing actionable error: $flags"
  [[ ! -f "$WORK/invalid/zigapagos.ziggy" ]] || fail "invalid flags wrote files"
done
"$ZIGAPAGOS" init --help >"$WORK/help.log" 2>&1
grep -q -- '--minimal' "$WORK/help.log" || fail "help omits minimal starter"
echo 'PASS: minimal static output, default scaffold, preservation, and invalid options'
