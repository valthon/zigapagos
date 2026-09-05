const Variant = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const log = std.log.scoped(.variant);

const builtin = @import("builtin");
const ziggy = @import("ziggy");
const FrontParser = ziggy.frontmatter.Parser(Page);
const tracy = @import("tracy");
const fatal = @import("fatal.zig");
const worker = @import("worker.zig");
const context = @import("context.zig");
const Page = context.Page;
const Build = @import("Build.zig");
const StringTable = @import("StringTable.zig");
const String = StringTable.String;
const PathTable = @import("PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;

output_path_prefix: []const u8,
/// Open for the full duration of the program.
content_dir: Io.Dir,
content_dir_path: []const u8,
/// Stores path components
string_table: StringTable,
/// Stores paths as slices of components (stored in string_table)
path_table: PathTable,
/// Section 0 is invalid, always start iterating from [1..].
sections: std.ArrayListUnmanaged(Section),
root_index: ?u32, // index into pages
pages: std.ArrayListUnmanaged(Page),
/// Output urls for pages, and assets.
/// - Scan phase: adds pages and assets
/// - Main thread after parse phase: adds aliases and alternatives
urls: std.AutoHashMapUnmanaged(PathName, LocationHint),
/// Overflowing LocationHints end up in here, populated alongside 'urls'.
collisions: std.ArrayListUnmanaged(Collision),
/// Content directories that hold pages but no index.smd, collected during the
/// scan and reported (as warnings) from the main thread in root.zig.
sectionless_dirs: std.ArrayListUnmanaged(SectionlessDir),

i18n: context.Map.ZiggyMap,
i18n_src: [:0]const u8,
i18n_diag: ziggy.Diagnostic,
i18n_arena: std.heap.ArenaAllocator.State,

const Collision = struct {
    url: PathName,
    loc: LocationHint,
    previous: LocationHint,
};

/// A content directory that holds `.smd` pages but no `index.smd`, so it never
/// became a section: its pages reparent to the enclosing section with deeper
/// URLs, no page is generated at the directory's own URL, and
/// `$page.subpages()` for anything pointing at it returns an empty list (the
/// `subsection_id == 0` short-circuit in context/Page.zig). Collected during
/// the worker-threaded scan and printed from the main thread in root.zig -- a
/// WARNING, not an error: the empty-list return is documented upstream
/// behaviour and the pattern is legitimately used for URL shaping (see
/// tests/rendering/simple/content/nested/).
pub const SectionlessDir = struct {
    path: PathTable.Path,
    /// Direct `.smd` pages in the directory. `index.smd` is by definition
    /// absent, so it is not counted.
    page_count: u32,
    /// True when a page elsewhere already owns this directory's would-be index
    /// URL -- i.e. a sibling `<dirname>.smd` that looks like the section index
    /// but is a plain page. Sharpens the note.
    sibling_leaf_page: bool,
};

/// Tells you where to look when figuring out what an output URL maps to.
pub const ResourceKind = enum { page_main, page_alias, page_alternative, page_asset, page_pagination };
pub const LocationHint = struct {
    id: u32, // index into pages
    kind: union(ResourceKind) {
        page_main,
        page_alias,
        page_alternative: []const u8,
        // for page assets, 'id' is the page that owns the asset
        page_asset: std.atomic.Value(u32), // reference counting
        page_pagination: u32, // page number (>= 2)
    },
    pub fn fmt(
        lh: LocationHint,
        st: *const StringTable,
        pt: *const PathTable,
        pages: []const Page,
    ) LocationHint.Formatter {
        return .{ .lh = lh, .st = st, .pt = pt, .pages = pages };
    }

    pub const Formatter = struct {
        lh: LocationHint,
        st: *const StringTable,
        pt: *const PathTable,
        pages: []const Page,

        pub fn format(f: LocationHint.Formatter, w: *Writer) !void {
            const page = f.pages[f.lh.id];
            try w.print("{f}", .{page._scan.file.fmt(f.st, f.pt, null, "")});

            switch (f.lh.kind) {
                .page_main => {
                    try w.writeAll(" (main output)");
                },
                .page_alias => {
                    try w.writeAll(" (page alias)");
                },
                .page_alternative => |alt| {
                    try w.print(" (page alternative '{s}')", .{alt});
                },
                .page_asset => {
                    try w.writeAll(" (page asset)");
                },
                .page_pagination => |n| {
                    try w.print(" (pagination page {d})", .{n});
                },
            }
        }
    };
};

pub const Section = struct {
    active: bool = true,
    content_sub_path: Path,
    parent_section: u32, // index into sections, 0 = no parent section
    index: u32, // index into pages
    pages: std.ArrayListUnmanaged(u32) = .empty, // indices into pages

    pub fn deinit(s: *const Section, gpa: Allocator) void {
        {
            var p = s.pages;
            p.deinit(gpa);
        }
    }

    pub fn activate(
        s: *Section,
        io: Io,
        gpa: Allocator,
        variant: *const Variant,
        index: *Page,
        drafts: bool,
        auto_heading_ids: bool,
    ) void {
        const zone = tracy.trace(@src());
        defer zone.end();

        index.parse(io, gpa, worker.cmark, null, variant, drafts, auto_heading_ids);
        s.active = index._parse.active;
    }

    pub fn sortPages(
        s: *Section,
        gpa: Allocator,
        v: *Variant,
        pages: []Page,
    ) void {
        // Precompute each page's output URL exactly once into a scratch arena
        // (O(n) formats), then sort with a stable O(n log n) block sort. The
        // previous implementation was an O(n²) insertion sort whose date-tie
        // break formatted *both* pages' full URLs on every comparison — and the
        // common undated case (Page.date defaults to the epoch) makes every
        // comparison take that tie-break. See AUD-018.
        const ids = s.pages.items;

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const Entry = struct { id: u32, url: []const u8 };
        const entries = arena.alloc(Entry, ids.len) catch fatal.oom();
        for (entries, ids) |*e, id| {
            const url = std.fmt.allocPrint(arena, "{f}", .{
                pages[id]._scan.url.fmt(
                    &v.string_table,
                    &v.path_table,
                    null,
                    false,
                ),
            }) catch fatal.oom();
            e.* = .{ .id = id, .url = url };
        }

        const Ctx = struct {
            pages: []Page,
            pub fn lessThan(ctx: @This(), lhs: Entry, rhs: Entry) bool {
                const lhs_date = ctx.pages[lhs.id].date;
                const rhs_date = ctx.pages[rhs.id].date;
                if (rhs_date.eql(lhs_date)) {
                    return std.mem.order(u8, rhs.url, lhs.url) == .lt;
                }
                return rhs_date.lessThan(lhs_date);
            }
        };

        std.sort.block(Entry, entries, Ctx{ .pages = pages }, Ctx.lessThan);

        for (ids, entries) |*id, e| id.* = e.id;
    }
};

pub fn deinit(v: *const Variant, io: Io, gpa: Allocator) void {
    {
        var dir = v.content_dir;
        dir.close(io);
    }
    // content_dir_path is in cfg_arena
    // gpa.free(v.content_dir_path);
    v.string_table.deinit(gpa);
    v.path_table.deinit(gpa);
    for (v.sections.items[1..]) |s| s.deinit(gpa);
    {
        var s = v.sections;
        s.deinit(gpa);
    }
    for (v.pages.items) |p| p.deinit(gpa);
    {
        var p = v.pages;
        p.deinit(gpa);
    }
    {
        var u = v.urls;
        u.deinit(gpa);
    }
    {
        var c = v.collisions;
        c.deinit(gpa);
    }
    {
        var s = v.sectionless_dirs;
        s.deinit(gpa);
    }
    v.i18n_arena.promote(gpa).deinit();
}

pub const MultilingualScanParams = struct {
    i18n_dir: Io.Dir,
    i18n_dir_path: []const u8,
    locale_code: []const u8,
};
pub fn scanContentDir(
    variant: *Variant,
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    base_dir: Io.Dir,
    content_dir_path: []const u8,
    variant_id: u32,
    multilingual: ?MultilingualScanParams,
    output_path_prefix: []const u8,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    var path_table: PathTable = .empty;
    _ = try path_table.intern(gpa, &.{}); // empty path
    const empty_path = try path_table.intern(gpa, &.{});
    var string_table: StringTable = .empty;
    _ = try string_table.intern(gpa, ""); // invalid path component string
    const index_smd = try string_table.intern(gpa, "index.smd");
    const index_html = try string_table.intern(gpa, "index.html");
    _ = try string_table.intern(gpa, "index.html");

    var pages: std.ArrayListUnmanaged(Page) = .empty;
    var sections: std.ArrayListUnmanaged(Section) = .empty;
    try sections.append(gpa, undefined); // section zero is invalid

    var urls: std.AutoHashMapUnmanaged(PathName, LocationHint) = .empty;
    var collisions: std.ArrayListUnmanaged(Collision) = .empty;
    var sectionless_dirs: std.ArrayListUnmanaged(SectionlessDir) = .empty;

    var dir_stack: std.ArrayListUnmanaged(struct {
        path: []const u8,
        parent_section: u32, // index into sections
        page_assets_owner: u32, // index into pages
    }) = .empty;
    try dir_stack.append(arena, .{
        .path = "",
        .parent_section = 0,
        .page_assets_owner = 0,
    });

    var root_index: ?u32 = null;
    var page_names: std.ArrayListUnmanaged(String) = .empty;
    var asset_names: std.ArrayListUnmanaged(String) = .empty;
    var dir_names: std.ArrayListUnmanaged(String) = .empty;
    const content_dir = base_dir.openDir(io, content_dir_path, .{
        .iterate = true,
    }) catch |err| fatal.dir(content_dir_path, err);

    while (dir_stack.pop()) |dir_entry| {
        var dir = switch (dir_entry.path.len) {
            0 => content_dir,
            else => content_dir.openDir(io, dir_entry.path, .{ .iterate = true }) catch |err| {
                fatal.dir(dir_entry.path, err);
            },
        };
        defer if (dir_entry.path.len > 0) dir.close(io);

        var found_index_smd = false;
        var it = dir.iterateAssumeFirstIteration();
        while (it.next(io) catch |err| fatal.dir(dir_entry.path, err)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            switch (entry.kind) {
                else => continue,
                .file, .sym_link => {
                    const str = try string_table.intern(gpa, entry.name);
                    if (str == index_html) {
                        fatal.msg(
                            "error: '{s}/index.html': raw index.html files are not allowed in the content dir (use index.smd)\n",
                            .{dir_entry.path},
                        );
                    }
                    if (std.mem.endsWith(u8, entry.name, ".smd")) {
                        if (str == index_smd) {
                            found_index_smd = true;
                            continue;
                        }
                        try page_names.append(arena, str);
                    } else {
                        try asset_names.append(arena, str);
                    }
                },
                .directory => {
                    const str = try string_table.intern(gpa, entry.name);
                    try dir_names.append(arena, str);
                },
            }
        }

        try urls.ensureUnusedCapacity(gpa, @intCast(@intFromBool(found_index_smd) +
            page_names.items.len + asset_names.items.len));

        // TODO: this should be a internPathExtend
        const content_sub_path = switch (dir_entry.path.len) {
            0 => empty_path,
            else => try path_table.internPath(
                gpa,
                &string_table,
                dir_entry.path,
            ),
        };

        // Would be nice to be able to use destructuring...
        var current_section = dir_entry.parent_section;
        const assets_owner_id = if (found_index_smd) blk: {
            const page_id: u32 = @intCast(pages.items.len);
            const is_root_index = dir_entry.path.len == 0;
            if (is_root_index) {
                // root index case
                root_index = page_id;
            } else {
                // Found index.smd: add it to the current section
                // and create a new section to be used for all
                // other files.
                try sections.items[dir_entry.parent_section].pages.append(
                    gpa,
                    page_id,
                );
            }

            current_section = @intCast(sections.items.len);
            try sections.append(gpa, .{
                .content_sub_path = content_sub_path,
                .parent_section = dir_entry.parent_section,
                .index = page_id,
            });

            const index_page = try pages.addOne(gpa);
            index_page._parse.active = false;
            // Pages are carved from undefined ArrayList memory, so field
            // defaults never run; initialize every field `Page.deinit` frees to
            // its empty state so deinit can always run over an unparsed
            // placeholder — `_render` (AUD-004) and `_parse.arena`, whose free is
            // unconditional. A later `parse()` overwrites `_parse` wholesale, so
            // the empty arena is harmless if this page is parsed.
            index_page._parse.arena = .{};
            index_page._render = .{};
            index_page._pagination = null;
            index_page._scan = .{
                .file = .{
                    .path = content_sub_path,
                    .name = index_smd,
                },
                .url = content_sub_path,
                .page_id = page_id,
                .subsection_id = current_section,
                .parent_section_id = dir_entry.parent_section,
                .variant_id = variant_id,
            };
            if (builtin.mode == .Debug) {
                index_page._debug = .{ .stage = .init(.scanned) };
            }

            const pn: PathName = .{ .path = content_sub_path, .name = index_html };
            const lh: LocationHint = .{ .id = page_id, .kind = .page_main };

            const gop = urls.getOrPutAssumeCapacity(pn);
            if (gop.found_existing) {
                try collisions.append(gpa, .{
                    .url = pn,
                    .loc = lh,
                    .previous = gop.value_ptr.*,
                });
            } else {
                gop.value_ptr.* = lh;
            }

            break :blk page_id;
        } else dir_entry.page_assets_owner;

        // A non-empty content root must provide an index.smd: it establishes
        // the root section (section 0 is the invalid sentinel). Without it,
        // pages, assets, or subdirectories would index the undefined section
        // 0 below, panicking in Debug and corrupting an undefined ArrayList in
        // release. A genuinely empty root is different: a migration may have
        // completed with every route blocked, so there is intentionally no
        // section and nothing below may index one. Skip the rest of this root
        // iteration in that case. Hidden VCS placeholders were filtered above
        // and therefore correctly count as empty. See AUD-009 and issue #205.
        if (dir_entry.path.len == 0 and !found_index_smd) {
            if (page_names.items.len == 0 and asset_names.items.len == 0 and dir_names.items.len == 0) {
                page_names.clearRetainingCapacity();
                asset_names.clearRetainingCapacity();
                dir_names.clearRetainingCapacity();
                continue;
            }
            fatal.msg(
                "error: the content root requires a content/index.smd page\n",
                .{},
            );
        }

        // This directory holds pages but no index.smd, so it never became a
        // section (see SectionlessDir). Detected here and not earlier because
        // `found_index_smd` and `page_names` are only final once the entry
        // iteration above has finished, and not later because `page_names` is
        // cleared at the bottom of the loop. The root case fataled just above,
        // hence the non-empty-path guard.
        if (dir_entry.path.len > 0 and !found_index_smd and page_names.items.len > 0) {
            // A hit here is a page from the PARENT directory whose output URL
            // is exactly this directory's would-be index -- i.e. a sibling
            // `<dirname>.smd`. The lookup is complete at this point: a parent
            // is always scanned before its children (children are only pushed
            // onto `dir_stack` while their parent is being processed) and the
            // parent's page URLs are inserted before that push. `found_index_smd`
            // is false here, so this can never be our own index.
            const would_be_index: PathName = .{
                .path = content_sub_path,
                .name = index_html,
            };
            const sibling = if (urls.get(would_be_index)) |hint|
                hint.kind == .page_main
            else
                false;
            try sectionless_dirs.append(gpa, .{
                .path = content_sub_path,
                .page_count = @intCast(page_names.items.len),
                .sibling_leaf_page = sibling,
            });
        }

        const section = &sections.items[current_section];
        const section_pages_old_len = section.pages.items.len;
        try section.pages.resize(gpa, section_pages_old_len + page_names.items.len);
        const pages_old_len = pages.items.len;
        try pages.resize(gpa, pages_old_len + page_names.items.len);

        if (builtin.mode == .Debug) {
            const Ctx = struct {
                st: *StringTable,
                pub fn lessThan(ctx: @This(), lhs: String, rhs: String) bool {
                    return std.mem.order(u8, lhs.slice(ctx.st), rhs.slice(ctx.st)) == .lt;
                }
            };

            const ctx: Ctx = .{ .st = &string_table };
            std.mem.sort(String, page_names.items, ctx, Ctx.lessThan);
        }

        for (
            section.pages.items[section_pages_old_len..],
            pages.items[pages_old_len..],
            page_names.items,
            pages_old_len..,
        ) |*sp, *p, f, idx| {
            // If we don't do this here, later on the call to f.slice might
            // return a pointer that gets invalidated when the string table
            // is expanded.
            try string_table.string_bytes.ensureUnusedCapacity(
                gpa,
                f.slice(&string_table).len + 1,
            );
            const page_url = try path_table.internExtend(
                gpa,
                content_sub_path,
                try string_table.intern(
                    gpa,
                    std.fs.path.stem(f.slice(&string_table)), // TODO: extensionless page names?
                ),
            );

            sp.* = @intCast(idx);
            p._parse.active = false;
            // See the index_page note above: initialize the fields `Page.deinit`
            // frees — `_render` (AUD-004) and `_parse.arena` — so deinit is safe
            // over an unparsed placeholder.
            p._parse.arena = .{};
            p._render = .{};
            p._pagination = null;
            p._scan = .{
                .file = .{
                    .path = content_sub_path,
                    .name = f,
                },
                .url = page_url,
                .page_id = @intCast(idx),
                .subsection_id = 0,
                .parent_section_id = current_section,
                .variant_id = variant_id,
            };
            if (builtin.mode == .Debug) {
                p._debug = .{ .stage = .init(.scanned) };
            }

            log.debug("'{s}/{s}' -> [{d}] -> [{d}]", .{
                dir_entry.path,
                f.slice(&string_table),
                page_url,
                page_url.slice(&path_table),
            });

            const pn: PathName = .{ .path = page_url, .name = index_html };
            const lh: LocationHint = .{ .id = @intCast(idx), .kind = .page_main };
            const gop = urls.getOrPutAssumeCapacity(pn);

            if (gop.found_existing) {
                try collisions.append(gpa, .{
                    .url = pn,
                    .loc = lh,
                    .previous = gop.value_ptr.*,
                });
            } else {
                gop.value_ptr.* = lh;
            }
        }

        // assets
        {
            // A content root without an index.smd was already rejected above
            // (AUD-009), so by here the root always has its index section.
            const lh: LocationHint = .{
                .id = assets_owner_id,
                .kind = .{ .page_asset = .init(0) },
            };

            for (asset_names.items) |a| {
                const pn: PathName = .{ .path = content_sub_path, .name = a };
                const gop = urls.getOrPutAssumeCapacity(pn);
                if (gop.found_existing) {
                    try collisions.append(gpa, .{
                        .url = pn,
                        .loc = lh,
                        .previous = gop.value_ptr.*,
                    });
                } else {
                    gop.value_ptr.* = lh;
                }
            }
        }

        const dir_stack_old_len = dir_stack.items.len;
        try dir_stack.resize(arena, dir_stack_old_len + dir_names.items.len);
        for (dir_stack.items[dir_stack_old_len..], dir_names.items) |*d, f| {
            const dir_path_bytes = try std.fs.path.join(arena, &.{
                dir_entry.path,
                f.slice(&string_table),
            });
            const dir_path = try path_table.internPath(gpa, &string_table, dir_path_bytes);
            const pn: PathName = .{ .path = dir_path, .name = index_html };
            d.* = .{
                .path = dir_path_bytes,
                .parent_section = current_section,
                .page_assets_owner = if (urls.get(pn)) |hint| hint.id else assets_owner_id,
            };
        }

        page_names.clearRetainingCapacity();
        asset_names.clearRetainingCapacity();
        dir_names.clearRetainingCapacity();
    }

    var i18n: context.Map.ZiggyMap = .{};
    var i18n_src: [:0]const u8 = "";
    var i18n_diag: ziggy.Diagnostic = .{ .path = null };
    var i18n_arena = std.heap.ArenaAllocator.init(gpa);
    // Present when in a multilingual site
    if (multilingual) |ml| {
        const name = try std.fmt.allocPrint(
            i18n_arena.allocator(),
            "{s}.ziggy",
            .{ml.locale_code},
        );
        i18n_src = ml.i18n_dir.readFileAllocOptions(
            io,
            name,
            i18n_arena.allocator(),
            .limited(ziggy.max_size),
            .@"1",
            0,
        ) catch |err| fatal.file(name, err);

        i18n_diag.path = name;
        i18n = ziggy.parseLeaky(
            context.Map.ZiggyMap,
            i18n_arena.allocator(),
            i18n_src,
            .{ .diagnostic = &i18n_diag },
        ) catch |err| switch (err) {
            error.OpenFrontmatter, error.MissingFrontmatter => unreachable,
            error.Overflow, error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => .{
                // We will detect later that an error happened by looking
                // at the diagnostic struct.
            },
        };
    }

    variant.* = .{
        .output_path_prefix = output_path_prefix,
        .content_dir = content_dir,
        .content_dir_path = content_dir_path,
        .string_table = string_table,
        .path_table = path_table,
        .sections = sections,
        .root_index = root_index,
        .pages = pages,
        .urls = urls,
        .collisions = collisions,
        .sectionless_dirs = sectionless_dirs,
        .i18n = i18n,
        .i18n_src = i18n_src,
        .i18n_diag = i18n_diag,
        .i18n_arena = i18n_arena.state,
    };
}

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

/// Lookup-only counterpart to `paginationPathName`, for the stale-output
/// prune (root.zig, after the render barrier): that probe walks past the end
/// of the current plan and, on a style change, past ranges that were never
/// planned at all, so most candidates it asks about were never registered.
/// `paginationPathName` INTERNS its formatted path into the string/path
/// tables on every call; probing with it would grow those tables once per
/// stale candidate, on every build, forever. This queries them instead
/// (`PathTable.PathName.get`, backed by `StringTable.get` /
/// `PathTable.getPathNoName` -- neither interns) and returns null both when
/// nothing is registered at that path AND when some path component was never
/// interned by anything else. The two cases are indistinguishable from a
/// pure lookup, but equivalent for the caller: every REAL entry in
/// `Variant.urls` was interned when it was registered, so "never interned
/// anywhere" already implies "not in `Variant.urls`".
pub fn paginationPathNameLookup(
    v: *const Variant,
    page: *const Page,
    style: context.Page.Pagination.UrlStyle,
    n: u32,
) ?PathName {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    switch (style) {
        .page_dir, .plain_dir => {
            const full = std.fmt.bufPrint(&buf, "{f}{s}{d}/index.html", .{
                page._scan.url.fmt(&v.string_table, &v.path_table, null, true),
                if (style == .page_dir) "page/" else "",
                n,
            }) catch return null;
            return PathName.get(&v.string_table, &v.path_table, full);
        },
        .page_html => {
            const name = std.fmt.bufPrint(&buf, "page-{d}.html", .{n}) catch return null;
            return .{
                .path = page._scan.url,
                .name = v.string_table.get(name) orelse return null,
            };
        },
    }
}

/// Whether the stale-pagination-prune candidate `rel` (page `n` of
/// `index_page`'s plan, under `style`, whose output-dir-relative path is
/// `rel`) must be PRESERVED rather than deleted. Two independent reasons a
/// candidate is real, not stale:
///
///  1. A page/alias/alternative/pagination-page URL is registered at that
///     path in `v.urls` -- checked via the lookup-only
///     `paginationPathNameLookup` above, so the probe never grows the
///     interning tables -- AND the page that OWNS that registration is
///     still active. `v.urls` is populated at SCAN time, before
///     draft/active status is known (`Section.activate` sets `_parse.active`
///     during the later parse phase), and an inactive page's `urls` entries
///     are never removed once scanned -- so a bare hit is not proof the path
///     is a real output of THIS build: a draft page can sit at a former
///     pagination path and keep its stale dir alive in release builds
///     forever. Every `LocationHint` kind carries the id of the page that
///     owns it (`page_main`/`page_alias`/`page_alternative`/`page_asset` are
///     all emitted -- or not -- alongside their owning page, same as
///     `page_pagination`), so deferring to that owner's `_parse.active` is a
///     uniform rule, not a special case for one `ResourceKind`.
///  2. An SPA prerendered a real output there (`build.spa_out_paths`). SPA
///     shells/manifests/the 404 fallback are never `Page`s, so they are
///     NEVER in `Variant.urls` -- reason 1 alone would let the prune delete
///     a real SPA output that happens to sit at a pagination-shaped path
///     (e.g. a `staticPaths` entry "2" under one SPA's base while a sibling
///     section's non-current-style sweep probes "…/2/index.html").
///
/// This is the single function both `root.zig`'s prune loop and this file's
/// own regression tests call, so a test pinning "an SPA output survives"
/// cannot drift from what the prune actually does.
///
/// NO_SLOP.md §2.2a contract 3 (caller-buffer): allocates nothing; `rel` is
/// the caller's own (already-freed-by-caller) `paginationOutputPath` result.
pub fn isPruneCandidateProtected(
    v: *const Variant,
    build: *const Build,
    index_page: *const Page,
    style: context.Page.Pagination.UrlStyle,
    n: u32,
    rel: []const u8,
) bool {
    if (v.paginationPathNameLookup(index_page, style, n)) |pn| {
        if (v.urls.get(pn)) |hint| {
            if (v.pages.items[hint.id]._parse.active) return true;
        }
    }
    return build.spa_out_paths.contains(rel);
}

pub fn installAssets(
    v: *const Variant,
    io: Io,
    progress: std.Progress.Node,
    install_dir: Io.Dir,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    // errdefer |err| switch (err) {
    //     error.OutOfMemory => fatal.oom(),
    // };

    var it = v.urls.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const hint = entry.value_ptr.*;
        if (hint.kind != .page_asset) continue;
        if (hint.kind.page_asset.raw == 0) continue;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const install_path = std.fmt.bufPrint(&buf, "{s}{s}{f}", .{
            v.output_path_prefix,
            if (v.output_path_prefix.len > 0) "/" else "",
            key.fmt(
                &v.string_table,
                &v.path_table,
                null,
                "",
            ),
        }) catch unreachable;

        const source_path = if (v.output_path_prefix.len == 0)
            install_path
        else
            install_path[v.output_path_prefix.len + 1 ..];

        _ = v.content_dir.updateFile(
            io,
            source_path,
            install_dir,
            std.mem.trimStart(u8, install_path, "/"),
            .{},
        ) catch |err| fatal.file(install_path, err);

        progress.completeOne();
    }
}

// --- tests ---

const testing = std.testing;

/// A `Variant` fixture sufficient for the pagination-prune helpers below:
/// only `string_table`/`path_table`/`urls`/`pages` are initialized (neither
/// `paginationPathName(Lookup)` nor `isPruneCandidateProtected` touches
/// anything else on `Variant`), left genuinely `undefined` otherwise on
/// purpose -- a stray read of an unrelated field is a Debug-mode crash
/// rather than silently "working" on garbage.
///
/// The priming calls mirror `Variant.load`'s exactly (see its first few
/// lines): `PathName.get`'s Debug-mode asserts require the empty path/string
/// to already sit at offset/index 0 in both tables, which only holds if they
/// are the FIRST thing ever interned.
///
/// `pages` starts empty: `isPruneCandidateProtected` now dereferences
/// `v.pages.items[hint.id]` for every `LocationHint` it finds in `v.urls`,
/// so any test that registers a `urls` entry must first give it an owning
/// page via `testOwningPage` below -- an unregistered `id` is a Debug-mode
/// out-of-bounds crash, same "crash rather than garbage" intent as leaving
/// the rest of `Variant` `undefined`.
fn testVariant(gpa: std.mem.Allocator) !Variant {
    var v: Variant = undefined;
    v.path_table = .empty;
    _ = try v.path_table.intern(gpa, &.{}); // empty path
    v.string_table = .empty;
    _ = try v.string_table.intern(gpa, ""); // invalid path component string
    v.urls = .empty;
    v.pages = .empty;
    return v;
}

/// Appends a minimal owning `Page` to `v.pages` with `_parse.active` set as
/// requested, and returns its index -- the `id` a test's `LocationHint`
/// needs to point at for `isPruneCandidateProtected`'s new active-owner
/// check. Every field but `title`/`layout`/`_parse.active` is left
/// `undefined`; the function under test reads nothing else off the page.
fn testOwningPage(v: *Variant, gpa: std.mem.Allocator, active: bool) !u32 {
    var page: Page = .{ .title = "Owner", .layout = "list.shtml" };
    page._parse.active = active;
    const id: u32 = @intCast(v.pages.items.len);
    try v.pages.append(gpa, page);
    return id;
}

/// A minimal section-index `Page` whose `_scan.url` is a real interned path
/// (everything pagination-prune code reads off a `Page`); every other field
/// is `undefined` on purpose, same reasoning as `testVariant`.
fn testIndexPage(v: *Variant, gpa: std.mem.Allocator, url: []const u8) !Page {
    var page: Page = .{ .title = "Test", .layout = "list.shtml" };
    page._scan.url = try v.path_table.internPath(gpa, &v.string_table, url);
    return page;
}

// Finding 2 (issue #127 tasks 8+9 combined review, fix round 1): nothing
// pinned that `paginationPathNameLookup` and `paginationPathName` agree --
// the invariant the stale-pagination prune's safety depends on entirely
// (skip a lookup HIT, delete a lookup MISS). Verified to fail without the
// fix: reverting `paginationPathNameLookup`'s `.page_dir`/`.plain_dir` arm to
// unconditionally `return null` makes the "then agrees" assertions below
// fail on `looked_up != null` for those two styles.
test "pagination: paginationPathNameLookup is null until paginationPathName registers the same path, then agrees, for every url style" {
    const gpa = testing.allocator;
    var v = try testVariant(gpa);
    defer v.string_table.deinit(gpa);
    defer v.path_table.deinit(gpa);
    defer v.urls.deinit(gpa);

    const page = try testIndexPage(&v, gpa, "blog");

    const styles = comptime std.enums.values(context.Page.Pagination.UrlStyle);
    for (styles) |style| {
        // Nothing interned yet for this (style, n) pair: lookup misses.
        try testing.expectEqual(@as(?PathName, null), v.paginationPathNameLookup(&page, style, 2));

        const interned = try v.paginationPathName(gpa, &page, style, 2);
        const looked_up = v.paginationPathNameLookup(&page, style, 2);
        try testing.expect(looked_up != null);
        try testing.expectEqual(interned.path, looked_up.?.path);
        try testing.expectEqual(interned.name, looked_up.?.name);
    }

    // An unregistered candidate (page 99, never interned by anything above)
    // still misses for every style -- the symmetry above didn't just get
    // lucky on n=2.
    for (styles) |style| {
        try testing.expectEqual(@as(?PathName, null), v.paginationPathNameLookup(&page, style, 99));
    }
}

// Finding 1 (issue #127 tasks 8+9 combined review, fix round 1): the prune's
// ONLY skip-list was `Variant.urls`, but an SPA's prerendered output is never
// a `Page` and so is never registered there -- a `staticPaths` entry "2"
// under an SPA based at `/news/` collides with `news`'s own non-current-style
// sweep (a sibling section still on `.page_dir`) and would be silently
// deleted every build. `isPruneCandidateProtected` is the exact function
// `root.zig`'s prune loop calls, so this pins the real behaviour rather than
// a reimplementation of it.
test "pagination: isPruneCandidateProtected treats a Variant.urls registration as protected" {
    const gpa = testing.allocator;
    var v = try testVariant(gpa);
    defer v.string_table.deinit(gpa);
    defer v.path_table.deinit(gpa);
    defer v.urls.deinit(gpa);
    defer v.pages.deinit(gpa);

    const page = try testIndexPage(&v, gpa, "news");

    // Register page 2 as a REAL page's main output -- mirrors what the scan
    // phase does for a subpage literally named "2" under `.plain_dir`. The
    // owning page is active, same as any real, published subpage.
    const owner_id = try testOwningPage(&v, gpa, true);
    const pn = try v.paginationPathName(gpa, &page, .plain_dir, 2);
    try v.urls.put(gpa, pn, .{ .id = owner_id, .kind = .page_main });

    var build: Build = undefined;
    build.spa_out_paths = .empty;
    defer build.spa_out_paths.deinit(gpa);

    try testing.expect(v.isPruneCandidateProtected(&build, &page, .plain_dir, 2, "news/2/index.html"));
    // A different, unregistered candidate is genuinely unprotected -- the
    // prune must still be able to delete real stale pagination pages.
    try testing.expect(!v.isPruneCandidateProtected(&build, &page, .plain_dir, 3, "news/3/index.html"));
}

// Finding 3 (issue #127 tasks 8+9 combined review, fix round 2): a
// `Variant.urls` hit alone was treated as protection, but `urls` is
// populated at SCAN time -- before draft/active status exists -- and an
// inactive page's entries are never removed. A draft page occupying a
// former pagination path therefore kept the stale dir alive forever in
// release builds. Verified to fail without the fix: reverting
// `isPruneCandidateProtected` to skip the `_parse.active` check makes the
// first assertion below fail (an inactive owner wrongly protects the path).
test "pagination: isPruneCandidateProtected ignores a Variant.urls registration owned by an inactive page" {
    const gpa = testing.allocator;
    var v = try testVariant(gpa);
    defer v.string_table.deinit(gpa);
    defer v.path_table.deinit(gpa);
    defer v.urls.deinit(gpa);
    defer v.pages.deinit(gpa);

    const page = try testIndexPage(&v, gpa, "news");

    // Same registration shape as the test above, but the owning page is a
    // draft: `_parse.active = false`, mirroring a page whose scan-time
    // `urls` entry outlived its own exclusion from the render.
    const inactive_owner = try testOwningPage(&v, gpa, false);
    const pn = try v.paginationPathName(gpa, &page, .plain_dir, 2);
    try v.urls.put(gpa, pn, .{ .id = inactive_owner, .kind = .page_main });

    var build: Build = undefined;
    build.spa_out_paths = .empty;
    defer build.spa_out_paths.deinit(gpa);

    // The urls hit exists, but its owner is inactive -- NOT protected, so
    // the stale pagination dir is free to be pruned.
    try testing.expect(!v.isPruneCandidateProtected(&build, &page, .plain_dir, 2, "news/2/index.html"));

    // The same path, owned by an ACTIVE page, is protected -- the uniform
    // rule cuts both ways.
    const active_owner = try testOwningPage(&v, gpa, true);
    const pn3 = try v.paginationPathName(gpa, &page, .plain_dir, 3);
    try v.urls.put(gpa, pn3, .{ .id = active_owner, .kind = .page_main });
    try testing.expect(v.isPruneCandidateProtected(&build, &page, .plain_dir, 3, "news/3/index.html"));
}

test "pagination: isPruneCandidateProtected treats a recorded SPA output path as protected, even with no Variant.urls entry" {
    const gpa = testing.allocator;
    var v = try testVariant(gpa);
    defer v.string_table.deinit(gpa);
    defer v.path_table.deinit(gpa);
    defer v.urls.deinit(gpa);
    defer v.pages.deinit(gpa);

    const page = try testIndexPage(&v, gpa, "blog");

    var build: Build = undefined;
    build.spa_out_paths = .empty;
    defer {
        var it = build.spa_out_paths.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        build.spa_out_paths.deinit(gpa);
    }
    // Mirrors spa.zig's recordSpaOutPath: an owned dupe, keyed by the exact
    // output-dir-relative path spa.zig's writeFile used.
    try build.spa_out_paths.put(gpa, try gpa.dupe(u8, "blog/2/index.html"), {});

    // Nothing is registered in Variant.urls for this candidate -- ONLY the
    // SPA record protects it. This is the exact reachable case the review
    // flagged: a staticPaths entry "2" under an SPA based at /blog/ collides
    // with a sibling .page_dir section's non-current-style sweep.
    try testing.expect(v.isPruneCandidateProtected(&build, &page, .plain_dir, 2, "blog/2/index.html"));

    // A path that is neither an SPA output nor in Variant.urls is genuinely
    // unprotected.
    try testing.expect(!v.isPruneCandidateProtected(&build, &page, .plain_dir, 3, "blog/3/index.html"));
}
