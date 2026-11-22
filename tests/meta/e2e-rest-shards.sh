#!/usr/bin/env bash
# Pin coverage, determinism, measured balance and anti-vacuity of the PR shards.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import glob
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('shards', '.github/scripts/e2e-rest-shards.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
workflow = Path('.github/workflows/ci.yml').read_text()
excluded = re.search(r'^      SHARDED_OUT: (.+)$', workflow, re.M)[1].split()
discovered = glob.glob('tests/*/*.sh')
a, b = module.partition(discovered, excluded)
assert a and b and not set(a) & set(b)
assert set(a + b) == set(discovered) - set(excluded)
assert [a, b] == module.partition(list(reversed(discovered)), excluded)
assert abs(sum(map(module.weight, a)) - sum(map(module.weight, b))) <= module.DEFAULT_WEIGHT
# Every exclusion has exactly one explicit CI owner, outside the shard job.
owners = workflow.split('  e2e-rest:')[0]
for script in excluded:
    assert len(re.findall(r'(?:bash |script=)' + re.escape(script) + r'(?:\s|$)', owners)) == 1, script
assert 'tests/schema/structural-agreement.sh' in excluded
assert 'tests/release/zero-config-release.sh' in excluded
compile_checks = workflow.split('  compile-checks:')[1].split('  build-test:')[0]
assert 'run: bash tests/schema/structural-agreement.sh' in compile_checks
new = 'tests/future/new.sh'
c, d = module.partition(discovered + [new], excluded)
assert (c + d).count(new) == 1
assert set(c + d) == set(a + b + [new])
# Pin the supplied measurements independently of the implementation.
measured = {
    'tests/npm/packaging.sh': 50, 'tests/ziggy/comment-boundaries.sh': 41,
    'tests/install/e2e.sh': 21, 'tests/migrate/rails-presentation.sh': 20,
    'tests/dev/background.sh': 13, 'tests/migrate/frameworks.sh': 11,
    'tests/config/csp-extra-sources.sh': 13, 'tests/migrate/rails-zero-edit.sh': 11,
    'tests/sitemap/sitemap.sh': 8, 'tests/release/authoring-defaults.sh': 7,
    'tests/config/csp-ownership.sh': 7,
}
assert all(module.MEASURED_SECONDS.get(p) == seconds for p, seconds in measured.items())
assert all(p in a + b for p in module.MEASURED_SECONDS), 'stale measured weight'
# Original inventory after moving schema: 111 long-tail scripts + 11 outliers.
fixture = [f'tests/fixture/{i}.sh' for i in range(111)] + list(measured)
a, b = module.partition(fixture, [])
def units(shard):
    return sum(measured[p] * 111 if p in measured else 186 for p in shard)
assert units(a) + units(b) == 388 * 111
assert abs(units(a) - units(b)) <= 186
# New scripts still run automatically, but their material cost cannot be silent.
for script, elapsed, warns in [(new, 6, False), (new, 7, True),
                               (new, 94, True), ('tests/npm/packaging.sh', 50, False)]:
    result = subprocess.run(['python3', '.github/scripts/e2e-rest-shards.py',
                             '--duration', script, str(elapsed)],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert ('::warning file=' in result.stdout) == warns, result.stdout
    if warns:
        assert script in result.stdout and 'MEASURED_SECONDS' in result.stdout
shard_job = workflow.split('  e2e-rest:')[1].split('  static-host-rehearsal:')[0]
assert 'started=$SECONDS' in shard_job
assert 'python3 .github/scripts/e2e-rest-shards.py --duration "$script" "$((SECONDS - started))"' in shard_job
for files, exclusions in [([], []), (discovered, discovered),
                          (discovered, ['tests/missing/gone.sh']),
                          (['tests/fixture/only.sh'], [])]:
    try:
        module.partition(files, exclusions)
    except ValueError:
        pass
    else:
        raise AssertionError('empty discovery, stale exclusion or empty shard passed')
print('PASS: e2e shards cover exactly once, balance measured work, warn on slow unweighted scripts and reject empty/stale inputs')
PY
