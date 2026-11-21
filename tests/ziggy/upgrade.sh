#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path
convert = runpy.run_path('scripts/upgrade-ziggy.py')['convert_document']
file_convert = runpy.run_path('scripts/upgrade-ziggy.py')['convert_file']
old = '''Site {
 .title = "Site { @date( untouched",
 // @date("comment") stays unchanged
 .custom = { .label = "x", .nested = { .a = 1 } },
}'''
new = convert(old)
assert new.startswith('.site = .simple( .{') and new.endswith('})')
assert '"label" : "x"' in new and '.nested' not in new
assert '"nested" : .{ .a = 1 }' in new
assert '"Site { @date( untouched"' in new
assert '// @date("comment") stays unchanged' in new
assert convert(new) == new
assert convert('Multilingual { .locales = [{ .code = "en" }] }') == '.site = .multilingual( .{ .locales = [.{ .code = "en" }] })'
assert convert('.author = "Jane", .date = @date("2024-01-01"),', frontmatter=True) == '.authors = ["Jane"], .date = .date("2024-01-01"),'
assert convert('{ .author = "Jane", .layout = "x" }', frontmatter=True) == '.{ .authors = ["Jane"], .layout = "x" }'
assert convert('.author = "",', frontmatter=True) == '.authors = [],'
assert convert('.custom = { "k": [.{ .a = 1 }] },') == '.custom = { "k": [.{ .a = 1 }] },'
assert convert('.pagination = { .page_size = 2, .url_style = "plain_dir" },', frontmatter=True) == '.pagination = .{ .page_size = 2, .url_style = .plain_dir },'
assert convert('.author = "data", .url_style = "plain_dir",') == '.author = "data", .url_style = "plain_dir",'
assert convert('.{ .author = "Jane" }', frontmatter=True) == '.{ .authors = ["Jane"] }'
assert convert('.custom = { .url_style = "plain_dir", .author = "data" },', frontmatter=True) == '.custom = { "url_style" : "plain_dir", "author" : "data" },'
for source in ('.date = "2024-01-01",', '.{ .date = "2024-01-01" }'):
    upgraded = convert(source, frontmatter=True)
    assert '.date = .date("2024-01-01")' in upgraded
    assert convert(upgraded, frontmatter=True) == upgraded
assert convert('.custom = { "date": "2024-01-01" },', frontmatter=True) == '.custom = { "date": "2024-01-01" },'
assert convert('.date = "data",') == '.date = "data",'
with tempfile.TemporaryDirectory() as directory:
    p = Path(directory) / 'page.smd'
    body = b'- list first\r\n```ziggy\r\n.author = "body", @date("body")\r\n```\r\n'
    p.write_bytes(b'---\r\n.title = "T",\r\n.author = "Jane",\r\n---\r\n' + body)
    assert file_convert(p)
    once = p.read_bytes()
    assert once == b'---\n.title = "T",\n.authors = ["Jane"],\n---\n' + body
    assert not file_convert(p) and p.read_bytes() == once
    p = Path(directory) / 'zigapagos.ziggy'
    p.write_bytes(b'Site {\r\n .title = "T",\r\n}\r\n')
    assert file_convert(p) and b'\r' not in p.read_bytes()
    assert not file_convert(p)
with tempfile.TemporaryDirectory() as directory:
    for source, reason in [(b'Body', 'opening'), (b'// comment\n---\n.title = "T"\n---\n', 'opening'), (b'---\n.title = "T"', 'closing')]:
        p = Path(directory) / 'declined.smd'
        p.write_bytes(source)
        result = subprocess.run([sys.executable, 'scripts/upgrade-ziggy.py', str(p)], capture_output=True, text=True)
        assert result.returncode != 0, result
        assert str(p) in result.stderr and reason in result.stderr, result.stderr
        assert p.read_bytes() == source
print('PASS: Ziggy converter (idempotence, literals, nested values, CRLF, body preservation)')
PY
