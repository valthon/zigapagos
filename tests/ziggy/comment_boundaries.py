#!/usr/bin/env python3
"""Generate comment insertions at every legacy-token boundary, then upgrade twice.

For this representative subset, legacy tokens are identifiers, quoted strings,
integers, and separate punctuation (including '.' and '@'). The old tokenizer
skips line comments, and Parser.nextMust imposes no token adjacency requirement:
all these boundaries legally accept comments. We never split an identifier,
number, string or existing comment. A comment token includes its terminating
newline so inserting after one cannot append to the existing comment's text.
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
UPGRADE = ROOT / 'scripts/upgrade-ziggy.py'
LEGACY_TOKEN = re.compile(r'//[^\n]*(?:\n|$)|"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|-?\d+|[@.={\}\[\](),:]')
BODY = b'- body stays byte-identical\r\n```ziggy\r\n.author = "body", @date("body")\r\n```\r\n'
SITE_FIELDS = '''.title = "Example", .host_url = "https://example.com",
.content_dir_path = "content", .layouts_dir_path = "layouts", .assets_dir_path = "assets",'''
FRONT_FIELDS = '''.title = "Page", .layout = "page.shtml", .author = "Jane",
.pagination = { .page_size = 2, .url_style = "plain_dir" },
.custom = { .nested = { .count = 42, .list = [{ .label = "one" }, { .label = "two" }] } },'''
CASES = {
    'simple': ('config', 'Site {\n' + SITE_FIELDS + '\n}'),
    'multilingual': ('config', '''Multilingual {
.host_url = "https://example.com", .i18n_dir_path = "i18n",
.layouts_dir_path = "layouts", .assets_dir_path = "assets",
.locales = [{ .code = "en-US", .name = "English", .site_title = "Example", .content_dir_path = "en" },
            { .code = "it-IT", .name = "Italiano", .site_title = "Esempio", .content_dir_path = "it" }],
}'''),
    'custom': ('config', 'Site {\n' + SITE_FIELDS + '\n.custom = { .brand = "Acme", .nested = { .active = true } },\n}'),
    'tagged-frontmatter': ('frontmatter', '.date = @date("2024-01-01"),\n' + FRONT_FIELDS),
    'quoted-frontmatter': ('frontmatter', '.date = "2024-01-01",\n' + FRONT_FIELDS),
    'braced-frontmatter': ('frontmatter', '{\n.date = @date("2024-01-01"),\n' + FRONT_FIELDS + '\n}'),
}


def comments(data):
    return [token[0].encode() for token in LEGACY_TOKEN.finditer(data.decode()) if token[0].startswith('//')]


def document(data, kind):
    if kind == 'config':
        return data
    return b'---\n' + data + b'\n---\n' + BODY


def frontmatter(data):
    return data.split(b'\n---\n', 1)[0][4:]


def main():
    work = Path(sys.argv[1])
    failures = []
    parser_files = []
    variants = positions = 0

    def check(label, source, kind, expected_tokens):
        actual_tokens = [token[0] for token in LEGACY_TOKEN.finditer(source) if not token[0].startswith('//')]
        # The legacy parser skips comments between these separate tokens.
        # Equal token streams preserve the baseline's grammar at every gap.
        assert actual_tokens == expected_tokens, f'{label}: insertion changed legacy tokens'
        original = document(source.encode(), kind)
        path = work / (label + ('.ziggy' if kind == 'config' else '.smd'))
        path.write_bytes(original)
        first = subprocess.run([sys.executable, str(UPGRADE), str(path)], capture_output=True)
        if first.returncode != 0:
            failures.append(f'{label}: first conversion exited {first.returncode}: {first.stderr.decode().strip()}')
            return
        converted = path.read_bytes()
        old_region = original if kind == 'config' else frontmatter(original)
        new_region = converted if kind == 'config' else frontmatter(converted)
        # Count, text, order and terminating newlines must all survive exactly.
        if comments(old_region) != comments(new_region):
            failures.append(f'{label}: changed/moved comment or lost its terminating newline')
        if kind == 'frontmatter' and converted.split(b'\n---\n', 1)[1] != BODY:
            failures.append(f'{label}: changed Markdown body bytes')
        parser_path = work / f'{label}-{kind}.ziggy'
        parser_path.write_bytes(new_region)
        parser_files.append(str(parser_path))
        second = subprocess.run([sys.executable, str(UPGRADE), str(path)], capture_output=True)
        if second.returncode != 0 or path.read_bytes() != converted:
            failures.append(f'{label}: second conversion exited {second.returncode} or changed bytes')

    for name, (kind, content) in CASES.items():
        source = '// original header: preserve me\n' + content + '\n// original footer: preserve me\n'
        tokens = list(LEGACY_TOKEN.finditer(source))
        cursor = 0
        for token in tokens:
            assert source[cursor:token.start()].isspace() or token.start() == cursor, (name, source[cursor:token.start()])
            cursor = token.end()
        assert not source[cursor:].strip(), name
        boundaries = [0] + [token.end() for token in tokens]
        expected_tokens = [token[0] for token in tokens if not token[0].startswith('//')]
        check(name + '-baseline', source, kind, expected_tokens)
        positions += len(boundaries)
        for index, boundary in enumerate(boundaries):
            marker = f' // inserted {name}/{index}: @date("literal") .author = "literal" café\n'
            check(f'{name}-{index}', source[:boundary] + marker + source[boundary:], kind, expected_tokens)
            variants += 1
        # Also cover interactions among all boundaries, not just one insertion.
        together = source
        for index, boundary in reversed(list(enumerate(boundaries))):
            together = together[:boundary] + f' // combined {name}/{index}\n' + together[boundary:]
        check(name + '-combined', together, kind, expected_tokens)
        variants += 1

    (work / 'parser-files').write_text('\n'.join(parser_files) + '\n')
    print(f'Comment boundary sweep: {variants} variants ({positions} single insertions + {len(CASES)} combined), {len(CASES)} baselines; skipped 0 positions.')
    print('Skip rationale: every chosen legacy-token boundary permits comments; no insertion splits an indivisible identifier, number, quoted string or comment/newline.')
    for failure in failures[:12]:
        print('FAIL:', failure)
    print(f'Comment/CLI/idempotence failures: {len(failures)}; converted documents submitted to the new parser: {len(parser_files)}')
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
