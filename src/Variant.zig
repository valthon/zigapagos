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

        // The content root must provide an index.smd: it establishes the
        // root section (section 0 is the invalid sentinel). Without it, any
        // content in the root — pages, assets, or nothing at all — would index
        // the undefined section 0 below, panicking in Debug and corrupting an
        // undefined ArrayList in release. Emit a clean diagnostic instead of
        // reaching that state. See AUD-009.
        if (dir_entry.path.len == 0 and !found_index_smd) {
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
