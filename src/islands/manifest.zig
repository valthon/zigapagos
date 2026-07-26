//! Dev-only island-usage manifest: maps each mounted island's
//! `src` to the set of content pages that mount it, so `zigapagos dev` can
//! turn an island-source edit into an incremental re-SSR of just those pages.
//! Written by every dev disk build (env `ZIGAPAGOS_ISLAND_MANIFEST`, see
//! `src/cli/release.zig`); never part of release output. A missing/stale
//! manifest makes dev fall back to a full rebuild — the manifest can only make
//! dev faster, never wrong.
const std = @import("std");
const RenderArena = @import("render_arena.zig").RenderArena;

/// Wire-format version. Bump on any incompatible shape change; a reader that
/// sees a version it doesn't understand treats the manifest as absent (full
/// rebuild), never misreads it.
pub const version: u32 = 1;

/// One (island src, page source path) pair collected during the SSR pass
/// (`src/worker.zig`'s `renderPage`). `island_src` is the verbatim
/// `<island src="…">` attribute (website-root-relative); `page_path` is the
/// '/'-separated content-dir-prefixed page source path (e.g.
/// `content/blog/foo.smd`) — the exact string the incremental `changed_files`
/// set matches on.
pub const Use = struct { island_src: []const u8, page_path: []const u8 };

/// JSON wire shape:
/// `{"version":1,"islands":{"components/X.island.tsx":["content/a.smd",…]}}`
pub const Json = struct {
    version: u32 = 0,
    islands: std.json.ArrayHashMap([]const []const u8) = .{},
};

/// Parse manifest text. Fails on malformed JSON or a version this build doesn't
/// understand; callers treat any error as "no manifest" (⇒ full-rebuild
/// fallback).
///
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): `parseFromSliceLeaky` returns a
/// `Json` whose `islands` ArrayHashMap, its keys, and every page slice in every
/// value list are separate allocations with no `deinit` — an interlinked graph
/// (1) that only the arena can reclaim; hand-freeing it would mean walking the
/// map to free each list and key for no benefit (2); and it dies with the
/// manifest-write pass that read the file (3).
pub fn parse(arena: RenderArena, text: []const u8) !Json {
    const parsed = try std.json.parseFromSliceLeaky(Json, arena.a, text, .{
        .ignore_unknown_fields = true,
    });
    if (parsed.version != version) return error.UnsupportedManifestVersion;
    return parsed;
}

pub const PageSet = std.StringArrayHashMapUnmanaged(void);
pub const Assembled = std.StringArrayHashMapUnmanaged(PageSet);

/// Build the island → page-set map for this build: start from `old` (null on
/// a full build) minus every page in `rendered_pages` (those pages just
/// re-rendered, so their mounts are re-derived from `uses` this build), then
/// add every collected `use` (deduplicating repeat pairs, e.g. a page's
/// `.alternative` render jobs). Islands left with zero pages are dropped.
/// All storage is arena-owned; key/page strings are borrowed from the inputs.
///
/// NO_SLOP.md §2.2a contract 4 (`RenderArena`): the result is a map of maps —
/// one `PageSet` allocation per island on top of the outer table — with no
/// `deinit` (1); freeing it by hand means iterating the outer table to deinit
/// each inner one, pure bookkeeping since every entry is live until `render`
/// serializes it (2); and it dies with the manifest-write pass (3).
pub fn assemble(
    arena: RenderArena,
    old: ?*const Json,
    rendered_pages: *const std.StringHashMapUnmanaged(void),
    uses: []const Use,
) error{OutOfMemory}!Assembled {
    var out: Assembled = .empty;
    if (old) |o| {
        var it = o.islands.map.iterator();
        while (it.next()) |entry| {
            var set: PageSet = .empty;
            for (entry.value_ptr.*) |page| {
                if (rendered_pages.contains(page)) continue;
                try set.put(arena.a, page, {});
            }
            if (set.count() > 0) try out.put(arena.a, entry.key_ptr.*, set);
        }
    }
    for (uses) |u| {
        const gop = try out.getOrPut(arena.a, u.island_src);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.put(arena.a, u.page_path, {});
    }
    return out;
}

/// Serialize deterministically: island keys and each island's page list are
/// emitted sorted, so the bytes don't depend on the (multi-threaded,
/// nondeterministic) collection order. Every string value goes through
/// `std.json.Stringify.value` (same convention as `src/spa.zig`'s
/// `renderManifest`) so a `"` or `\` in a path can't break the JSON.
///
/// NO_SLOP.md §2.2a contract 1: one allocation escapes (the returned JSON), and
/// the sort scratch — a dupe of the island keys plus one of each island's page
/// keys, needed because `assembled`'s own key arrays are borrowed and must not
/// be reordered — is freed here, so this is correct under any allocator even
/// though its only caller hands it the render pass's arena.
pub fn render(
    alloc: std.mem.Allocator,
    assembled: *const Assembled,
) error{ OutOfMemory, WriteFailed }![]u8 {
    const keys = try alloc.dupe([]const u8, assembled.keys());
    defer alloc.free(keys);
    std.mem.sort([]const u8, keys, {}, strLessThan);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"version\":{d},\"islands\":{{", .{version});
    for (keys, 0..) |island_src, i| {
        if (i != 0) try w.writeAll(",");
        try std.json.Stringify.value(island_src, .{}, w);
        try w.writeAll(":[");
        const pages = try alloc.dupe([]const u8, assembled.getPtr(island_src).?.keys());
        defer alloc.free(pages);
        std.mem.sort([]const u8, pages, {}, strLessThan);
        for (pages, 0..) |page, j| {
            if (j != 0) try w.writeAll(",");
            try std.json.Stringify.value(page, .{}, w);
        }
        try w.writeAll("]");
    }
    try w.writeAll("}}");
    return aw.toOwnedSlice();
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// --- unit tests (run via `zig build test-islands`) ----------------------------

const no_rendered_pages: std.StringHashMapUnmanaged(void) = .empty;

test "islands manifest: full-build assemble dedups and render/parse round-trips" {
    // `parse`/`assemble` are contract 4, so this test keeps a real arena (see
    // scripts/allocator-allowlist.txt). `render` is contract 1, so it is called
    // with the raw testing allocator below — leak-checked even here.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    // Duplicate pair (a page's main + alternative render jobs both report the
    // mount) must collapse to one entry.
    const uses = [_]Use{
        .{ .island_src = "components/B.island.tsx", .page_path = "content/b.smd" },
        .{ .island_src = "components/A.island.tsx", .page_path = "content/z.smd" },
        .{ .island_src = "components/A.island.tsx", .page_path = "content/a.smd" },
        .{ .island_src = "components/A.island.tsx", .page_path = "content/a.smd" },
    };
    var assembled = try assemble(arena, null, &no_rendered_pages, &uses);
    const text = try render(std.testing.allocator, &assembled);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"islands\":{" ++
            "\"components/A.island.tsx\":[\"content/a.smd\",\"content/z.smd\"]," ++
            "\"components/B.island.tsx\":[\"content/b.smd\"]}}",
        text,
    );

    const back = try parse(arena, text);
    try std.testing.expectEqual(version, back.version);
    const a_pages = back.islands.map.get("components/A.island.tsx").?;
    try std.testing.expectEqual(@as(usize, 2), a_pages.len);
    try std.testing.expectEqualStrings("content/a.smd", a_pages[0]);
    try std.testing.expectEqualStrings("content/z.smd", a_pages[1]);
}

test "islands manifest: incremental assemble replaces a rendered page's mounts and drops emptied islands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const old = try parse(arena,
        \\{"version":1,"islands":{
        \\  "components/A.island.tsx":["content/a.smd","content/keep.smd"],
        \\  "components/Gone.island.tsx":["content/a.smd"]}}
    );

    // content/a.smd was re-rendered this build; it now mounts only A.
    var rendered: std.StringHashMapUnmanaged(void) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try rendered.put(std.testing.allocator, "content/a.smd", {});

    const uses = [_]Use{
        .{ .island_src = "components/A.island.tsx", .page_path = "content/a.smd" },
    };
    var assembled = try assemble(arena, &old, &rendered, &uses);
    const text = try render(std.testing.allocator, &assembled);
    defer std.testing.allocator.free(text);
    // Gone.island.tsx was mounted only by the re-rendered page and got no new
    // use ⇒ dropped entirely; keep.smd (not rendered this build) is carried over.
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"islands\":{" ++
            "\"components/A.island.tsx\":[\"content/a.smd\",\"content/keep.smd\"]}}",
        text,
    );
}

test "islands manifest: parse rejects garbage and unknown versions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        parse(arena, "{\"version\":999,\"islands\":{}}"),
    );
    // A manifest with no version field defaults to 0 ⇒ also rejected.
    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        parse(arena, "{\"islands\":{}}"),
    );
    try std.testing.expect(std.meta.isError(parse(arena, "not json {")));
}

test "islands manifest: parse tolerates unknown fields (forward compat)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const m = try parse(
        arena,
        "{\"version\":1,\"islands\":{\"x.tsx\":[\"content/p.md\"]},\"future\":true}",
    );
    try std.testing.expectEqual(@as(usize, 1), m.islands.map.count());
}
