#!/usr/bin/env python3
"""Print one deterministic partition of CI's discovered shell e2e remainder."""
import glob
import os
from pathlib import Path
import sys

# Seconds measured on 2026-11-22, e1d95cb1. Of 123 scripts, the schema
# mutations took 94s and now run in compile-checks. The eleven outliers below
# total 202s; the other 111 shared 482 - 94 - 202 = 186s. Keep integer
# weights at 111 units/second so their estimated mean stays exact.
SCALE = 111
MEASURED_SECONDS = {
    'tests/npm/packaging.sh': 50,
    'tests/ziggy/comment-boundaries.sh': 41,
    'tests/install/e2e.sh': 21,
    'tests/migrate/rails-presentation.sh': 20,
    'tests/dev/background.sh': 13,
    'tests/migrate/frameworks.sh': 11,
    'tests/config/csp-extra-sources.sh': 13,
    'tests/migrate/rails-zero-edit.sh': 11,
    'tests/sitemap/sitemap.sh': 8,
    'tests/release/authoring-defaults.sh': 7,
    'tests/config/csp-ownership.sh': 7,
}
DEFAULT_WEIGHT = 186
# Seven seconds is the smallest individually measured outlier. Warn rather
# than fail: a first CI run is how a contributor obtains a hosted-runner time.
UNMEASURED_WARNING_SECONDS = 7


def weight(script):
    if script in MEASURED_SECONDS:
        return MEASURED_SECONDS[script] * SCALE
    return DEFAULT_WEIGHT


def duration_warning(script, seconds):
    if script not in MEASURED_SECONDS and seconds >= UNMEASURED_WARNING_SECONDS:
        return (f'::warning file={script}::{script} took {seconds}s without a measured '
                'shard weight; add its CI seconds to MEASURED_SECONDS in '
                '.github/scripts/e2e-rest-shards.py and run tests/meta/e2e-rest-shards.sh')
    return ''


def partition(discovered, excluded):
    if not discovered:
        raise ValueError('no tests/*/*.sh found — the glob or the layout changed')
    for path in excluded:
        if path not in discovered or not Path(path).is_file():
            raise ValueError(f'{path} is listed as sharded-out but does not exist in discovery')
    scripts = sorted(set(discovered) - set(excluded))
    if not scripts:
        raise ValueError('every discovered script was excluded — the shard split is wrong')
    shards = [[], []]
    loads = [0, 0]
    for script in sorted(scripts, key=lambda p: (-weight(p), p)):
        shard = min(range(2), key=lambda i: (loads[i], i))
        shards[shard].append(script)
        loads[shard] += weight(script)
    if not all(shards):
        raise ValueError('nothing selected for a shard — need at least two remaining scripts')
    return [sorted(shard) for shard in shards]


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--duration':
            warning = duration_warning(sys.argv[2], int(sys.argv[3]))
            if warning:
                print(warning)
            sys.exit(0)
        if len(sys.argv) != 2 or sys.argv[1] not in ('1', '2'):
            raise ValueError('expected shard 1 or 2')
        shards = partition(glob.glob('tests/*/*.sh'), os.environ['SHARDED_OUT'].split())
        print('\n'.join(shards[int(sys.argv[1]) - 1]))
    except (ValueError, KeyError) as error:
        sys.exit(f'::error::{error}')
