#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${ZIGAPAGOS_BIN:-$PWD/zig-out/bin/zigapagos}"
python3 - "$BIN" <<'PY'
import json, pathlib, subprocess, sys, tempfile
binary = sys.argv[1]
with tempfile.TemporaryDirectory() as work:
    root = pathlib.Path(work)
    tree = root / 'output'; (tree / 'docs').mkdir(parents=True)
    js = 'console.log("α");\n'
    css = '@import "unmeasured.css"; body { color: red; }\n'
    inline_js = 'window.message = "β";'
    inline_css = 'main { display: grid; }'
    (tree / 'app.js').write_text(js, encoding="utf-8", newline="\n")
    (tree / 'style.css').write_text(css, encoding="utf-8", newline="\n")
    (tree / 'unreferenced.js').write_text('unmeasuredDependency()', encoding="utf-8", newline="\n")
    page = tree / 'docs/index.html'
    def markup(body='', head=''):
        page.write_text('<!DOCTYPE html><html><head><title>Page</title>' + head + '</head><body>' + body + '</body></html>', encoding="utf-8", newline="\n")
    def run(*args, expected=0, prefix=True, page_arg=True, target=tree):
        argv = [binary, 'inspect-output', str(target), '--format=json']
        if page_arg: argv += ['--page=docs/index.html']
        if prefix: argv += ['--url-prefix=project']
        p = subprocess.run(argv + list(args), text=True, capture_output=True, timeout=15)
        assert p.returncode == expected, (argv, args, p.returncode, p.stdout, p.stderr)
        return [json.loads(line) for line in p.stdout.splitlines()], p
    def record(rows, kind): return next(r for r in rows if r['type'] == kind)
    markup('<div data-z-module="/project/app%2Ejs"></div>',
        '<script src="../app.js?v=1&amp;other=2#entry"></script>'
        '<script src="/project/sub/../app.js"></script>'
        '<link rel="modulepreload" href="/project/app.js">'
        '<link rel="stylesheet" href="../style.css?v=2">'
        '<link rel="alternate stylesheet" href="/project/style.css">'
        f'<script>{inline_js}</script><style>{inline_css}</style>'
        '<script type="application/json">{"not":"code"}</script><script type="importmap">{}</script>')
    rows, _ = run()
    summary = record(rows, 'page_resources')
    expected_js = len(js.encode()) + len(inline_js.encode())
    expected_css = len(css.encode()) + len(inline_css.encode())
    assert summary['metric'] == 'direct_reference_raw_bytes'
    assert summary['raw_bytes'] == {'js': expected_js, 'css': expected_css}, summary
    assert summary['inline_body_bytes'] == {'js': len(inline_js.encode()), 'css': len(inline_css.encode())}, summary
    assert summary['unique_local_files'] == {'js': 1, 'css': 1} and summary['coverage_complete'], summary
    assert not summary['import_graph_measured'] and not summary['transfer_bytes_measured']
    assert len([r for r in rows if r['type'] == 'page_resource' and r['status'] == 'duplicate']) == 4
    run(f'--max-page-js-bytes={expected_js}', f'--max-page-css-bytes={expected_css}')
    for flag, value in [('js',expected_js), ('css',expected_css)]:
        failed,_ = run(f'--max-page-{flag}-bytes={value-1}', expected=1)
        assert not record(failed, 'page_budget')['passed']
        assert failed[-1]['page_budgets_failed'] == 1 and failed[-1]['budgets_exceeded'] == 0
    # Without page selection, old aggregate measurement still reports raw files;
    # no resolved-resource records or page budgets appear.
    aggregate,_ = run(prefix=False, page_arg=False)
    assert not any(r['type'] == 'page_resources' for r in aggregate)
    assert aggregate[-1]['raw_bytes']['js'] == len(js.encode()) + len('unmeasuredDependency()')
    # A filesystem target determines bytes, not the extension in its URL.
    (tree / 'bundle').write_text('plain extensionless JS', encoding="utf-8", newline="\n")
    markup(head='<script src="../bundle"></script>')
    assert record(run()[0], 'page_resources')['raw_bytes']['js'] == len('plain extensionless JS')
    # Missing, external, escaped, and unsupported paths are unknown, not zero.
    cases = [
        ('../missing.js', 'FileNotFound'), ('https://cdn.example/app.js', 'NonlocalUrl'),
        ('//cdn.example/app.js', 'NonlocalUrl'), ('../../app.js', 'OutsideDeployment'),
        ('/app.js', 'OutsideDeployment'), ('../../../outside.js', 'EscapesRoot'),
        ('../%2fapp.js', 'UnsupportedUrlEncoding'), ('../a&amp;b.js', 'UnsupportedUrlEncoding'),
        ('../%00.js', 'UnsupportedUrlEncoding'), ('../bad%zz.js', 'MalformedEscape'), ('', 'EmptyUrl'),
    ]
    for url,status in cases:
        markup(head=f'<script src="{url}"></script>')
        unknown,_ = run()
        ref = record(unknown, 'page_resource')
        assert ref['status'] == status and ref['raw_bytes'] is None, ref
        assert not record(unknown, 'page_resources')['coverage_complete']
        failed,_ = run('--max-page-js-bytes=999999', expected=1)
        assert not record(failed, 'page_budget')['passed']
    # Page budgets are intentionally conservative across JS and CSS: an external
    # stylesheet blocks all page budgets rather than implying the page is measured.
    markup(head='<link rel="stylesheet" href="https://cdn.example/style.css">')
    assert not record(run('--max-page-js-bytes=0', expected=1)[0], 'page_budget')['coverage_complete']
    for head in [
        '<base href="/project/"><script src="app.js"></script>',
        '<base href="https://cdn.example/"><script src="app.js"></script>',
        '<script type="&#109;odule">window.test=1</script>',
        '<script language="java&#115;cript">window.test=1</script>',
        '<link rel="style&#115;heet" href="../style.css">',
        '<style type="text/c&#115;s">body{color:red}</style>',
    ]:
        markup(head=head)
        assert not record(run('--max-page-js-bytes=99999', expected=1)[0], 'page_resources')['coverage_complete']
    # A base changes every reference's meaning, even a normally invalid local URL.
    for url in ['../outside.js', '%GG', 'https://cdn.example/app.js']:
        markup(head=f'<base href="/elsewhere/"><script src="{url}"></script>')
        rows,_ = run('--max-page-js-bytes=99999', expected=1)
        assert record(rows, 'page_resource')['status'] == 'base_href_unsupported'
    # Parsing failures are incomplete even if the parser recovered some references.
    markup('<div><script>window.test=1;</script>')
    assert not record(run('--max-page-js-bytes=99999', expected=1)[0], 'page_budget')['coverage_complete']
    # No scripts, and inert data scripts, genuinely contribute zero to this metric.
    markup(head='<script type="application/json">{"data":1}</script>')
    assert record(run('--max-page-js-bytes=0', '--max-page-css-bytes=0')[0], 'page_resources')['raw_bytes'] == {'js':0,'css':0}
    # Symlink files and directories cannot make outside bytes look deployed.
    outside = root / 'outside.js'; outside.write_text('outside', encoding="utf-8", newline="\n")
    (tree / 'linked.js').symlink_to(outside)
    assert 'SymlinkInOutput' in run(expected=1)[1].stderr
    (tree / 'linked.js').unlink()
    (tree / 'linked').symlink_to(root, target_is_directory=True)
    assert 'SymlinkInOutput' in run(expected=1)[1].stderr
    (tree / 'linked').unlink()
    for arg in ['--page=../index.html', '--page=/index.html', '--page=absent.html', '--url-prefix=project/../other']:
        assert 'ZP_FATAL' in run(arg, expected=1)[1].stderr
    assert 'require --page' in run('--max-page-js-bytes=0', prefix=False, page_arg=False, expected=1)[1].stderr
    # Build an actual prefixed minimal site, rather than testing only handcrafted
    # HTML. The emitted stylesheet URL must map back to its installed bytes.
    built = root / 'built'; built.mkdir()
    p = subprocess.run([binary,'init','--minimal'], cwd=built, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    config = built / 'zigapagos.ziggy'
    config.write_text(config.read_text().replace('Site {', 'Site {\n    .url_path_prefix = "project",'), encoding="utf-8", newline="\n")
    p = subprocess.run([binary,'release'], cwd=built, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    actual,_ = run('--page=index.html', '--max-page-js-bytes=0', '--max-page-css-bytes='+str((built/'assets/style.css').stat().st_size), target=built/'public')
    measured = record(actual,'page_resources')
    assert measured['coverage_complete'] and measured['raw_bytes']['js'] == 0, measured
    assert measured['raw_bytes']['css'] == (built/'assets/style.css').stat().st_size, measured
print('PASS: direct page bytes, alias deduplication, exact budgets, unknown coverage, and prefixed production build')
PY
