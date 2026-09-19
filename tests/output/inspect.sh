#!/usr/bin/env bash
# Exercises emitted files and exact-byte regressions, independently of source templates.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${ZIGAPAGOS_BIN:-$PWD/zig-out/bin/zigapagos}"
python3 - "$BIN" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
binary = sys.argv[1]
with tempfile.TemporaryDirectory() as work:
    root = pathlib.Path(work)
    tree = root / 'output'
    tree.mkdir()
    files = {
        'index.html': '''<!DOCTYPE html><html><head><title>App</title>
<link rel="alternate MODULEPRELOAD" href="chunks/lazy.mjs">
<script src="/app.js" defer></script><script type="module" src="https://cdn.example/app.js"></script>
<script>window.app = true;</script><script type="application/json">{"props":1}</script>
<script type="importmap">{"imports":{}}</script></head><body>
<div data-z-module="/islands/card.js"></div></body></html>''',
        'docs/index.html': '<!DOCTYPE html><html><head><title>Docs</title></head><body>No scripts</body></html>',
        'app.js': 'console.log("hello");\n',
        'islands/card.js': 'export default 42;\n',
        'chunks/lazy.mjs': 'export const lazy = true;\n',
        'unused.cjs': 'module.exports = 1;\n',
        'style.CSS': 'body { color: red; }\n',
        'app.js.map': '{}', 'app.js.br': 'compressed companion', 'image.png': 'image bytes',
    }
    for name, source in files.items():
        p = tree / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(source)
    def run(*args, target=tree, expected=0):
        p = subprocess.run([binary, 'inspect-output', str(target), '--format=json', *args], capture_output=True, text=True, timeout=10)
        assert p.returncode == expected, (p.returncode, p.stdout, p.stderr)
        return p
    output = run()
    assert output.stdout == run().stdout, 'report order is nondeterministic'
    rows = [json.loads(line) for line in output.stdout.splitlines()]
    assert not output.stderr, output.stderr
    summary = rows[-1]
    assets = [r for r in rows if r['type'] == 'asset']
    assert [r['path'] for r in assets] == sorted(r['path'] for r in assets)
    expected_bytes = {'html': 0, 'css': 0, 'js': 0}
    for name, source in files.items():
        ext = pathlib.Path(name).suffix.lower()
        kind = 'js' if ext in ['.js', '.mjs', '.cjs'] else ext[1:]
        if kind in expected_bytes:
            expected_bytes[kind] += len(source.encode())
    assert summary['type'] == 'summary' and summary['raw_bytes'] == expected_bytes, summary
    assert summary['files'] == 7 and summary['pages'] == 2, summary
    assert summary['pages_with_partial_references'] == 0, summary
    assert not summary['external_resources_measured'] and not summary['references_resolved']
    assert summary['measurement'] == 'raw_file_bytes' and summary['inline_script_bytes_in'] == 'html'
    refs = [r for r in rows if r['type'] == 'reference']
    assert len(refs) == 4 and all(r['resolution'] == 'not_resolved' for r in refs), refs
    assert {'modulepreload', 'script_src', 'island_module'} == set(r['kind'] for r in refs)
    assert [r for r in refs if r['url_scope'] == 'nonlocal_url'][0]['url'] == 'https://cdn.example/app.js'
    pages = {r['path']: r for r in rows if r['type'] == 'page'}
    assert pages['index.html']['inline_javascript_elements'] == 1, pages
    assert pages['index.html']['inline_other_script_elements'] == 2, pages
    assert pages['docs/index.html']['references'] == 0 and pages['docs/index.html']['inline_javascript_elements'] == 0
    # Equal is allowed; a one-byte growth is a regression, without KB rounding.
    run(*[f'--max-{kind}-bytes={value}' for kind, value in expected_bytes.items()])
    for kind, value in expected_bytes.items():
        bad = run(f'--max-{kind}-bytes={value-1}', expected=1)
        parsed = [json.loads(line) for line in bad.stdout.splitlines()]
        assert parsed[-1]['budgets_exceeded'] == 1
        assert [r for r in parsed if r['type'] == 'budget'][0]['passed'] is False
    # Human output names raw-byte scope and pass/fail.
    human = subprocess.run([binary, 'inspect-output', str(tree), '--max-js-bytes=0'], capture_output=True, text=True)
    assert human.returncode == 1 and 'not transfer bytes' in human.stdout and 'exceeded' in human.stdout
    # Zero external JS bytes cannot imply zero browser JS. Inline, CDN, and base
    # details stay visible while only existing emitted files determine budgets.
    zero = root / 'zero'
    zero.mkdir()
    (zero / 'index.html').write_text('<!DOCTYPE html><html><head><title>Zero files</title><base href="https://cdn.example/"><script src="external.js"></script><script type="application/json">{}</script></head><body></body></html>')
    zr = [json.loads(line) for line in run('--max-js-bytes=0', target=zero).stdout.splitlines()]
    assert zr[-1]['raw_bytes']['js'] == 0
    assert [r for r in zr if r['type'] == 'page'][0]['has_base_href'] is True
    # Browser-tolerated missing end tags must not erase byte counts; incomplete
    # reference coverage is explicit, so consumers cannot infer zero JS from it.
    partial = root / 'partial'; partial.mkdir()
    malformed = '<!DOCTYPE html><html><head><title>Partial</title></head><body><div><script src="app.js"></script></body></html>'
    (partial / 'index.html').write_text(malformed)
    pr = [json.loads(line) for line in run(target=partial).stdout.splitlines()]
    assert pr[-1]['raw_bytes']['html'] == len(malformed.encode()), pr
    assert pr[-1]['pages_with_partial_references'] == 1, pr
    assert [r for r in pr if r['type'] == 'page'][0]['reference_coverage'] == 'partial'
    if os.geteuid() != 0:
        (partial / 'index.html').chmod(0)
        try:
            assert 'AccessDenied' in run(target=partial, expected=1).stderr
        finally:
            (partial / 'index.html').chmod(0o600)
    encoded = root / 'encoded'; encoded.mkdir()
    (encoded / 'index.html').write_text('<!DOCTYPE html><html><head><title>Encoded</title><script type="&#109;odule">window.example=1;</script><link rel="modulepre&#108;oad" href="app.js"></head><body></body></html>')
    er = [json.loads(line) for line in run(target=encoded).stdout.splitlines()]
    ep = [r for r in er if r['type'] == 'page'][0]
    assert ep['reference_coverage'] == 'partial' and ep['encoded_classification_elements'] == 2, er
    assert ep['inline_unclassified_script_elements'] == 1 and ep['inline_other_script_elements'] == 0, er
    assert [r for r in er if r['type'] == 'inline_script'][0]['javascript'] is None, er
    assert [r for r in er if r['type'] == 'reference'][0]['kind'] == 'link_href_unclassified', er
    assert er[-1]['pages_with_partial_references'] == 1, er
    # Empty/wrong tree and unsupported symlinks cannot certify a zero inventory.
    empty = root / 'empty'; empty.mkdir()
    for target in [empty, root / 'missing']:
        p = run(target=target, expected=1)
        assert json.loads(p.stderr)['code'] == 'ZP_FATAL', p.stderr
        assert not any(json.loads(line).get('type') == 'summary' for line in p.stdout.splitlines())
    (zero / 'outside.js').symlink_to(tree / 'app.js')
    assert 'SymlinkInOutput' in run(target=zero, expected=1).stderr
    (zero / 'outside.js').unlink()
    (zero / 'linked').symlink_to(tree, target_is_directory=True)
    assert 'SymlinkInOutput' in run(target=zero, expected=1).stderr
    for arg in ['--max-js-bytes=', '--max-js-bytes=-1', '--max-css-bytes=2kb', '--max-html-bytes=18446744073709551616', '--unknown']:
        p = run(arg, expected=1)
        assert json.loads(p.stderr)['code'] == 'ZP_FATAL', p.stderr
    help_out = subprocess.run([binary, 'inspect-output', '--help'], capture_output=True, text=True)
    assert help_out.returncode == 0 and '--max-js-bytes' in help_out.stderr
print('PASS: output inventory, references, exact raw-byte budgets, JSON, zero JS, and failure coverage')
PY
