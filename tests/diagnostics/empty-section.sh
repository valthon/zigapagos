#!/usr/bin/env bash
# The scanner unit test observes poisoned timestamps before parsing.
# These real builds pin inactive-subtree semantics and the draft-root container.
# active-pages.sh separately pins errors for direct inactive-index lookups.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ZIGAPAGOS_BIN="${ZIGAPAGOS_BIN:-$ROOT/zig-out/bin/zigapagos}"
export EMPTY_SECTION_FIXTURE="$ROOT/tests/diagnostics/empty-section"
python3 - <<'PY'
import json, os, pathlib, re, resource, shutil, subprocess, tempfile
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
errors = []
for mode in ("flat", "nested", "draft-root"):
    nested = mode != "flat"
    draft_root = mode == "draft-root"
    with tempfile.TemporaryDirectory() as tmp:
        site = pathlib.Path(tmp)/'site'
        shutil.copytree(os.environ['EMPTY_SECTION_FIXTURE'],site)
        if not nested:
            shutil.rmtree(site/'content/empty/nested')
        if draft_root:
            root = site/'content/index.smd'
            root.write_text(root.read_text().replace('.title = "Root",','.title = "Root",\n.draft = true,'))
            # The unpublished root still provides active child lists to other pages.
            leaf = site/'layouts/leaf.shtml'
            extra = ''.join(f'<ul id="root-{name}" :loop="$site.page(\'\').{name}()"><li :text="$loop.it.title"></li></ul>\n'
                            for name in ('subpages','subpagesAlphabetic','leaves'))
            leaf.write_text(leaf.read_text().replace('</body>',extra+'</body>'))
        for command in ('release','validate'):
            for fmt in ('text','json'):
                args = [os.environ['ZIGAPAGOS_BIN'],command,'--format='+fmt]
                if command=='release': args+=['--force','-o','out']
                p = subprocess.run(args,cwd=site,capture_output=True,text=True)
                try:
                    assert p.returncode==0, f'exit {p.returncode}: {p.stderr[:300]}'
                    assert 'panic' not in p.stderr and 'leaked' not in p.stderr, p.stderr
                    if fmt=='json':
                        records=[json.loads(line) for line in p.stderr.splitlines()]
                        assert len(records)==1, records
                        d=records[0]
                        assert d['code']=='ZP_EMPTY_PAGE' and d['severity']=='warning' and d['file']=='content/empty/index.smd',d
                    else:
                        assert "Ignoring empty file 'content/empty/index.smd'" in p.stderr,p.stderr
                    if command=='validate':
                        assert ('2 pages' if draft_root else '3 pages') in p.stdout and '0 errors' in p.stdout,p.stdout
                    else:
                        out=site/'out'
                        expected={'new/index.html','old/index.html'}
                        if not draft_root: expected|={'index.html','page/2/index.html'}
                        actual={str(p.relative_to(out)) for p in out.rglob('*.html')}
                        assert actual==expected, actual
                        if draft_root:
                            for path in expected:
                                html=(out/path).read_text()
                                for name in ('subpages','leaves','subpagesAlphabetic'):
                                    blocks=re.findall(r'<ul[^>]*id="root-'+name+r'"[^>]*>(.*?)</ul>',html,re.S)
                                    titles=re.findall(r'<li>(.*?)</li>',''.join(blocks),re.S)
                                    assert titles==['Newest','Oldest'],(name,html)
                            continue
                        for path,title in [('index.html','Newest'),('page/2/index.html','Oldest')]:
                            html=(out/path).read_text()
                            def items(name):
                                # :loop repeats the UL, so gather all matching elements.
                                blocks=re.findall(r'<ul[^>]*id="'+name+r'"[^>]*>(.*?)</ul>',html,re.S)
                                return re.findall(r'<li>(.*?)</li>',''.join(blocks),re.S)
                            assert items('subpages')==[title],html
                            assert items('alphabetic')==[title],html
                            assert items('leaves')==['Newest','Oldest'],html
                            for name in ('inactive-subpages','inactive-alphabetic','inactive-leaves',
                                         'nested-subpages','nested-subpagesAlphabetic','nested-leaves'):
                                assert items(name)==[],html
                            assert re.search(r'id="items"[^>]*>2</p>',html),html
                            assert re.search(r'id="windows"[^>]*>2</p>',html),html
                            assert 'Hidden' not in html,html
                except (AssertionError,ValueError) as e:
                    errors.append(f'{mode} {command}/{fmt}: {e}')
for error in errors: print('FAIL:',error)
assert not errors,f'{len(errors)} empty-section checks failed'
print('PASS: empty sections stay absent; a draft root preserves its active child container (12 runs)')
PY
