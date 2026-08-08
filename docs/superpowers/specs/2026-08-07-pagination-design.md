# Pagination for content sections

Design, 2026-08-07. Issue #127. Approved by valthon 2026-08-07 (with the
importer scope expanded from docs-only to a real enhancement).

## Problem

Zigapagos has no pagination: a section index renders **all** subpages, so a
200-post blog gets one giant listing. Astro's `paginate()` is ubiquitous in real
Astro sites, which makes this a hole in the unattended-migration spec — an Astro
site using `paginate()` currently has no target, and the importer neither
detects nor converts the pattern.

## Shape of the feature

A section index opts in via frontmatter:

```ziggy
.pagination = .{ .page_size = 10 },
```

and the build emits `/blog/`, `/blog/page/2/`, … from the same layout, each
render seeing a different window of subpages. Templates get
`$page.pagination?()` with `current`/`total`/`page_size`/`total_items` and
`prevLink()`/`nextLink()`/`pageLink(n)`. The URL shape is configurable
per-section. The Astro importer detects `paginate()` routes, and
`init --from-astro` converts them.

## Approach

**Render the section index N times via a new `RenderJobKind` arm.**
`alternatives` already renders the same `*Page` N times — one `page_render` job
per alternative, distinguished only by `RenderJobKind = union(enum) { main,
alternative: u32 }` (`src/worker.zig:1229`), each with its own layout selection,
output path (`suffixedOutputPath`, `src/worker.zig:1218`), and result slot
(`_render.alternatives[aidx]`). Pagination adds a `pagination: u32` arm (the
1-based page number ≥ 2) and queues its jobs beside the alternatives loop at
`src/root.zig:2639`.

Rejected alternatives:

- **Synthetic `Page` entries appended after parse.** `Variant.pages` is never
  appended to after scan; `subpages()`, `$site.page()` and the already-queued
  render jobs all hold raw `*Page` pointers into it, so one reallocating append
  dangles them all. Synthetic entries absent from `Section.pages` also panic
  the `indexOfScalar(...).?` asserts in `nextPage`/`prevPage` and the
  `assert(idx == page_list.len)` in `$site.pages()`.
- **A separate pass like the SPA prerenderer.** That pipeline is
  single-threaded and non-`Page`; copying its shape duplicates the render
  machinery and forfeits worker-pool parallelism.

Reads are safe: nothing in the render path memoizes on `Page` or `Section`,
and `Section.pages` is frozen (sorted date-descending, URL tie-break) by
`Section.sortPages` at `src/root.zig:1216`, before any render job is queued.

## Frontmatter

A new field on `Page` (`src/context/Page.zig:45` — the struct *is* the ziggy
schema):

```zig
pagination: ?Pagination = null,

pub const Pagination = struct {
    page_size: u32,
    url_style: UrlStyle = .page_dir,
    pub const UrlStyle = enum { page_dir, plain_dir, page_html };
};
```

The `= null` default is mandatory — a defaultless field makes ziggy report
`missing field` on every existing page in every snapshot fixture. Declaring
`UrlStyle` as a real Zig enum gets parse-time validation from ziggy for free.

Semantic validation happens in `worker.analyzeFrontmatter`
(`src/worker.zig:293`) as new `FrontmatterAnalysisError` variants
(`src/context/Page.zig:314`), so errors carry a recovered source span:

- `.page_size == 0` — invalid.
- `.pagination` on a page that is not a section index — invalid.

Each variant needs an arm in the exhaustive `code()`, an `info()` entry in
`src/diag.zig`, and an `[ACTIVE]` row in the append-only
`src/diag-codes.frozen` ledger. If the messages are quoted in
`docs/build-errors.md`, `tests/meta/build-errors-doc.sh` requires them to
remain literal substrings of the emitting source.

`frontmatter.ziggy-schema` (editor-only, ungated) gains the `Pagination`
struct. While in there, fix its known drift: `translation_key` is missing and
its `Alternative` declares a `title: ?bytes` that does not exist (the real
struct has a required `name`).

## URL shapes

Page 1 is always the section's canonical URL (`/blog/`); no `page/1/` output
exists, and `prevLink()` from page 2 returns the bare section URL. For page
n ≥ 2, per `url_style`:

| `url_style` | Page n output | URL |
|---|---|---|
| `.page_dir` (default) | `blog/page/n/index.html` | `/blog/page/n/` |
| `.plain_dir` | `blog/n/index.html` | `/blog/n/` (Astro rest-param parity) |
| `.page_html` | `blog/page-n.html` | `/blog/page-n.html` (hosts without rewrites — Astro 7.1's `format()` lesson) |

The shape is per-section frontmatter only; no site-wide config field. A site
default can be added later without breaking anything, and the config surface
stays flat until someone needs it.

Paths are computed by a **fifth path helper** beside
`urlFmt`/`pageDir`/`mainOutputPath`/`suffixedOutputPath` in
`src/worker.zig:1147-1227` (contract-1 self-freeing, like its siblings). Those
helpers were deliberately extracted (#45/#47) so `zigapagos explain` and
`--summary` report the real emit paths; pagination must not recreate the drift
they removed.

## The planning pass

Page counts depend on `page_size` (frontmatter) and the **active** subpage
count — `Section.pages` includes drafts and `subpages()` filters at read time,
so `s.pages.items.len` is the wrong number. Both are final only after parse +
`sortPages`, but `Variant.urls` (the collision registry) is capacity-reserved
and populated during scan. That ordering gap is closed by a small main-thread
planning pass immediately after `Section.sortPages` (`src/root.zig:1216`):

For each active section index with `.pagination`:

1. Count active subpages; compute `total_pages = ceil(active / page_size)`
   (minimum 1; a section with ≤ `page_size` active subpages emits only its
   canonical page and `$page.pagination?()` reports `total = 1`).
2. Store the plan (total pages, page size, url_style, active count) on a new
   parser-hidden internal field `Page._pagination` (added to
   `ziggy_options.skip_fields`, like `_scan`/`_parse`/`_analysis`/`_render`).
3. Register each page-n output (n ≥ 2) in `Variant.urls` with a new
   `ResourceKind.pagination`, after an explicit `ensureUnusedCapacity` for the
   batch. Collisions (e.g. a real subpage named `2` under `.plain_dir`)
   accumulate into `Variant.collisions` and abort at the existing error gate
   (`src/root.zig:2493`), before any file is written.

Adding the `ResourceKind` variant updates its four consumers together: the
formatter in `src/Variant.zig:104-120`, `src/summary.zig` plus its population
site at `src/root.zig:2657`, and the exhaustive switch in
`src/cli/explain.zig:503-556`.

## Rendering

At the render-dispatch site (`src/root.zig:2628-2648`), a paginated index
queues, in addition to its `.main` job and alternatives, one job per extra page:
`kind = .{ .pagination = n }` for n = 2…total.

Per-render state cannot live on `Page`: the same pointer is read concurrently
by all its jobs on different worker threads. It rides on `context.Root`
(`src/context/Root.zig:20-36`), which is a stack local built fresh per job in
`renderPage` (`src/worker.zig:1288`): a nullable
`{ current, total, page_size, total_items, window_start, window_end }`
populated from `Page._pagination` + the job kind (`.main` on a paginated index
sets `current = 1`; alternatives and non-paginated pages leave it null).

Results: `_render.pagination: []RenderResult` mirroring
`_render.alternatives`, pre-allocated at queue time — reusing the single
`_render.out` slot would be a data race and, in `.memory` mode
(`validate`/`explain`, which must keep working), a leak. Disk emit for a
`.pagination` job goes through the new path helper instead of the hardcoded
`pageDir + "index.html"` at `src/worker.zig:1655`.

`aliases` copies and asset installs are `.main`-job-only and unchanged. Asset
refcounts (`src/context/Asset.zig`) inflate by the extra renders; the install
decision only tests `raw == 0`, so behavior is unchanged, but this is noted for
anyone reading count diagnostics.

## Scripty API

**Windowed `subpages()`.** On a render with pagination state, `subpages()`
(`src/context/Page.zig:1258`) returns only the current window of active
subpages. Existing section layouts paginate with zero template edits — page 1
shows items 1–10 instead of all 200. `subpagesAlphabetic()` re-sorts the
window. Alternatives render unwindowed (pagination state null), so RSS feeds
keep the full list. Both already take `ctx`, so no signature changes.

**`$page.pagination?()`**, following the `nextPage?()` optional idiom so
shared layouts can branch, returns a new `Pagination` context value:

- Fields: `current` (1-based), `total` (page count), `page_size`,
  `total_items` (active subpages).
- Builtins: `prevLink()` / `nextLink()` (error on page 1 / page `total` — guard
  with `current`/`total`, matching how `nextPage?()` consumers guard), and
  `pageLink(n)` for numbered pagers (n = 1 returns the canonical section URL).

All links compose through `Root.printLinkPrefix`
(`src/context/Root.zig:38-74`) — the single point that makes `url_path_prefix`
(GitHub-Pages project sites) correct. Building URLs from `_scan.url` with a
hand-prepended `/` is the known trap and is forbidden here.

Docs plumbing, or the generator silently omits things: the new type becomes a
`Value` union variant (`src/context.zig:44`) with
`Fields`/`Builtins`/`docs_description`, gets a `ScriptyParam` entry
(`src/context/doctypes.zig:26-66`), the `Page` builtin gets a `signature` (a
missing one fails `zig build check`), and the frontmatter field gets a
`Page.Fields` doc entry (a missing one is silently skipped). Then
`zig build docs-reference` regenerates `docs/scripty.md` (never hand-edited;
drift-gated by `tests/meta/scripty-reference.sh`).

## Stale-output pruning

A genuinely new failure mode: nothing in the codebase prunes page outputs, and
`zigapagos dev` always builds with `--force` into the same tree — so when a
section shrinks from 3 pages to 1, `/blog/page/2/` would be served forever, in
dev and release. This is the first feature where the output set shrinks as a
function of content.

After the render barrier, `.disk` mode only: for each paginated section, probe
page paths beyond `total` (n = total+1, total+2, …) using the same path helper
and delete until one does not exist — the same bounded shape as the island
stale-slice prune (`src/root.zig:877`). A candidate path that is registered in
`Variant.urls` is skipped, not deleted: under `.plain_dir`, a section that
shrank while gaining a real subpage named `3` would otherwise have that page's
freshly-emitted output deleted by the probe.

## Dev loop

Correctness is inherited: AUD-016 (`src/cli/dev.zig:999`) forces a full rebuild
on **any** content edit, naming `subpages()` embedding as the reason — exactly
the dependency pagination adds. No classifier work needed.

One real gap: the island-edit incremental fast path (`src/root.zig:2586-2606`)
re-renders only pages whose source is in the changed set. When such a page is a
paginated index, its `.pagination` jobs must be re-queued alongside `.main`,
or page-2+ outputs go stale after an island edit.

## Importer enhancement

Astro background: `paginate()` requires its dynamic segment to be named `page`.
`src/pages/blog/[page].astro` emits `/blog/1`, `/blog/2`, …;
`[...page].astro` emits `/blog`, `/blog/2`, … Astro never inserts a `/page/`
segment (that convention is Hugo/Jekyll).

**Detector** (`src/cli/migrate_detect.zig`, std-only and string-testable per
that module's contract): `pub fn detectPaginate(path, src) ?PaginateSpec`.
Fires when the basename is `[page].astro` / `[...page].astro` **and** the
leading `---`…`---` frontmatter fence contains `getStaticPaths` and
`paginate(`. Fence-scoping is a new small helper (nothing existing scopes to
the fence). Extracted:

- `page_size`: the integer literal after `pageSize:`; absent → 10 (Astro's
  default); non-literal → `null` with a `needs_review` flag.
- `route_form`: `.numbered` (`[page]`) or `.rest` (`[...page]`).
- `section`: derived from the path (`src/pages/blog/[page].astro` → `blog`;
  `Entry.path` keeps its `src/pages/` prefix, so this is string work).

**`zigapagos migrate`** stays a converter of nothing (test-pinned,
`src/cli/migrate.zig:1065`). The detector runs in `scanFile`
(`src/cli/migrate.zig:226-250`, the one place file bytes are in memory),
following the `uses_islands` precedent: result stored on `migrate.Entry`,
freed in `freeScanResult`. The worklist (`buildReport`,
`src/cli/migrate.zig:608`) gains, per detected route, a §2 checkbox line with
the exact conversion to perform:

> `- [ ] src/pages/blog/[page].astro` uses `paginate(…, { pageSize: 10 })` →
> delete the route file and add `.pagination = .{ .page_size = 10,
> .url_style = .plain_dir }` to `content/blog/index.smd` (§11 of the mapping
> reference). Numbered form: page 1 moves from `/blog/1` to `/blog/`; add
> `.aliases = ["1/index.html"]` if the old URL must keep working.

`migrate --doctor` on a paginated route file reports the same analysis.

**`init --from-astro`** — the file-emitting path — converts: for each detected
paginated route it emits `content/<section>/index.smd`, the first per-section
file the importer writes. A new `emitSectionIndexStub` beside
`emitContentStub` (`src/cli/init_from_astro.zig:474`) produces the same stub
frontmatter plus the `.pagination` line, mapping `route_form` to `url_style`:
`.rest` → `.plain_dir` (exact URL parity), `.numbered` → `.plain_dir` plus a
worklist note about the page-1 URL change. A `needs_review` page size falls
back to 10 with a worklist flag. Non-clobber semantics are inherited from
`writeFile` (`.new` on collision).

**`capabilities_section`** (`src/cli/migrate_detect.zig:579`): pagination is
added to the Supported list; the Gaps line is reworded to distinguish general
dynamic routes `[slug]` (still a gap) from paginated routes
`[page]`/`[...page]` (now native). The literal markers `"Supported:"` and
`"Gaps (use workarounds):"` and the `"[slug]"` gap must survive — the drift
guard at `migrate_detect.zig:899` unwraps and asserts them — and `"pagination"`
is added to the test's `shipped` whitelist so the new claim is guarded too.

## Documentation

- `docs/migration/astro-to-zigapagos.md`: a `### Pagination` subsection inside
  existing §11 (a new numbered section would break eleven in-prose `§N`
  references and one anchor link), in house style — a mapping table
  (`page.data` → windowed `subpages()`, `page.currentPage` → `current`,
  `page.lastPage` → `total`, `page.url.prev/next` → `prevLink()`/`nextLink()`,
  `page.size` → `page_size`, `page.total` → `total_items`), bullets for the
  two Astro URL shapes and the Hugo/Jekyll `/page/2/` expectation, and a note
  that 7.1's `format()` needs no equivalent for a directory-style-output SSG.
- Same file: a `[page]`/`[...page]` row in the §3 routing table (fixing that
  table's header to three columns — row 90 already has a third cell that the
  two-column header silently drops), and the Gaps section reworded to scope
  "the content layer has no `getStaticPaths`" to `[slug]` only.
- The `site/content/docs/*.smd` mirrors are generated; only the `.md` files
  are edited.
- `docs/scripty.md` regenerates via `zig build docs-reference`.

## Testing

- **Snapshot fixtures** (auto-discovered by `build/snapshot.zig`):
  `tests/rendering/pagination/` covering all three URL styles, a
  single-page-after-pagination section, and prev/next/pageLink output;
  `tests/drafts/pagination/` because drafts change the page-count arithmetic.
- **Shell e2e** `tests/rendering/pagination.sh`: proves the stale-page prune
  (build with 3 pages, shrink content, rebuild with `--force`, assert
  `page/3/` is gone) and that `--summary` agrees with the emitted tree.
- **Zig unit tests**: `test "pagination: ..."` blocks beside the code (picked
  up by the unfiltered `test-init`/`test-spa` exe-module suites — no CI edit);
  `detectPaginate` cases in `migrate_detect.zig` under `test-migrate`;
  `emitSectionIndexStub` string tests under `test-init`.
- **Importer fixture**: `tests/migrate/astro-sample/` gains
  `src/pages/blog/[page].astro` with a real `getStaticPaths` + `paginate()`
  (plus a README contract line); `tests/init/from-astro.sh` asserts the
  emitted `content/blog/index.smd` contains the `.pagination` frontmatter.
- Repo gates: every regression test verified to **fail without the fix**;
  `zig build check -Dsingle-threaded`; `zig fmt --check` over `git ls-files`;
  `bash scripts/check-allocator-contracts.sh` (new helpers are contract-1
  self-freeing; no new arena-scoped signatures expected).

## Decision record

- Windowed `subpages()` on paginated renders (vs. a separate items accessor) —
  matches the issue text; existing layouts paginate without edits.
- Per-section frontmatter `url_style`, no site-wide config; default
  `.page_dir`.
- Page 1 at the bare section URL always; no `page/1/` output.
- Stale pagination outputs are pruned, not documented away.
- Importer: full enhancement (detector + worklist instructions +
  `init --from-astro` conversion) — user overturned the original docs-only
  scoping. `migrate` itself still converts nothing; that contract is
  load-bearing and test-pinned.
- API surface capped at `current`/`total`/`page_size`/`total_items` +
  `prevLink()`/`nextLink()`/`pageLink(n)`; `first`/`last` compose from
  `pageLink(1)`/`pageLink(total)`.
