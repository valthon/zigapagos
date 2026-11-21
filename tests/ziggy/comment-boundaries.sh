#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
conversion_rc=0
python3 tests/ziggy/comment_boundaries.py "$work" > "$work/conversion.log" 2>&1 || conversion_rc=$?
cat "$work/conversion.log"
mapfile -t files < "$work/parser-files"
test "${#files[@]}" -gt 0
parser_rc=0
zig build docs-ziggy-check -- "${files[@]}" > "$work/parser.log" 2>&1 || parser_rc=$?
if [[ $parser_rc != 0 ]]; then sed -n '1,18p' "$work/parser.log"; else cat "$work/parser.log"; fi
printf 'Comment sweep exits: converter/assertions=%s, new parser/schema=%s\n' "$conversion_rc" "$parser_rc"
test "$conversion_rc" -eq 0
test "$parser_rc" -eq 0
