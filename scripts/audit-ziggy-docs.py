#!/usr/bin/env python3
"""Inventory changed documentation examples and extract complete Ziggy documents.

Audit output compares exact UTF-8 bytes with the fork's pre-upgrade base. The
check mode feeds complete documents to the pinned Ziggy parser through the
small docs-ziggy-check build tool; partial/placeholder snippets are inventoried
but are not complete documents. Side-by-side mappings are split into columns.
"""
import argparse
import difflib
import json
from pathlib import Path
import re
import subprocess
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
BASE = 'e8b84cad'
ROOT_DOCS = {'README.md', 'CONTRIBUTING.md', 'CLAUDE.md', 'NO_SLOP.md'}


def examples(text):
    lines = text.splitlines(keepends=True)
    result, occupied = [], set()
    start = None
    for i, line in enumerate(lines):
        match = re.match(r' {0,3}(`{3,}|~{3,})([^\n]*)', line)
        if start is None and match:
            start = i
            fence, info = match.groups()
        elif start is not None and re.match(r' {0,3}' + re.escape(fence[0]) + '{' + str(len(fence)) + r',}\s*$', line):
            result.append(('fence', info.strip(), ''.join(lines[start + 1:i]), start + 2))
            occupied.update(range(start, i + 1))
            start = None
    for i, line in enumerate(lines):
        if i in occupied:
            continue
        for match in re.finditer(r'(`+)(.+?)\1(?!`)', line):
            result.append(('inline', '', match[2], i + 1))
        for match in re.finditer(r'<code(?:\s[^>]*)?>(.*?)</code>', line):
            result.append(('html-code', '', match[1], i + 1))
    return sorted(result, key=lambda e: e[3])


def paths():
    names = subprocess.check_output(['git', 'diff', '--name-only', BASE], cwd=ROOT, text=True).splitlines()
    return [p for p in names if p in ROOT_DOCS or (p.split('/')[0] in {'docs', 'skills', 'site'} and Path(p).suffix in {'.md', '.smd', '.shtml', '.tsx', '.ts'})]


def string_projection(source):
    source = re.sub(r'^\s*\\\\.*$', 'MULTILINE_STRING', source, flags=re.M)
    tokens = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`'
    return re.sub(tokens, lambda match: 'COMMENT' if match[0].startswith(('//', '/*')) else 'STRING', source)


def html_projection(source):
    source = re.sub(r':props=([\'"])[\s\S]*?\1', ':props=ZIGGY', source)
    source = re.sub(r':text=([\'"])[\s\S]*?\1', ':text=SCRIPTY', source)
    return re.sub(r'<!-- \.custom[^\n]*-->', '<!-- ZIGGY -->', source)


def intent(name, example, prior):
    kind, lang, after, _ = example
    if prior is None:
        return 'new upgrade/schema documentation'
    before = prior[2]
    if lang in {'zig', 'ts', 'tsx', 'js', 'javascript', 'typescript'}:
        if string_projection(before) == string_projection(after):
            return 'serialized Ziggy values; surrounding code byte-identical'
    if lang in {'html', 'superhtml', 'markdown'} and html_projection(before) == html_projection(after):
        return 'Ziggy props or Scripty attributes; surrounding markup byte-identical'
    if lang == 'superhtml' and before.replace('$page.author.', "$page.authors.join(' ').") == after:
        return 'Scripty authors array converted to string for String builtins'
    if kind == 'inline':
        if any(term in before for term in ('@date', '.author', 'author', 'Site {', 'Multilingual {', '{', 'frontmatter.ziggy-schema')) or re.search(r'\[[A-Za-z]+\]', before):
            return 'Ziggy syntax/types or schema provisioning reference'
        if (before, after) in {('189d1d5e862e', '7fc62a537ba3'), ('""', '[]'), ('.smd', '.zigapagos.ziggy-schema')}:
            return 'dependency pin, authors default, or schema provisioning reference'
    if '// astro.config.mjs' in before:
        assert [row[:44] for row in before.splitlines()] == [row[:44] for row in after.splitlines()], name
        return 'config mapping; Astro column byte-identical'
    if '// src/pages/post.astro' in before:
        for old, new in zip(before.splitlines(), after.splitlines()):
            field = re.search(r' {2,}(\.[a-z_]+\s*=.*)$', old)
            if field:
                assert old[:field.start(1)] == new[:field.start(1)], name
            else:
                assert old == new, name
        return 'frontmatter mapping; Astro column byte-identical'
    if before.startswith('---') and after.startswith('---'):
        return 'complete Ziggy frontmatter (parser/schema checked)'
    if lang == 'ziggy':
        return 'Ziggy config/value syntax'
    if lang in {'bash', 'sh'}:
        rewritten = before.replace('frontmatter.ziggy-schema', 'src/schemas/page.ziggy-schema').replace('editor-only', 'shipped')
        if rewritten == after:
            return 'schema source path in historical shell commands'
        def remove_heredocs(source):
            return re.sub(r"(<<'?([A-Za-z_]+)'?[^\n]*\n)[\s\S]*?^\2$", r'\1ZIGGY_HEREDOC', source, flags=re.M)
        if remove_heredocs(before) == remove_heredocs(after):
            return 'generated Ziggy in heredocs; shell code byte-identical'
    if kind == 'source':
        if name == 'site/scripts/gen-docs-mirror.ts' and before.replace('`author`', '`authors`') == after:
            return 'comment names the renamed authors field'
        if name == 'site/scripts/md-to-smd.ts':
            return 'intentional Ziggy dictionary emitter and its documented syntax'
    raise AssertionError(f'unclassified non-Ziggy example change: {name}:{example[3]} ({kind}, {lang})')


def units(name, source):
    result = examples(source)
    if Path(name).suffix in {'.shtml', '.tsx', '.ts'}:
        result.insert(0, ('source', 'html' if name.endswith('.shtml') else 'ts', source, 1))
    return result


def audit():
    checked = changed = 0
    reasons = Counter()
    kinds = Counter()
    for name in paths():
        old = subprocess.run(['git', 'show', f'{BASE}:{name}'], cwd=ROOT, text=True, capture_output=True)
        before = units(name, old.stdout) if old.returncode == 0 else []
        after = units(name, (ROOT / name).read_text())
        checked += len(after)
        kinds.update(example[0] for example in after)
        matcher = difflib.SequenceMatcher(a=[x[:3] for x in before], b=[x[:3] for x in after], autojunk=False)
        for op, a, b, c, d in matcher.get_opcodes():
            if op == 'equal':
                continue
            changed += d - c
            for index, example in enumerate(after[c:d]):
                prior = before[a + index] if a + index < b else None
                reason = intent(name, example, prior)
                reasons[reason] += 1
                print(json.dumps({'path': name, 'line': example[3], 'kind': example[0], 'language': example[1], 'reason': reason, 'before': prior[2] if prior else None, 'after': example[2]}, ensure_ascii=False))
    print(json.dumps({'blocks_checked': checked, 'blocks_changed': changed, 'units_by_kind': kinds, 'intended_changes': reasons}))


def documents():
    # Check every current documentation file, including unchanged neighbors.
    names = subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines()
    names += [str(p.relative_to(ROOT)) for p in (ROOT / 'docs').rglob('*.md')]
    for name in sorted(set(names)):
        if name not in ROOT_DOCS and not (name.split('/')[0] in {'docs', 'skills', 'site'} and Path(name).suffix in {'.md', '.smd', '.shtml', '.tsx', '.ts'}):
            continue
        path = ROOT / name
        if not path.exists():
            continue
        for kind, lang, body, line in examples(path.read_text()):
            if kind != 'fence':
                # Inline values containing a complete site envelope are useful
                # syntax examples too; placeholder ellipses are excluded below.
                if '.site = ' not in body or '}' not in body:
                    continue
            candidates = [body]
            if '// astro.config.mjs' in body and '// zigapagos.ziggy' in body:
                # The mapping reserves columns 0..43 for Astro.
                candidates = ['\n'.join(row[44:] for row in body.splitlines()[1:])]
            elif '// src/pages/post.astro' in body:
                right = []
                for row in body.splitlines():
                    field = re.search(r' {2,}(\.[a-z_]+\s*=.*)$', row)
                    if field:
                        right.append(field[1])
                    elif re.search(r' {2,}---\s*$', row):
                        right.append('---')
                candidates = ['\n'.join(right)]
            # Complete configs/frontmatter embedded in shell examples are
            # documents too; parse the heredoc body rather than shell syntax.
            candidates += [match[3] for match in re.finditer(r"(<<'?([A-Za-z_]+)'?[^\n]*\n)([\s\S]*?)^\2$", body, re.M)]
            for source in candidates:
                if '…' in source or '...' in re.sub(r'//[^\n]*', '', source):
                    continue
                # Whole site configs and framed page frontmatter. Bare property
                # snippets (even labeled ziggy) are deliberately not whole sites.
                if re.search(r'^\s*\.site\s*=', source):
                    yield name, line, source
                elif re.search(r'^\s*---\s*$', source, re.M) and '.title' in source and '.layout' in source:
                    frame = re.search(r'^---[^\n]*\n([\s\S]*?)^---\s*$', source, re.M)
                    if frame:
                        yield name, line, frame[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', action='store_true')
    parser.add_argument('--extract', type=Path)
    args = parser.parse_args()
    if args.audit:
        audit()
    if args.extract:
        args.extract.mkdir(parents=True, exist_ok=True)
        count = 0
        for count, (name, line, source) in enumerate(documents(), 1):
            kind = 'config' if re.search(r'^\s*\.site\s*=', source) else 'frontmatter'
            path = args.extract / f'{count}-{kind}.ziggy'
            path.write_text(source)
            print(f'{path}\t{name}:{line}')
        print(f'complete_blocks_extracted={count}')


if __name__ == '__main__':
    main()
