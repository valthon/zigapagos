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
    for d in ('content', 'layouts', 'assets', 'data', 'components', 'i18n'):
        (work/d).mkdir()
    empty = '{ "options": .{}, "dict": {}, "list": [] }'
    value = '{ "empty": '+empty+', "union": .payload(.{}) }'
    for d in ('data', 'assets', 'i18n'):
        (work/d/('en.ziggy' if d == 'i18n' else 'empty.ziggy')).write_text(value)
    (work/'components/Empty.island.tsx').write_text('export default function Empty(props: Record<string, unknown>) { return JSON.stringify(props); }')
    configs = ['''.site = .simple(.{ .title = "Empty", .host_url = "https://example.com",
.content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets", .custom = VALUE,
})'''.replace('VALUE', value), '''.site = .multilingual(.{ .host_url = "https://example.com",
.layouts_dir_path = "layouts", .assets_dir_path = "assets", .i18n_dir_path = "i18n",
.locales = [.{ .code = "en", .name = "English", .site_title = "Empty", .content_dir_path = "content", .output_prefix_override = "" }],
})''']
    readers = {'page': '$page.custom', 'site': '$site.custom', 'data': "$site.data('empty')",
               'asset': "$site.asset('empty.ziggy').ziggy()", 'i18n': '$i18n', 'island': None}
    for reader, source in readers.items():
        if os.environ.get('CASE', reader) != reader: continue
        config = configs[1] if reader == 'i18n' else configs[0].replace(value, value if reader == 'site' else '{}')
        (work/'zigapagos.ziggy').write_text(config)
        (work/'content/index.smd').write_text('---\n.title = "Home", .layout = "index.shtml",\n.custom = '+(value if reader == 'page' else '{}')+',\n---\nBody')
        sources = [source] if source else []
        body = []
        for i, source in enumerate(sources):
            body += [f'<pre id="empty{i}" :text="{source}.get(\'empty\').toJson()"></pre>',
                     f'<pre id="union{i}" :text="{source}.get(\'union\').payload.toJson()"></pre>']
        if reader == 'island': body += ['<island src="components/Empty.island.tsx" client:load :props=\''+empty+'\'></island>',
                 '<island src="components/Empty.island.tsx" client:load :props=".{}"></island>']
        (work/'layouts/index.shtml').write_text('<html><head></head><body>'+''.join(body)+'</body></html>')
        for command in ('release', 'validate'):
            args = [binary, command]
            if command == 'release': args += ['--force', '--bun=bun', '--island-sidecar='+str(repo/'runtime/sidecar/render.ts'), '--island-src-dir=.']
            p = subprocess.run(args, cwd=work, capture_output=True, text=True)
            assert p.returncode == 0, p.stderr
            if command == 'validate': continue
            output = (work/'public/index.html').read_text()
            for i in range(len(sources)):
                for name, expected in [('empty', {'options':{}, 'dict':{}, 'list':[]}), ('union', {})]:
                    match = re.search(f'id="{name}{i}"[^>]*>(.*?)</pre>', output, re.S)
                    assert match and json.loads(html.unescape(match[1])) == expected, output
            if reader != 'island': continue
            props = re.findall(r'<script[^>]*type="application/json"[^>]*>(.*?)</script>', output, re.S)
            assert {'options':{}, 'dict':{}, 'list':[]} in [json.loads(p) for p in props], output
            assert {} in [json.loads(p) for p in props], output
print('PASS: empty structs/dicts/lists/union payloads across every dynamic reader')
PY
