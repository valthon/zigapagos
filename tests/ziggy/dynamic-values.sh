#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$REPO" <<'PY'
import html, json, os, re, subprocess, sys, tempfile
from pathlib import Path
repo = Path(sys.argv[1])
binary = os.environ.get('ZIGAPAGOS_BIN', str(repo/'zig-out/bin/zigapagos'))
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    for name in ['content', 'layouts', 'assets', 'data', 'components']:
        (work/name).mkdir()
    keys = (repo/'tests/ziggy/escaped-keys.ziggy').read_text()
    (work/'assets/keys.ziggy').write_text(keys)
    (work/'data/keys.ziggy').write_text(keys)
    union = '.foo(.{ .answer = "payload" })'
    (work/'assets/union.ziggy').write_text(union)
    (work/'data/union.ziggy').write_text('.value = '+union)
    config = '''.site = .simple(.{
.title = "Dynamic", .host_url = "https://example.com",
.content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets",
.custom = { "keys": KEYS, "value": UNION },
})'''.replace('KEYS', keys).replace('UNION', union)
    (work/'zigapagos.ziggy').write_text(config)
    (work/'content/index.smd').write_text('---\n.title = "Home", .layout = "index.shtml",\n.custom = { "keys": '+keys+', "value": '+union+' },\n---\nBody')
    sources = ["$page.custom.get('value')", "$site.custom.get('value')",
               "$site.data('union').get('value')", "$site.asset('union.ziggy').ziggy()"]
    if os.environ.get("DYNAMIC_KEYS_ONLY"): sources = []
    body = []
    for i, expr in enumerate(sources):
        body += [f'<p id="field{i}" :text="{expr}.foo.get(\'answer\')"></p>',
                 f'<p id="tag{i}" :text="{expr}.tag()"></p>',
                 f'<ctx :if="{expr}.case?(\'foo\')"><p id="case{i}" :text="$if.get(\'answer\')"></p></ctx>',
                 f'<ctx :if="{expr}.case?(\'other\')"><p>WRONG-CASE</p></ctx>']
    maps = ["$page.custom.get('keys')", "$site.custom.get('keys')",
            "$site.data('keys')", "$site.asset('keys.ziggy').ziggy()"]
    for i, expr in enumerate(maps):
        body.append(f'<pre id="keys{i}" :text="{expr}.toJson()"></pre>')
    body.append('<island src="components/Keys.island.tsx" client:load :props=\''+keys+'\'></island>')
    (work/'components/Keys.island.tsx').write_text('export default function Keys(props: Record<string, unknown>) { return JSON.stringify(props); }')
    layout = '<html><head></head><body>'+''.join(body)+'</body></html>'
    (work/'layouts/index.shtml').write_text(layout)
    args = [binary, 'release', '--force', '--bun=bun', '--island-sidecar='+str(repo/'runtime/sidecar/render.ts'), '--island-src-dir=.']
    result = subprocess.run(args, cwd=work, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    output = (work/'public/index.html').read_text()
    for i in range(len(sources)):
        for kind, value in [('field','payload'), ('tag','foo'), ('case','payload')]:
            assert re.search(f'id="{kind}{i}"[^>]*>{value}</p>', output), output
    assert 'WRONG-CASE' not in output, output
    # Both parsers consume the SAME fixture; the native result also travels as
    # :props, so escaped island prop names cannot silently diverge from data.
    program = 'import {parseZiggyFrontmatter} from '+json.dumps(str(repo/'runtime/scripts/site-data.ts'))+'; console.log(JSON.stringify(parseZiggyFrontmatter(".keys = "+await Bun.file(process.argv[1]).text(), "fixture").keys));'
    ts = subprocess.run(['bun', '-e', program, str(repo/'tests/ziggy/escaped-keys.ziggy')], capture_output=True, text=True)
    assert ts.returncode == 0, ts.stderr
    expected = json.loads(ts.stdout)
    assert expected == {'a\n':1, 'tab\tkey':{'quote"':2, 'slash\\n':3}, 'a':4}, expected
    for i in range(len(maps)):
        match = re.search(f'id="keys{i}"[^>]*>(.*?)</pre>', output, re.S)
        assert match and json.loads(html.unescape(match[1])) == expected, output
    props = re.search(r'<script[^>]*data-z-props="[^"]*"[^>]*>(.*?)</script>', output, re.S)
    # The script id is referenced by data-z-props on the island wrapper.
    if not props:
        props = re.search(r'<script[^>]*type="application/json"[^>]*>(.*?)</script>', output, re.S)
    assert props and json.loads(props[1]) == expected, output
    # Different escaped spellings of the same key are still duplicates.
    (work/'data/keys.ziggy').write_text('{ "a": 1, "\\u0061": 2 }')
    result = subprocess.run(args, cwd=work, text=True, capture_output=True)
    assert result.returncode != 0 and 'duplicate' in result.stderr, result.stderr
    (work/'data/keys.ziggy').write_text(keys)
    (work/'i18n').mkdir()
    (work/'i18n/en-US.ziggy').write_text(keys)
    (work/'zigapagos.ziggy').write_text(""".site = .multilingual(.{
.host_url = "https://example.com", .i18n_dir_path = "i18n",
.layouts_dir_path = "layouts", .assets_dir_path = "assets",
.locales = [.{ .code = "en-US", .name = "English", .site_title = "English",
.content_dir_path = "content", .output_prefix_override = "" }],
})""")
    (work/'layouts/index.shtml').write_text('<html><head></head><body><pre :text="$i18n.toJson()"></pre></body></html>')
    result = subprocess.run(args, cwd=work, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    output = (work/'public/index.html').read_text()
    value = re.search(r'<pre[^>]*>(.*?)</pre>', output, re.S)
    assert value and json.loads(html.unescape(value[1])) == expected, output
print('PASS: dynamic union access and escaped dictionary parity, including island props')
PY
