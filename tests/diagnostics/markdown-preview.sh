#!/usr/bin/env bash
# All error kinds through disk text/JSON and memory validate text/JSON.
# Most fixtures intentionally lack a trailing newline. The unit matrix also
# supplies truncated sources and malformed primary/related parser positions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ZIGAPAGOS_BIN="${ZIGAPAGOS_BIN:-$ROOT/zig-out/bin/zigapagos}"
export MARKDOWN_PREVIEW_FIXTURES="$ROOT/tests/diagnostics/markdown-preview"
python3 - <<'PY'
import json, os, pathlib, re, resource, subprocess, tempfile
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
fixtures = pathlib.Path(os.environ['MARKDOWN_PREVIEW_FIXTURES'])
expected = {
    'nested-html': 'not a valid html element',
    'blank-line-html': 'erroneous end tag',
    'html-parent-span': 'invalid nesting under <span>',
    'html-parent-p': 'invalid nesting under <p>',
    'quoted-html': 'not a valid html element',
    'empty-line-html': 'eof_in_attribute_value',
    'inline-html': 'inline html syntax is forbidden',
    'missing-section-id': 'missing section id',
    'heading-suffix': 'text outside of inner link',
    'alt-text': 'vanilla alt text',
    'image-expression': 'scripty expression in image syntax',
    'empty-expression': 'link syntax without link',
    'invalid-reference': 'unknown ref',
    'duplicate-id': "duplicate id 'same'",
    'heading-gap': 'skipped heading level',
    'heading-baseline': "heading above the document's first heading level",
    'scripty-autolink': 'invalid URL',
}
failures = []
def bounded_previews(text):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith('|    ') and re.fullmatch(r' *\^+', line[5:]):
            source = lines[i-1].removeprefix('|    ')
            assert 1 <= len(line[5:]) <= min(1024, max(1, len(source))), (source, line)

with tempfile.TemporaryDirectory() as tmp:
    site = pathlib.Path(tmp)
    (site/'content').mkdir()
    (site/'layouts').mkdir()
    (site/'zigapagos.ziggy').write_text('''.site = .simple(.{
.title = "Markdown previews",
.host_url = "https://example.com",
.content_dir_path = "content",
.layouts_dir_path = "layouts",
.assets_dir_path = "content",
})\n''')
    (site/'layouts/index.shtml').write_text('<html><body><div :html="$page.content()"></div></body></html>')
    assert {p.stem for p in fixtures.glob('*.smd')} == set(expected)
    for name, message in expected.items():
        source = (fixtures/(name+'.smd')).read_text()
        (site/'content/index.smd').write_text(source)
        for command, fmt in [('release','text'), ('release','json'), ('validate','text'), ('validate','json')]:
            args = [os.environ['ZIGAPAGOS_BIN'], command, '--format='+fmt]
            if command == 'release': args += ['--force','-o',str(site/'out')]
            p = subprocess.run(args, cwd=site, capture_output=True, text=True)
            try:
                assert p.returncode == 1, f'exit {p.returncode}: {p.stderr[:160]}'
                assert 'panic' not in p.stderr and 'leaked' not in p.stderr, p.stderr
                if fmt == 'json':
                    records = [json.loads(line) for line in p.stderr.splitlines()]
                    ds = [d for d in records if d['code']=='ZP_SUPERMD']
                    assert ds and any(message in d['message'] for d in ds), records
                    for d in ds:
                        assert d['file']=='content/index.smd', d
                        assert 1 <= d['line'] <= len(source.split('\n')), d
                        assert 1 <= d['col'] <= max(1,len(source.split('\n')[d['line']-1])), d
                        bounded_previews(d['help'] or '')
                        if name=='duplicate-id':
                            assert '[first]' in d['help'] and 'first definition was on line' in d['help'], d
                        if name=='heading-gap': assert '# First' in d['help'] and 'previous heading' in d['help'], d
                else:
                    assert message in p.stderr and re.search(r'content/index\.smd:\d+:\d+:',p.stderr), p.stderr
                    bounded_previews(p.stderr)
                    if name=='duplicate-id': assert '[first]' in p.stderr and 'first definition was on line' in p.stderr
                    if name=='heading-gap': assert '# First' in p.stderr and 'previous heading' in p.stderr
            except (AssertionError, ValueError) as e:
                failures.append(f'{name} {command}/{fmt}: {e}')
for failure in failures: print('FAIL:',failure)
assert not failures, f'{len(failures)} Markdown preview checks failed'
print(f'PASS: {len(expected)} fixtures across text, JSON and memory modes ({len(expected)*4} runs)')
PY
