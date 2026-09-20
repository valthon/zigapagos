#!/usr/bin/env bash
# Keep whole-release inventory separate from each page's direct raw-byte cost.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=zig-out/site
REPO="$(cd .. && pwd)"
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"

# Whole-tree limits include unused and lazy bundles. Page limits include local
# directly named resources plus inline executable script bodies; neither metric
# claims compressed transfer size or a complete import/dependency graph.
if ! "$ZIGAPAGOS" inspect-output "$OUT" --format=json \
  --max-html-bytes=2500000 --max-css-bytes=20000 --max-js-bytes=180000 \
  --page=index.html --url-prefix=zigapagos --max-page-js-bytes=61440 \
  > zig-out/output-budget.ndjson; then
  cat zig-out/output-budget.ndjson >&2
  exit 1
fi
# Keep the shared theme script small on a representative documentation page.
if ! "$ZIGAPAGOS" inspect-output "$OUT" --format=json \
  --page=docs/overview/index.html --url-prefix=zigapagos --max-page-js-bytes=1400 \
  > zig-out/docs-output-budget.ndjson; then
  cat zig-out/docs-output-budget.ndjson >&2
  exit 1
fi
python3 - <<'PYREPORT'
import json
from pathlib import Path
reports = [json.loads(line) for line in Path("zig-out/output-budget.ndjson").read_text().splitlines()]
summary = next(report for report in reports if report["type"] == "summary")
print("whole-release raw bytes:", summary["raw_bytes"])
pages = [r for r in reports if r["type"] == "page" and r["path"].startswith("docs/")]
assert pages, "No documentation pages inspected"
for page in pages:
    assert page["reference_coverage"] == "parsed", ("Incomplete docs reference coverage", page)
for report in reports:
    if not report.get("page", "").startswith("docs/"):
        continue
    if report["type"] == "reference":
        assert report["kind"] not in ("script_src", "island_module", "modulepreload", "link_href_unclassified"), report
    if report["type"] == "inline_script":
        assert report["script_type"].strip().lower() != "module", report
for filename in ["output-budget.ndjson", "docs-output-budget.ndjson"]:
    records = [json.loads(line) for line in Path("zig-out", filename).read_text().splitlines()]
    page = next(r for r in records if r["type"] == "page_resources")
    assert page["coverage_complete"], page
    print("page direct-reference raw bytes:", page["raw_bytes"])
print("PASS: aggregate and page budgets, complete direct coverage, and no documentation script bundles")
PYREPORT
