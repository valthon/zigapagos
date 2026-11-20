#!/usr/bin/env bash
# Execute the production workflow's version/commit checks against a local
# annotated tag and fake installed binaries. No registry or GitHub access.
set -euo pipefail
python3 - "$(dirname "$0")/../../.github/workflows/smoke-published.yml" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap

workflow = Path(sys.argv[1]).read_text()

def checks(step):
    body = workflow.split(f'      - name: "{step}"', 1)[1]
    body = body.split('\n      - name:', 1)[0]
    shell = textwrap.dedent(body.split('        run: |\n', 1)[1])
    # Installation and archive extraction precede this seam; exercise exactly
    # the commands that validate the already-installed binary in each channel.
    return shell[shell.index('out="$('):].replace('${{ matrix.label }}', 'fixture')

failures = []
with tempfile.TemporaryDirectory(prefix='zigapagos-provenance-') as tmp:
    root = Path(tmp)
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root, text=True).strip()
    git('init', '-q')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '-q', '--allow-empty', '-m', 'release')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'tag', '-a', 'v0.5.0', '-m', 'annotated release')
    commit = git('rev-parse', 'v0.5.0^{commit}')
    assert commit != git('rev-parse', 'v0.5.0'), 'fixture must require tag peeling'
    binary = root / 'zigapagos'
    binary.write_text('#!/bin/sh\nprintf "zigapagos %s\\ncommit:      %s\\n" "$FAKE_VERSION" "$FAKE_COMMIT"\nexit "$FAKE_STATUS"\n')
    binary.chmod(0o755)
    checkout = root / 'checkout'
    checkout.mkdir()
    (root / '.git').rename(checkout / '.git')
    installed = root / 'installed'
    installed.mkdir()
    for step in ('zigapagos version reports release provenance',
                 'npm install of the published version runs the CLI'):
        # Keep the step name tied to the workflow so moving/removing a check
        # cannot silently make this test exercise a stale duplicate predicate.
        script = checks(step)
        for name, version, reported, status, want in (
            ('matching prefix', '0.5.0', commit[:12], '0', True),
            ('wrong commit prefix', '0.5.0', '1' * 12, '0', False),
            ('wrong full commit', '0.5.0', '1' * 40, '0', False),
            ('full SHA is not printed format', '0.5.0', commit, '0', False),
            ('missing commit', '0.5.0', '', '0', False),
            ('wrong version', '0.5.1', commit[:12], '0', False),
            ('binary fails', '0.5.0', commit[:12], '7', False),
        ):
            env = dict(os.environ, GITHUB_WORKSPACE=str(checkout), TAG='v0.5.0', ARCHIVE='fixture', version='0.5.0',
                       FAKE_VERSION=version, FAKE_COMMIT=reported, FAKE_STATUS=status)
            result = subprocess.run(['bash', '-c', 'set -euo pipefail\nbin="$1"\n' + script,
                                     'fixture', str(binary)], cwd=installed, env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            passed = result.returncode == 0
            label = f'{step}: {name}'
            if passed != want:
                failures.append(label)
                print(f'FAIL: {label} (RC {result.returncode})\n{result.stdout}')
            else:
                print(f'PASS: {label} (RC {result.returncode})')
if failures:
    sys.exit(1)
PY
