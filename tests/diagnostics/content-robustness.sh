#!/usr/bin/env bash
# Exercise real disk/JSON/memory builds; CASE selects an independent regression
# for checking each assertion against the unpatched binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ZIGAPAGOS_BIN="${ZIGAPAGOS_BIN:-$ROOT/zig-out/bin/zigapagos}"
export CONTENT_ROBUSTNESS_ROOT="$ROOT"
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
binary = os.environ['ZIGAPAGOS_BIN']
root = pathlib.Path(os.environ['CONTENT_ROBUSTNESS_ROOT'])
case = os.environ.get('CASE', 'all')

def page(body='', extra=''):
    return '---\n.title = "Test",\n.layout = "index.shtml",\n' + extra + '---\n' + body

with tempfile.TemporaryDirectory() as tmp:
    site = pathlib.Path(tmp)
    for d in ('content', 'layouts', 'assets/nested'):
        (site/d).mkdir(parents=True)
    (site/'zigapagos.ziggy').write_text('''.site = .simple(.{
.title = "Content diagnostics",
.host_url = "https://example.com",
.content_dir_path = "content",
.layouts_dir_path = "layouts",
.assets_dir_path = "assets",
})\n''')
    def run(command='release', fmt='text', good=False):
        args = [binary, command, '--format='+fmt]
        if command == 'release': args += ['--force', '-o', str(site/'out')]
        p = subprocess.run(args, cwd=site, text=True, capture_output=True)
        assert (p.returncode == 0) == good, (args, p.returncode, p.stderr)
        assert 'panic' not in p.stderr and 'leaked' not in p.stderr, p.stderr
        return p
    def records(p):
        return [json.loads(x) for x in p.stderr.splitlines()]
    (site/'layouts/index.shtml').write_text('<html><body><div :html="$page.content()"></div></body></html>\n')
    (site/'content/index.smd').write_text(page())
    if case in ('all', 'empty'):
        (site/'content/empty.smd').write_bytes(b'')
        (site/'content/valid.smd').write_text(page())
        (site/'content/index.smd').write_text(page(extra='.pagination = .{ .page_size = 1 },\n'))
        (site/'layouts/index.shtml').write_text('''<html><body>
<ul :loop="$page.subpages()"><li :text="$loop.it.title"></li></ul>
<ol :loop="$site.page('').leaves()"><li :text="$loop.it.title"></li></ol>
<div :html="$page.content()"></div></body></html>''')
        # Leaf templates cannot call subpages().
        (site/'layouts/leaf.shtml').write_text('<html><body><div :html="$page.content()"></div></body></html>')
        (site/'content/valid.smd').write_text(page().replace('index.shtml','leaf.shtml'))
        text = run(good=True)
        assert 'Ignoring empty file' in text.stderr, text.stderr
        data = records(run(fmt='json', good=True))
        assert len([d for d in data if d['code']=='ZP_EMPTY_PAGE']) == 1, data
        html = (site/'out/index.html').read_text()
        assert html.count('<li>Test</li>') == 2, html
        assert not (site/'out/page/2/index.html').exists()
        assert '2 pages' in run(command='validate', good=True).stdout
        (site/'content/empty.smd').unlink()
        (site/'content/valid.smd').unlink()
    (site/'layouts/index.shtml').write_text('<html><body><div :html="$page.content()"></div></body></html>\n')
    (site/'content/index.smd').write_text(page())
    if case in ('all', 'framing'):
        (site/'content/missing.smd').write_text('Missing frontmatter\n')
        (site/'content/broken.smd').write_text('---\n.title = [,\n---\n')
        data = records(run(fmt='json'))
        assert {'ZP_FRONTMATTER_FRAMING','ZP_FRONTMATTER_PARSE'} <= {d['code'] for d in data}, data
        run(command='validate')
        (site/'content/missing.smd').unlink()
        (site/'content/broken.smd').unlink()
    if case in ('all', 'date'):
        (site/'content/index.smd').write_text(page(extra='.date = .date("2020-7-6T00:00:00"),\n'))
        text = run().stderr
        assert 'unable to parse date:' in text and 'UnexpectedToken' not in text, text
        data = records(run(fmt='json'))
        d = next(d for d in data if d['code']=='ZP_INVALID_DATE')
        assert d['line']==4 and d['col']==9 and 'unable to parse date:' in d['message'], d
        run(command='validate')
    if case in ('all', 'duplicate'):
        (site/'content/index.smd').write_text(page('[original]($text.id("same"))\n\n[duplicate]($text.id("same"))\n'))
        for cmd, fmt in [('release','text'),('release','json'),('validate','text')]:
            p = run(command=cmd, fmt=fmt)
            rendered = p.stderr if fmt=='text' else '\n'.join((d['message']+'\n'+(d.get('help') or '')) for d in records(p))
            assert "duplicate id 'same'" in rendered and 'first definition was on line' in rendered and '[original]' in rendered, rendered
    if case in ('all', 'html'):
        (site/'content/index.smd').write_text(page('```=html\n<div invalid="unterminated>\n```\n'))
        text = run().stderr
        data = records(run(fmt='json'))
        d = next(d for d in data if d['code']=='ZP_SUPERMD')
        assert '[html] error:' in d['message'] and len(d['message'].split())>4, d
        assert d['message'] in text and d['line']>=5 and d['col']>=1, (d,text)
    if case in ('all', 'directives'):
        body = '''[unknown](#absent)
[]($link.page(/other))
[]($link.page('/other'))
[]($link.page('foo//bar'))
## []($section)
[]($link.page("foo") "alt")
![]($link)
[empty]()
'''
        (site/'content/index.smd').write_text(page(body))
        p = run()
        for message in ('unknown ref', 'scripty', 'vanilla alt text', 'scripty expression in image syntax', 'link syntax without link'):
            assert message in p.stderr, (message,p.stderr)
    if case in ('all', 'asset'):
        (site/'content/index.smd').write_text(page())
        (site/'layouts/index.shtml').write_text('''<html><body><span :text="$site.asset('nested/bad.ziggy').ziggy().get('value')"></span></body></html>''')
        (site/'assets/nested/bad.ziggy').write_text('.value = [\n')
        text = run().stderr
        assert 'assets/nested/bad.ziggy:' in text, text
    if case in ('all', 'reference'):
        ref = (root/'docs/scripty.md').read_text()
        for name in ('first?', 'last?'):
            assert f'Array.{name}() -> ?any' in ref
print('PASS: content robustness (' + case + ')')
PY
