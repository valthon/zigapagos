//! `zigapagos release --summary`: an inventory of what a build actually
//! emitted, grouped by category (issue #42).
//!
//! Why it exists: the only way to learn what a build produced was
//! `find zig-out/site`, and the cost of that was a landing page describing a
//! deploy tree no build emits — written from the OPTIONS rather than from the
//! OUTPUT. A summary is only worth having if it cannot make that same mistake,
//! which fixes two rules:
//!
//!  * **Entries are recorded where the file is written, not re-derived
//!    afterwards.** Every `add` call in `root.zig`/`spa.zig` sits at the same
//!    place, with the same path expression, as the write it reports. The one
//!    exception — page assets, installed by `Variant.installAssets` on a worker
//!    thread — is called out at its collection site, and
//!    `tests/summary/summary.sh` cross-checks the whole printed set against the
//!    output tree so a divergence is a red test rather than a plausible lie.
//!  * **It reports; it never decides.** Nothing here can change what a build
//!    emits: the collector is an inert list and the only failure it can produce
//!    is `OutOfMemory`.
//!
//! Deliberately NOT a category: host configs. `zigapagos` itself never writes
//! an nginx/apache/zigbase config — `build/site.zig` runs
//! `runtime/scripts/emit-host-config.ts` as a separate build step, outside this
//! process. What the binary does emit for a host is each SPA's
//! `routing-manifest.json`, which those emitters read, and that is what the
//! `SPA routing manifest` category reports. Claiming a host-config category
//! here would be exactly the "describe the options, not the output" defect
//! above.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Summary = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        category: Category,
        /// Output-dir-relative, never leading-slashed (see `add`).
        path: []const u8,
    };

    /// Declaration order is print order: the page tree first (what a reader
    /// asked the site for), then the assets it pulls in, then the SPA
    /// artifacts, which are a different kind of thing entirely — a shell plus
    /// the manifest a host needs to route to it.
    pub const Category = enum {
        page,
        page_alias,
        page_alternative,
        page_pagination,
        page_asset,
        site_asset,
        build_asset,
        spa_shell,
        spa_manifest,
        spa_fallback,

        /// Plural heading, since every group prints its count.
        pub fn heading(c: Category) []const u8 {
            return switch (c) {
                .page => "pages",
                .page_alias => "page aliases",
                .page_alternative => "page alternatives",
                .page_pagination => "pagination pages",
                .page_asset => "page assets",
                .site_asset => "site assets",
                .build_asset => "build assets",
                .spa_shell => "SPA shells",
                .spa_manifest => "SPA routing manifests",
                .spa_fallback => "SPA 404 fallback",
            };
        }
    };

    /// Record one emitted file.
    ///
    /// Allocator contract: NO_SLOP.md §2.2a contract 2 (owned-result) — the
    /// `Summary` owns a copy of every path and `deinit` frees them all. The
    /// copy is not optional: every caller's `path` is either a stack buffer
    /// reused on the next iteration or a slice out of a pass-scoped arena that
    /// is gone by the time the report prints.
    ///
    /// The leading `/` is trimmed here rather than left to each call site.
    /// None of the *formatters* the collection sites read from emit one —
    /// not `worker.mainOutputPath`, not `fingerprint.fmtUrl`, and not
    /// `PathName.fmt` with a null prefix (`PathName.Formatter.format` writes a
    /// prefix only when there is one, and never a bare separator). What can
    /// arrive root-absolute is the strings an AUTHOR writes: a build asset's
    /// `install_path` from the consumer's `build.zig`, and a page's `aliases` /
    /// `alternatives[].output` frontmatter, all of which accept a
    /// root-relative `/foo` spelling. Every call site that writes such a path
    /// to disk already has to strip it — `updateFile` needs a path relative to
    /// the output dir, and `worker.suffixedOutputPath` hands back `suffix[1..]`
    /// — so this trim is the belt to those braces rather than the only thing
    /// doing the work. It stays here, once, because the alternative is nine
    /// call sites each independently remembering: one that forgot would print a
    /// spelling the emitted tree does not have, and the exact set comparison in
    /// `tests/summary/summary.sh` would then fail on a cosmetic difference
    /// instead of on a real one.
    pub fn add(
        s: *Summary,
        gpa: Allocator,
        category: Category,
        path: []const u8,
    ) error{OutOfMemory}!void {
        const owned = try gpa.dupe(u8, std.mem.trimStart(u8, path, "/"));
        errdefer gpa.free(owned);
        try s.entries.append(gpa, .{ .category = category, .path = owned });
    }

    pub fn deinit(s: *Summary, gpa: Allocator) void {
        for (s.entries.items) |e| gpa.free(e.path);
        s.entries.deinit(gpa);
    }

    /// Sort into print order: by category (declaration order), then by path.
    ///
    /// Sorting is not cosmetic. Site assets and page assets are enumerated
    /// from hash maps, so as-found order differs between two builds of the
    /// same site — the same reason `root.zig`'s pruned-asset report sorts, and
    /// `spa.zig`'s `spaHeadWarningAsset` picks the lexicographically smallest
    /// match. A report that reordered itself run to run could not be diffed,
    /// which is most of what a build inventory is for.
    fn sortEntries(s: *Summary) void {
        std.mem.sort(Entry, s.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                const ao = @intFromEnum(a.category);
                const bo = @intFromEnum(b.category);
                if (ao != bo) return ao < bo;
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan);
    }

    /// Write the report. `out_dir_path` is the output directory the paths are
    /// relative to, printed once in the header so no line has to repeat it.
    ///
    /// Allocator contract: allocates nothing (§2.2a contract 3) — it sorts the
    /// entries it already owns and writes through the caller's writer.
    pub fn render(s: *Summary, w: *std.Io.Writer, out_dir_path: []const u8) std.Io.Writer.Error!void {
        if (s.entries.items.len == 0) {
            try w.print("build summary: nothing was emitted under '{s}'\n", .{out_dir_path});
            return;
        }

        s.sortEntries();

        try w.print("build summary: {d} file(s) emitted under '{s}'\n", .{
            s.entries.items.len,
            out_dir_path,
        });

        var idx: usize = 0;
        while (idx < s.entries.items.len) {
            const cat = s.entries.items[idx].category;
            var end = idx;
            while (end < s.entries.items.len and s.entries.items[end].category == cat) end += 1;
            try w.print("  {s} ({d}):\n", .{ cat.heading(), end - idx });
            for (s.entries.items[idx..end]) |e| try w.print("    {s}\n", .{e.path});
            idx = end;
        }
    }
};

const testing = std.testing;

test "summary: entries print grouped by category, sorted, with counts" {
    const gpa = testing.allocator;
    var s: Summary = .{};
    defer s.deinit(gpa);

    // Deliberately added out of order, and with a leading slash on one path,
    // to exercise both normalizations at once.
    try s.add(gpa, .site_asset, "/style.css");
    try s.add(gpa, .page, "docs/index.html");
    try s.add(gpa, .page, "index.html");
    try s.add(gpa, .page_alias, "overview.html");

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.render(&w, "out");

    try testing.expectEqualStrings(
        \\build summary: 4 file(s) emitted under 'out'
        \\  pages (2):
        \\    docs/index.html
        \\    index.html
        \\  page aliases (1):
        \\    overview.html
        \\  site assets (1):
        \\    style.css
        \\
    , w.buffered());
}

test "summary: an empty build says so rather than printing an empty report" {
    const gpa = testing.allocator;
    var s: Summary = .{};
    defer s.deinit(gpa);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.render(&w, "public");

    try testing.expectEqualStrings(
        "build summary: nothing was emitted under 'public'\n",
        w.buffered(),
    );
}

test "summary: every category has a distinct heading" {
    // A copy-pasted heading would silently merge two groups in the report —
    // and the grouping loop in `render` would then print the same heading
    // twice, which reads as a bug in the build rather than in this table.
    const cats = std.enums.values(Summary.Category);
    for (cats, 0..) |a, i| {
        for (cats[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.heading(), b.heading()));
        }
    }
}
