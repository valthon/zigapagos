#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${ZIGAPAGOS_BIN:-$PWD/zig-out/bin/zigapagos}"
python3 - "$BIN" <<'PY'
import pathlib, shutil, subprocess, sys, tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())
fixture = pathlib.Path('tests/rendering/site-data')
with tempfile.TemporaryDirectory(prefix='zigapagos-site-data-') as tmp:
    site = pathlib.Path(tmp)
    for name in ('content', 'layouts', 'data', 'assets'):
        shutil.copytree(fixture / name, site / name)
    shutil.copyfile(fixture / 'zigapagos.ziggy', site / 'zigapagos.ziggy')

    def release():
        result = subprocess.run([binary, 'release', '--force', '--output=out'],
                                cwd=site, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        return (site / 'out/index.html').read_bytes()

    # The process must complete cleanup as well as produce the nested data.
    # A single-threaded Debug binary caught the old wrong-allocator free here.
    assert release() == (fixture / 'snapshot/index.html').read_bytes()

    # A fresh build must load new data, with no retained backing allocation.
    data = site / 'data/site.ziggy'
    data.write_text(data.read_text().replace('Jane Runner', 'Second Owner'))
    assert b'Second Owner' in release()

    # The optional missing-data directory also has a valid empty arena lifetime.
    shutil.rmtree(site / 'data')
    (site / 'layouts/index.shtml').write_text(
        '<!DOCTYPE html><html><head><title>Empty</title></head>'
        '<body><p>No data directory</p></body></html>')
    assert b'No data directory' in release()
print('site-data rendering and allocator cleanup: PASS')
PY
