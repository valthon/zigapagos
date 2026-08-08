### Added

- Pagination for content sections (issue #127): a section index opts in with
  `.pagination = { .page_size = 10 }` in its `index.smd` frontmatter and the build renders
  that index once per window of active subpages. Nothing changes for a section that doesn't
  set it, and drafts are excluded from the counts rather than merely hidden. Three URL styles
  via `.pagination.url_style` — `page_dir` (`/blog/page/2/`, the default), `plain_dir`
  (`/blog/2/`), `page_html` (`/blog/page-2.html`) — and page 1 is always the section's own URL
  in every style. One formula backs the generated `href`, the on-disk output path and the
  browser pathname handed to island SSR, so a link and the file it addresses cannot drift.
- Windowed layout surface: `$page.subpages()` and `$page.subpagesAlphabetic()` return only the
  current window when called on the index being rendered — a shared layout's existing loop
  paginates with no edit. `$page.pagination?()` returns a `Paginator` on such a render and
  null everywhere else, so a layout shared with unpaginated sections branches with a plain
  `:if`. `Paginator` carries `current`, `total`, `page_size`, `total_items`, plus
  `prevLink?()`, `nextLink?()` and `pageLink(n)` (which errors out of range — guard numbered
  pagers with `.total`). A different section reached through `$site.page(…)` still sees its
  full subpage list, and RSS `alternatives` are never windowed.
- Guardrails and observability: `ZP_INVALID_PAGINATION_SIZE` (zero `page_size`) and
  `ZP_PAGINATION_NOT_SECTION` (`.pagination` on a leaf page) are span-carrying frontmatter
  diagnostics; a pagination URL colliding with a real page (a subpage literally named `2`
  under `plain_dir`) aborts through the ordinary collision gate; `--summary` counts a
  "pagination pages" category and `explain` lists each pagination page by output path.
- Stale pagination output is pruned on rebuild. Pagination is the first feature whose output
  set *shrinks* with content, and dev builds into the same tree, so a section dropping from
  three pages to one would otherwise serve an orphaned `page/2/` forever. The prune probes
  past each section's live plan in all three URL styles (changing `url_style` orphans the
  previous shape) and skips anything registered as a real output or prerendered by an SPA.
- Astro importer support: `zigapagos migrate` recognises `[page].astro` / `[...page].astro`
  routes calling `paginate()`, reads a literal `pageSize` (flagging a computed one for review
  rather than guessing), and prescribes the conversion in the worklist, the port doctor's
  report and its `--format=json` output; `zigapagos init --from-astro` writes the section
  `index.smd` stub with `.pagination` already set.

### Changed

- `docs/migration/astro-to-zigapagos.md` gains the full `paginate()` mapping table
  (`page.data` → windowed `$page.subpages()`, `page.currentPage`/`page.lastPage`/`page.size`/
  `page.total` → `Paginator` fields, `page.url.*` → the link helpers; `page.start`/`page.end`
  have no direct equivalent — compute from `.current` and `.page_size`). Two porting notes:
  Astro's `[...page].astro` is exact URL parity with `plain_dir`, while `[page].astro` puts
  page 1 at `/blog/1` — zigapagos always puts page 1 at the section URL, so add
  `.aliases = ["1/index.html"]` if the old URL must keep working.

### Fixed

- `frontmatter.ziggy-schema` had drifted from the frontmatter the build actually accepts: it
  was missing `translation_key` and `Alternative.name`, and still declared an
  `Alternative.title` that no longer exists — editors validating against the schema rejected
  valid fields and accepted a dead one.

### Internal

- Two allocator defects surfaced by the new tests and fixed alongside: `migrate.zig`'s
  `buildReport` returned an `Allocating` buffer *view* that panics with "Invalid free" under
  the debug allocator once a caller frees it, and `scanDir` leaked one joined-path allocation
  per directory level.
