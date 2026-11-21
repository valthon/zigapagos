#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$REPO" <<'PY'
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
repo = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    fixture = repo/'tests/rendering/multi'
    for name in ['content', 'layouts', 'assets', 'i18n']:
        shutil.copytree(fixture/name, work/name)
    base = (fixture/'zigapagos.ziggy').read_text().rstrip()[:-2]
    asset = work/'assets/csp-sources.json'
    asset.write_text('multilingual user asset\n')
    extras = '\n.csp_extra_sources = [.{ .directive = "img-src", .sources = ["data:"] }],\n'
    def release(prefix, selection, declarations):
        config = base.replace('.assets_prefix_path = "static"', '.assets_prefix_path = ' + json.dumps(prefix))
        (work/'zigapagos.ziggy').write_text(config + '\n.static_assets = [' + json.dumps(selection) + '],\n' + declarations + '})')
        return subprocess.run([str(repo/'zig-out/bin/zigapagos'), 'release', '--force'], cwd=work, env=os.environ | {'ZIGAPAGOS_RUNTIME_DIR': str(repo/'runtime')}, capture_output=True, text=True)
    for selection in ['csp-sources.json', '**']:
        for prefix in ['static', './static/', '.']:
            out = work/'public'
            if out.exists():
                shutil.rmtree(out)
            result = release(prefix, selection, '')
            assert result.returncode == 0, result.stderr
            installed = out/prefix/'csp-sources.json'
            assert installed.read_text() == asset.read_text()
            result = release(prefix, selection, extras)
            if prefix == '.':
                assert result.returncode != 0, 'root asset collision accepted'
                assert 'collid' in result.stderr, result.stderr
                assert installed.read_text() == asset.read_text()
                continue
            assert result.returncode == 0, result.stderr
            assert installed.read_text() == asset.read_text(), 'prefixed user asset overwritten'
            metadata = out/'csp-sources.json'
            assert json.loads(metadata.read_text())['csp_extra_sources'][0]['sources'] == ['data:']
            result = release(prefix, selection, '')
            assert result.returncode == 0, result.stderr
            assert not metadata.exists(), 'prefixed asset incorrectly claimed ownership of root metadata'
            assert installed.read_text() == asset.read_text(), 'prefixed user asset deleted'
print('PASS: multilingual CSP uses installed asset paths for collisions and ownership')
PY
