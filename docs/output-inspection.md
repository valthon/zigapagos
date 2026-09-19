# Inspecting and budgeting emitted output

`zigapagos inspect-output` inventories an existing output directory without
building, modifying files, starting Bun, or making network requests:

```sh
zigapagos release
zigapagos inspect-output public
zigapagos inspect-output public --format=json \
  --max-html-bytes=2500000 --max-css-bytes=20000 --max-js-bytes=180000
```

Limits are optional nonnegative decimal integers in **bytes**, not rounded
kilobytes. Equality passes; one byte over a configured limit fails with exit 1.
No limits are applied by default. A failed inventory also exits 1; missing,
empty, unscannable, and symlink-containing trees cannot report a successful
zero-byte result. Unreadable HTML fails rather than silently losing page coverage. Supply an output directory containing at least one
HTML page. HTML files over 16 MiB are rejected rather than partially parsed.

## What is measured

The command counts the size of every regular `.html`, `.htm`, `.css`, `.js`,
`.mjs`, and `.cjs` file, with case-insensitive extensions. Each emitted path is
counted once. Images, fonts, source maps, and precompressed `.gz`/`.br` copies
are outside these totals. JavaScript files count even when no HTML page directly
references them: lazy chunks, unused bundles, and CommonJS output all contribute
to the emitted-JavaScript budget.

These are **raw on-disk bytes**, not compressed transfer sizes, initial-page
cost, execution time, or a browser performance score. Inline scripts contribute
to HTML bytes, not the JavaScript-file total. A zero JavaScript-file budget does
not prove a page executes no JavaScript: inspect its inline-script and reference
records too. External scripts never contribute to file totals.

## Page references

For each HTML page, the report lists literal `script src`, `data-z-module`
(island module), and `link rel=modulepreload` attributes in document order. It
also counts inline JavaScript elements separately from data/other script
blocks, such as `application/json` props and import maps. JSON reports preserve
the explicit script type and legacy language attribute for inline scripts.
Entity-encoded `type`, `language`, or `rel` attributes are not guessed: an inline
script is counted as unclassified (`javascript: null`), and a link keeps its
href as a `link_href_unclassified` reference. The page reports the number of
elements with encoded classification attributes and partial reference coverage.

If SuperHTML reports syntax errors (including missing end tags), the page is
marked `reference_coverage: "partial"` and its references are best-effort. This
does not invalidate raw file sizes or aggregate budgets: browsers can tolerate
markup this parser rejects. Require zero `pages_with_partial_references` if your
consumer needs the parser to accept every page; even parsed references are not a
browser dependency graph.

The counts describe markup, not whether the browser will execute a script
under its CSP, `nomodule`, or other conditions.

References are **not resolved or fetched**. Duplicate references remain visible;
no per-route byte total or load timing is inferred. Import maps, dynamic imports,
CSS imports, and module dependency graphs are not traversed. A script with a
non-JavaScript `type` can still have a `src` attribute in the report; its presence
alone does not establish a network request.

`url_scope` distinguishes local-looking URLs from scheme or `//` URLs;
backslashes and entity-containing URLs are `unclassified`. Attribute strings
are not HTML-entity decoded. A page with `<base href>` is explicitly marked:
its local-looking URLs may resolve to another origin. None of these references
are included as extra bytes in the inventory or certified as valid links.
Run `zigapagos doctor public --strict` separately for its supported local-link
checks, then test actual routes in the browser.

## JSON contract

`--format=json` emits NDJSON on stdout in sorted file-path order. Each record has
a `type` discriminator:

- `asset`: `kind` (`html`, `css`, or `js`), `path`, and `raw_bytes`.
- `reference`: `page`, `kind` (`script_src`, `island_module`, `modulepreload`, or `link_href_unclassified`),
  literal `url`, `script_type`, `url_scope`, and `resolution: "not_resolved"`.
- `inline_script`: `page`, `script_type`, `language`, and nullable `javascript` (null means unclassified).
- `page`: `path`, reference count, `inline_javascript_elements`,
  `inline_other_script_elements`, `inline_unclassified_script_elements`,
  `encoded_classification_elements`, `has_base_href`, `reference_coverage`
  (`parsed` or `partial`), nullable `html_parser_first_error`, and its zero-based
  `html_parser_first_error_byte` offset.
- `budget`: `kind`, `raw_bytes`, `max_bytes`, and `passed`, for each set limit.
- `summary`: final totals and scope, shown below.

```json
{"type":"summary","raw_bytes":{"html":420,"css":80,"js":0},"files":2,"pages":1,"references":0,"pages_with_partial_references":0,"budgets_exceeded":0,"measurement":"raw_file_bytes","scope":"all_emitted_html_css_js","external_resources_measured":false,"import_graph_measured":false,"references_resolved":false,"inline_script_bytes_in":"html"}
```

A complete report ends with exactly one summary, including when a budget fails.
Read failures can leave a partial stdout report without a summary; check the
exit status and require the summary before consuming totals. Fatal diagnostics
use `ZP_FATAL` NDJSON on stderr. Text mode uses the same measurements and limits.

The repository's site gate uses aggregate budgets alongside its separate
landing-page reference budget. These answer different questions: how much the
release emits, and which bundles that particular page directly names.
