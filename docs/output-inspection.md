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

The default reference records are **not resolved or fetched**. Use `--page`
for the additional bounded local resolution report described below. Duplicate references remain visible;
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

## Direct resources of one emitted page

Use `--page` to measure one emitted HTML file's directly named resources and
inline bodies, with independent opt-in page limits:

```sh
zigapagos inspect-output public --page=index.html --url-prefix=project \
  --max-page-js-bytes=61440 --max-page-css-bytes=20000 --format=json
```

`--page` is a path **inside the output directory**, such as `docs/index.html`;
it is not a browser route or URL. `--url-prefix` describes where that directory
is deployed. Page limits and nonempty URL prefixes require `--page`. The full
output inventory and aggregate limits continue to include every emitted file.

The metric is `direct_reference_raw_bytes`. JavaScript includes regular local
files named by executable `script src`, `data-z-module`, and `modulepreload`,
plus the UTF-8 bytes between the opening and closing tags of executable inline
`script` elements. CSS includes local `link rel=stylesheet` files plus inline
`style` bodies. Tag bytes, data scripts, and import-map JSON remain in aggregate
HTML bytes. Inline event-handler attributes and `style` attributes are **not**
part of these page metrics. Non-JavaScript scripts and non-CSS style elements
are excluded.

A local resource's kind comes from its referencing element, not its filename
extension: a script at `/bundle` contributes to page JS even though an
extensionless file is outside the aggregate `.js` inventory. Repeated references
are deduplicated **by normalized output path within each kind**. Dot-segment,
percent-encoded filename, query-string, and fragment aliases of the same file
count once. This is neither a network request count nor a browser cache-key
model; different query strings can cause separate browser fetches.

URLs resolve relative to the emitted HTML directory. Root-relative references
must remain within `--url-prefix`; ordinary parent traversal is normalized
before the prefix is removed. Encoded slashes, backslashes, control bytes,
entity-encoded path characters, and paths climbing above the URL root are
rejected rather than guessed. Query strings and fragments do not affect file
sizes. Files are required to exist exactly at the resolved path; host rewrites
and directory-index fallback for script/style requests are not assumed.

**Incomplete direct coverage fails every requested page budget**, even if
known bytes fit. This includes external URLs, missing targets, unsupported
encodings, `<base href>`, and partial HTML/classification coverage. An external
stylesheet also prevents a JavaScript page budget from passing: coverage is a
conservative property of the selected page, not a per-kind waiver. The report
names each unresolved reference or unsupported classification. Known bytes
remain visible as a lower bound, with `coverage_complete: false`; unknown
resource byte counts are `null`, never zero. With no page limit requested,
incomplete direct coverage is report-only and does not invalidate the complete
aggregate file inventory.

Even complete **direct** coverage does not measure a module or CSS import graph.
JavaScript imports, dynamic imports, CSS `@import`, font/image URLs inside CSS,
import-map targets, and runtime-inserted resources remain untraversed. An island
or preload may be named in HTML but fetched later or not executed. The report
never labels this metric total page cost, initial loading cost, or compressed
transfer size. Browser journey tests and network measurements answer those
questions.

### Additional JSON records

With `--page`, existing `reference` and aggregate records keep their original
meaning. New records report resolution separately:

- `page_resource`: selected `page`, reference `kind`, literal `url`, nullable
  resolved `path` and `raw_bytes`, and `status`. `measured` counts toward the
  page total; `duplicate` describes a previously counted path. Failure statuses
  include `NonlocalUrl`, `FileNotFound`, `OutsideDeployment`, and
  `UnsupportedUrlEncoding`.
- `page_coverage`: selected `page` and an unsupported-coverage `reason`.
- `page_resources`: `metric: "direct_reference_raw_bytes"`, `raw_bytes`,
  `local_file_bytes`, and `inline_body_bytes` (each with `js`/`css` fields),
  `unique_local_files`, `unresolved_references`, `coverage_complete`, and
  `has_base_href`. `import_graph_measured` and `transfer_bytes_measured` remain
  false.
- `page_budget`: `page`, `kind`, metric, `raw_bytes`, `max_bytes`,
  `coverage_complete`, and `passed`. Equality passes only with complete coverage.

The final summary adds `page_budgets_failed`; aggregate `budgets_exceeded`
continues to count only aggregate limits. Either nonzero count makes the command
exit 1. The existing summary's `references_resolved: false` describes its
original literal-reference records, not the selected page's additional
resolution records.

## Static initial and lazy dependency estimates

For a deeper graph report, use the **checkout-only developer tool** with Bun and
this repository's runtime development dependencies installed. It is intentionally
not shipped with the installed CLI: its inert HTML parser comes from the existing
Happy DOM development dependency, and its JavaScript parser uses TypeScript.

```sh
cd runtime && bun install --frozen-lockfile && cd ..
bun runtime/tooling/route-loading.ts public --page=app/index.html \
  --url-prefix=/project > route-loading.json
# Repeatable fixture; no release build required:
bun runtime/tooling/route-loading.ts runtime/tooling/fixtures/route-loading \
  --page=index.html --strict
```

The JSON report's `initial` group is the static closure of scripts, script/style preload and modulepreload
hints, stylesheets and executable inline imports. `lazy_only` contains reachable
files outside that initial closure. Literal `import()` targets and island
`data-z-module` attributes contribute lazy candidates; each `lazy_entries` record
lists its static closure after removing initial files. Nested dynamic imports
have their own entries. Shared files count once in the union, but can appear in
several candidate entries. These candidates do not claim an import happens only
after interaction: top-level dynamic imports, prefetching and hydration policies
can load them immediately. Modulepreload, conditional stylesheets and `nomodule`
scripts are conservatively included; the report does not simulate browser
conditions or execution. SPA routing-manifest chunk tables are not sufficient to
prove execution order, so this first slice uses emitted HTML and module edges,
without attributing chunks to named application routes.

The tool traverses static imports, reexports, literal dynamic imports, and CSS
`@import`. It resolves exact, prefix and scoped import-map entries. Scope keys
match the exact importer URL, or a URL prefix only when the key ends in `/`, as
specified by the [HTML module-resolution algorithm](https://html.spec.whatwg.org/multipage/webappapis.html#resolve-a-module-specifier). HTML entities
and CSS escapes use the existing parsers; CSS parsing externalizes every
reference, and HTML parsing disables script execution and external loading.
No application module is executed and no resource is fetched. Inline script and
style body sizes are reported separately but remain part of the measured HTML
file, preventing double counting them as standalone files.

Every measured physical file has `raw`, `gzip`, and `brotli` byte counts. The
compression figures use gzip level 9 and Brotli quality 11 **independently per
file**; they are estimates, not observed HTTP transfer sizes. They exclude HTTP
headers, negotiation, cache hits and server compression settings. No compressed
output is written. Query strings and fragments are ignored for physical-file
deduplication, which differs from browser module identity and request caching.
Module identity involving queries/fragments and import-map scopes is flagged
unsupported. The report contains its measurement/compression conventions and
lists each graph edge and resource.

`coverage_complete` describes only this bounded static JS/CSS graph.
`browser_loading_complete` is always false. Fonts, images, CSS `url()` assets,
workers, service workers, fetch/XHR, DOM-inserted resources, inline event handlers,
and runtime-dependent loading are outside the metric. HTML parsing is tolerant,
not a markup-validity check. The graph assumes scripting is enabled; `noscript`
and uninstantiated `template` contents are not roots. Missing/external files,
computed imports, CommonJS `require`, unsupported static module attributes or dynamic import options,
multiple/late/invalid import maps, `base href`, foreign SVG/MathML content, unsupported legacy script languages,
syntax diagnostics, symlinks and unsafe paths are reported in
`unknowns`; these prevent complete graph coverage. Map validation includes unused
malformed entries and invalid scope URLs, a conservative check even where browsers can
ignore an entry or normalize it to a blocker. Explicit null blockers are supported:
an unused blocker or valid external address does not imply a resource load.
A failed resource visit retains an unresolved (`null`) edge target.
Known-resource estimates for an incomplete graph are not a certified lower bound on actual loading.
Each file is limited to 16 MiB, and graphs to 10,000 files.

By default incomplete coverage is report-only. Add `--strict` to exit 1 while
still emitting the complete JSON report if any unknown remains. Invalid command
arguments or an unreadable selected page exit 1 with a diagnostic on stderr;
there is no successful JSON report in that case. Existing `inspect-output`
aggregate and direct-page budgets are unchanged and remain separate metrics.

Repeated-slash aliases share a canonical physical file key and count once. They
also produce an explicit unknown: collapsing a browser URL can change relative
import resolution and scoped mappings. The report does not claim complete graph
coverage for those aliases, even when the underlying file exists.
