#!/usr/bin/env bash
# Exercise the baseline rule through validate's JSON and in-memory build path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${ZIGAPAGOS_BIN:-$ROOT/zig-out/bin/zigapagos}"
python3 - "$ROOT" "$BIN" <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root, binary = Path(sys.argv[1]), sys.argv[2]
fixture = root / 'tests/rendering/heading-baseline'
rejections = root / 'tests/content-scanning/dialect-rejections/content'
with tempfile.TemporaryDirectory() as tmp:
    site = Path(tmp)
    shutil.copy(fixture / 'zigapagos.ziggy', site)
    shutil.copytree(fixture / 'layouts', site / 'layouts')
    (site / 'content').mkdir()
    for page in sorted((fixture / 'content').glob('*.smd')):
        shutil.copy(page, site / 'content/index.smd')
        result = subprocess.run([binary, 'validate', '--format=json'], cwd=site,
                                capture_output=True, text=True)
        assert result.returncode == 0, (page.name, result.stderr)
        assert result.stderr == '', (page.name, result.stderr)
    for name, message in [
        ('heading-gap', 'skipped heading level'),
        ('heading-gap-from-h1', 'skipped heading level'),
        ('heading-above-baseline', "heading above the document's first heading level"),
    ]:
        shutil.copy(rejections / (name + '.smd'), site / 'content/index.smd')
        result = subprocess.run([binary, 'validate', '--format=json'], cwd=site,
                                capture_output=True, text=True)
        assert result.returncode == 1, (name, result.stderr)
        errors = [json.loads(line) for line in result.stderr.splitlines()]
        assert len(errors) == 1, (name, errors)
        error = errors[0]
        assert error['code'] == 'ZP_SUPERMD', error
        assert error['severity'] == 'error', error
        assert error['file'] == 'content/index.smd', error
        # Front matter is lines 1-7 of each rejection fixture; the offending
        # heading sits on line 10 (line 8 is the first heading, 9 is blank).
        assert (error['line'], error['col']) == (10, 1), error
        assert error['message'] == message, error
print('PASS: heading baselines, sectioned/nested exceptions, and JSON memory-mode diagnostics')
PY
