#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$REPO" <<'PY'
import json, os, resource, subprocess, sys, tempfile
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
binary = os.environ.get('ZIGAPAGOS_BIN', str(Path(sys.argv[1])/'zig-out/bin/zigapagos'))
case = os.environ.get('CASE', 'all')
failures = []
def page(title, extra='', body='Body'):
    return f'---\n.title = "{title}", .layout = "leaf.shtml",\n.authors = ["A"], .tags = ["T"],\n'+extra+'\n---\n'+body
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    for d in ('en/hidden/nested', 'fr/hidden/nested', 'layouts', 'assets', 'i18n'):
        (work/d).mkdir(parents=True)
    (work/'zigapagos.ziggy').write_text('''.site = .multilingual(.{
.host_url = "https://example.com", .layouts_dir_path = "layouts", .assets_dir_path = "assets", .i18n_dir_path = "i18n",
.locales = [.{ .code = "en", .name = "English", .site_title = "English", .content_dir_path = "en" },
.{ .code = "fr", .name = "French", .site_title = "French", .content_dir_path = "fr" }],
})''')
    for lang in ('en', 'fr'):
        (work/f'i18n/{lang}.ziggy').write_text('{}')
        (work/f'{lang}/index.smd').write_text(page('Root', '.draft = true,'))
        (work/f'{lang}/hidden/index.smd').write_text('')
        (work/f'{lang}/hidden/nested/index.smd').write_text(page('Hidden'))
        (work/f'{lang}/hidden/leaf.smd').write_text(page('Hidden'))
        (work/f'{lang}/empty.smd').write_text('')
        (work/f'{lang}/draft.smd').write_text(page('Draft', '.draft = true,'))
        (work/f'{lang}/old.smd').write_text(page('Old', '.date = .unix(1),'))
    (work/'en/probe.smd').write_text(page('Probe', '.date = .unix(2),'))
    (work/'fr/probe.smd').write_text('')
    def run(label, layout, good=True, needle=None, flags=()):
        if case not in ('all', label): return
        (work/'layouts/leaf.shtml').write_text('<html><body>'+layout.replace('$site.', "$site.locale('en').")+'</body></html>')
        for command in ('release', 'validate'):
            for fmt in ('text', 'json'):
                args = [binary, command, '--format='+fmt, *flags]
                if command == 'release': args += ['--force']
                p = subprocess.run(args, cwd=work, capture_output=True, text=True)
                try:
                    assert (p.returncode == 0) == good, (p.returncode, p.stderr)
                    assert p.returncode >= 0, p.stderr
                    assert 'panic' not in p.stderr and 'leaked' not in p.stderr, p.stderr
                    if fmt == 'json':
                        rows = [json.loads(line) for line in p.stderr.splitlines()]
                        if not good: assert any(r['severity'] == 'error' for r in rows), rows
                    if good and command == 'release':
                        output = (work/'public/en/probe/index.html').read_text()
                        for expected in ([needle] if isinstance(needle, str) else needle or []):
                            assert expected in output, output
                        assert 'Hidden' not in output and 'Draft' not in output, output
                except (AssertionError, ValueError) as e:
                    failures.append(f'{label}/{command}/{fmt}: {str(e)[-1500:]}')
    run('pages', '<p :text="$site.pages().len"></p><ul :loop="$site.pages()"><li :text="$loop.it.title"></li></ul>', needle='<p>2</p>')
    for target in ('empty', 'draft', 'hidden', 'hidden/leaf', 'hidden/nested'):
        for builtin in ('page', 'pages'):
            run(builtin+'-'+target, f'<p :text="$site.{builtin}(\'{target}\').len"></p>' if builtin == 'pages' else f'<p :text="$site.page(\'{target}\').title"></p>', good=False)
    # The root page stays addressable as a parsed structural container, but is
    # absent from published-page enumeration and locale counterparts.
    for builtin in ('subpages', 'subpagesAlphabetic', 'leaves', "subpagesByAuthor('A')", "subpagesByTag('T')"):
        expr = builtin if '(' in builtin else builtin+'()'
        run(builtin, f'<p :text="$site.index().{expr}.len"></p>', needle='<p>2</p>')
    run('parentSection', '<p :text="$page.parentSection().title"></p>', needle='<p>Root</p>')
    run('locales', '<p :text="$site.page(\'probe\').locales().len"></p>', needle='<p>1</p>')
    run('locale?', '<ctx :if="$site.page(\'probe\').locale?(\'fr\')"><p>Hidden</p></ctx>', needle='<body>')
    run('locale', '<p :text="$site.page(\'probe\').locale(\'fr\').title"></p>', good=False)
    for state, content in [('draft', page('Draft', '.draft = true,')), ('suppressed', None)]:
        (work/'fr/probe.smd').write_text(content or page('Hidden'))
        if content is None: (work/'fr/index.smd').write_text('')
        run(state+'-locales', '<p :text="$site.page(\'probe\').locales().len"></p>', needle='<p>1</p>')
        run(state+'-locale?', '<ctx :if="$site.page(\'probe\').locale?(\'fr\')"><p>Hidden</p></ctx>', needle='<body>')
        run(state+'-locale', '<p :text="$site.page(\'probe\').locale(\'fr\').title"></p>', good=False)
    run('inactive-index', '<p :text="$site.locale(\'fr\').index().title"></p>', good=False)
    (work/'fr/index.smd').write_text(page('Root', '.draft = true,'))
    # Keyed lookup's index already excludes inactive pages: pin the invariant.
    for lang in ('en', 'fr'):
        (work/f'{lang}/key.smd').write_text(page('Key', '.translation_key = "key",'+(' .draft = true,' if lang == 'fr' else '')))
    run('key-locales', '<p :text="$site.page(\'key\').locales().len"></p>', needle='<p>1</p>')
    run('key-locale?', '<ctx :if="$site.page(\'key\').locale?(\'fr\')"><p>Hidden</p></ctx>', needle='<body>')
    run('key-locale', '<p :text="$site.page(\'key\').locale(\'fr\').title"></p>', good=False)
    for lang in ('en', 'fr'): (work/f'{lang}/key.smd').unlink()
    run('navigation', '''<ctx :if="$site.page('old').nextPage?()"><p :text="$if.title"></p></ctx>
<ctx :if="$site.page('probe').prevPage?()"><p :text="$if.title"></p></ctx>
<p :if="$site.page('old').hasNext()">has-next</p><p :if="$site.page('probe').hasPrev()">has-prev</p>''', needle=['<p>Probe</p>', '<p>Old</p>', 'has-next</p>', 'has-prev</p>'])
    # Draft roots are addressable containers, but their translation keys are
    # absent from the active-page index when no published counterpart exists.
    for lang in ('en', 'fr'):
        (work/f'{lang}/index.smd').write_text(page('Root', '.draft = true, .translation_key = "root",'))
    run('root-key-locales', '<p :text="$site.index().locales().len"></p>', needle='<p>0</p>')
    run('root-key-locale?', '<ctx :if="$site.index().locale?(\'fr\')"><p>Hidden</p></ctx>', needle='<body>')
    run('root-key-locale', '<p :text="$site.index().locale(\'fr\').title"></p>', good=False)
    # An inactive direct lookup must stop before any content/alternative/ref reader.
    for expr in ('content()', "alternative('feed').link()", "linkRef('anchor')", "absLinkRef('anchor')", 'link()', 'absLink()'):
        run(expr, f'<div :html="$site.page(\'empty\').{expr}"></div>', good=False)
for failure in failures: print('FAIL:', failure)
assert not failures, f'{len(failures)} active-page checks failed'
print('PASS: all template page readers respect activity and draft-root structure')
PY
