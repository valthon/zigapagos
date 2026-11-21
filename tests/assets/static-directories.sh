#!/usr/bin/env bash
# Directory expansion must feed the same refcounts as explicit static files.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$REPO" <<'PY'
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
binary = os.environ.get('ZIGAPAGOS_BIN', str(repo/'zig-out/bin/zigapagos'))
failures = []
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    (work/'content').mkdir()
    (work/'layouts').mkdir()
    shutil.copy(repo/'tests/rendering/simple/content/index.smd', work/'content/index.smd')
    (work/'layouts/index.shtml').write_text('''<html><head>
<link rel="preload" href="$site.asset('fonts/a.woff2').link()">
</head><body><div :html="$page.content()"></div></body></html>''')
    assets = work/'assets'
    (assets/'fonts/nested').mkdir(parents=True)
    (assets/'empty').mkdir()
    files = {'fonts/a.woff2': 'font', 'fonts/nested/b.woff2': 'nested', 'fonts/.hidden': 'hidden',
             'fonts/nested/private.ziggy': '.secret = "private",',
             'fonts-other.txt': 'not selected', 'single.txt': 'single'}
    for path, data in files.items():
        (assets/path).write_text(data)
    (work/'outside.txt').write_text('outside')
    (assets/'escape.txt').symlink_to(work/'outside.txt')
    (assets/'broken.txt').symlink_to(work/'absent.txt')
    (assets/'dir-link').symlink_to(assets/'fonts', target_is_directory=True)
    (work/'assets-other').mkdir()
    (work/'assets-other/file').write_text('outside')
    (assets/'prefix-escape').symlink_to(work/'assets-other/file')
    os.mkfifo(assets/'pipe')
    base = (repo/'tests/rendering/simple/zigapagos.ziggy').read_text().replace(
        '.assets_dir_path = "content"', '.assets_dir_path = "assets"').rstrip()
    assert base.endswith('})'), base
    base = base[:-2]
    def run(entries, fmt='text', command='release', extra=''):
        # A misleading comment must not become the diagnostic's position.
        source = base + '\n// .static_assets = ["fake"]\n.static_assets = [\n'
        positions = []
        for entry in entries:
            positions.append((source.count('\n') + 1, 5))
            source += '    ' + json.dumps(entry).replace('\\u0000', '\\x00') + ',\n'
        source += '],\n.asset_fingerprint = true,\n' + extra + '\n})'
        (work/'zigapagos.ziggy').write_text(source)
        args = [binary, command, '--format=' + fmt]
        if command == 'release':
            args += ['--force']
        return subprocess.run(args, cwd=work, text=True, capture_output=True), positions

    def check(name, fn):
        try:
            fn()
            print('PASS: ' + name)
        except (AssertionError, ValueError) as e:
            failures.append(name)
            print('FAIL: ' + name + ': ' + str(e))

    def installed():
        result, _ = run(['fonts', 'empty/', 'single.txt'])
        assert result.returncode == 0, result.stderr
        out = work/'public'
        for path, data in files.items():
            if path.startswith('fonts/') or path == 'single.txt':
                assert (out/path).read_text() == data, path
        assert not (out/'fonts-other.txt').exists(), 'directory prefix matched sibling'
        assert not list(out.rglob('*.????????.woff2')), 'static directory was fingerprinted'
        assert 'href="/fonts/a.woff2"' in (out/'index.html').read_text(), 'rendered link was fingerprinted'
        # A trailing slash has the same subtree meaning.
        result, _ = run(['fonts/'])
        assert result.returncode == 0, result.stderr
    check('nested subtree, stable paths, private files, empty and trailing directories', installed)

    def literal_files():
        # Apart from the existing trailing-** glob form, paths name literal
        # files; punctuation supported by the filesystem is not a pattern.
        names = ['font[1].woff2', 'literal?.txt', 'literal:txt', 'c:notes.txt']
        for name in names:
            (assets/name).write_text(name)
        result, _ = run(names)
        assert result.returncode == 0, result.stderr
        for name in names:
            assert (work/'public'/name).read_text() == name, name
    check('file-only literal filename compatibility', literal_files)

    def external_links():
        for entries in [['escape.txt', 'prefix-escape'], ['**']]:
            # Keep broken/non-file rejection separate from this valid glob.
            if entries == ['**']:
                shutil.rmtree(work/'public')
                (assets/'broken.txt').unlink()
                (assets/'pipe').unlink()
                (assets/'dir-link').unlink()
            result, _ = run(entries)
            assert result.returncode == 0, result.stderr
            assert (work/'public/escape.txt').read_text() == 'outside'
            assert (work/'public/prefix-escape').read_text() == 'outside'
        (assets/'dir-link').symlink_to(assets/'fonts', target_is_directory=True)
        # Restore invalid selections for the diagnostic matrix below.
        (assets/'broken.txt').symlink_to(work/'absent.txt')
        os.mkfifo(assets/'pipe')
    check('external file symlinks directly and through glob', external_links)

    cases = [
        ('file plus directory', ['fonts/a.woff2', 'fonts'], 'ZP_STATIC_ASSET_DUPLICATE', ['fonts/a.woff2', 'fonts']),
        ('directory plus file', ['fonts', 'fonts/a.woff2'], 'ZP_STATIC_ASSET_DUPLICATE', ['fonts/a.woff2', 'fonts']),
        ('overlapping directories', ['fonts', 'fonts/nested'], 'ZP_STATIC_ASSET_DUPLICATE', ['fonts', 'fonts/nested']),
        ('reversed overlap', ['fonts/nested/', 'fonts/'], 'ZP_STATIC_ASSET_DUPLICATE', ['fonts/nested/', 'fonts/']),
        ('repeated file', ['single.txt', 'single.txt'], 'ZP_STATIC_ASSET_DUPLICATE', ['single.txt']),
        ('glob overlap', ['fonts/**', 'fonts/nested'], 'ZP_STATIC_ASSET_DUPLICATE', ['fonts/**', 'fonts/nested']),
        ('missing', ['missing'], 'ZP_STATIC_ASSET_MISSING', ['missing']),
        ('parent escape', ['../outside.txt'], 'ZP_STATIC_ASSET_INVALID', ['../outside.txt']),
        ('absolute', [str(work/'outside.txt')], 'ZP_STATIC_ASSET_INVALID', ['outside.txt']),
        ('empty', [''], 'ZP_STATIC_ASSET_INVALID', []),
        ('repeated separator', ['fonts//nested'], 'ZP_STATIC_ASSET_INVALID', []),
        ('trailing repeated separator', ['fonts//'], 'ZP_STATIC_ASSET_INVALID', []),
        ('file with slash', ['single.txt/'], 'ZP_STATIC_ASSET_INVALID', []),
        ('dot component', ['fonts/../single.txt'], 'ZP_STATIC_ASSET_INVALID', []),
        ('backslash', ['fonts\\a.woff2'], 'ZP_STATIC_ASSET_INVALID', []),
        ('nul', ['bad\x00path'], 'ZP_STATIC_ASSET_INVALID', []),
        ('missing literal wildcard', ['fonts/*'], 'ZP_STATIC_ASSET_MISSING', []),
        ('empty glob', ['absent/**'], 'ZP_STATIC_ASSET_GLOB_EMPTY', []),
        ('broken symlink', ['broken.txt'], 'ZP_STATIC_ASSET_INVALID', ['broken.txt']),
        ('directory symlink', ['dir-link'], 'ZP_STATIC_ASSET_INVALID', ['dir-link']),
        ('directory symlink ancestor', ['dir-link/nested'], 'ZP_STATIC_ASSET_INVALID', ['dir-link/nested']),
        ('non-file', ['pipe'], 'ZP_STATIC_ASSET_INVALID', ['pipe']),
    ]
    for name, entries, code, mentions in cases:
        for fmt in ['text', 'json']:
            def diagnostic(entries=entries, code=code, mentions=mentions, fmt=fmt):
                sentinel = work/'public/index.html'
                sentinel.write_text('untouched')
                result, positions = run(entries, fmt)
                assert result.returncode != 0, 'invalid selection succeeded'
                assert sentinel.read_text() == 'untouched', 'error detected after page writes'
                if fmt == 'json':
                    rows = [json.loads(line) for line in result.stderr.splitlines()]
                    ds = [d for d in rows if d['code'] == code]
                    assert ds, result.stderr
                    d = ds[0]
                    assert d['file'] and d['file'].endswith('zigapagos.ziggy'), d
                    assert (d['line'], d['col']) == positions[-1], d
                    message = d['message']
                else:
                    assert code in result.stderr, result.stderr
                    assert f'zigapagos.ziggy:{positions[-1][0]}:5:' in result.stderr, result.stderr
                    message = result.stderr
                for mention in mentions:
                    assert mention in message, message
                result, _ = run(entries, fmt, 'validate')
                assert result.returncode != 0, 'validate accepted invalid static assets'
            check(name + ' ' + fmt, diagnostic)
    def collisions():
        (assets/'downloads').mkdir()
        (assets/'downloads/sitemap.xml').write_text('asset')
        # Whole-tree selection must still hit the generated-output collision checks.
        (assets/'sitemap.xml').write_text('asset')
        (assets/'escape.txt').unlink()
        (assets/'broken.txt').unlink()
        result, _ = run(['**'], 'json', extra='.sitemap = true,')
        assert result.returncode != 0, result.stderr
        assert 'ZP_STATIC_ASSET_OUTPUT_COLLISION' in result.stderr, result.stderr
    check('generated output collision retained', collisions)
if failures:
    sys.exit('Failed cases: ' + ', '.join(failures))
PY
