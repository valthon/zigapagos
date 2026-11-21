#!/usr/bin/env python3
"""Upgrade Ziggy site configs and SuperMD frontmatter in place (Python 3).

Only frontmatter bytes, including its delimiters, are changed in .smd files.
Commit your site first and review the diff after running this tool.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

# Strings, multiline strings and comments are indivisible: syntax-looking text
# inside them must survive conversion byte for byte (apart from prefix CRLF).
TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|\\\\[^\n]*|//[^\n]*|\s+|@[A-Za-z_]\w*|\.[A-Za-z_]\w*|[A-Za-z_]\w*|.', re.S)


def convert_document(source, *, frontmatter=False):
    tokens = TOKEN.findall(source.replace('\r\n', '\n'))
    significant = [i for i, t in enumerate(tokens) if not t.isspace() and not t.startswith('//')]
    # Legacy '.'/'@' and identifiers were separate tokens, so comments may
    # separate them. Attach the prefix to the identifier's slot, leaving every
    # intervening whitespace/comment token in place. New Ziggy identifiers and
    # union cases must be lexically contiguous.
    for prefix, name in zip(significant, significant[1:]):
        if tokens[prefix] in ('.', '@') and re.fullmatch(r'[A-Za-z_]\w*', tokens[name]):
            tokens[name] = tokens[prefix] + tokens[name]
            tokens[prefix] = ''
    significant = [i for i in significant if tokens[i]]
    following = {a: b for a, b in zip(significant, significant[1:])}
    previous = {b: a for a, b in zip(significant, significant[1:])}
    stack = []
    root_opening = None
    if significant:
        if tokens[significant[0]] == '{':
            root_opening = significant[0]
        elif len(significant) > 1 and tokens[significant[0]] == '.' and tokens[significant[1]] == '{':
            root_opening = significant[1]
    # (opening token, dictionary converted from old .custom struct)
    config_close = None
    def pagination_record():
        if not stack:
            return False
        assignment = previous.get(stack[-1][0])
        if assignment is not None and tokens[assignment] == '.':
            assignment = previous.get(assignment)
        field = previous.get(assignment)
        at_root = len(stack) == 1 or (len(stack) == 2 and stack[0][0] == root_opening)
        return at_root and assignment is not None and tokens[assignment] == '=' and field is not None and tokens[field] == '.pagination'

    for i in significant:
        t = tokens[i]
        before = tokens[previous[i]] if i in previous else ''
        after = tokens[following[i]] if i in following else ''
        if t in ('Site', 'Multilingual') and after == '{' and i == significant[0]:
            tokens[i] = '.site = .' + ('simple' if t == 'Site' else 'multilingual') + '('
            config_close = following[i]
        elif t == '@date':
            # Comments may also separate the old tag name and '('. Write the
            # entire new union-case token in the paren's slot; do not move the
            # comments or erase the newlines that terminate them.
            opening = following.get(i)
            if opening is None or tokens[opening] != '(':
                raise ValueError('@date must be followed by an opening parenthesis')
            tokens[i] = ''
            tokens[opening] = '.date('
        elif frontmatter and t == '.url_style' and after == '=' and pagination_record():
            value = following.get(following[i])
            if value is not None and tokens[value] in ('"page_dir"', '"plain_dir"', '"page_html"'):
                tokens[value] = '.' + tokens[value][1:-1]
        elif frontmatter and t == '.date' and after == '=' and (not stack or (config_close is None and len(stack) == 1 and stack[0][0] == root_opening)):
            value = following.get(following[i])
            if value is not None and tokens[value].startswith('"'):
                tokens[value] = '.date(' + tokens[value] + ')'
        elif frontmatter and t == '.author' and after == '=' and (not stack or (config_close is None and len(stack) == 1 and stack[0][0] == root_opening)):
            eq = following[i]
            value = following.get(eq)
            if value is None or not tokens[value].startswith('"'):
                raise ValueError('.author must be a string; convert it to .authors manually')
            tokens[i] = '.authors'
            tokens[value] = '[]' if tokens[value] == '""' else '[' + tokens[value] + ']'
        elif t == '{':
            # The old custom record is a dictionary in the new schema.
            prevprev = previous.get(previous.get(i))
            custom = before == '=' and prevprev is not None and tokens[prevprev] == '.custom'
            old_struct = after.startswith('.') and after != '.{'
            stack.append((i, custom and old_struct))
            if i == config_close or (old_struct and not custom and before != '.'):
                tokens[i] = '.{'
        elif t == '}':
            if not stack:
                raise ValueError('unbalanced closing brace')
            opening, _ = stack.pop()
            if opening == config_close:
                tokens[i] = '})'
        elif stack and stack[-1][1] and t.startswith('.') and after == '=':
            tokens[i] = json.dumps(t[1:])
            tokens[following[i]] = ':'
    if stack:
        raise ValueError('unclosed brace')
    return ''.join(tokens)


def convert_file(path):
    if path.suffix not in ('.smd', '.ziggy'):
        raise ValueError('expected a .smd or .ziggy file')
    original = path.read_bytes()
    if path.suffix == '.smd':
        # Match complete delimiter lines. Preserve every byte after the closing
        # delimiter's newline, including body CRLF and old syntax in code fences.
        opening = re.match(rb'[ \t\r\n]*---[^\r\n]*\r?\n', original)
        if not opening:
            raise ValueError('frontmatter has no opening delimiter; put --- before any comments or body')
        closing = re.search(rb'^---[^\r\n]*(?:\r?\n|$)', original[opening.end():], re.M)
        if not closing:
            raise ValueError('frontmatter has no closing delimiter')
        end = opening.end() + closing.end()
        prefix = original[:opening.end()].replace(b'\r\n', b'\n')
        document_end = opening.end() + closing.start()
        document = original[opening.end():document_end].decode('utf-8')
        suffix = original[document_end:end].replace(b'\r\n', b'\n')
        result = prefix + convert_document(document, frontmatter=True).encode('utf-8') + suffix + original[end:]
    else:
        result = convert_document(original.decode('utf-8')).encode('utf-8')
    if result == original:
        return False
    path.write_bytes(result)
    return True


def files(paths):
    ignored = {'.git', '.zig-cache', 'zig-pkg', 'zig-out', 'node_modules', 'public', '.zigapagos-cache'}
    for path in paths:
        if path.is_symlink():
            continue
        if path.is_file():
            yield path
        else:
            for base, dirs, names in os.walk(path):
                dirs[:] = sorted(d for d in dirs if d not in ignored and not (Path(base) / d).is_symlink())
                for name in sorted(names):
                    p = Path(base) / name
                    if p.suffix in ('.ziggy', '.smd') and not p.is_symlink():
                        yield p


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+', type=Path, help='site directory or .ziggy/.smd files')
    args = parser.parse_args()
    failed = False
    for path in files(args.paths):
        try:
            if not path.exists():
                raise ValueError('path does not exist')
            if convert_file(path):
                print(path)
        except (ValueError, OSError, UnicodeError) as error:
            print(f'{path}: {error}', file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
