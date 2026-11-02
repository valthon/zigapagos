#!/usr/bin/env bash
# The copyable contributor commands must include CI's complete unit inventory
# and must return failure when an integration script fails.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import tempfile

doc = Path('CONTRIBUTING.md').read_text()
workflow = Path('.github/workflows/ci.yml').read_text()
step = re.search(r'- name: Subsystem unit tests[^\n]*\n\s+run: \|\n((?:[ ]{10}[^\n]*\n)+)', workflow)
assert step, 'cannot find the CI subsystem unit-test command'
required = set(re.findall(r'\btest-[\w-]+', step[1]))
assert required, 'CI unit-test inventory is empty'
commands = re.findall(r'(?m)^zig build test-islands\b[^\n]*', doc.replace('\\\n', ' '))
assert commands, 'CONTRIBUTING.md has no copyable subsystem unit-test command'
for command in commands:
    actual = set(re.findall(r'\btest-[\w-]+', command))
    assert actual == required, f'contributor unit inventory differs from CI: missing={required-actual}, extra={actual-required}'

block = next((b for b in re.findall(r'```sh\n(.*?)\n```', doc, re.S)
              if 'for s in tests/*/*.sh' in b), None)
assert block, 'cannot find the copyable integration loop'
loop = block[block.index('(cd runtime'):].split('\n', 1)[1]
with tempfile.TemporaryDirectory(prefix='z-contributor-gates-') as temporary:
    root = Path(temporary)
    tests = root / 'tests/fixture'
    tests.mkdir(parents=True)
    (tests / 'a-fail.sh').write_text('exit 7\n')
    (tests / 'z-pass.sh').write_text('touch last-script-ran\n')
    failed = subprocess.run(['bash', '-c', loop], cwd=root, capture_output=True, text=True)
    assert failed.returncode != 0, 'documented integration loop masks a failing script'
    assert (root / 'last-script-ran').exists(), 'documented loop skips later scripts after a failure'
    (tests / 'a-fail.sh').write_text('exit 0\n')
    passed = subprocess.run(['bash', '-c', loop], cwd=root, capture_output=True, text=True)
    assert passed.returncode == 0, 'documented integration loop fails when all scripts pass'
print('PASS: contributor unit inventory matches CI and the documented loop preserves failures')
PY
