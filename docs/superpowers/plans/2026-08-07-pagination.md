# Pagination for Content Sections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Frontmatter-opt-in pagination for section indexes (`.pagination = .{ .page_size = N }` emits `/blog/`, `/blog/page/2/`, …), a `$page.pagination?()` Scripty API with a windowed `subpages()`, stale-page pruning, and Astro-importer detection + conversion of `paginate()` routes.

**Architecture:** Extend the proven `alternatives` N-render machinery with a `pagination` arm on `RenderJobKind`; per-render window state rides on `context.Root` (never on `Page` — the same `*Page` is read by N worker threads); a main-thread planning pass after `Section.sortPages` computes page counts and registers extra output URLs in `Variant.urls`; a fifth path helper in `worker.zig` keeps `explain`/`--summary` honest. Spec: `docs/superpowers/specs/2026-08-07-pagination-design.md`.

**Tech Stack:** Zig 0.16 (via mise), superhtml/scripty/ziggy (vendored in gitignored `zig-pkg/` — never edit), bash e2e, git-diff snapshot tests.

## Global Constraints

- Check `zig version` → must be 0.16.0 before believing any build error (version skew produces walls of fake dependency errors).
- Branch: `worktree-pagination-design` (already exists, has the spec). Never push to `main`.
- The git index is shared across worktrees: always commit with explicit paths — `git add <paths> && git commit -m … -- <paths>`. Never bare `git stash`.
- zsh: no `${PIPESTATUS[0]}`; run commands unpiped and check `$?`. Use `>|` for redirects if noclobber bites.
- Every allocator-taking function must declare its NO_SLOP §2.2a contract in a doc comment (new helpers here are all contract 1, self-freeing). Run `bash scripts/check-allocator-contracts.sh` before final commit of each task that adds one.
- `zig fmt` the files you touched before every commit: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` is CI's first gate. Never reformat `zig-pkg/`.
- `zig build test` REGENERATES snapshot fixtures and stages them (`git add tests/`); a change shows up in `git diff --cached -- tests/`. Blessing = inspect that diff, commit if intended. Keep `tests/` clean before running it.
- Regression tests must be verified to FAIL without the fix (revert the source change temporarily, or write the test first — steps below do the latter).
- Commit messages explain the defect/reasoning, not just the change. End with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `src/diag-codes.frozen` is append-only; codes go under `[ACTIVE]`, alphabetically.
- Docs `docs/scripty.md` is generated (`zig build docs-reference`) — never hand-edit. `site/content/docs/*.smd` mirrors are generated — edit only the `.md` sources.
- A fresh worktree needs `cd runtime && bun install --frozen-lockfile` once before anything bun-dependent (some e2e shell tests boot the sidecar).

---

### Task 1: Frontmatter field `pagination` + Scripty settings plumbing

The `Page` struct IS the ziggy frontmatter schema. Adding the field forces Scripty/`Value.from` support for the new types at compile time (every non-underscore `Page` field must be `Value.from`-able), so field + value plumbing is one task.

**Files:**
- Modify: `src/context/Page.zig` (fields at :45-59, `Fields` docs at :720-787)
- Modify: `src/context.zig` (`Value` union at :45-68, `Value.from` at :137-187)
- Modify: `src/context/doctypes.zig` (`ScriptyParam` at :26-70, `fromType` at :71+)
- Modify: `frontmatter.ziggy-schema` (repo root; editor-only, ungated)

**Interfaces:**
- Produces: `Page.pagination: ?Page.Pagination` field; `pub const Page.Pagination = struct { page_size: u32, url_style: UrlStyle = .page_dir }` with `pub const UrlStyle = enum { page_dir, plain_dir, page_html }`. Later tasks read `page.pagination.?.page_size` / `.url_style`.

- [ ] **Step 1: Write the failing test** — append to `src/context/Page.zig` (bottom of file; there are no tests in `src/context/` today — these run under the unfiltered `test-init`/`test-spa` exe-module suites automatically):

```zig
const testing = std.testing;

test "pagination: frontmatter field parses with defaults" {
    // The Page struct is the ziggy schema; parse a minimal frontmatter the way
    // Page.parse does and check the new field round-trips.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\.title = "Blog",
        \\.layout = "index.shtml",
        \\.pagination = .{ .page_size = 10 },
    ;
    const page = try ziggy.parseLeaky(Page, arena, src, .{});
    const pg = page.pagination.?;
    try testing.expectEqual(@as(u32, 10), pg.page_size);
    try testing.expectEqual(Pagination.UrlStyle.page_dir, pg.url_style);

    const src_style =
        \\.title = "Blog",
        \\.layout = "index.shtml",
        \\.pagination = .{ .page_size = 3, .url_style = .plain_dir },
    ;
    const page2 = try ziggy.parseLeaky(Page, arena, src_style, .{});
    try testing.expectEqual(Pagination.UrlStyle.plain_dir, page2.pagination.?.url_style);

    const src_none =
        \\.title = "Blog",
        \\.layout = "index.shtml",
    ;
    const page3 = try ziggy.parseLeaky(Page, arena, src_none, .{});
    try testing.expectEqual(@as(?Pagination, null), page3.pagination);
}
```

Adapt the `parseLeaky` call to match how `Page.parse` (`src/context/Page.zig:515-544`) invokes it (options/diagnostic arguments) — copy its invocation shape exactly. If parsing frontmatter requires the `---` framing pre-stripped, pass just the struct body as above.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-init 2>&1 | tail -5` — then re-run unpiped and check `$?`. Expected: compile error, `Page` has no member `pagination` / `Pagination` undeclared.

- [ ] **Step 3: Implement.** In `src/context/Page.zig` after `custom` (line 59):

```zig
/// Opt-in pagination for a section index: the page pass renders this index
/// once per window of `page_size` active subpages. Only meaningful on an
/// `index.smd` (validated in analyzeFrontmatter). See docs/superpowers/specs/
/// 2026-08-07-pagination-design.md.
pagination: ?Pagination = null,
```

and beside `Alternative` (`Page.zig:568`), following its exact shape:

```zig
pub const Pagination = struct {
    page_size: u32,
    url_style: UrlStyle = .page_dir,

    pub const UrlStyle = enum { page_dir, plain_dir, page_html };

    pub const Dot = true;

    pub const docs_description =
        \\Pagination settings of a section index page,
        \\as set in the SuperMD frontmatter.
    ;
    pub const Fields = struct {
        pub const page_size =
            \\How many subpages each pagination window holds.
        ;
        pub const url_style =
            \\URL shape of page 2 and beyond: `page_dir` (`blog/page/2/`),
            \\`plain_dir` (`blog/2/`), or `page_html` (`blog/page-2.html`).
            \\Page 1 is always the section's own URL.
        ;
    };
    pub const Builtins = struct {};
};
```

In `Page.Fields` (after `custom`, `Page.zig:783`):

```zig
pub const pagination =
    \\Pagination settings of this section index,
    \\as set in the SuperMD frontmatter (null when not paginated).
    \\
    \\`.pagination = .{ .page_size = 10 }` makes the build render this
    \\index once per window of 10 active subpages. Use
    \\`$page.pagination?()` for the per-render state (current page,
    \\total pages, prev/next links).
;
```

In `src/context.zig`: add `pagination: Page.Pagination,` to the `Value` union (after `alternative` at :51), and in `Value.from` (:137) add arms:

```zig
Page.Pagination => .{ .pagination = v },
?Page.Pagination => if (v) |pg|
    try context.Optional.init(gpa, pg)
else
    context.Optional.Null,
Page.Pagination.UrlStyle => .{ .string = .{ .value = @tagName(v) } },
```

and widen the int arm `i64, usize =>` to `i64, usize, u32 =>` (`page_size` is `u32`; `Value.from` must accept it for field access).

In `src/context/doctypes.zig`: add `Pagination,` to `ScriptyParam` (after `Alternative` at :33) and to `ScriptyParam.Base` (after `Alternative` at :54), and in `fromType` add `context.Page.Pagination => .Pagination,` beside the `Alternative` line (:81). Follow the compiler: `ScriptyParam` has `link`/`name` helpers further down that switch on the tag — add `Pagination` arms wherever the build demands, naming the type `Pagination`.

In `frontmatter.ziggy-schema`: add a `Pagination` struct (`page_size: int`, `url_style: ?bytes`) and reference it from the page struct as an optional field. Also fix the two known drift bugs while here: add the missing `translation_key: ?bytes`, and fix `Alternative` (it declares `title: ?bytes` but the real struct at `Page.zig:568` has required `name: []const u8` and no `title`).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-init` (check `$?` is 0). Then `zig build check` — this compiles the docs generator too and fails on a malformed `signature`/`ScriptyParam`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/context/Page.zig src/context.zig src/context/doctypes.zig
git add src/context/Page.zig src/context.zig src/context/doctypes.zig frontmatter.ziggy-schema
git commit -m "Add the pagination frontmatter field and its Scripty value plumbing

The Page struct is the ziggy frontmatter schema, so the opt-in is a
defaulted optional field (a defaultless field would fail every existing
page with 'missing field'). Every non-underscore Page field must be
Value.from-able, so the settings struct, its enum, and u32 land in the
Value union / ScriptyParam in the same change.

Also fixes known drift in the editor-only frontmatter.ziggy-schema
(missing translation_key; Alternative declared a nonexistent title).

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/context/Page.zig src/context.zig src/context/doctypes.zig frontmatter.ziggy-schema
```

---

### Task 2: Semantic validation + diagnostic codes

**Files:**
- Modify: `src/context/Page.zig` (`FrontmatterAnalysisError` at :314-419)
- Modify: `src/worker.zig` (`analyzeFrontmatter` at :293-323)
- Modify: `src/diag.zig` (`Code` enum ~:180, `info()` ~:320)
- Modify: `src/diag-codes.frozen` (`[ACTIVE]` section, alphabetical)
- Modify: `docs/build-errors.md` (entries for the new codes)

**Interfaces:**
- Consumes: `Page.pagination` from Task 1.
- Produces: `FrontmatterAnalysisError` variants `pagination_size` and `pagination_not_section`; diag codes `ZP_INVALID_PAGINATION_SIZE`, `ZP_PAGINATION_NOT_SECTION`. Task 4's planning pass may assume `page_size == 0` is already reported.

- [ ] **Step 1: Write the failing test** — append to `src/context/Page.zig`:

```zig
test "pagination: analysis error variants carry codes and titles" {
    const size_err: FrontmatterAnalysisError = .pagination_size;
    try testing.expectEqual(diagcodes.Code.ZP_INVALID_PAGINATION_SIZE, size_err.code());
    try testing.expect(size_err.title().len > 0);

    const sec_err: FrontmatterAnalysisError = .pagination_not_section;
    try testing.expectEqual(diagcodes.Code.ZP_PAGINATION_NOT_SECTION, sec_err.code());
    try testing.expect(sec_err.title().len > 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-init` — expected: compile error (no `pagination_size` variant / no such codes).

- [ ] **Step 3: Implement.**

`FrontmatterAnalysisError` (`Page.zig:314`): add variants `pagination_size,` and `pagination_not_section,`. `title()`:

```zig
.pagination_size => "pagination page_size must be at least 1",
.pagination_not_section => "'pagination' is only valid on a section index page",
```

`code()` (exhaustive, no `else`):

```zig
.pagination_size => .ZP_INVALID_PAGINATION_SIZE,
.pagination_not_section => .ZP_PAGINATION_NOT_SECTION,
```

`location()`: both variants recover the span of the `pagination` field — copy the `.layout` arm's walk (`Page.zig:358-370`) matching identifier `"pagination"`:

```zig
.pagination_size, .pagination_not_section => {
    assert(ast.nodes[2].tag == .@"struct" or
        ast.nodes[2].tag == .braceless_struct);
    var current = ast.nodes[3];
    while (true) : (current = ast.nodes[current.next_id]) {
        assert(current.tag == .struct_field);
        const identifier = ast.nodes[current.first_child_id];
        if (std.mem.eql(u8, "pagination", identifier.loc.src(src))) {
            return ast.nodes[identifier.next_id].loc;
        }
    }
},
```

`worker.analyzeFrontmatter` (`worker.zig:293`, after the alternatives loop):

```zig
if (p.pagination) |pg| {
    if (pg.page_size == 0) try errors.append(page_arena, .pagination_size);
    // subsection_id == 0 means "this page owns no section" — i.e. it is a
    // leaf page, not an index.smd (see Variant.zig's scan).
    if (p._scan.subsection_id == 0) try errors.append(page_arena, .pagination_not_section);
}
```

`src/diag.zig` `Code` enum (each field carries an `// emitted by:` comment; never register a code this change does not emit):

```zig
// emitted by: context/Page.zig FrontmatterAnalysisError, pagination page_size == 0
ZP_INVALID_PAGINATION_SIZE,
// emitted by: context/Page.zig FrontmatterAnalysisError, pagination on a non-section page
ZP_PAGINATION_NOT_SECTION,
```

`info()` (match house style, see `.ZP_INVALID_ALIAS` at :320):

```zig
.ZP_INVALID_PAGINATION_SIZE => .{
    .summary = "a page's `pagination.page_size` is zero",
    .explanation =
    \\`.pagination = .{ .page_size = N }` splits a section index into
    \\windows of N subpages, so N must be at least 1. This fires when
    \\the frontmatter sets it to 0.
    ,
},
.ZP_PAGINATION_NOT_SECTION => .{
    .summary = "`pagination` was set on a page that is not a section index",
    .explanation =
    \\Pagination windows a section's subpage list, so it is only
    \\meaningful on an `index.smd` that owns a section. This fires when
    \\a leaf page sets `.pagination` in its frontmatter.
    ,
},
```

`src/diag-codes.frozen`: insert `ZP_INVALID_PAGINATION_SIZE` and `ZP_PAGINATION_NOT_SECTION` under `[ACTIVE]`, alphabetically. `docs/build-errors.md`: add entries for both codes following the file's existing per-code format (the gate `tests/meta/build-errors-doc.sh` requires any quoted error text to be a literal substring of the emitting source and the code to be `[ACTIVE]` — reuse the `title()` strings above verbatim).

- [ ] **Step 4: Run tests**

Run: `zig build test-init` (pass), then `bash tests/meta/build-errors-doc.sh` (pass), and the diag self-tests: `zig build test-validate` or whichever suite `src/diag.zig`'s `test "diag: ..."` blocks run under — they are reachable from the exe module, so `zig build test-init` covers them; confirm no failure mentioning the frozen ledger.

- [ ] **Step 5: Content-scanning snapshot fixture.** Create `tests/content-scanning/pagination-errors/` mirroring an existing error fixture in that directory (copy the shape of any sibling: a `zigapagos.ziggy` — five-line config like `tests/rendering/simple/zigapagos.ziggy` — plus minimal `layouts/index.shtml` and content). Content: `content/index.smd` (plain root index), `content/post.smd` with `.pagination = .{ .page_size = 0 }` in its frontmatter (triggers BOTH errors: size 0 + not a section). Run `zig build test`; inspect `git diff --cached -- tests/` — the new fixture's `snapshot.txt` must show both error titles with `^^^` spans pointing at the `pagination` field. If the errors don't appear, the fix isn't wired — do not bless.

- [ ] **Step 6: Commit**

```bash
zig fmt src/context/Page.zig src/worker.zig src/diag.zig
git add src/context/Page.zig src/worker.zig src/diag.zig src/diag-codes.frozen docs/build-errors.md tests/content-scanning/pagination-errors
git commit -m "Validate pagination frontmatter semantically

page_size == 0 and pagination-on-a-leaf-page become accumulated
FrontmatterAnalysisError diagnostics with recovered source spans,
not fatal exits: syntactic ziggy errors abort per page, but semantic
ones collect, matching aliases/alternatives. Two new frozen diag codes.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/context/Page.zig src/worker.zig src/diag.zig src/diag-codes.frozen docs/build-errors.md tests/content-scanning/pagination-errors
```

---

### Task 3: The pagination path helpers in `worker.zig`

**Files:**
- Modify: `src/worker.zig` (beside the four helpers at :1147-1227)

**Interfaces:**
- Consumes: `Page.Pagination.UrlStyle` (Task 1).
- Produces:
  - `pub fn paginationSuffix(alloc: Allocator, style: Page.Pagination.UrlStyle, n: u32) ![]const u8` — page-dir-relative suffix, e.g. `"page/2/index.html"`.
  - `pub fn paginationOutputPath(alloc: Allocator, cfg: *const root.Config, variant: *const Variant, page: *const Page, style: Page.Pagination.UrlStyle, n: u32) ![]const u8` — output-dir-relative emit path.
  - `pub fn paginationPruneDir(alloc: Allocator, style: Page.Pagination.UrlStyle, n: u32) !?[]const u8` — the page-dir-relative *directory* to delete for dir styles (`"page/2"` / `"2"`), null for `.page_html` (delete the file instead). Tasks 4, 5, 7, 8 consume these.

- [ ] **Step 1: Write the failing test** — append to `src/worker.zig` (tests here run under the unfiltered exe-module suites):

```zig
test "pagination: suffix formats per url_style" {
    const t = std.testing;
    const cases = .{
        .{ Page.Pagination.UrlStyle.page_dir, 2, "page/2/index.html" },
        .{ Page.Pagination.UrlStyle.plain_dir, 2, "2/index.html" },
        .{ Page.Pagination.UrlStyle.page_html, 2, "page-2.html" },
        .{ Page.Pagination.UrlStyle.page_dir, 10, "page/10/index.html" },
    };
    inline for (cases) |c| {
        const got = try paginationSuffix(t.allocator, c[0], c[1]);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c[2], got);
    }
}

test "pagination: prune dir is the page directory for dir styles, null for html" {
    const t = std.testing;
    const d = (try paginationPruneDir(t.allocator, .page_dir, 3)).?;
    defer t.allocator.free(d);
    try t.expectEqualStrings("page/3", d);
    const p = (try paginationPruneDir(t.allocator, .plain_dir, 3)).?;
    defer t.allocator.free(p);
    try t.expectEqualStrings("3", p);
    try t.expectEqual(@as(?[]const u8, null), try paginationPruneDir(t.allocator, .page_html, 3));
}
```

- [ ] **Step 2: Run to verify failure**: `zig build test-init` → compile error, `paginationSuffix` undeclared.

- [ ] **Step 3: Implement** beside `suffixedOutputPath` (`worker.zig:1218`):

```zig
/// The page-dir-relative suffix of pagination page `n` (n >= 2) under the
/// given URL style. Page 1 has no suffix: it IS the section's main output.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): one allocation, escapes as
/// the return.
pub fn paginationSuffix(
    alloc: Allocator,
    style: Page.Pagination.UrlStyle,
    n: u32,
) ![]const u8 {
    assert(n >= 2);
    return switch (style) {
        .page_dir => std.fmt.allocPrint(alloc, "page/{d}/index.html", .{n}),
        .plain_dir => std.fmt.allocPrint(alloc, "{d}/index.html", .{n}),
        .page_html => std.fmt.allocPrint(alloc, "page-{d}.html", .{n}),
    };
}

/// Output path of pagination page `n` of a section index, relative to the
/// output directory — the fifth path helper beside `mainOutputPath` and
/// friends, extracted for the same H7 reason (issues #45/#47): `explain`,
/// `--summary`, the emit path, and the prune must share ONE formula.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): the suffix is an internal
/// scratch allocation freed here; only the joined path escapes.
pub fn paginationOutputPath(
    alloc: Allocator,
    cfg: *const root.Config,
    variant: *const Variant,
    page: *const Page,
    style: Page.Pagination.UrlStyle,
    n: u32,
) ![]const u8 {
    const suffix = try paginationSuffix(alloc, style, n);
    defer alloc.free(suffix);
    return std.fmt.allocPrint(alloc, "{f}{s}", .{ urlFmt(cfg, variant, page), suffix });
}

/// The page-dir-relative DIRECTORY that pagination page `n` occupies, for the
/// stale-page prune: deleting `page/3/index.html` alone leaves an empty dir
/// behind, so dir styles prune the directory. `.page_html` emits a bare file
/// and returns null — the caller deletes `paginationSuffix` instead.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing).
pub fn paginationPruneDir(
    alloc: Allocator,
    style: Page.Pagination.UrlStyle,
    n: u32,
) !?[]const u8 {
    assert(n >= 2);
    return switch (style) {
        .page_dir => try std.fmt.allocPrint(alloc, "page/{d}", .{n}),
        .plain_dir => try std.fmt.allocPrint(alloc, "{d}", .{n}),
        .page_html => null,
    };
}
```

- [ ] **Step 4: Run**: `zig build test-init` → pass. `bash scripts/check-allocator-contracts.sh` → pass.

- [ ] **Step 5: Commit**

```bash
zig fmt src/worker.zig
git add src/worker.zig
git commit -m "Add the pagination path helpers beside the existing four

One formula shared by emit, explain, --summary, and the prune — the H7
extraction rule (#45/#47): a second driftable copy of a path formula is
how the docs came to describe a deploy tree no build emits.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/worker.zig
```

---

### Task 4: Planning pass + URL registration + `ResourceKind.page_pagination`

**Files:**
- Modify: `src/context/Page.zig` (`_pagination` internal field + `skip_fields` at :35-43)
- Modify: `src/Variant.zig` (`ResourceKind`/`LocationHint` at :78-124; a `paginationPathName` helper; scan-time init of `_pagination`)
- Modify: `src/root.zig` (planning pass after `sortPages` at :1214-1218)
- Modify: `src/summary.zig` (`Category` at :46-56)
- Modify: `src/cli/explain.zig` (kind switch at :509-514)

**Interfaces:**
- Consumes: `Page.pagination` (Task 1); Task 2 guarantees `page_size == 0` is reported (the pass skips it).
- Produces: `Page._pagination: ?struct { total_pages: u32, active_count: u32 }` — set for every active, parsed section index with `.pagination`, INCLUDING single-page sections (`total_pages == 1`), so renders know they're paginated. `Variant.ResourceKind` gains `page_pagination`; `LocationHint.kind` gains `page_pagination: u32` (the page number). `Variant.paginationPathName(gpa, v, page, style, n) !PathName` interns/builds the registry key. `summary.Category` gains `page_pagination`. Tasks 5-9 consume all of these.

- [ ] **Step 1: Internal field.** In `src/context/Page.zig`, after `_render` (:128):

```zig
/// Set by root.zig's pagination planning pass (main thread, after
/// Section.sortPages) for an active section index with `.pagination`.
/// null everywhere else. Counts are ACTIVE subpages — `Section.pages`
/// includes drafts, so `s.pages.items.len` is the wrong number.
_pagination: ?struct {
    total_pages: u32,
    active_count: u32,
} = null,
```

Add `._pagination` to `ziggy_options.skip_fields` (:36). **Pages are carved from undefined ArrayList memory — field defaults never run** (see the comment at `Variant.zig:379-384`): find BOTH scan-time page-construction sites in `src/Variant.zig` (the index page at ~:377-400 where `index_page._parse.arena = .{}; index_page._render = .{};` is set, and the non-index `pages.resize` site at ~:461-521 with the same init pattern) and add `._pagination = null` (`index_page._pagination = null;` / the equivalent per-page line) beside `._render = .{}` at each.

- [ ] **Step 2: ResourceKind + summary category + explain arm (compile-driven).** In `src/Variant.zig:79`:

```zig
pub const ResourceKind = enum { page_main, page_alias, page_alternative, page_asset, page_pagination };
```

`LocationHint.kind` union (:82): add `page_pagination: u32, // page number (>= 2)`. Its `Formatter.format` (:104): add

```zig
.page_pagination => |n| {
    try w.print(" (pagination page {d})", .{n});
},
```

`src/summary.zig` `Category` (:46): add `page_pagination,` after `page_alternative`, and a heading arm `"pagination pages"` in `heading()`. `src/cli/explain.zig:509`: the kind switch gains `.page_pagination => {},` for now (Task 9 prints them properly). Chase every remaining non-exhaustive-switch compile error `zig build check` reports — the enum's consumers are exactly the errors.

- [ ] **Step 3: `paginationPathName`.** In `src/Variant.zig` (near the scan's own `urls` inserts, ~:402):

```zig
/// Build the Variant.urls key for pagination page `n` of `page` — the same
/// shape the scan uses for main outputs (`.path = dir, .name = file`), so
/// pagination pages collide honestly with real pages and assets. Interns
/// into the variant's tables; main-thread only (the tables are not locked).
///
/// NO_SLOP.md §2.2a contract 1: allocations land in the interning tables,
/// which own them; nothing escapes to the caller to free.
pub fn paginationPathName(
    v: *Variant,
    gpa: Allocator,
    page: *const Page,
    style: context.Page.Pagination.UrlStyle,
    n: u32,
) !PathName {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    switch (style) {
        .page_dir, .plain_dir => {
            const dir = std.fmt.bufPrint(&buf, "{f}{s}{d}", .{
                page._scan.url.fmt(&v.string_table, &v.path_table, null, true),
                if (style == .page_dir) "page/" else "",
                n,
            }) catch return error.NameTooLong;
            return .{
                .path = try v.path_table.internPath(gpa, &v.string_table, dir),
                .name = try v.string_table.intern(gpa, "index.html"),
            };
        },
        .page_html => {
            const name = std.fmt.bufPrint(&buf, "page-{d}.html", .{n}) catch return error.NameTooLong;
            return .{
                .path = page._scan.url,
                .name = try v.string_table.intern(gpa, name),
            };
        },
    }
}
```

Adapt to the real `internPath` signature (see its use at `Variant.zig:345` — if it takes path components rather than a joined string, split accordingly; the existing call passes `dir_entry.path`, so match whatever type that is). The `_scan.url` formatter with prefix `null` and trailing-slash `true` is the exact spelling `urlFmt` uses for a `.Site` config; pagination URLs are variant-relative like every other `urls` key (scan registers `.path = content_sub_path` with no locale prefix), so `null` prefix is correct for both config shapes.

- [ ] **Step 4: The planning pass.** In `src/root.zig`, immediately after the `sortPages` loop (:1214-1218):

```zig
// Pagination planning: page counts need parsed frontmatter (page_size)
// and the DRAFT-FILTERED subpage count, both final only here — after
// parse + sortPages — while Variant.urls capacity was reserved at scan
// time. Register the extra outputs now, before the collision gate at the
// error-gate below and before any render job is queued, so a pagination
// URL colliding with a real page (e.g. a subpage literally named "2"
// under .plain_dir) aborts the build like any other collision.
for (build.variants) |*v| {
    for (v.sections.items[1..]) |*s| {
        const index_page = &v.pages.items[s.index];
        if (!index_page._parse.active) continue;
        if (index_page._parse.status != .parsed) continue;
        const settings = index_page.pagination orelse continue;
        // page_size == 0 is a frontmatter analysis error (reported with a
        // source span); planning anything from it would divide by zero.
        if (settings.page_size == 0) continue;

        var active_count: u32 = 0;
        for (s.pages.items) |pidx| {
            if (v.pages.items[pidx]._parse.active) active_count += 1;
        }
        const total_pages: u32 = @max(
            1,
            std.math.divCeil(u32, active_count, settings.page_size) catch unreachable,
        );
        index_page._pagination = .{
            .total_pages = total_pages,
            .active_count = active_count,
        };
        if (total_pages < 2) continue;

        try v.urls.ensureUnusedCapacity(gpa, total_pages - 1);
        var n: u32 = 2;
        while (n <= total_pages) : (n += 1) {
            const pn = try v.paginationPathName(gpa, index_page, settings.url_style, n);
            const lh: Variant.LocationHint = .{
                .id = index_page._scan.page_id,
                .kind = .{ .page_pagination = n },
            };
            const gop = v.urls.getOrPutAssumeCapacity(pn);
            if (gop.found_existing) {
                try v.collisions.append(gpa, .{
                    .url = pn,
                    .loc = lh,
                    .previous = gop.value_ptr.*,
                });
            } else gop.value_ptr.* = lh;
        }
    }
}
```

(If `paginationPathName`'s error set includes `NameTooLong`, handle it with a `fatal.msg` naming the page — a URL too long to format cannot be built.)

- [ ] **Step 5: Collision fixture (regression test).** Add `tests/content-scanning/pagination-collision/`: a section `content/blog/` with `.pagination = .{ .page_size = 1, .url_style = .plain_dir }` on `content/blog/index.smd` and THREE subpages, one literally named `content/blog/2.smd` — its main output `blog/2/index.html` collides with pagination page 2. Run `zig build test`; the staged `snapshot.txt` must show a URL-collision error naming both owners (`(main output)` and `(pagination page 2)`). If it builds clean, registration isn't wired — do not bless.

- [ ] **Step 6: Verify + commit.** `zig build check` clean, `zig build test-init` pass, `zig build test` diff shows only the new fixture.

```bash
zig fmt src/context/Page.zig src/Variant.zig src/root.zig src/summary.zig src/cli/explain.zig
git add src/context/Page.zig src/Variant.zig src/root.zig src/summary.zig src/cli/explain.zig tests/content-scanning/pagination-collision
git commit -m "Plan pagination after sortPages and register its URLs

Page counts depend on parsed frontmatter and the draft-filtered subpage
count, final only after parse+sort — but Variant.urls capacity is
reserved during the scan. A main-thread pass closes that ordering gap:
counts, a _pagination plan on the index page, and per-page URL
registration with a new ResourceKind, so pagination outputs collide
honestly with real pages before anything is written.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/context/Page.zig src/Variant.zig src/root.zig src/summary.zig src/cli/explain.zig tests/content-scanning/pagination-collision
```

---

### Task 5: Render N times — `RenderJobKind.pagination` + result slots + dispatch

**Files:**
- Modify: `src/worker.zig` (`RenderJobKind` at :1229, `renderPage` at :1231-1305, memory-store at :1602-1623 and :1343-1346, disk emit at :1624-1700)
- Modify: `src/context/Page.zig` (`_render` at :121-128, `deinit` at :421-434)
- Modify: `src/context/Root.zig` (per-render state field)
- Modify: `src/root.zig` (dispatch loop at :2614-2648)

**Interfaces:**
- Consumes: `Page._pagination` (Task 4), `paginationOutputPath` (Task 3).
- Produces: `RenderJobKind = union(enum) { main, alternative: u32, pagination: u32 }` (the page number, ≥ 2); `Page._render.pagination: []…` slots indexed `[n - 2]`; `context.Root._pagination: ?PaginationState` where `pub const PaginationState = struct { current: usize, total_pages: usize, page_size: usize, total_items: usize }` — Task 6's builtins read exactly this.

- [ ] **Step 1: `Root` state.** In `src/context/Root.zig` after the `_meta` field (:32):

```zig
/// Per-RENDER pagination state — lives here and not on Page because the
/// same *Page is read concurrently by its .main job and every
/// .alternative/.pagination job on other worker threads. Root is a stack
/// local built fresh per job in renderPage, so this is naturally per-job.
/// Set only for .main/.pagination renders of a paginated section index;
/// null for alternatives (RSS must see the full list) and everything else.
_pagination: ?PaginationState = null,

pub const PaginationState = struct {
    current: usize, // 1-based
    total_pages: usize,
    page_size: usize,
    total_items: usize,
};
```

- [ ] **Step 2: `_render` slots + deinit.** In `Page.zig` `_render` (:121), after `alternatives`:

```zig
pagination: []struct {
    out: []const u8 = "",
    errors: []const u8 = "",
} = &.{},
```

In `deinit` (:421), mirror the alternatives loop:

```zig
for (p._render.pagination) |pg| {
    gpa.free(pg.out);
    gpa.free(pg.errors);
}
gpa.free(p._render.pagination);
```

- [ ] **Step 3: `worker.zig`.** `RenderJobKind`:

```zig
pub const RenderJobKind = union(enum) { main, alternative: u32, pagination: u32 };
```

Then let the compiler drive: `zig build check` finds every non-exhaustive switch. The arms to add:

`progress_name` (:1265):

```zig
.pagination => |n| try std.fmt.allocPrint(arena.a, "{s} (page {d})", .{ page_path, n }),
```

`ctx` construction (:1288) — add the state (this also covers `.main` on a paginated index):

```zig
._pagination = switch (kind) {
    .alternative => null,
    .main, .pagination => if (page._pagination) |plan| .{
        .current = switch (kind) {
            .pagination => |n| n,
            else => 1,
        },
        .total_pages = plan.total_pages,
        .page_size = page.pagination.?.page_size,
        .total_items = plan.active_count,
    } else null,
},
```

`layout_path` (:1302): `.pagination => page.layout,` (same layout as main — that is the feature).

memory-mode error store (:1343):

```zig
.pagination => |n| page._render.pagination[n - 2].errors = errs,
```

memory-mode output store (:1602):

```zig
.pagination => |n| {
    page._render.pagination[n - 2].out = if (rendered_html_is_gpa_owned)
        rendered_html
    else
        gpa.dupe(u8, rendered_html) catch fatal.oom();
    page._render.pagination[n - 2].errors = "";
},
```

disk emit — add an arm beside `.alternative` (:1675), using the Task 3 helper (aliases stay `.main`-only):

```zig
.pagination => |n| blk: {
    const style = page.pagination.?.url_style;
    const out_path = try paginationOutputPath(arena.a, build.cfg, variant, page, style, n);
    if (std.fs.path.dirnamePosix(out_path)) |path| {
        disk.output_dir.createDirPath(io, path) catch |err| fatal.dir(path, err);
    }
    break :blk disk.output_dir.createFile(io, out_path, .{}) catch |err| fatal.file(out_path, err);
},
```

- [ ] **Step 4: Dispatch.** In `src/root.zig` (:2614), extend the slot pre-allocation and queue jobs beside the alternatives loop:

```zig
const pag_count: u32 = if (p._pagination) |plan| plan.total_pages - 1 else 0;
const pags = try gpa.alloc(
    @typeInfo(@TypeOf(p._render.pagination)).pointer.child,
    pag_count,
);
for (pags) |*x| x.* = .{ .out = "", .errors = "" };
p._render = .{
    .out = "",
    .errors = "",
    .alternatives = alts,
    .pagination = pags,
};
```

(i.e. add `.pagination = pags` to the existing `p._render = .{...}` assignment), and after the alternatives job loop (:2638-2648):

```zig
// Pagination page jobs. Queued in the SAME loop body as .main, so the
// dev incremental fast path (the changed_set filter above) re-queues
// them automatically whenever the index page itself re-renders.
var pag_n: u32 = 2;
while (pag_n <= pag_count + 1) : (pag_n += 1) {
    worker.addJob(io, .{
        .page_render = .{
            .progress = progress_page_render,
            .build = &build,
            .sites = &sites,
            .page = p,
            .kind = .{ .pagination = pag_n },
        },
    });
}
```

- [ ] **Step 5: Verify.** `zig build check` clean (all switches exhaustive), `zig build check -Dsingle-threaded` clean, `zig build test` — expected: NO snapshot diff (no fixture uses pagination yet; a diff here means behavior leaked into unpaginated pages — investigate, do not bless). `zig build test-init` pass.

- [ ] **Step 6: Commit**

```bash
zig fmt src/worker.zig src/context/Page.zig src/context/Root.zig src/root.zig
git add src/worker.zig src/context/Page.zig src/context/Root.zig src/root.zig
git commit -m "Render paginated section indexes N times via a new job kind

Reuses the alternatives machinery: one page_render job per extra page,
per-kind output path and result slot. Per-render window state rides on
context.Root (a stack local per job) — stashing it on Page would be a
data race across the N concurrent jobs reading the same *Page. Slots
mirror _render.alternatives because reusing the single _render.out from
N main-kind jobs races and leaks in .memory mode.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/worker.zig src/context/Page.zig src/context/Root.zig src/root.zig
```

---

### Task 6: Scripty API — windowed `subpages()`, `Paginator`, `$page.pagination?()`

**Files:**
- Modify: `src/context/Page.zig` (`subpages` at :1258, `subpagesAlphabetic` at :1299, new `Paginator` type + builtin)
- Modify: `src/context.zig` (`Value` union + `from`)
- Modify: `src/context/doctypes.zig` (`ScriptyParam`)

**Interfaces:**
- Consumes: `Root._pagination` (Task 5), `paginationSuffix` (Task 3) — via a shared URL printer.
- Produces: `Page.Paginator = struct { current: usize, total: usize, page_size: usize, total_items: usize, _page: *const Page }` with builtins `prevLink?()`, `nextLink?()` (Opt String — matching the `nextPage?()` idiom, since a shared layout has no comparison guard; NOTE this is a deliberate deviation from the spec's error-returning `prevLink()`/`nextLink()`), and `pageLink(n)` (String; n=1 → the section's canonical URL). Builtin `@"pagination?"` on Page returning `.{ .Opt = .Paginator }`.

- [ ] **Step 1: Windowing test via snapshot is deferred to Task 7 (Scripty builtins need a full build context; `src/context/` has no unit-test harness for them). This task is compile-driven; Task 7 is its test and MUST land in the same review.**

- [ ] **Step 2: The `Paginator` type.** In `Page.zig` beside `Alternative` (:568-658), following its exact shape:

```zig
pub const Paginator = struct {
    current: usize,
    total: usize,
    page_size: usize,
    total_items: usize,
    _page: *const Page,

    pub const Dot = true;

    pub const docs_description =
        \\The pagination state of the section-index render in progress:
        \\which window this output is, out of how many. Obtained from
        \\`$page.pagination?()`.
    ;
    pub const Fields = struct {
        pub const current =
            \\The current page number, 1-based.
        ;
        pub const total =
            \\How many pages this section paginates into.
        ;
        pub const page_size =
            \\How many subpages each window holds (`pagination.page_size`).
        ;
        pub const total_items =
            \\Total active subpages across all windows.
        ;
    };

    fn printPageUrl(
        pg: Paginator,
        w: *Writer,
        ctx: *const context.Root,
        n: usize,
    ) error{OutOfMemory}!void {
        const p = pg._page;
        const v = &ctx._meta.build.variants[p._scan.variant_id];
        // Compose through printLinkPrefix, exactly like $page.link():
        // it is the single point that makes url_path_prefix correct.
        ctx.printLinkPrefix(w, p._scan.variant_id, false) catch return error.OutOfMemory;
        w.print("{f}", .{
            p._scan.url.fmt(&v.string_table, &v.path_table, null, true),
        }) catch return error.OutOfMemory;
        if (n <= 1) return; // page 1 IS the section URL
        const style = p.pagination.?.url_style;
        switch (style) {
            .page_dir => w.print("page/{d}/", .{n}) catch return error.OutOfMemory,
            .plain_dir => w.print("{d}/", .{n}) catch return error.OutOfMemory,
            .page_html => w.print("page-{d}.html", .{n}) catch return error.OutOfMemory,
        }
    }

    pub const Builtins = struct {
        pub const @"prevLink?" = struct {
            pub const signature: Signature = .{ .ret = .{ .Opt = .String } };
            pub const docs_description =
                \\URL of the previous pagination page, or null on page 1.
                \\From page 2 this is the section's own URL.
            ;
            pub const examples =
                \\<a :if="$page.pagination?().prevLink?()" href="$if">Newer</a>
            ;
            pub fn call(
                pg: Paginator,
                gpa: Allocator,
                ctx: *const context.Root,
                args: []const Value,
            ) context.CallError!Value {
                if (args.len != 0) return .{ .err = "expected 0 arguments" };
                if (pg.current <= 1) return context.Optional.Null;
                var aw: Writer.Allocating = .init(gpa);
                try pg.printPageUrl(&aw.writer, ctx, pg.current - 1);
                return context.Optional.init(gpa, Value{ .string = .{ .value = aw.written() } });
            }
        };
        pub const @"nextLink?" = struct {
            pub const signature: Signature = .{ .ret = .{ .Opt = .String } };
            pub const docs_description =
                \\URL of the next pagination page, or null on the last page.
            ;
            pub const examples =
                \\<a :if="$page.pagination?().nextLink?()" href="$if">Older</a>
            ;
            pub fn call(
                pg: Paginator,
                gpa: Allocator,
                ctx: *const context.Root,
                args: []const Value,
            ) context.CallError!Value {
                if (args.len != 0) return .{ .err = "expected 0 arguments" };
                if (pg.current >= pg.total) return context.Optional.Null;
                var aw: Writer.Allocating = .init(gpa);
                try pg.printPageUrl(&aw.writer, ctx, pg.current + 1);
                return context.Optional.init(gpa, Value{ .string = .{ .value = aw.written() } });
            }
        };
        pub const pageLink = struct {
            pub const signature: Signature = .{ .params = &.{.Int}, .ret = .String };
            pub const docs_description =
                \\URL of pagination page `n` (1-based). Page 1 is the
                \\section's canonical URL. Errors when `n` is out of range.
            ;
            pub const examples =
                \\<a href="$page.pagination?().pageLink(2)">2</a>
            ;
            pub fn call(
                pg: Paginator,
                gpa: Allocator,
                ctx: *const context.Root,
                args: []const Value,
            ) context.CallError!Value {
                if (args.len != 1) return .{ .err = "expected 1 argument" };
                const n_val = switch (args[0]) {
                    .int => |i| i.value,
                    else => return .{ .err = "expected an integer argument" },
                };
                if (n_val < 1 or n_val > pg.total) {
                    return Value.errFmt(gpa, "page {d} is out of range (1..{d})", .{ n_val, pg.total });
                }
                var aw: Writer.Allocating = .init(gpa);
                try pg.printPageUrl(&aw.writer, ctx, @intCast(n_val));
                return String.init(aw.written());
            }
        };
    };
};
```

Note `examples` for the optional builtins: adjust the `$if` usage to whatever the current superhtml optional-unpacking idiom in this file's other examples is (`nextPage?`'s example at :1355 is the model).

- [ ] **Step 3: The `pagination?` builtin on Page.** In `Page.Builtins` beside `@"nextPage?"` (:1346):

```zig
pub const @"pagination?" = struct {
    pub const signature: Signature = .{ .ret = .{ .Opt = .Paginator } };
    pub const docs_description =
        \\Returns the pagination state when the current render is a
        \\window of THIS page's section (the page sets `.pagination`
        \\in its frontmatter), null otherwise — so shared layouts can
        \\branch with an `if` attribute.
    ;
    pub const examples =
        \\<div :if="$page.pagination?()">
        \\  <span :text="$if.current"></span> / <span :text="$if.total"></span>
        \\</div>
    ;
    pub fn call(
        p: *const Page,
        gpa: Allocator,
        ctx: *const context.Root,
        args: []const Value,
    ) context.CallError!Value {
        if (args.len != 0) return .{ .err = "expected 0 arguments" };
        const state = ctx._pagination orelse return context.Optional.Null;
        // Only the paginated index itself has a window; other pages
        // referenced during the same render (e.g. $site.page(...)) don't.
        if (p != ctx.page) return context.Optional.Null;
        return context.Optional.init(gpa, Value{ .paginator = .{
            .current = state.current,
            .total = state.total_pages,
            .page_size = state.page_size,
            .total_items = state.total_items,
            ._page = p,
        } });
    }
};
```

- [ ] **Step 4: Window `subpages()`/`subpagesAlphabetic()`.** In `subpages.call` (:1272-1296), replace the final `return`:

```zig
var active = pages[0..out_idx];
// Windowing: only the paginated index being rendered gets a slice —
// a DIFFERENT page's subpages() inside the same render (via
// $site.page(...)) must stay full, as must alternatives (state null).
if (ctx._pagination) |pg| {
    if (p == ctx.page) {
        const start = @min((pg.current - 1) * pg.page_size, active.len);
        const end = @min(start + pg.page_size, active.len);
        active = active[start..end];
    }
}
return context.Array.init(gpa, Value, active);
```

Same edit in `subpagesAlphabetic.call` (:1310-1343) — window FIRST (on the date-sorted list; the window is defined on date order), THEN alphabetic-sort the window: apply the slice to `pages` before the `std.mem.sort` call and sort/return the slice.

- [ ] **Step 5: Register `Paginator`.** `src/context.zig`: `Value` union gains `paginator: Page.Paginator,`; `Value.from` gains `Page.Paginator => .{ .paginator = v },`. `doctypes.zig`: `ScriptyParam` + `Base` gain `Paginator`; `fromType` gains `context.Page.Paginator => .Paginator,`. Chase remaining switch arms via `zig build check`.

- [ ] **Step 6: Verify + commit.** `zig build check` clean, `zig build check -Dsingle-threaded` clean, `zig build test` — still no diff expected. `zig build test-init` pass.

```bash
zig fmt src/context/Page.zig src/context.zig src/context/doctypes.zig
git add src/context/Page.zig src/context.zig src/context/doctypes.zig
git commit -m "Add the pagination Scripty surface

subpages() windows itself on the paginated index render — existing
section layouts paginate with zero template edits. pagination?() follows
the nextPage?() optional idiom (spec deviation: prev/next links are
Opt String, not error-returning — a shared layout has no comparison
builtin to guard an erroring call with). All URLs compose through
printLinkPrefix so url_path_prefix sites stay correct.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/context/Page.zig src/context.zig src/context/doctypes.zig
```

---

### Task 7: Snapshot fixtures — rendering + drafts

**Files:**
- Create: `tests/rendering/pagination/` (full site fixture)
- Create: `tests/drafts/pagination/` (same content, drafts included)

**Interfaces:**
- Consumes: everything from Tasks 1-6. This is Task 6's real test.

- [ ] **Step 1: Build the fixture.** `tests/rendering/pagination/zigapagos.ziggy`:

```ziggy
Site {
    .title = "Pagination Test Website",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "content",
}
```

Content tree (dates force the sort order — newest first; use distinct dates):

```
content/index.smd                 plain root index (layout root.shtml)
content/blog/index.smd            .pagination page_size=2, url_style default (page_dir), layout list.shtml
content/blog/post1.smd … post5.smd   5 posts → 3 pages
content/news/index.smd            .pagination page_size=2, .url_style = .plain_dir, layout list.shtml
content/news/n1.smd … n3.smd      3 posts → 2 pages
content/docs/index.smd            .pagination page_size=2, .url_style = .page_html, layout list.shtml
content/docs/d1.smd … d3.smd      3 posts → 2 pages
content/tiny/index.smd            .pagination page_size=10, layout list.shtml
content/tiny/t1.smd               1 post → 1 page (no page/2, pagination?() total=1)
content/drafty/index.smd          .pagination page_size=2, layout list.shtml
content/drafty/a.smd b.smd c.smd  active, .draft=false
content/drafty/x.smd              .draft = true  → 3 active → 2 pages (drafts excluded)
```

`layouts/list.shtml` — the load-bearing template (model markup on `tests/rendering/simple/`'s layouts for the html/head skeleton this repo's fixtures use):

```superhtml
<ul :loop="$page.subpages()">
  <li :text="$loop.it.title"></li>
</ul>
<div :if="$page.pagination?()">
  <p>Page <span :text="$if.current"></span> of <span :text="$if.total"></span>
     (<span :text="$if.total_items"></span> items, <span :text="$if.page_size"></span>/page)</p>
  <a :if="$if.prevLink?()" href="$if">newer</a>
  <a :if="$if.nextLink?()" href="$if">older</a>
  <a href="$if.pageLink(1)">first</a>
</div>
```

Adjust nesting to real superhtml semantics: nested `:if` rebinds `$if`, so if the inner `:if` shadows the Paginator, hoist with `<ctx pg="$page.pagination?()">`-style binding as done in `Alternative`'s example (`Page.zig:604-611`). Whatever spelling you land on, the OUTPUT must show: item titles per window, current/total, prev absent on page 1, next absent on the last page, and correct hrefs (`/blog/page/2/`, `/news/2/`, `/docs/page-2.html`).

- [ ] **Step 2: Run `zig build test`.** First run generates `snapshot.txt` + `snapshot/` and stages them. Inspect `git diff --cached -- tests/rendering/pagination` carefully — this diff IS the feature's acceptance test:
  - `snapshot/blog/index.html`, `snapshot/blog/page/2/index.html`, `snapshot/blog/page/3/index.html` exist; page 1 lists posts 5+4 (newest first), page 3 lists post 1.
  - `snapshot/news/2/index.html`, `snapshot/docs/page-2.html` exist.
  - `snapshot/tiny/index.html` shows `Page 1 of 1`; NO `tiny/page/` anywhere.
  - `snapshot/drafty/` has exactly 2 pages; the draft never appears.
  - No prev link on any page 1; no next link on any last page.

- [ ] **Step 3: Drafts root.** Copy the `drafty` section + config + layouts into `tests/drafts/pagination/` (that root builds with `--drafts`, so the draft becomes ACTIVE and the count arithmetic changes: 4 active → 2 full pages). Run `zig build test`, verify the drafts snapshot shows the draft post inside a window and the page count reflects 4 items. This pins the active-count-not-list-len rule.

- [ ] **Step 4: Verify-it-fails check.** `git stash` is forbidden; instead temporarily comment out the windowing block added in Task 6 Step 4 (`subpages.call`), run `zig build test`, and confirm the staged diff shows every page listing ALL posts (test catches the regression). Restore the code, re-run, confirm clean.

- [ ] **Step 5: Commit** (the snapshot machinery already staged `tests/`):

```bash
git add tests/rendering/pagination tests/drafts/pagination
git commit -m "Pin pagination rendering in snapshot fixtures

All three URL styles, the single-page section, first/last-page link
absence, and the drafts interaction (Section.pages includes drafts;
the count must not) — the drafts root builds with --drafts, so the
same section pins both sides of the arithmetic.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- tests/rendering/pagination tests/drafts/pagination
```

---

### Task 8: Stale-page prune + shell e2e

**Files:**
- Modify: `src/root.zig` (after the render barrier at :2683)
- Create: `tests/rendering/pagination.sh`

**Interfaces:**
- Consumes: `Page._pagination`, `paginationOutputPath`/`paginationPruneDir`/`paginationSuffix` (Task 3), `Variant.urls` + `paginationPathName` (Task 4).

- [ ] **Step 1: Write the failing e2e** `tests/rendering/pagination.sh`, modeled on `tests/rendering/incremental.sh`'s harness (header comment stating the claim, `set -euo pipefail`, `cd "$(dirname "$0")/../.."`, build `zig-out/bin/zigapagos` via `mise exec -- zig build` if missing, `WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT`, its own `fail()`). Body:

1. Copy `tests/rendering/pagination/{content,layouts,zigapagos.ziggy}` into `$WORK/site`; the fixture's blog has 5 posts / page_size 2 → 3 pages.
2. Build with `"$ZIGAPAGOS" release --force --output="$WORK/out"` from `$WORK/site` (match `incremental.sh`'s exact invocation shape). Assert `out/blog/page/2/index.html` and `out/blog/page/3/index.html` exist.
3. Assert `--summary` agreement: re-run with `--summary` captured to a file (unpiped; check `$?`), `grep -F 'blog/page/3/index.html'` in it, and under a "pagination pages" heading.
4. Assert `explain` knows: run `"$ZIGAPAGOS" explain content/blog/index.smd` (adjust to the real CLI shape — see `tests/summary/summary.sh` or `zigapagos explain --help` for invocation), grep `pagination page`.
5. Delete `post1.smd`..`post3.smd` (leaves 2 posts → 1 page). Rebuild with `--force` into the SAME `$WORK/out`. Assert `out/blog/index.html` exists, `out/blog/page/2` and `out/blog/page/3` are GONE (the prune), and `out/blog/page` dir is gone or empty.
6. Prune-skip proof: the fixture's `news` section is `.plain_dir` with 3 posts / page_size 2 → 2 pages. Add a REAL page `content/news/2.smd`?? No — that collides while pagination still emits page 2. Instead: shrink `news` to 1 post (delete n2/n3 → 1 page, so pagination page 2 is gone from the plan), AND add a real subpage named `content/news/2.smd` in the same edit. Rebuild. Assert `out/news/2/index.html` EXISTS and contains the real page's title (the prune probed `news/2`, found it registered in `Variant.urls` as a main output, and skipped it).
7. `echo "ALL PROOF CHECKS PASSED (pagination)"`.

- [ ] **Step 2: Run it — verify it fails at step 5** (prune not implemented; `page/3` survives): `bash tests/rendering/pagination.sh`; expected `FAIL:` on the page/3-gone assertion.

- [ ] **Step 3: Implement the prune** in `src/root.zig` right after the render barrier (`worker.wait()` at :2683), guarded like the SPA prerender:

```zig
// Stale pagination outputs: the FIRST feature whose output set shrinks
// as a function of content (a section dropping from 3 pages to 1), and
// dev always builds --force into the same tree, so without this the
// orphaned page/N/ dirs are served forever. Bounded probe past the last
// live page, mirroring the island stale-slice prune above; a candidate
// registered in Variant.urls is a REAL output that happens to sit at a
// pagination-shaped path (e.g. a subpage named "2" under .plain_dir
// after the section shrank) and is skipped, never deleted. Known
// limitation, same knowledge-bound as the island prune: removing
// `.pagination` from the frontmatter entirely leaves old page dirs
// behind — with no plan there is nothing to probe from.
if (build.mode == .disk and !incremental) {
    for (build.variants) |*v| {
        for (v.sections.items[1..]) |*s| {
            const index_page = &v.pages.items[s.index];
            const plan = index_page._pagination orelse continue;
            const style = index_page.pagination.?.url_style;
            var n: u32 = plan.total_pages + 1;
            while (true) : (n += 1) {
                // Skip (and stop probing past) outputs some page owns.
                const pn = v.paginationPathName(gpa, index_page, style, n) catch break;
                if (v.urls.get(pn) != null) continue;

                const rel = try worker.paginationOutputPath(gpa, build.cfg, v, index_page, style, n);
                defer gpa.free(rel);
                _ = build.mode.disk.output_dir.statFile(io, rel) catch break; // probe: first miss ends the sweep

                if (try worker.paginationPruneDir(gpa, style, n)) |sub| {
                    defer gpa.free(sub);
                    const page_dir = try worker.pageDir(gpa, build.cfg, v, index_page);
                    defer gpa.free(page_dir);
                    const full = try std.fmt.allocPrint(gpa, "{s}{s}", .{ page_dir, sub });
                    defer gpa.free(full);
                    build.mode.disk.output_dir.deleteTree(io, full) catch |err| fatal.msg(
                        "error: could not delete stale pagination output '{s}': {s}\n",
                        .{ full, @errorName(err) },
                    );
                } else {
                    build.mode.disk.output_dir.deleteFile(io, rel) catch |err| fatal.msg(
                        "error: could not delete stale pagination output '{s}': {s}\n",
                        .{ rel, @errorName(err) },
                    );
                }
            }
        }
    }
}
```

Adapt `statFile`/`deleteTree`/`deleteFile` to the actual `Io.Dir` API (the island prune at :877 and `Build.zig` show the idioms). Note `paginationPathName` interns into the tables — acceptable growth (bounded by the probe count), but if a lookup-only path exists (`PathName.get`-style, see `worker.zig:1307`), prefer it and treat "not internable" as "not registered".

- [ ] **Step 4: The `.main`-emit special case.** The prune handles n ≥ 2. One more stale shape: style CHANGED (e.g. `.page_dir` → `.plain_dir` leaves old `page/2/` while new `2/` is written). The probe loop above only sweeps the CURRENT style. Sweep all three styles per section: wrap the `while` in `inline for (@typeInfo(Page.Pagination.UrlStyle).@"enum".fields)`-style loop over styles (probe each style's paths from `if style == current: plan.total_pages + 1 else 2`). Keep it simple: three sequential probe loops, one per style, starting at 2 for non-current styles.

- [ ] **Step 5: Run the e2e to green**: `bash tests/rendering/pagination.sh` → `ALL PROOF CHECKS PASSED`. Also re-run `zig build test` (no unexpected snapshot diff — the snapshot tree is written fresh each run, so the prune is invisible there) and `bash scripts/check-allocator-contracts.sh`.

- [ ] **Step 6: Commit**

```bash
zig fmt src/root.zig
git add src/root.zig tests/rendering/pagination.sh
git commit -m "Prune stale pagination outputs after render

First feature where the output set shrinks with content; dev builds
--force into the same tree, so orphaned page/N dirs would be served
forever. Bounded probe past the plan, all three URL styles (a style
change orphans the old shape), skipping any candidate registered in
Variant.urls — a shrunken section that gained a real subpage named '2'
must not lose it to the sweep. E2e proves emit, summary/explain
agreement, prune, and the registered-URL skip.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/root.zig tests/rendering/pagination.sh
```

---

### Task 9: `--summary` + `explain` report pagination outputs

**Files:**
- Modify: `src/root.zig` (collect block at :2658-2678)
- Modify: `src/cli/explain.zig` (emitted-paths block at :499-557)

**Interfaces:**
- Consumes: `Page._pagination`, `paginationOutputPath` (Task 3), `summary.Category.page_pagination` (Task 4).

- [ ] **Step 1:** In the `if (collect) |sm|` block (`root.zig:2658`), after the alternatives loop:

```zig
if (p._pagination) |plan| {
    const style = p.pagination.?.url_style;
    var n: u32 = 2;
    while (n <= plan.total_pages) : (n += 1) {
        const pag_path = try worker.paginationOutputPath(gpa, build.cfg, v, p, style, n);
        defer gpa.free(pag_path);
        try sm.add(gpa, .page_pagination, pag_path);
    }
}
```

- [ ] **Step 2:** In `explain.zig`'s emitted-paths block: count registered pagination hints in the `it2` switch (`.page_pagination => pagination_count += 1,` with `var pagination_count: usize = 0;` beside `alias_count`), and print after the alternatives loop:

```zig
if (page._pagination) |plan| {
    const style = page.pagination.?.url_style;
    var n: u32 = 2;
    while (n <= plan.total_pages) : (n += 1) {
        const p2 = try worker.paginationOutputPath(alloc, build.cfg, v, page, style, n);
        defer alloc.free(p2);
        try w.print("  {s}   pagination page {d}\n", .{ p2, n });
    }
    if (plan.total_pages - 1 != pagination_count) {
        try w.print(
            "  (note: {d} pagination hint(s) registered in Variant.urls but the plan has {d} page(s) — please report this)\n",
            .{ pagination_count, plan.total_pages },
        );
    }
}
```

- [ ] **Step 3: Verify via the e2e** (its steps 3-4 assert exactly this output): `bash tests/rendering/pagination.sh` → pass. Run `bash tests/summary/summary.sh` → pass (it cross-checks the printed set against the emitted tree; a divergence here means the helper drifted).

- [ ] **Step 4: Commit**

```bash
zig fmt src/root.zig src/cli/explain.zig
git add src/root.zig src/cli/explain.zig
git commit -m "Report pagination outputs in --summary and explain

Recorded beside the jobs that do the writing, through the same path
helper renderPage emits with, so the inventory can't drift from the
tree (the H7 rule).

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/root.zig src/cli/explain.zig
```

---

### Task 10: Generated + written docs

**Files:**
- Regenerate: `docs/scripty.md` (via `zig build docs-reference` — NEVER hand-edit)
- Modify: `docs/migration/astro-to-zigapagos.md`

**Interfaces:** consumes the Task 6 API names verbatim.

- [ ] **Step 1:** Run `zig build docs-reference`. Inspect the `docs/scripty.md` diff: the `pagination` field, the `pagination?` builtin, and the `Paginator` type with all four fields and three builtins must appear. **If any is missing, the docgen silently skipped it** — a field lacking a `Fields` entry or a type not reachable from the `Value` union; fix the registration (Task 1/6), regenerate. Gate: `bash tests/meta/scripty-reference.sh` must pass.

- [ ] **Step 2:** `docs/migration/astro-to-zigapagos.md` edits (the `site/content/docs/` mirror is generated — do not touch it):

(a) §3 routing table (:81-90): fix the header to three columns (`| Astro | Zigapagos | Notes |` + separator — row 90 already has a third cell the two-column header silently drops) and add:

```markdown
| `src/pages/blog/[page].astro` / `[...page].astro` + `paginate()` | `.pagination = .{ .page_size = N }` on `content/blog/index.smd` | Native pagination (§11). Delete the route file; the section index renders once per window. |
```

(b) §11 (after the "Per-section collections" subsection at :487-495) — new subsection, house style (table → bullets → code):

```markdown
### Pagination (`paginate()` → `.pagination`)

| Astro | Zigapagos |
|---|---|
| `paginate(posts, { pageSize: 10 })` | `.pagination = .{ .page_size = 10 }` on the section's `index.smd` |
| `page.data` | `$page.subpages()` (windowed automatically on a paginated render) |
| `page.currentPage` | `$page.pagination?()` → `.current` |
| `page.lastPage` | `.total` |
| `page.size` | `.page_size` |
| `page.total` | `.total_items` |
| `page.url.prev` / `page.url.next` | `.prevLink?()` / `.nextLink?()` |
| `page.url.first` / `page.url.last` | `.pageLink(1)` / `.pageLink($…total)` |
| `page.start` / `page.end` | no equivalent (compute from `.current` and `.page_size` if needed) |

- URL shape is `.url_style`: `page_dir` (`/blog/page/2/`, the default), `plain_dir`
  (`/blog/2/` — Astro's rest-parameter shape), `page_html` (`/blog/page-2.html`).
- Astro's two filename forms differ: `[...page].astro` puts page 1 at `/blog/`
  (exact parity with `plain_dir`); `[page].astro` puts page 1 at `/blog/1` —
  in Zigapagos page 1 is ALWAYS the section URL, so add
  `.aliases = ["1/index.html"]` if the old `/blog/1` URL must keep working.
- Astro never emits `/page/2/` — that expectation comes from Hugo/Jekyll;
  `page_dir` provides it natively.
- Astro 7.1's `format()` option exists to patch pagination URLs for hosts
  without rewrite rules; Zigapagos emits directory-style outputs everywhere,
  so there is no equivalent to need — `page_html` covers the no-rewrites host.

```superhtml
<ul :loop="$page.subpages()"><li :text="$loop.it.title"></li></ul>
<div :if="$page.pagination?()">
  <a :if="$if.prevLink?()" href="$if">Newer</a>
  <a :if="$if.nextLink?()" href="$if">Older</a>
</div>
```
```

(Adjust the code block to the final template idiom Task 7 landed.)

(c) Gaps section (:577-584): scope the dynamic-routes bullet — replace "the content layer has no `getStaticPaths`; generate one `.smd` per entry" with wording that carves out pagination, e.g.: "**Dynamic routes (`[slug]`) in static content** — the content layer has no general `getStaticPaths`; generate one `.smd` per entry. Paginated routes (`[page]`/`[...page]` + `paginate()`) are the exception: they map to native `.pagination` (§11). For app-like pages, …" (keep the existing SPA sentence).

- [ ] **Step 3: Verify:** `bash tests/meta/scripty-reference.sh`, `bash tests/branding.sh` (new prose must not use the upstream name), and `bash site/test/docs-mirror.sh` if it runs locally (CI gates it; it regenerates the mirror from the `.md`).

- [ ] **Step 4: Commit**

```bash
git add docs/scripty.md docs/migration/astro-to-zigapagos.md
git commit -m "Document pagination: regenerate the Scripty reference, map paginate()

The migration mapping is a §11 subsection, not a new numbered section —
eleven in-prose §N references and an anchor link would silently break
on renumbering. §3 grows the pagination routing row (and the three-
column header its table already needed).

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- docs/scripty.md docs/migration/astro-to-zigapagos.md
```

---

### Task 11: Importer — `detectPaginate` in `migrate_detect.zig`

**Files:**
- Modify: `src/cli/migrate_detect.zig` (std-only, string-testable module — its stated contract at :1-6)
- Test: same file, `test "paginate: ..."` blocks (suite: `zig build test-migrate`)

**Interfaces:**
- Produces:

```zig
pub const PaginateSpec = struct {
    /// Slice of the caller's `path` (NOT owned): the section dir relative to
    /// src/pages/, "" for a root-level paginated route.
    section: []const u8,
    route_form: enum { numbered, rest },
    page_size: u32,
    /// False when paginate() was found but pageSize wasn't an integer
    /// literal — the caller flags it for review and uses the default 10.
    page_size_is_literal: bool,
};
pub fn detectPaginate(path: []const u8, src: []const u8) ?PaginateSpec
```

Tasks 12-13 consume this.

- [ ] **Step 1: Write the failing tests** (append near the other detection tests at :893+):

```zig
test "paginate: detects rest and numbered forms with pageSize" {
    const src =
        \\---
        \\import { getCollection } from "astro:content";
        \\export async function getStaticPaths({ paginate }) {
        \\  const posts = await getCollection("blog");
        \\  return paginate(posts, { pageSize: 10 });
        \\}
        \\const { page } = Astro.props;
        \\---
        \\<ul>{page.data.map((p) => <li>{p.data.title}</li>)}</ul>
    ;
    const rest = detectPaginate("src/pages/blog/[...page].astro", src).?;
    try testing.expectEqualStrings("blog", rest.section);
    try testing.expectEqual(.rest, rest.route_form);
    try testing.expectEqual(@as(u32, 10), rest.page_size);
    try testing.expect(rest.page_size_is_literal);

    const numbered = detectPaginate("src/pages/blog/[page].astro", src).?;
    try testing.expectEqual(.numbered, numbered.route_form);
}

test "paginate: nested section, defaulted and non-literal pageSize" {
    const no_size =
        \\---
        \\export function getStaticPaths({ paginate }) {
        \\  return paginate(items);
        \\}
        \\---
    ;
    const spec = detectPaginate("src/pages/a/b/[page].astro", no_size).?;
    try testing.expectEqualStrings("a/b", spec.section);
    try testing.expectEqual(@as(u32, 10), spec.page_size); // Astro's default
    try testing.expect(spec.page_size_is_literal); // absent == known default

    const computed =
        \\---
        \\export function getStaticPaths({ paginate }) {
        \\  return paginate(items, { pageSize: SIZE });
        \\}
        \\---
    ;
    const spec2 = detectPaginate("src/pages/a/[page].astro", computed).?;
    try testing.expectEqual(@as(u32, 10), spec2.page_size);
    try testing.expect(!spec2.page_size_is_literal);
}

test "paginate: non-matches return null" {
    const paginate_src =
        \\---
        \\export function getStaticPaths({ paginate }) { return paginate(x); }
        \\---
    ;
    // Wrong basename: paginate() requires the param be named `page`.
    try testing.expectEqual(null, detectPaginate("src/pages/blog/[slug].astro", paginate_src));
    // Right basename, no paginate in the fence.
    try testing.expectEqual(null, detectPaginate("src/pages/blog/[page].astro",
        \\---
        \\export function getStaticPaths() { return []; }
        \\---
    ));
    // paginate mentioned only in the BODY, not the fence.
    try testing.expectEqual(null, detectPaginate("src/pages/blog/[page].astro",
        \\---
        \\const x = 1;
        \\---
        \\<p>call paginate() yourself</p>
    ));
    // Not under src/pages/.
    try testing.expectEqual(null, detectPaginate("src/components/[page].astro", paginate_src));
}
```

- [ ] **Step 2: Run to verify failure**: `zig build test-migrate` → compile error, `detectPaginate` undeclared.

- [ ] **Step 3: Implement** (near `collectClientUsages` at :51). Sketch — pure string work, std-only:

```zig
/// Detect Astro's paginate() pattern: a src/pages/**/[page].astro or
/// [...page].astro whose frontmatter fence calls paginate() inside
/// getStaticPaths. Astro requires the dynamic segment be named `page`
/// for paginate(), so the basename check is exact, not heuristic.
/// Returns slices of `path`; nothing is allocated or owned.
pub fn detectPaginate(path: []const u8, src: []const u8) ?PaginateSpec {
    const pages_prefix = "src/pages/";
    if (!std.mem.startsWith(u8, path, pages_prefix)) return null;
    const rel = path[pages_prefix.len..];
    const basename = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    const route_form: @FieldType(PaginateSpec, "route_form") =
        if (std.mem.eql(u8, basename, "[...page].astro")) .rest
        else if (std.mem.eql(u8, basename, "[page].astro")) .numbered
        else return null;
    const section = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[0..i] else "";

    // Scope to the leading frontmatter fence: nothing in the template body
    // counts. The fence is `---\n ... \n---`.
    const fence = frontmatterFence(src) orelse return null;
    if (std.mem.indexOf(u8, fence, "getStaticPaths") == null) return null;
    if (std.mem.indexOf(u8, fence, "paginate(") == null) return null;

    var page_size: u32 = 10; // Astro's documented default
    var literal = true;
    if (std.mem.indexOf(u8, fence, "pageSize")) |i| {
        var j = i + "pageSize".len;
        while (j < fence.len and (fence[j] == ':' or fence[j] == ' ' or fence[j] == '\t')) j += 1;
        var k = j;
        while (k < fence.len and std.ascii.isDigit(fence[k])) k += 1;
        if (k > j) {
            page_size = std.fmt.parseInt(u32, fence[j..k], 10) catch blk: {
                literal = false;
                break :blk 10;
            };
        } else literal = false;
    }
    return .{
        .section = section,
        .route_form = route_form,
        .page_size = page_size,
        .page_size_is_literal = literal,
    };
}

/// The text between the leading `---` fence pair, or null when the file
/// has no complete fence. New helper: nothing in this module scoped to
/// the fence before.
fn frontmatterFence(src: []const u8) ?[]const u8 {
    const trimmed_start = std.mem.indexOf(u8, src, "---") orelse return null;
    if (trimmed_start != 0 and !std.mem.eql(u8, std.mem.trimStart(u8, src[0..trimmed_start], " \t\r\n"), "")) return null;
    const body_start = trimmed_start + 3;
    const rel_end = std.mem.indexOf(u8, src[body_start..], "\n---") orelse return null;
    return src[body_start .. body_start + rel_end];
}
```

- [ ] **Step 4: Run**: `zig build test-migrate` → pass (all four tests).

- [ ] **Step 5: Commit**

```bash
zig fmt src/cli/migrate_detect.zig
git add src/cli/migrate_detect.zig
git commit -m "Detect Astro paginate() routes in the migrate scanner module

Fence-scoped, string-only, std-only per this module's contract. The
basename check is exact — Astro requires paginate()'s dynamic segment
to be named 'page' — so [slug] routes stay undetected on purpose.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/migrate_detect.zig
```

---

### Task 12: `zigapagos migrate` — worklist line + capabilities section + fixture

**Files:**
- Modify: `src/cli/migrate.zig` (`Entry` at :59, `scanFile` at :226-250, `section()` at :739)
- Modify: `src/cli/migrate_detect.zig` (`capabilities_section` at :579-609 + drift test at :899)
- Modify: `tests/migrate/astro-sample/` (new fixture page + README line)

**Interfaces:**
- Consumes: `detect.detectPaginate` (Task 11).
- Produces: `Entry.paginate: ?detect.PaginateSpec = null` (borrows `Entry.path`; freed with it — no separate free). Task 13 consumes it.
- **Constraint:** `migrate` converts nothing — that is test-pinned (`migrate.zig:1065`). This task only reports.

- [ ] **Step 1: Failing test** (append to `migrate.zig`'s tests, :847+, using its `std.testing.tmpDir` style — model on an existing scan test in that range):

```zig
test "paginate: scan flags a paginated route and buildReport prescribes the conversion" {
    // Build a fake astro tree in a tmp dir with a paginated route, scan it,
    // and check the worklist output.
    // (Model the tmpDir + Io setup on the existing scan tests above.)
    // After scan: the src/pages/blog/[page].astro entry has .paginate != null,
    // spec.section == "blog", spec.page_size == 4.
    // buildReport output contains:
    //   "`src/pages/blog/[page].astro`"
    //   "delete the route file"
    //   ".pagination = .{ .page_size = 4, .url_style = .plain_dir }"
    //   "content/blog/index.smd"
}
```

Write it fully by copying the closest existing scan test's harness (there is one that writes files and calls `scan` — reuse its setup verbatim, change the file set). Assertions via `std.mem.indexOf` on the report string, like the capabilities test.

- [ ] **Step 2: Run to verify failure**: `zig build test-init` → fails (no `.paginate` field / report line).

- [ ] **Step 3: Implement.**

`Entry` (:59): add `paginate: ?detect.PaginateSpec = null,` with a comment: `// Borrows Entry.path; freed with it.` (`freeScanResult` at :113 needs no change — document WHY in the field comment.)

`scanFile` (:226): pages only:

```zig
const paginate = if (kind == .page) detect.detectPaginate(path, content) else null;
out.append(gpa, .{ .path = path, .kind = kind, .uses_islands = uses, .paginate = paginate }) catch fatal.oom();
```

**Bug to avoid:** `PaginateSpec.section` must slice `path` — the `Entry.path` that outlives the call — not `content`, which is freed at `scanFile`'s end. `detectPaginate(path, src)` takes both; its section slices `path`. Correct as written in Task 11; re-verify when wiring.

`section()` (:739) — extend the per-entry note:

```zig
for (entries) |e| {
    if (e.kind == kind) {
        if (e.paginate) |spec| {
            w.print(
                "- [ ] `{s}` — uses `paginate()`: delete the route file and add `.pagination = .{{ .page_size = {d}, .url_style = .plain_dir }}` to `content/{s}{s}index.smd` (mapping reference §11).{s}{s}\n",
                .{
                    e.path,
                    spec.page_size,
                    spec.section,
                    if (spec.section.len == 0) "" else "/",
                    if (spec.route_form == .numbered)
                        " Numbered form: page 1 moves from `/1` to the section URL; add `.aliases = [\"1/index.html\"]` if the old URL must keep working."
                    else
                        "",
                    if (!spec.page_size_is_literal)
                        " NOTE: pageSize was not an integer literal — 10 assumed; verify."
                    else
                        "",
                },
            ) catch fatal.oom();
            any = true;
            continue;
        }
        const note = if (e.uses_islands) "  — contains `client:` usage; translate the island sites" else "";
        w.print("- [ ] `{s}`{s}\n", .{ e.path, note }) catch fatal.oom();
        any = true;
    }
}
```

(The `content/{s}{s}index.smd` spelling collapses to `content/index.smd` for a root-level paginated route, matching Task 13's root-section skip.)

`capabilities_section` (`migrate_detect.zig:579`): in the Supported checkbox, append before the final period: `, and paginated sections (Astro `paginate()` → `.pagination` on a section index)`. In the Gaps checkbox, change `dynamic routes `[slug]`` to `dynamic routes `[slug]` (but `[page]`/`[...page]` paginated routes are native — see the mapping reference §11)`. **Wording constraint:** the Gaps text must NOT contain the exact string `pagination` — the drift test will assert `"pagination"` appears under Supported and NOT under Gaps, and `"paginated"` does not contain `"pagination"` as a substring, so the wording above is safe; double-check before committing.

Drift test (:899): add `"pagination"` to the `shipped` array.

Fixture: add `tests/migrate/astro-sample/src/pages/blog/[page].astro`:

```astro
---
import { getCollection } from "astro:content";
export async function getStaticPaths({ paginate }) {
  const posts = await getCollection("blog");
  return paginate(posts, { pageSize: 4 });
}
const { page } = Astro.props;
---
<ul>
  {page.data.map((post) => <li><a href={post.url}>{post.data.title}</a></li>)}
</ul>
<a href={page.url.prev}>Newer</a>
<a href={page.url.next}>Older</a>
```

and a line in that fixture's `README.md` stating the expected classification (paginated route → worklist conversion instruction, not an island/partial).

`migrate --doctor`: `doctorFile` (reached from `migrate.zig:155,793`) analyzes one file; add a paginate line to its report when `detectPaginate` fires (same sentence as the worklist line). Follow the existing doctor renderer tests (`migrate_detect.zig:1284,1302`) and add one assertion there.

- [ ] **Step 4: Run**: `zig build test-migrate` and `zig build test-init` → pass, including the drift guard.

- [ ] **Step 5: Commit**

```bash
zig fmt src/cli/migrate.zig src/cli/migrate_detect.zig
git add src/cli/migrate.zig src/cli/migrate_detect.zig tests/migrate/astro-sample
git commit -m "migrate: detect paginate() routes and prescribe the conversion

migrate still converts nothing (test-pinned); the worklist gains the
exact frontmatter to paste and where. Capabilities: pagination moves to
Supported; the [slug] gap is scoped to exclude [page]/[...page] — worded
so the drift guard can assert 'pagination' appears only under Supported.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/migrate.zig src/cli/migrate_detect.zig tests/migrate/astro-sample
```

---

### Task 13: `init --from-astro` converts paginated routes

**Files:**
- Modify: `src/cli/init_from_astro.zig` (`emitContentStub` neighborhood at :474-491, `run()` write list at :806-831)
- Modify: `tests/init/from-astro.sh`

**Interfaces:**
- Consumes: `Entry.paginate` (Task 12), `escapeZiggyStr` (`init_from_astro.zig:410`).
- Produces: `pub fn emitSectionIndexStub(gpa: Allocator, name: []const u8, spec: migrate.detect.PaginateSpec) []const u8`.

- [ ] **Step 1: Failing unit test** (append to `init_from_astro.zig` tests, :859+, string-assertion style like the `emitContentStub`/`escapeZiggyStr` tests there):

```zig
test "paginate: emitSectionIndexStub carries the pagination frontmatter" {
    const spec: migrate.detect.PaginateSpec = .{
        .section = "blog",
        .route_form = .rest,
        .page_size = 4,
        .page_size_is_literal = true,
    };
    const out = emitSectionIndexStub(std.testing.allocator, "blog", spec);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out,
        ".pagination = .{ .page_size = 4, .url_style = .plain_dir },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".layout = \"index.shtml\",") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "---\n"));
}
```

- [ ] **Step 2: Run to verify failure**: `zig build test-init` → compile error.

- [ ] **Step 3: Implement.** Beside `emitContentStub` (:474):

```zig
/// A section-index stub for a detected Astro paginate() route — the same
/// stub emitContentStub writes, plus the .pagination line. Both Astro
/// filename forms map to .plain_dir (the rest form is exact URL parity;
/// the numbered form differs only at page 1, which Zigapagos always puts
/// at the section URL — MIGRATION.md carries the aliases note).
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing).
pub fn emitSectionIndexStub(
    gpa: Allocator,
    name: []const u8,
    spec: migrate.detect.PaginateSpec,
) []const u8 {
    const safe_name = escapeZiggyStr(gpa, name);
    defer gpa.free(safe_name);
    return std.fmt.allocPrint(gpa,
        \\---
        \\.title = "{s}",
        \\.date = @date("1970-01-01T00:00:00"),
        \\.layout = "index.shtml",
        \\.draft = false,
        \\.pagination = .{{ .page_size = {d}, .url_style = .plain_dir }},
        \\---
        \\
        \\TODO: port the paginated listing from the original Astro route
        \\(the layout's `$page.subpages()` loop is windowed automatically).
        \\
    , .{ safe_name, spec.page_size }) catch fatal.oom();
}
```

In `run()` after the `content/index.smd` write (:818):

```zig
// Convert detected paginate() routes: the first per-section files the
// importer emits. Non-clobber semantics come from writeFile (.new on
// collision), same as every other scaffolded file.
for (res.entries) |e| {
    const spec = e.paginate orelse continue;
    if (spec.section.len == 0) continue; // root paginate: content/index.smd already written; MIGRATION.md carries the instruction
    const rel = std.fmt.allocPrint(a, "content/{s}/index.smd", .{spec.section}) catch fatal.oom();
    trackOutcome(&written, writeFile(io, out_dir, rel, emitSectionIndexStub(a, spec.section, spec), o.force));
}
```

- [ ] **Step 4: e2e.** Extend `tests/init/from-astro.sh` (after the generated-tree assertions at :58-63): assert `content/blog/index.smd` exists in the output and contains `.pagination = .{ .page_size = 4, .url_style = .plain_dir },`, and that `MIGRATION.md` contains the `paginate()` worklist instruction. (The fixture page was added in Task 12, so plain re-run picks it up.) Run `bash tests/init/from-astro.sh` → `PASS` end to end (needs `bun` on PATH; in a fresh worktree run `cd runtime && bun install --frozen-lockfile` first — and note the mise-shim gotcha: if it dies with "No version is set for shim: bun", it's environment, not code).

- [ ] **Step 5: Run all importer suites**: `zig build test-migrate test-init` → pass.

- [ ] **Step 6: Commit**

```bash
zig fmt src/cli/init_from_astro.zig
git add src/cli/init_from_astro.zig tests/init/from-astro.sh
git commit -m "init --from-astro: convert paginate() routes to section stubs

The importer's file-emitting path gains its first per-section output: a
content/<section>/index.smd carrying the detected .pagination settings.
Both Astro filename forms map to .plain_dir; the page-1 URL difference
of the numbered form is a MIGRATION.md note, not a build artifact.

Part of issue #127.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/init_from_astro.zig tests/init/from-astro.sh
```

---

### Task 14: Full-gate verification sweep

**Files:** none new — this task runs every gate and fixes fallout only.

- [ ] **Step 1:** `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` → clean.
- [ ] **Step 2:** `zig build check` and `zig build check -Dsingle-threaded` → clean (the single-threaded gate compiles every test binary; a test that reaches `std.Thread.spawn` is a compile error there — prune with `if (comptime !builtin.single_threaded)`, never `error.SkipZigTest`).
- [ ] **Step 3:** All seventeen unit suites: `zig build test-islands test-props test-migrate test-sidecar test-init test-release test-debug test-spa test-assets test-e2e test-dev test-doctor test-slugs test-validate test-explain test-diag test-summary` → pass.
- [ ] **Step 4:** `zig build test` → no unstaged surprises; `git diff --cached -- tests/` empty (fixtures already committed).
- [ ] **Step 5:** `zig build api-check` → pass (should be untouched; a failure means something leaked into codegen).
- [ ] **Step 6:** `bash scripts/check-allocator-contracts.sh` and `bash scripts/check-allocator-contracts.test.sh` → pass.
- [ ] **Step 7:** Shell e2e, at minimum the touched areas: `bash tests/rendering/pagination.sh`, `bash tests/rendering/incremental.sh`, `bash tests/init/from-astro.sh`, `bash tests/summary/summary.sh`, `bash tests/meta/scripty-reference.sh`, `bash tests/meta/build-errors-doc.sh`, `bash tests/branding.sh`, `bash tests/spa/prerender-order.sh`.
- [ ] **Step 8:** `cd runtime && bun test` → 685+ pass (nothing here should touch TS, but the gate is cheap).
- [ ] **Step 9:** `zig build docs-reference` → zero diff (docs already regenerated in Task 10).
- [ ] **Step 10:** Commit any stragglers with explicit paths; push the branch. Do NOT open a PR yet — run the tell-a-git-story skill first (user preference: curate history before any PR), then `gh pr create --repo valthon/zigapagos` (NEVER without `--repo`; `gh` defaults to the upstream remote).

---

## Self-review notes (already applied)

- Spec coverage: frontmatter (T1), validation (T2), URL shapes + helper (T3), planning/registration/ResourceKind (T4), N-render + Root state (T5), Scripty API + windowing (T6), fixtures incl. drafts (T7), prune + e2e (T8), summary/explain (T9), docs + migration §11/§3/Gaps (T10), importer detect (T11), migrate worklist/capabilities/doctor/fixture (T12), init conversion (T13), gates (T14). Dev incremental re-queue is by-construction in T5 Step 4 (jobs queued in the same filtered loop body).
- Deliberate spec deviations, called out inline: `prevLink?()`/`nextLink?()` return Opt String instead of erroring (T6 — a shared layout cannot guard an erroring call); the prune also sweeps non-current URL styles (T8 Step 4 — a style change orphans the old shape, which the spec missed).
- Type-consistency: `PaginateSpec` fields, `Paginator` fields, `PaginationState` fields, `_pagination` plan fields, and the helper signatures are spelled identically at every use site above.
- Known adapt-points (exact code depends on APIs the plan quotes but could not fully verify): `ziggy.parseLeaky` options (T1), `internPath` argument type (T4), `Io.Dir` stat/delete idioms (T8), explain CLI invocation (T8 e2e), superhtml `$if` rebinding in nested `:if` (T7). Each is flagged at its step with where to look.
