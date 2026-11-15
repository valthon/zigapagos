#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$REPO" "${1:-all}" <<'PY'
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
repo, mode = Path(sys.argv[1]), sys.argv[2]
base = (repo/'tests/rendering/simple/zigapagos.ziggy').read_text().rstrip()[:-1]
extras = '\n.csp_extra_sources = [{ .directive = "img-src", .sources = ["data:"] }],\n'
env = os.environ | {'ZIGAPAGOS_RUNTIME_DIR': str(repo/'runtime')}
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    for name in ['content', 'layouts']:
        shutil.copytree(repo/'tests/rendering/simple'/name, work/name)
    def config(fields=''):
        (work/'zigapagos.ziggy').write_text(base + fields + '}')
    def release(cwd=work, args=()):
        return subprocess.run([str(repo/'zig-out/bin/zigapagos'), 'release', '--force', *args], cwd=cwd, env=env, text=True, capture_output=True)
    if mode in ['all', 'collision']:
        asset = work/'content/csp-sources.json'
        asset.write_text(json.dumps({'generated_by': 'emit-host-config.ts', 'csp_extra_sources': []}))
        for selection in ['csp-sources.json', '**']:
            for fields in [extras, '']:
                config(fields + '\n.static_assets = [' + json.dumps(selection) + '],\n')
                out = work/'public'
                out.mkdir(exist_ok=True)
                sentinel = out/'index.html'
                sentinel.write_text('untouched')
                result = release()
                if fields:
                    assert result.returncode != 0, 'CSP metadata silently overwrote installed asset: ' + selection
                    assert 'csp-sources.json' in result.stderr and 'collid' in result.stderr, result.stderr
                    assert sentinel.read_text() == 'untouched', 'collision detected after output writes'
                else:
                    assert result.returncode == 0, result.stderr
                    assert (out/'csp-sources.json').read_text() == asset.read_text(), 'release deleted installed asset: ' + selection
        asset.unlink()
    if mode in ['all', 'cleanup']:
        config()
        out = work/'public'
        out.mkdir(exist_ok=True)
        metadata = out/'csp-sources.json'
        metadata.write_text('unrelated pre-existing file\n')
        result = release()
        assert result.returncode == 0, result.stderr
        assert metadata.read_text() == 'unrelated pre-existing file\n', 'deleted unrelated pre-existing file'
        config(extras)
        result = release()
        assert result.returncode != 0, 'overwrote unrelated pre-existing file'
        assert metadata.read_text() == 'unrelated pre-existing file\n'
        metadata.unlink()
    if mode in ['all', 'child']:
        config(extras)
        child = work/'child'
        child.mkdir()
        unrelated = child/'public'
        unrelated.mkdir()
        (unrelated/'csp-sources.json').write_text('child sentinel\n')
        result = release(child)
        assert result.returncode == 0, result.stderr
        metadata = work/'public/csp-sources.json'
        assert metadata.exists(), 'metadata missing from project output'
        assert json.loads(metadata.read_text())['csp_extra_sources'][0]['sources'] == ['data:']
        assert (unrelated/'csp-sources.json').read_text() == 'child sentinel\n', 'modified child public tree'
        config()
        result = release(child)
        assert result.returncode == 0, result.stderr
        assert not metadata.exists(), 'project stale metadata survived child release'
        assert (unrelated/'csp-sources.json').read_text() == 'child sentinel\n'
        config(extras)
        result = release(child, ['--output=explicit'])
        assert result.returncode == 0, result.stderr
        assert (child/'explicit/csp-sources.json').exists(), 'explicit output lost cwd-relative meaning'
print('CSP review regression passed: ' + mode)
PY
