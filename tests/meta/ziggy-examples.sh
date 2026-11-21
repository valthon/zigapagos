#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 scripts/audit-ziggy-docs.py --extract "$work" > "$work/manifest"
mapfile -t files < <(cut -f1 "$work/manifest" | sed '/^complete_blocks_extracted=/d')
test "${#files[@]}" -gt 0
zig build docs-ziggy-check -- "${files[@]}"
# Prove this check rejects the missing union close from the config mapping.
python3 - "${files[0]}" "$work/bad-config.ziggy" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert '})' in source
Path(sys.argv[2]).write_text(source.replace('})', '}', 1))
PYTHON
if zig build docs-ziggy-check -- "$work/bad-config.ziggy" > "$work/negative.log" 2>&1; then
  echo 'FAIL: docs checker accepted an unclosed config union'; exit 1
fi
grep -q 'missing token' "$work/negative.log"
echo "PASS: ${#files[@]} complete documentation configs/frontmatter parse and match shipped schemas"
