//! `sitemap.xml` emission (issue #150): a sibling Zig pass to the render
//! pipeline, not a bun-driven one -- a plain content site (no islands, no
//! SPAs) is the most common sitemap consumer, and it never enters the
//! bun-gated host-config block in `src/cli/release.zig`. See that file's
//! call site and the design caveat on the issue for the full reasoning.
//!
//! Coverage rules (matched against the exact filters the page-render loop
//! and `spa.zig`'s prerender pass already apply, so this can never disagree
//! with what a build actually installed):
//!   - drafts excluded (`Page._parse.active == false`);
//!   - alias/alternative duplicates excluded -- only a page's own canonical
//!     URL (main render + pagination windows) is listed, never `p.aliases`
//!     or `p.alternatives`. A page whose alias/alternative resolves to the
//!     site-root 'sitemap.xml' is a hard build error instead (root.zig's
//!     `fatalIfSitemapRootCollision`), so this pass never has to arbitrate
//!     a collision with itself;
//!   - a paginated section's page-2+ windows are listed, one URL per window,
//!     suffixed per its `url_style`;
//!   - a prerendered SPA route is listed only when it is a REAL, indexable
//!     page: a declared static route or a `staticPaths` concrete entry (a
//!     dynamic route's own pattern shell, `_shell.html`, is never listed,
//!     since "/app/club/:id" is not a URL anyone can visit) AND the owning
//!     SPA does not have `noindex` on (the default -- see `spa.zig`'s
//!     `desc.spa.noindex orelse true`). A noindex SPA's shells already carry
//!     `<meta name="robots" content="noindex">`; listing them here would
//!     submit URLs to search engines that the same build tells them not to
//!     index (Search Console's "Submitted URL marked 'noindex'").
//!
//! Deliberately NOT here (see the issue and NO_SLOP discipline): a `doctor`
//! cross-reference check against the installed tree, a sitemap-index for
//! sites past the 50k-URL single-file limit, and `<lastmod>` -- all named as
//! follow-ups, none built.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Build = @import("Build.zig");
const context = @import("context.zig");
const Root = @import("context/Root.zig");
const StringTable = @import("StringTable.zig");
const PathTable = @import("PathTable.zig");

/// Root-relative name of the emitted file. Shared with `src/root.zig`'s
/// alias-collision check (search this repo for "sitemap.filename") so the
/// two can never name the artifact differently.
pub const filename = "sitemap.xml";

/// Emit `sitemap.xml` at `out_dir`'s root.
///
/// Only meaningful to call when `build.cfg.getSitemap()` is true (checked by
/// the caller, `src/cli/release.zig`, which also gates the call on a full,
/// non-incremental disk build -- see that call site's comment for why an
/// incremental `zigapagos dev` rebuild must leave a previously-written
/// sitemap untouched rather than regenerate a partial one).
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): every URL string is
/// composed into scratch, appended to a temporary list, sorted, written to
/// the XML buffer and freed -- nothing escapes this function but the file
/// it writes to `out_dir`.
pub fn write(io: Io, gpa: Allocator, build: *const Build, out_dir: Io.Dir) !void {
    var urls: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (urls.items) |u| gpa.free(u);
        urls.deinit(gpa);
    }

    const host_url = build.cfg.getHostUrl(null);
    const url_path_prefix = build.cfg.getUrlPathPrefix();

    for (build.variants) |*v| {
        for (v.pages.items) |*p| {
            // Mirrors, field for field, the filter `root.zig`'s page-render
            // loop applies before queuing a render job -- a page that fails
            // any of these never reaches disk, so it must never reach the
            // sitemap either. (The loop's fifth condition, the incremental
            // changed-files skip, is irrelevant here: the caller already
            // restricts sitemap emission to full, non-incremental builds.)
            if (!p._parse.active) continue;
            if (p._parse.status != .parsed) continue;
            if (p._analysis.frontmatter.items.len > 0) continue;
            if (context.Page.PageAnalysisError.anyError(p._analysis.page.items)) continue;

            try urls.append(gpa, try composePageUrl(gpa, host_url, url_path_prefix, &v.string_table, &v.path_table, p, 1));

            if (p._pagination) |plan| {
                var n: u32 = 2;
                while (n <= plan.total_pages) : (n += 1) {
                    try urls.append(gpa, try composePageUrl(gpa, host_url, url_path_prefix, &v.string_table, &v.path_table, p, n));
                }
            }
        }
    }

    for (build.sitemap_urls.items) |u| {
        try urls.append(gpa, try composeRawUrl(gpa, host_url, url_path_prefix, u));
    }

    // Sorted for the same reason `Summary.sortEntries` sorts (see that
    // function's doc comment): page iteration order depends on filesystem
    // walk / hash-map order, so an unsorted sitemap would reorder itself
    // between two builds of an unchanged site, which is not a property a
    // diffable release artifact should have.
    std.mem.sort([]const u8, urls.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.writeAll("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    for (urls.items) |u| {
        try w.writeAll("  <url><loc>");
        try writeXmlEscaped(w, u);
        try w.writeAll("</loc></url>\n");
    }
    try w.writeAll("</urlset>\n");

    var f = try out_dir.createFile(io, filename, .{});
    defer f.close(io);
    var fw = f.writer(io, &.{});
    try fw.interface.writeAll(aw.written());
}

/// Compose one absolute page URL: `host_url` + `url_path_prefix` (via
/// `Root.printSimplePrefix`, the SAME chokepoint `$page.link()` and
/// `$page.pagination?().nextLink?()` compose through -- see that function's
/// doc comment for why this pass cannot just call `printLinkPrefix` itself)
/// + the page's own URL path + (for `n > 1`) the pagination window's
/// `url_style` suffix. NO_SLOP.md §2.2a contract 1 (self-freeing scratch,
/// one slice escapes as the return; caller frees it).
fn composePageUrl(
    gpa: Allocator,
    host_url: []const u8,
    url_path_prefix: []const u8,
    st: *const StringTable,
    pt: *const PathTable,
    p: *const context.Page,
    n: u32,
) ![]const u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try Root.printSimplePrefix(w, host_url, url_path_prefix, true);
    try w.print("{f}", .{p._scan.url.fmt(st, pt, null, true)});
    if (n > 1) try p.pagination.?.url_style.writePathnameTail(w, n);
    return aw.toOwnedSlice();
}

/// Compose one absolute URL from an already-relative-to-site-root path (an
/// SPA `static_url`, e.g. "/app/club/1/") -- same prefix chokepoint as
/// `composePageUrl`, just without a `Page` to read a `Path` off of. Contract
/// 1 (self-freeing), same as `composePageUrl`.
fn composeRawUrl(gpa: Allocator, host_url: []const u8, url_path_prefix: []const u8, path: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try Root.printSimplePrefix(w, host_url, url_path_prefix, true);
    try w.writeAll(std.mem.trimStart(u8, path, "/"));
    return aw.toOwnedSlice();
}

/// XML-escape the five characters the sitemap spec requires inside `<loc>`
/// (https://www.sitemaps.org/protocol.html#escaping). A page URL built from
/// `host_url` + slug-derived path segments essentially never contains one of
/// these, but a `&`/`'` in a hand-authored `aliases`/pagination-adjacent
/// segment is not impossible, and an unescaped `&` breaks the XML.
fn writeXmlEscaped(w: *Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(c),
    };
}

test "sitemap: writeXmlEscaped escapes the five XML special characters" {
    const gpa = std.testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeXmlEscaped(&aw.writer, "a&b<c>d\"e'f");
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&apos;f", aw.written());
}

test "sitemap: writeXmlEscaped leaves a plain URL untouched" {
    const gpa = std.testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeXmlEscaped(&aw.writer, "https://example.com/blog/post/");
    try std.testing.expectEqualStrings("https://example.com/blog/post/", aw.written());
}

test "sitemap: composeRawUrl joins host_url + url_path_prefix + a root-relative SPA static_url exactly once" {
    const gpa = std.testing.allocator;
    const got = try composeRawUrl(gpa, "https://example.com", "myprefix", "/app/club/1/");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("https://example.com/myprefix/app/club/1/", got);
}

test "sitemap: composeRawUrl with no url_path_prefix" {
    const gpa = std.testing.allocator;
    const got = try composeRawUrl(gpa, "https://example.com", "", "/app/");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("https://example.com/app/", got);
}

test "sitemap: composeRawUrl trims a trailing-slash host_url instead of doubling the slash" {
    // Config.validate (root.zig) explicitly allows a host_url whose URI path
    // is exactly "/" -- e.g. "https://example.com/" -- and stores it
    // untrimmed. Root.printSimplePrefix (the chokepoint this composes
    // through) has to trim it, or every absolute URL doubles the slash.
    const gpa = std.testing.allocator;
    const got = try composeRawUrl(gpa, "https://example.com/", "myprefix", "/app/");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("https://example.com/myprefix/app/", got);
    // Scoped past the scheme's own "//" -- this is the doubled-slash defect
    // shape specifically (host immediately followed by a second "/").
    try std.testing.expect(std.mem.indexOf(u8, got, "example.com//") == null);
}

test "sitemap: composePageUrl composes host_url + url_path_prefix + page path with no pagination tail at n=1" {
    const gpa = std.testing.allocator;
    var st: StringTable = .empty;
    defer st.deinit(gpa);
    var pt: PathTable = .empty;
    defer pt.deinit(gpa);
    // Reserve index 0 in both tables as the empty string/path, mirroring
    // every production caller (Variant.zig's scan/tests) -- PathName/Path
    // formatting assumes it in Debug builds.
    _ = try st.intern(gpa, "");
    _ = try pt.intern(gpa, &.{});

    const blog = try st.intern(gpa, "blog");
    const path = try pt.intern(gpa, &.{blog});

    var p: context.Page = .{ .title = "Blog", .layout = "list.shtml" };
    p._scan.url = path;

    const got = try composePageUrl(gpa, "https://example.com", "myprefix", &st, &pt, &p, 1);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("https://example.com/myprefix/blog/", got);
}

test "sitemap: composePageUrl appends the pagination window's url_style tail for n > 1" {
    const gpa = std.testing.allocator;
    var st: StringTable = .empty;
    defer st.deinit(gpa);
    var pt: PathTable = .empty;
    defer pt.deinit(gpa);
    _ = try st.intern(gpa, "");
    _ = try pt.intern(gpa, &.{});

    const blog = try st.intern(gpa, "blog");
    const path = try pt.intern(gpa, &.{blog});

    // Default url_style (.page_dir): "page/<n>/".
    var p_page_dir: context.Page = .{ .title = "Blog", .layout = "list.shtml", .pagination = .{ .page_size = 2 } };
    p_page_dir._scan.url = path;
    const got_page_dir = try composePageUrl(gpa, "https://example.com", "myprefix", &st, &pt, &p_page_dir, 3);
    defer gpa.free(got_page_dir);
    try std.testing.expectEqualStrings("https://example.com/myprefix/blog/page/3/", got_page_dir);

    // .plain_dir: bare "<n>/", no "page/" segment -- proves the tail comes
    // from `p.pagination.?.url_style`, not a hardcoded shape.
    var p_plain_dir: context.Page = .{
        .title = "Blog",
        .layout = "list.shtml",
        .pagination = .{ .page_size = 2, .url_style = .plain_dir },
    };
    p_plain_dir._scan.url = path;
    const got_plain_dir = try composePageUrl(gpa, "https://example.com", "myprefix", &st, &pt, &p_plain_dir, 2);
    defer gpa.free(got_plain_dir);
    try std.testing.expectEqualStrings("https://example.com/myprefix/blog/2/", got_plain_dir);
}
