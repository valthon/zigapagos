#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$REPO" <<'PY'
import json, os, resource, subprocess, sys, tempfile
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
binary = os.environ.get('ZIGAPAGOS_BIN', str(Path(sys.argv[1])/'zig-out/bin/zigapagos'))
case = os.environ.get('CASE', 'all')
failures = []
def page(body='', extra=''):
    return '---\n.title = "Home", .layout = "index.shtml",\n'+extra+'\n---\n'+body
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    for d in ('content/hidden/nested', 'content/child', 'layouts', 'assets'):
        (work/d).mkdir(parents=True)
    (work/'zigapagos.ziggy').write_text('''.site = .simple(.{
.title = "Seams", .host_url = "https://example.com",
.content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets",
})''')
    (work/'layouts/index.shtml').write_text('<html><body><div :html="$page.content()"></div></body></html>')
    (work/'content/empty.smd').write_text('')
    (work/'content/hidden/index.smd').write_text('')
    (work/'content/hidden/nested/index.smd').write_text(page())
    (work/'content/hidden/leaf.smd').write_text(page())
    (work/'content/child/index.smd').write_text(page())
    for name in ('ref', 'forbid'):
        if case not in ('all', name): continue
        targets = ('empty', 'hidden/leaf', 'hidden/nested') if name == 'ref' else ('child',)
        for target in targets:
            body = f'[target]($link.page("{target}").ref("anchor"))' if name == 'ref' else ''
            (work/'content/index.smd').write_text(page(body, '.draft = true, .forbid_subsections = true,' if name == 'forbid' else ''))
            for command in ('release', 'validate'):
                for fmt in ('text', 'json'):
                    for tolerate in ((False, True) if name == 'ref' else (False,)):
                        args = [binary, command, '--format='+fmt]
                        if command == 'release': args += ['--force']
                        if tolerate: args += ['--allow-missing-pages']
                        p = subprocess.run(args, cwd=work, capture_output=True, text=True)
                        try:
                            assert (p.returncode == 0) == tolerate, (p.returncode, p.stderr)
                            assert p.returncode >= 0, p.stderr
                            assert 'panic' not in p.stderr and 'leaked' not in p.stderr, p.stderr
                            if fmt == 'json':
                                rows = [json.loads(line) for line in p.stderr.splitlines()]
                                code = 'ZP_MISSING_PAGE_TOLERATED' if tolerate else ('ZP_UNKNOWN_PAGE' if name == 'ref' else 'ZP_FORBIDDEN_SUBSECTION')
                                assert any(row['code'] == code for row in rows), rows
                            else:
                                assert ('forbids subsections' if name == 'forbid' else ('missing page' if tolerate else 'unknown page')) in p.stderr, p.stderr
                        except (AssertionError, ValueError) as e:
                            failures.append(f'{name}/{target}/{command}/{fmt}/{tolerate}: {str(e)[:500]}')
for failure in failures: print('FAIL:', failure)
assert not failures, f'{len(failures)} seam checks failed'
print('PASS: inactive link refs and draft-root subsection enforcement')
PY
