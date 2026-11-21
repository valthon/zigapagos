"""Check both directions of each structural relationship, without source edits."""
from pathlib import Path
import subprocess
import sys
import tempfile

(
    (checker, source), (optional_checker, optional_source),
    (dynamic_checker, dynamic_source), (bytes_checker, bytes_source),
    (collection_checker, collection_source), (dictionary_checker, dictionary_source),
    (config_checker, config_source), (page_checker, page_source),
) = zip(sys.argv[1::2], sys.argv[2::2])
base = Path(source).read_text()
optional_base = Path(optional_source).read_text()
# Mutate only schema text; the binaries always reflect the real fixture types.
# Keep the label list in sync with docs/testing.md's coverage inventory.
cases = [
    ("root union declaration", "$ = Record", "$ = Choice"),
    ("root enum declaration", "$ = Record", "$ = Members"),
    ("root bool", "$ = Record", "$ = bool"),
    ("root int", "$ = Record", "$ = int"),
    ("root float", "$ = Record", "$ = float"),
    ("root missing", "$ = Record\n", ""),
    ("duplicate root", "$ = Record", "$ = Record\n$ = Record"),
    ("root unparsed token", "$ = Record", "$ = Record int"),
    ("nested unreferenced declaration", "    label: bytes,\n}", "    label: bytes,\n    struct Unused { value: int, }\n}"),
    ("bytes cannot be an integer list", "label: bytes,", "label: []int,"),
    ("unparsed expression suffix", "required: int,", "required: int bool,"),
    ("root scalar bytes", "$ = Record", "$ = bytes"),
    ("root optional", "$ = Record", "$ = ?Record"),
    ("root list", "$ = Record", "$ = []Record"),
    ("root dictionary", "$ = Record", "$ = {:}Record"),
    ("root any", "$ = Record", "$ = any"),
    ("root unknown reference", "$ = Record", "$ = Unknown"),
    ("field only in Zig", "    required: int,\n", ""),
    ("field only in schema", "struct Record {", "struct Record {\n    extra: int,"),
    ("skipped Zig field in schema", "struct Record {", "struct Record {\n    hidden: bool,"),
    ("schema optional, Zig required", "required: int,", "required: ?int,"),
    ("schema required, Zig optional", "optional: ?int,", "optional: int,"),
    ("union payload only in Zig", "payload: int,", "payload,"),
    ("union payload only in schema", "    empty,", "    empty: int,"),
    ("union case only in Zig", "    empty,\n", ""),
    ("union case only in schema", "union Choice {", "union Choice {\n    extra,"),
    ("enum member only in Zig", "    second,\n", ""),
    ("enum member only in schema", "union Members {", "union Members {\n    third,"),
    ("enum member gains payload", "    first,", "    first: int,"),
    ("union payload becomes optional", "payload: int,", "payload: ?int,"),
    ("optional union payload becomes required", "nullable: ?int,", "nullable: int,"),
    ("list element kind", "list: []int,", "list: []bool,"),
    ("list becomes named container", "list: []int,", "list: Nested,"),
    ("exported type missing from schema", "union Choice {", "union Other {"),
    ("list element becomes container", "list: []int,", "list: []Nested,"),
    ("dictionary element becomes container", "dictionary: {:}int,", "dictionary: {:}Nested,"),
    ("list becomes scalar", "list: []int,", "list: int,"),
    ("scalar becomes list", "required: int,", "required: []int,"),
    ("dictionary element kind", "dictionary: {:}int,", "dictionary: {:}bool,"),
    ("dictionary becomes list", "dictionary: {:}int,", "dictionary: []int,"),
    ("list becomes dictionary", "list: []int,", "list: {:}int,"),
    ("nested field only in Zig", "    label: bytes,\n", ""),
    ("nested field only in schema", "struct Nested {", "struct Nested {\n    extra: bool,"),
    ("nested field scalar kind", "label: bytes,", "label: int,"),
    ("nested struct becomes union", "struct Nested {", "union Nested {"),
    ("union becomes struct", "union Choice {\n    payload: int,\n    empty,\n    nullable: ?int,", "struct Choice {\n    payload: int,\n    empty: bool,\n    nullable: ?int,"),
    ("enum becomes struct", "union Members {\n    first,\n    second,", "struct Members {\n    first: int,\n    second: int,"),
    ("nested struct becomes scalar", "nested: Nested,", "nested: bytes,"),
    ("scalar becomes nested struct", "required: int,", "required: Nested,"),
    ("scalar int becomes bool", "required: int,", "required: bool,"),
    ("scalar bool becomes int", "defaulted: ?bool,", "defaulted: ?int,"),
]
# Exercise every ordered pair of scalar kinds, retaining field optionality.
for field, kind in [("required", "int"), ("defaulted", "bool"), ("label", "bytes"), ("ratio", "float")]:
    prefix = "?" if field == "defaulted" else ""
    for other in ["int", "bool", "bytes", "float"]:
        if other != kind:
            cases.append((f"scalar {kind} versus {other}", f"{field}: {prefix}{kind},", f"{field}: {prefix}{other},"))
optional_cases = [
    ("optional list element kind", "list: ?[]int,", "list: ?[]bool,"),
    ("optional dictionary element kind", "dictionary: ?{:}int,", "dictionary: ?{:}bool,"),
    ("optional custom list element kind", "custom_list: ?[]int,", "custom_list: ?[]bool,"),
    ("optional list becomes required", "list: ?[]int,", "list: []int,"),
    ("optional dictionary becomes required", "dictionary: ?{:}int,", "dictionary: {:}int,"),
    ("optional nested becomes required", "nested: ?Nested,", "nested: Nested,"),
    ("optional nested field kind", "label: bytes,", "label: bool,"),
]
failures = []
with tempfile.TemporaryDirectory(prefix="schema-agreement-") as tmp:
    path = Path(tmp)/"case.ziggy-schema"

    def run(name, binary, text, expected, diagnostic=None):
        path.write_text(text)
        result = subprocess.run([binary, str(path)], capture_output=True, text=True)
        # A compiler error, signal or panic is not a successful rejection.
        ok = result.returncode == expected and (diagnostic is None or diagnostic in result.stderr)
        print(f'{"PASS" if ok else "FAIL"}: {name} (exit {result.returncode}, expected {expected})')
        if not ok:
            failures.append(name)
            print(result.stderr)

    run("matching fields, defaults, required slices, union and enum", checker, base, 0)
    for name, old, new in cases:
        assert base.count(old) == 1, (name, old)
        diagnostic = "unreferenced declaration or expression" if name == "nested unreferenced declaration" else None
        run(name, checker, base.replace(old, new), 1, diagnostic)
    for label, suffix in [
        ("unreferenced struct declaration", "\nstruct Unused { field: int, }"),
        ("unreferenced union declaration", "\nunion Unused { payload: int, }"),
        ("unreferenced enum declaration", "\nunion Unused { first, second, }"),
        ("unknown declaration syntax", "\nenum Unknown { first, }"),
        ("unknown reference in unused declaration", "\nstruct Unused { field: Unknown, }"),
        ("unparsed trailing line", "\nthis line is not a declaration"),
        ("embedded NUL hiding a declaration", "\x00\nstruct Hidden { field: int, }"),
    ]:
        diagnostic = "unreferenced declaration or expression" if label.startswith("unreferenced ") else "not checked"
        run(label, checker, base + suffix, 1, diagnostic)
    run("matching optional builtin/custom containers", optional_checker, optional_base, 0)
    for name, old, new in optional_cases:
        # Match complete lines: custom_list must not match list.
        old, new = "    "+old, "    "+new
        assert optional_base.count(old) == 1, (name, old)
        run(name, optional_checker, optional_base.replace(old, new), 1)
    # Non-named document roots use the same expression walker as fields.
    for expression in ["any", "[]any", "{:}any", "[]{:}any", "{:}[]any"]:
        run("dynamic root compatibility " + expression, dynamic_checker, "$ = " + expression, 0)
    for expression in ["int", "bytes", "bool", "float", "{:}int", "[]bytes"]:
        run("dynamic root narrowed leaf " + expression, dynamic_checker, "$ = " + expression, 1, "not checked")
    run("dynamic root named declaration", dynamic_checker, "$ = Narrow\nstruct Narrow { value: any, }", 1, "not checked")
    run("byte-string root", bytes_checker, Path(bytes_source).read_text(), 0)
    run("byte-string root cannot become list", bytes_checker, "$ = []int", 1)
    run("optional-list root", collection_checker, Path(collection_source).read_text(), 0)
    run("optional-list root loses optional", collection_checker, "$ = []int", 1)
    run("dictionary root", dictionary_checker, Path(dictionary_source).read_text(), 0)
    run("dictionary root wrong child", dictionary_checker, "$ = {:}bool", 1)
    real_cases = [
        ("real Config", config_checker, Path(config_source).read_text(), [
            ("reported root bytes", "$ = Config", "$ = bytes"),
            ("reported root Simple", "$ = Config", "$ = Simple"),
            ("union loses payload", "    simple: Simple,", "    simple,"),
            ("scalar kind", "    title: bytes,", "    title: bool,"),
            ("field only in Zig", "    title: bytes,\n", ""),
            ("field only in schema", "struct Simple {", "struct Simple {\n    extra: int,"),
        ]),
        ("real Page date", page_checker, Path(page_source).read_text(), [
            ("narrowed any integer", "    custom: {:}any,", "    custom: {:}int,"),
            ("narrowed any bytes", "    custom: {:}any,", "    custom: {:}bytes,"),
            ("narrowed any reference", "    custom: {:}any,", "    custom: {:}Alternative,"),
            ("narrowed any float", "    custom: {:}any,", "    custom: {:}float,"),
            ("narrowed any bool", "    custom: {:}any,", "    custom: {:}bool,"),
            ("union becomes scalar", "    date: ?Date,", "    date: ?bytes,"),
            ("date payload kind", "        date: bytes,", "        date: bool,"),
            ("unix payload kind", "        unix: int,", "        unix: bytes,"),
            ("case only in Zig", "        date: bytes,\n", ""),
            ("case only in schema", "    union Date {", "    union Date {\n        extra: int,"),
            ("union loses payload", "        date: bytes,", "        date,"),
        ]),
    ]
    for label, binary, text, mutations in real_cases:
        run(label + " matching schema", binary, text, 0)
        for name, old, new in mutations:
            assert text.count(old) == 1, (label, name, old)
            run(label + " " + name, binary, text.replace(old, new), 1)
if failures:
    sys.exit("Schema agreement failures: " + ", ".join(failures))
