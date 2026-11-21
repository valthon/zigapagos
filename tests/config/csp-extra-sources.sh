#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$REPO/tests/rendering/simple/content" "$REPO/tests/rendering/simple/layouts" "$WORK/"
python3 - "$REPO" "$WORK" <<'CONFIG'
from pathlib import Path
import subprocess, sys, json, os
repo, work = map(Path, sys.argv[1:])
base = (repo/'tests/rendering/simple/zigapagos.ziggy').read_text().rstrip()[:-2]
# No island/SPA bundle has run in this fresh static site to create the report directory.
assert not (work/'.zigapagos-cache/bundles').exists()
(work/'zigapagos.ziggy').write_text(base + '\n.csp_extra_sources = [.{ .directive = "script-src", .sources = ["https://js.sentry-cdn.com"] }],\n})\n')
result = subprocess.run([str(repo/'zig-out/bin/zigapagos'), 'release', '--force', '--summary'], cwd=work, capture_output=True, text=True, env=os.environ | {"ZIGAPAGOS_RUNTIME_DIR": str(repo/"runtime")})
assert result.returncode == 0, result.stderr
report = json.loads((work/'.zigapagos-cache/bundles/host-config-report.json').read_text())
for artifact in ['csp-sources.json', 'csp.zigbase.txt', 'csp.nginx.conf', 'csp.apache.conf']:
    assert artifact in report, report
    assert artifact in result.stdout + result.stderr, 'missing from build summary: ' + artifact
for directive, source, good in [
    ('script-src', 'https://js.sentry-cdn.com', True),
    ('frame-src', 'https://www.google.com/recaptcha/', True),
    ('connect-src', 'wss://*.example.com:*/socket', True),
    ('connect-src', 'https://api.example/a%20b', True),
    ('img-src', 'data:', True),
    ('script-src', "'sha256-YWJj'", True),
    ('script-src', "'unsafe-eval'", True),
    ('unknown-src', 'https://example.com', False),
    ('script-src', 'https://good.example;img-src *', False),
    ('img-src', 'https://example.com/\nInjected', False),
    ('script-src', 'https://example.com?query', False),
    ('script-src', "'sha256-!!!'", False),
    ('script-src', 'https://', False),
    ('script-src', 'not a source', False),
]:
    (work/'zigapagos.ziggy').write_text(base + '\n.csp_extra_sources = [.{ .directive = '+json.dumps(directive)+', .sources = ['+json.dumps(source)+'] }],\n})\n')
    out = work/'public'
    out.mkdir(exist_ok=True)
    sentinel = out/'index.html'
    sentinel.write_text('untouched')
    result = subprocess.run([str(repo/'zig-out/bin/zigapagos'), 'release', '--force'], cwd=work, capture_output=True, text=True, env=os.environ | {"ZIGAPAGOS_RUNTIME_DIR": str(repo/"runtime")})
    assert (result.returncode == 0) == good, (directive, source, result.returncode, result.stderr)
    if good:
        assert json.loads((out/'csp-sources.json').read_text())['csp_extra_sources'] == [{'directive': directive, 'sources': [source]}]
        for artifact in ['csp.zigbase.txt', 'csp.nginx.conf', 'csp.apache.conf']:
            rendered = source.replace('%', '%%') if artifact == 'csp.apache.conf' else source
            assert rendered in (out/artifact).read_text(), artifact
    if not good:
        assert 'csp_extra_sources' in result.stderr, result.stderr
        assert sentinel.read_text() == 'untouched', 'invalid config modified output'
(work/'zigapagos.ziggy').write_text(base + '})')
result = subprocess.run([str(repo/'zig-out/bin/zigapagos'), 'release', '--force'], cwd=work, capture_output=True, text=True, env=os.environ | {"ZIGAPAGOS_RUNTIME_DIR": str(repo/"runtime")})
assert result.returncode == 0, result.stderr
assert not (out/'csp-sources.json').exists(), 'stale CSP declarations survived removal'
assert 'js.sentry-cdn.com' not in (out/'csp.zigbase.txt').read_text()
print('CSP config parsing and early validation passed')
CONFIG
