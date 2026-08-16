const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const builtin = @import("builtin");
const supermd = @import("supermd");
const superhtml = @import("superhtml");
const scripty = @import("scripty");
const ziggy = @import("ziggy");
const tracy = @import("tracy");
const syntax = @import("syntax");
const languages = @import("languages.zig");
const root = @import("root.zig");
const fatal = @import("fatal.zig");
const context = @import("context.zig");
const Page = context.Page;
const Build = @import("Build.zig");
const StringTable = @import("StringTable.zig");
const String = StringTable.String;
const PathTable = @import("PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;
const Variant = @import("Variant.zig");
const Template = @import("Template.zig");
const highlight = @import("highlight.zig");
const main = @import("main.zig");
const gpa = main.gpa;
const wuffs = @import("wuffs.zig");
const image_requests = @import("image/requests.zig");
const Channel = @import("channel.zig").Channel;
const islands = @import("islands/pass.zig");
const RenderArena = @import("islands/render_arena.zig").RenderArena;

const log = std.log.scoped(.worker);

// singleton
var ch_buf: [64]Job = undefined;
var ch: Channel(Job) = .init(&ch_buf);
var wg: @import("hacks/WaitGroup.zig") = undefined;
var threads: []std.Thread = &.{};

pub var started = false;
pub threadlocal var cmark: supermd.Ast.CmarkParser = undefined;

pub const Job = union(enum) {
    template_parse: struct {
        template: *Template,
        build: *const Build,
        pn: PathName,
    },
    scan: struct {
        variant: *Variant,
        base_dir: Io.Dir,
        content_dir_path: []const u8,
        variant_id: u32,
        multilingual: ?Variant.MultilingualScanParams,
        output_path_prefix: []const u8,
    },
    section_activate: struct {
        variant: *const Variant,
        section: *Variant.Section,
        page: *Page,
        drafts: bool,
        auto_heading_ids: bool,
    },
    page_parse: struct {
        progress: std.Progress.Node,
        drafts: bool,
        variant: *const Variant,
        page: *Page,
        auto_heading_ids: bool,
    },
    page_analyze: struct {
        progress: std.Progress.Node,
        build: *const Build,
        variant_id: u32,
        page: *Page,
    },
    page_render: struct {
        progress: std.Progress.Node,
        build: *Build,
        sites: *const std.StringArrayHashMapUnmanaged(context.Site),
        page: *Page,
        kind: RenderJobKind,
    },

    variant_assets_install: struct {
        progress: std.Progress.Node,
        variant: *const Variant,
        install_dir: Io.Dir,
    },

    /// One source image: decode once, resample+encode every planned
    /// variant, staging through .zigapagos-cache/images (#132).
    image_derive: @import("image/derive.zig").Job,

    leave,
};

pub fn start(io: Io) void {
    assert(!started);
    started = true;

    wg = .{ .io = io };

    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    supermd.c.cmark_gfm_core_extensions_ensure_registered();

    if (builtin.single_threaded) {
        cmark = supermd.Ast.CmarkParser.default();
        return;
    }

    const thread_count = @max(1, std.Thread.getCpuCount() catch 1);
    threads = try gpa.alloc(std.Thread, thread_count);

    for (0..thread_count) |idx| {
        const _cmark = supermd.Ast.CmarkParser.default();
        threads[idx] = std.Thread.spawn(
            .{ .allocator = gpa },
            workerFn,
            .{ io, _cmark },
        ) catch |err| fatal.msg("error: unable to spawn thread pool: {s}\n", .{
            @errorName(err),
        });
    }
}

pub fn stopWaitAndDeinit(io: Io) void {
    if (builtin.mode != .Debug) return;
    if (builtin.single_threaded) addJob(io, .leave);

    for (threads) |_| addJob(io, .leave);
    for (threads) |t| t.join();
    gpa.free(threads);
}

var single_threaded_arena_state = std.heap.ArenaAllocator.init(gpa);
// The per-job arena, typed (NO_SLOP.md §2.2a): a render job's arena-scoped
// callees (`islands.process`) take a `RenderArena`, and this is the boundary that
// owns and resets it.
const single_threaded_arena = RenderArena.from(&single_threaded_arena_state);
pub fn addJob(io: Io, job: Job) void {
    if (builtin.single_threaded) {
        const continue_ = runOneJob(io, single_threaded_arena, job);
        _ = single_threaded_arena_state.reset(.retain_capacity);

        if (builtin.mode == .Debug and !continue_) {
            single_threaded_arena_state.deinit();
        }
    } else {
        wg.start();
        ch.put(io, job) catch unreachable;
    }
}

pub fn wait() void {
    if (builtin.single_threaded) return;

    wg.wait();
    wg.reset();
}

fn workerFn(
    io: Io,
    _cmark: supermd.Ast.CmarkParser,
) void {
    cmark = _cmark;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = RenderArena.from(&arena_state);
    while (runOneJob(io, arena, ch.get(io) catch return)) {
        _ = arena_state.reset(.retain_capacity);
        wg.finish();
    }
}

inline fn runOneJob(
    io: Io,
    arena: RenderArena,
    job: Job,
) bool {
    switch (job) {
        .leave => {
            supermd.c.cmark_parser_free(cmark.parser);
            return false;
        },
        .template_parse => |tp| tp.template.parse(
            io,
            gpa,
            arena.a,
            tp.build,
            tp.pn,
        ),
        .scan => |s| s.variant.scanContentDir(
            io,
            gpa,
            arena.a,
            s.base_dir,
            s.content_dir_path,
            s.variant_id,
            s.multilingual,
            s.output_path_prefix,
        ),
        .section_activate => |ap| ap.section.activate(
            io,
            gpa,
            ap.variant,
            ap.page,
            ap.drafts,
            ap.auto_heading_ids,
        ),
        .page_parse => |pp| pp.page.parse(
            io,
            gpa,
            cmark,
            pp.progress,
            pp.variant,
            pp.drafts,
            pp.auto_heading_ids,
        ),
        .page_render => |pr| renderPage(
            io,
            arena,
            pr.progress,
            pr.build,
            pr.sites,
            pr.page,
            pr.kind,
        ),
        .page_analyze => |pa| analyzePage(
            io,
            arena.a,
            pa.progress,
            pa.build,
            pa.variant_id,
            pa.page,
        ),

        .variant_assets_install => |vai| vai.variant.installAssets(
            io,
            vai.progress,
            vai.install_dir,
        ),

        .image_derive => |d| {
            @import("image/derive.zig").run(io, gpa, d);
            d.progress.completeOne();
        },
    }
    return true;
}

fn analyzePage(
    io: Io,
    arena: Allocator,
    progress: std.Progress.Node,
    build: *const Build,
    variant_id: u32,
    page: *Page,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    assert(page._parse.status == .parsed);
    if (builtin.mode == .Debug) {
        const last = page._debug.stage.swap(.analyzed, .monotonic);
        assert(last == .parsed);
    }

    const v = &build.variants[variant_id];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const page_path = std.fmt.bufPrint(&buf, "{f}", .{
        page._scan.file.fmt(
            &v.string_table,
            &v.path_table,
            v.content_dir_path,
            "",
        ),
    }) catch unreachable;

    const p = progress.start(page_path, 1);
    defer p.end();

    // We do not set all of analysis because it might contain a missing
    // layout error put there by the main thread.
    // page._analysis = .{};

    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    var arena_state = page._parse.arena.promote(gpa);
    defer page._parse.arena = arena_state.state;
    const page_arena = arena_state.allocator();

    try analyzeFrontmatter(page_arena, page);
    try analyzeContent(io, page_arena, arena, build, variant_id, page);
}

fn analyzeFrontmatter(page_arena: Allocator, p: *Page) error{OutOfMemory}!void {
    // We don't validate layout because it will be validated
    // later on by the main function where we will also check
    // if the file exists or not. Leaving this check here
    // would result in duplicated error reporting.
    // if (p.layout.len == 0) try errors.append(gpa, .layout);

    const errors = &p._analysis.frontmatter;

    for (p.aliases, 0..) |a, aidx| {
        if (!validOutputPath(a)) try errors.append(page_arena, .{
            .alias = @intCast(aidx),
        });
    }

    for (p.alternatives, 0..) |alt, aidx| {
        if (!validOutputPath(alt.output)) try errors.append(page_arena, .{
            .alternative = .{
                .id = @intCast(aidx),
                .kind = .path,
            },
        });

        if (alt.name.len == 0) try errors.append(page_arena, .{
            .alternative = .{
                .id = @intCast(aidx),
                .kind = .name,
            },
        });
    }

    if (p.pagination) |pg| {
        if (pg.page_size == 0) try errors.append(page_arena, .pagination_size);
        // subsection_id == 0 means "this page owns no section" — i.e. it is a
        // leaf page, not an index.smd (see Variant.zig's scan).
        if (p._scan.subsection_id == 0) try errors.append(page_arena, .pagination_not_section);
    }
}

/// A page-output path (an `aliases` entry or an alternative's `output`) comes
/// straight from user frontmatter and is later interned by the URL-collision
/// pass, whose structural asserts require: non-empty, ASCII-only, no backslash,
/// a file extension, and no `.` in any directory component. Validate all of
/// that here so a malformed value becomes a frontmatter diagnostic instead of
/// reaching (and, in ReleaseFast where asserts compile out, silently violating)
/// those invariants. See AUD-002.
pub fn validOutputPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |c| if (!std.ascii.isAscii(c)) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.fs.path.extension(path).len == 0) return false;
    if (std.mem.indexOfScalar(
        u8,
        std.fs.path.dirnamePosix(path) orelse "",
        '.',
    ) != null) return false;
    return true;
}

/// --allow-missing-pages (issue #27 / DX-8): which base to prepend to a
/// dangling `$link.page/sibling/sub` ref when computing the URL the target
/// page WOULD have. Mirrors the three ways `analyzeContent` resolves a ref's
/// base in the `path: Path = switch (p.kind) { ... }` block below.
const MissingPageBase = union(enum) {
    /// `.absolute`: the ref is rooted at the content dir, no base to prepend.
    root,
    /// `.sibling`/`.sub`: the parent section's `content_sub_path`, or the
    /// section page's own `_scan.file.path` -- formatted with a trailing
    /// slash (mirrors `Path.Formatter`'s `trailing_slash=true`), then `ref`
    /// is appended after it.
    base_dir: Path,
    /// The fourth `unknown_page` site: `getPathNoName` already resolved a
    /// full `Path` for `ref` (some OTHER content under the same directory
    /// already exists, e.g. a sibling asset) -- format it directly. `ref` is
    /// already baked into this `Path`, so it must NOT be appended again.
    resolved: Path,
};

/// NO_SLOP.md §2.2a contract 1 (self-freeing): the only allocation is the
/// returned string, from `page_arena` so it outlives analysis and survives
/// into render (the caller stashes it into `directive.kind.*.src = .{ .url =
/// ... }` and/or a `PageAnalysisError`). Returned via `aw.toOwnedSlice()`, not
/// `aw.written()`: the latter can return a slice shorter than the buffer it
/// points into, which a caller cannot `free` under an arbitrary allocator --
/// contract 1 promises exactly one allocation a caller CAN free, and
/// `toOwnedSlice` is what actually makes that true (harmless today, since
/// `page_arena` never frees anyway, but the label has to hold regardless of
/// which allocator happens to be passed).
///
/// Computes the URL a not-yet-existing page WOULD have once its content file
/// lands, so an `--allow-missing-pages` build can emit a real, url_prefix-
/// /locale-prefix-aware `href` instead of failing the build. Mirrors
/// `render/html.zig`'s `printUrl` `.page` arm (`printLinkPrefix` +
/// `Path.Formatter`, `trailing_slash=true`), but works from static build
/// state (`b.cfg`/the variant) instead of a live `context.Root`, since
/// analysis runs long before any page renders.
///
/// KNOWN, ACCEPTED LIMITATION: `printUrl` emits an ABSOLUTE (host-qualified)
/// URL when the page containing the link is rendered embedded inside a
/// DIFFERENT page (`page != ctx.page` -- e.g. an index listing that pulls in
/// another page's content), or across variants with differing
/// `host_url_override`s. Analysis runs once per source AST, before any
/// renderer knows which page(s) will embed it, so this helper always emits
/// the root-relative form. Accepted because the tolerated link only ever
/// points at a page that does not exist yet -- a 404 either way -- and is
/// only reachable at all behind the explicit `--allow-missing-pages` opt-in.
fn missingPageUrl(
    page_arena: Allocator,
    b: *const Build,
    variant_id: u32,
    base: MissingPageBase,
    ref: []const u8,
) error{OutOfMemory}![]const u8 {
    const variant = &b.variants[variant_id];
    var aw: Writer.Allocating = .init(page_arena);
    const w = &aw.writer;

    missingPageLinkPrefix(w, b.cfg, variant_id) catch return error.OutOfMemory;

    switch (base) {
        .root => {},
        .base_dir => |p| w.print("{f}", .{
            p.fmt(&variant.string_table, &variant.path_table, null, true),
        }) catch return error.OutOfMemory,
        .resolved => |p| {
            w.print("{f}", .{
                p.fmt(&variant.string_table, &variant.path_table, null, true),
            }) catch return error.OutOfMemory;
            return aw.toOwnedSlice();
        },
    }

    w.writeAll(ref) catch return error.OutOfMemory;
    w.writeAll("/") catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// The non-`force_host_url` half of `context/Root.zig`'s `printLinkPrefix`,
/// reimplemented against static `Config` state (analysis has no
/// `context.Root` yet -- see `missingPageUrl`'s doc comment for why that's
/// the accepted tradeoff here).
fn missingPageLinkPrefix(
    w: *Writer,
    cfg: *const root.Config,
    variant_id: u32,
) error{WriteFailed}!void {
    switch (cfg.*) {
        .Site => |s| {
            if (s.url_path_prefix.len > 0) {
                try w.print("/{s}/", .{s.url_path_prefix});
            } else {
                try w.writeAll("/");
            }
        },
        .Multilingual => |ml| {
            const locale = ml.locales[variant_id];
            try w.writeAll("/");
            const path_prefix = locale.output_prefix_override orelse locale.code;
            if (path_prefix.len > 0) try w.print("{s}/", .{path_prefix});
        },
    }
}

fn analyzeContent(
    io: Io,
    page_arena: Allocator,
    scratch: Allocator,
    b: *const Build,
    variant_id: u32,
    page: *Page,
) error{OutOfMemory}!void {
    const ast = &page._parse.ast;
    const errors = &page._analysis.page;
    const variant = &b.variants[variant_id];
    const autosize = b.cfg.getImageAutosize();
    const index_smd: String = @enumFromInt(1);
    assert(variant.string_table.get("index.smd") == index_smd);
    const index_html: String = @enumFromInt(11);
    assert(variant.string_table.get("index.html") == index_html);

    var current: ?supermd.Node = ast.md.root.firstChild();
    outer: while (current) |n| : (current = n.next(ast.md.root)) {
        if (n.nodeType() == .CODE_BLOCK) blk: {
            const fence_info = n.fenceInfo() orelse break :blk;
            var fence_it = std.mem.tokenizeScalar(u8, fence_info, ' ');
            const lang = fence_it.next() orelse break :blk;

            if (!languageExists(lang)) {
                try errors.append(page_arena, .{
                    .node = n,
                    .kind = .{
                        .unknown_language = .{
                            .lang = lang,
                            .suggestion = languages.suggest(lang),
                        },
                    },
                });
            }

            continue :outer;
        }

        const directive = n.getDirective() orelse continue;

        switch (directive.kind) {
            .section, .block, .heading, .text, .mathtex => {},
            .code => |code| {
                const path, const base_dir = switch (code.src.?) {
                    else => unreachable,
                    .page_asset => |pa| blk: {
                        assert(std.mem.indexOfScalar(u8, pa.ref, '\\') == null);
                        var buf: std.ArrayList(String) = .empty;

                        try buf.appendSlice(scratch, page._scan.url.slice(
                            &variant.path_table,
                        ));

                        var it = std.mem.tokenizeScalar(u8, pa.ref, '/');
                        while (it.next()) |component_bytes| {
                            const component = variant.string_table.get(
                                component_bytes,
                            ) orelse {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .missing_asset = .{
                                            .ref = pa.ref,
                                            .kind = .page,
                                        },
                                    },
                                });
                                continue :outer;
                            };
                            try buf.append(scratch, component);
                        }

                        const path_strings = buf.items[0 .. buf.items.len - 1];
                        const name = buf.items[buf.items.len - 1];
                        if (variant.path_table.get(path_strings)) |path| {
                            const pn: PathName = .{ .path = path, .name = name };
                            if (variant.urls.getPtr(pn)) |hint| {
                                switch (hint.kind) {
                                    .page_asset => {
                                        break :blk .{
                                            try std.fmt.allocPrint(scratch, "{f}", .{
                                                pn.fmt(
                                                    &variant.string_table,
                                                    &variant.path_table,
                                                    null,
                                                    "",
                                                ),
                                            }),
                                            variant.content_dir,
                                        };
                                    },
                                    else => {},
                                }
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = pa.ref,
                                    .kind = .page,
                                },
                            },
                        });
                        continue :outer;
                    },
                    .build_asset => |ba| blk: {
                        const asset = b.build_assets.get(ba.ref) orelse {
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .missing_asset = .{
                                        .ref = ba.ref,
                                        .kind = .build,
                                    },
                                },
                            });
                            continue :outer;
                        };
                        break :blk .{ asset.input_path, Io.Dir.cwd() };
                    },
                    .site_asset => |*sa| blk: {
                        if (PathName.get(&b.st, &b.pt, sa.ref)) |pn| {
                            if (b.site_assets.contains(pn)) {
                                break :blk .{
                                    sa.ref,
                                    // dir is not relevant because the path is
                                    // absolute
                                    b.site_assets_dir,
                                };
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = sa.ref,
                                    .kind = .site,
                                },
                            },
                        });
                        continue :outer;
                    },
                };
                const src = base_dir.readFileAlloc(
                    io,
                    path,
                    page_arena,
                    .unlimited,
                ) catch |err| fatal.file(path, err);

                if (!languageExists(code.language)) {
                    // Warn-and-continue (issue #31), NOT `continue :outer`: unlike
                    // the fence-path site above, this arm still has to run --
                    // `directive.kind.code.src` below is what the renderer reads
                    // (src/render/html.zig's `code.src.?.url`), and it's still a
                    // `.page_asset`/`.site_asset`/`.build_asset` union member at
                    // this point. Skipping the assignment would leave the render
                    // pass reading a stale union tag instead of the resolved URL.
                    try errors.append(page_arena, .{
                        .node = n,
                        .kind = .{
                            .unknown_language = .{
                                .lang = code.language.?,
                                .suggestion = languages.suggest(code.language.?),
                            },
                        },
                    });
                }
                const snippet = if (code.lines) |lines| blk: {
                    var line_num: usize = 1;
                    var slice_start: usize = 0;

                    for (src, 0..) |byte, index| {
                        if (byte == '\n') {
                            line_num += 1;
                            if (line_num == lines.start) {
                                slice_start = index + 1;
                            }
                            if (line_num == lines.end + 1) {
                                break :blk src[slice_start .. index + 1];
                            }
                        }
                    }
                    break :blk src[slice_start..];
                } else src;

                directive.kind.code.src = .{ .url = snippet };
            },

            // Link, Image, Video directives
            inline else => |*val| {
                switch (val.src.?) {
                    .url => continue :outer,
                    .self_page => |*resolved_alt| {
                        // This value is only expected for Link directives.
                        if (@TypeOf(val.*) != supermd.context.Link) continue :outer;

                        if (val.alternative) |alt_name| {
                            for (page.alternatives) |alt| {
                                if (std.mem.eql(u8, alt.name, alt_name)) {
                                    resolved_alt.* = alt.output;
                                    break;
                                }
                            } else {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_alternative = .{
                                            .name = alt_name,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }

                        if (val.ref) |ref| {
                            if (!val.ref_unsafe and !ast.ids.contains(ref) and ref.len > 0) {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_ref = .{
                                            .ref = ref,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }
                    },

                    .page => |*p| {
                        // This value is only expected for Link directives.
                        if (@TypeOf(val.*) != supermd.context.Link) continue :outer;

                        const path: Path = switch (p.kind) {
                            .absolute => blk: {
                                log.debug("absolute page link '{s}'", .{p.ref});
                                if (variant.path_table.getPathNoName(
                                    &variant.string_table,
                                    &.{},
                                    p.ref,
                                )) |path| break :blk path;
                                log.debug("page link '{s}': path not found", .{p.ref});
                                if (builtin.mode == .Debug) {
                                    var it = std.mem.tokenizeScalar(u8, p.ref, '/');
                                    while (it.next()) |c| {
                                        log.debug("'{s}' -> [{?d}]", .{
                                            c, variant.string_table.get(c),
                                        });
                                    }
                                }

                                // --allow-missing-pages: read `ref` out before
                                // overwriting `val.src` below -- `p` points
                                // INTO `val.src`'s `.page` payload, so once we
                                // assign the `.url` variant `p.ref` aliases
                                // whatever bytes now live there.
                                if (b.allow_missing_pages) {
                                    const ref = p.ref;
                                    const url = try missingPageUrl(page_arena, b, variant_id, .root, ref);
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .{
                                            .missing_page_tolerated = .{ .ref = ref, .url = url },
                                        },
                                    });
                                    val.src = .{ .url = url };
                                    continue :outer;
                                }

                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                            .sibling => blk: {
                                // Sibling means that the path is rooted in
                                // the current's section path. All pages have
                                // a section except the root index page.
                                const section_id = page._scan.parent_section_id;
                                if (section_id == 0) {
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .no_parent_section,
                                    });
                                    continue :outer;
                                }

                                const section = variant.sections.items[section_id];
                                if (variant.path_table.getPathNoName(
                                    &variant.string_table,
                                    section.content_sub_path.slice(
                                        &variant.path_table,
                                    ),
                                    p.ref,
                                )) |path| break :blk path;

                                // --allow-missing-pages: same ordering caveat
                                // as the `.absolute` site above.
                                if (b.allow_missing_pages) {
                                    const ref = p.ref;
                                    const url = try missingPageUrl(
                                        page_arena,
                                        b,
                                        variant_id,
                                        .{ .base_dir = section.content_sub_path },
                                        ref,
                                    );
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .{
                                            .missing_page_tolerated = .{ .ref = ref, .url = url },
                                        },
                                    });
                                    val.src = .{ .url = url };
                                    continue :outer;
                                }

                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                            .sub => blk: {
                                // Subpage means that the final path is
                                // based on the current page's URL path.
                                // It also is only available on pages that
                                // are sections, which means that the page
                                // is guaranteed to be named `index.smd`.
                                if (page._scan.file.name != index_smd) {
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .not_a_section,
                                    });
                                    continue :outer;
                                }

                                var buf: std.ArrayList(String) = .empty;
                                try buf.appendSlice(scratch, page._scan.file.path.slice(
                                    &variant.path_table,
                                ));

                                if (variant.path_table.getPathNoName(
                                    &variant.string_table,
                                    buf.items,
                                    p.ref,
                                )) |path| break :blk path;

                                // --allow-missing-pages: same ordering caveat
                                // as the `.absolute` site above.
                                if (b.allow_missing_pages) {
                                    const ref = p.ref;
                                    const url = try missingPageUrl(
                                        page_arena,
                                        b,
                                        variant_id,
                                        .{ .base_dir = page._scan.file.path },
                                        ref,
                                    );
                                    try errors.append(page_arena, .{
                                        .node = n,
                                        .kind = .{
                                            .missing_page_tolerated = .{ .ref = ref, .url = url },
                                        },
                                    });
                                    val.src = .{ .url = url };
                                    continue :outer;
                                }

                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_page = .{
                                            .ref = p.ref,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                        };

                        const pn: PathName = .{ .path = path, .name = index_html };
                        const hint = variant.urls.get(pn) orelse {
                            log.debug("absolute page link '{s}': hint not found", .{
                                p.ref,
                            });

                            // --allow-missing-pages: `path` already resolved
                            // (some other content shares its directory), so
                            // format it directly -- see `MissingPageBase.resolved`.
                            // Same read-before-overwrite ordering as the three
                            // sites above.
                            if (b.allow_missing_pages) {
                                const ref = p.ref;
                                const url = try missingPageUrl(
                                    page_arena,
                                    b,
                                    variant_id,
                                    .{ .resolved = path },
                                    ref,
                                );
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .missing_page_tolerated = .{ .ref = ref, .url = url },
                                    },
                                });
                                val.src = .{ .url = url };
                                continue :outer;
                            }

                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .unknown_page = .{
                                        .ref = p.ref,
                                    },
                                },
                            });
                            continue :outer;
                        };

                        log.debug("absolute page link '{s}' hint: {any}", .{ p.ref, hint });
                        switch (hint.kind) {
                            .page_main => {},
                            else => {
                                log.debug("absolute page link '{s}' wrong kint kind: {any}", .{ p.ref, hint.kind });
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .resource_kind_mismatch = .{
                                            .expected = .page_main,
                                            .got = hint.kind,
                                        },
                                    },
                                });
                                continue :outer;
                            },
                        }

                        const other_page = if (p.locale) |loc| {
                            // Locale-qualified page links (a second locale-code
                            // argument to $link.page/sub/sibling/site) are not
                            // resolved yet; report a clean link-resolution error
                            // instead of aborting the build. See AUD-011.
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .locale_link_unsupported = .{ .locale = loc },
                                },
                            });
                            continue :outer;
                        } else variant.pages.items[hint.id];

                        p.resolved = .{
                            .page_id = hint.id,
                            .variant_id = other_page._scan.variant_id,
                            .path = @intFromEnum(path),
                        };

                        if (val.alternative) |alt_name| {
                            log.debug("absolute page link '{s}' has alternative: {s}", .{
                                p.ref,
                                alt_name,
                            });
                            for (other_page.alternatives) |alt| {
                                if (std.mem.eql(u8, alt.name, alt_name)) {
                                    p.resolved.alt = alt.output;
                                    break;
                                }
                            } else {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_alternative = .{
                                            .name = alt_name,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }

                        if (val.ref) |ref| {
                            if (!val.ref_unsafe and !other_page._parse.ast.ids.contains(ref)) {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .unknown_ref = .{
                                            .ref = ref,
                                        },
                                    },
                                });
                                continue :outer;
                            }
                        }
                    },

                    .page_asset => |*pa| {
                        assert(std.mem.indexOfScalar(u8, pa.ref, '\\') == null);
                        var buf: std.ArrayList(String) = .empty;

                        try buf.appendSlice(
                            scratch,
                            page._scan.url.slice(&variant.path_table),
                        );

                        var it = std.mem.tokenizeScalar(u8, pa.ref, '/');
                        while (it.next()) |component_bytes| {
                            const component = variant.string_table.get(
                                component_bytes,
                            ) orelse {
                                try errors.append(page_arena, .{
                                    .node = n,
                                    .kind = .{
                                        .missing_asset = .{
                                            .ref = pa.ref,
                                            .kind = .page,
                                        },
                                    },
                                });
                                continue :outer;
                            };
                            try buf.append(scratch, component);
                        }

                        const path_strings = buf.items[0 .. buf.items.len - 1];
                        const name = buf.items[buf.items.len - 1];
                        if (variant.path_table.get(path_strings)) |path| {
                            const pn: PathName = .{ .path = path, .name = name };
                            if (variant.urls.getPtr(pn)) |hint| {
                                switch (hint.kind) {
                                    .page_asset => |*rc| {
                                        // TODO: when going from zero to one
                                        //       grab image size info if needed
                                        _ = rc.fetchAdd(1, .acq_rel);
                                        pa.resolved = .{
                                            .path = @intFromEnum(path),
                                            .name = @intFromEnum(name),
                                        };

                                        const bytes = try std.fmt.allocPrint(scratch, "{f}", .{
                                            pn.fmt(
                                                &variant.string_table,
                                                &variant.path_table,
                                                null,
                                                "/",
                                            ),
                                        });

                                        if (autosize and directive.kind == .image and directive.kind.image.size == null) {
                                            wuffs.setImageSize(
                                                io,
                                                scratch,
                                                directive,
                                                variant.content_dir,
                                                bytes,
                                            );
                                        }

                                        if (b.mode == .disk and b.cfg.getImageOptimize() != null and directive.kind == .image) {
                                            image_requests.register(io, gpa, .{
                                                .kind = .page,
                                                .variant_id = variant_id,
                                                .path = @intFromEnum(path),
                                                .name = @intFromEnum(name),
                                            }) catch fatal.oom();
                                        }
                                        continue :outer;
                                    },
                                    else => {},
                                }
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = pa.ref,
                                    .kind = .page,
                                },
                            },
                        });
                        continue :outer;
                    },
                    .site_asset => |*sa| { //ref
                        assert(std.mem.indexOfScalar(u8, sa.ref, '\\') == null);

                        const dirname = std.fs.path.dirnamePosix(sa.ref) orelse "";
                        if (b.pt.getPathNoName(&b.st, &.{}, dirname)) |path| {
                            const basename = std.fs.path.basenamePosix(sa.ref);
                            if (b.st.get(basename)) |name| {
                                const pn: PathName = .{
                                    .path = path,
                                    .name = name,
                                };

                                if (b.site_assets.getPtr(pn)) |rc| {
                                    _ = rc.fetchAdd(1, .acq_rel);
                                    sa.resolved = .{
                                        .path = @intFromEnum(path),
                                        .name = @intFromEnum(name),
                                    };

                                    if (autosize and directive.kind == .image and directive.kind.image.size == null) {
                                        wuffs.setImageSize(
                                            io,
                                            scratch,
                                            directive,
                                            b.site_assets_dir,
                                            sa.ref,
                                        );
                                    }

                                    if (b.mode == .disk and b.cfg.getImageOptimize() != null and directive.kind == .image) {
                                        image_requests.register(io, gpa, .{
                                            .kind = .site,
                                            .variant_id = 0,
                                            .path = @intFromEnum(path),
                                            .name = @intFromEnum(name),
                                        }) catch fatal.oom();
                                    }
                                    continue :outer;
                                }
                            }
                        }

                        try errors.append(page_arena, .{
                            .node = n,
                            .kind = .{
                                .missing_asset = .{
                                    .ref = sa.ref,
                                    .kind = .site,
                                },
                            },
                        });
                        continue :outer;
                    },
                    .build_asset => |*ba| {
                        const asset = b.build_assets.getPtr(ba.ref) orelse {
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .missing_asset = .{
                                        .ref = ba.ref,
                                        .kind = .build,
                                    },
                                },
                            });
                            continue :outer;
                        };

                        if (autosize and directive.kind == .image and directive.kind.image.size == null) {
                            wuffs.setImageSize(
                                io,
                                scratch,
                                directive,
                                b.site_assets_dir,
                                asset.input_path,
                            );
                        }

                        // Bump rc only after confirming an install path exists:
                        // a no-install asset must not be marked for install
                        // (installBuildAssets would otherwise unwrap a null
                        // install_path). The missing-path case is a page error.
                        const output_path = asset.install_path orelse {
                            try errors.append(page_arena, .{
                                .node = n,
                                .kind = .{
                                    .build_asset_missing_install_path = .{
                                        .ref = ba.ref,
                                    },
                                },
                            });
                            continue :outer;
                        };

                        _ = asset.rc.fetchAdd(1, .acq_rel);
                        ba.ref = output_path;
                    },
                }
            },
        }
    }
}

/// The `{f}` formatter for a page's output directory -- the *un-rendered* core
/// of `pageDir`/`mainOutputPath`/`suffixedOutputPath` below. Allocates nothing.
/// It exists so each of those three is a SINGLE `allocPrint` with no
/// intermediate directory string to allocate, leak or free: that is what makes
/// all three honest §2.2a contract-1 functions, and it keeps the emit path at
/// the one allocation per output it had before this extraction. (The first cut
/// of the extraction formatted `pageDir`'s *result* instead, which both doubled
/// the allocation count on the hot path and leaked the intermediate under any
/// non-arena allocator -- a contract-4 leak wearing a contract-1 label.)
///
/// The only difference between the two config shapes is the locale prefix: a
/// `.Site` has none, a `.Multilingual` variant contributes its
/// `output_path_prefix`.
fn urlFmt(
    cfg: *const root.Config,
    variant: *const Variant,
    page: *const Page,
) PathTable.Path.Formatter {
    const prefix: ?[]const u8 = switch (cfg.*) {
        .Site => null,
        .Multilingual => variant.output_path_prefix,
    };
    return page._scan.url.fmt(&variant.string_table, &variant.path_table, prefix, true);
}

/// The directory a page's own output lands in, relative to the output
/// directory root: "" for the site's root page, otherwise a `/`-terminated
/// path. This is the shared core of `mainOutputPath`/`suffixedOutputPath`
/// below, and the exact formula `renderPage`'s disk-mode emit path further
/// down uses for `out_dir_path` (the main-output case) -- extracted (H7 in the
/// `dx/introspection` plan, issues #45/#47) so `zigapagos explain` reports the
/// REAL emitted path instead of a second, driftable copy of this formula: a
/// stale copy of exactly this kind is the defect issue #47 exists to fix (a doc
/// claimed a deploy tree no build actually emits).
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): exactly one allocation and it
/// escapes as the return; there is no scratch. Correct under ANY allocator,
/// not just the render arena the emit path happens to hand it.
pub fn pageDir(
    alloc: Allocator,
    cfg: *const root.Config,
    variant: *const Variant,
    page: *const Page,
) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{f}", .{urlFmt(cfg, variant, page)});
}

/// A page's MAIN output path (its rendered `index.html`), relative to the
/// output directory -- `pageDir` plus the filename every main output gets. See
/// `pageDir`'s doc comment for why this is extracted.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing), same as `pageDir`: the filename
/// is appended INSIDE the single `allocPrint` via `urlFmt` rather than by
/// formatting `pageDir`'s result, so there is no intermediate allocation left
/// unfreed.
pub fn mainOutputPath(
    alloc: Allocator,
    cfg: *const root.Config,
    variant: *const Variant,
    page: *const Page,
) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{f}index.html", .{urlFmt(cfg, variant, page)});
}

/// The output path of one of a page's `aliases` entries or one
/// `alternatives[].output`, relative to the output directory -- the exact
/// formula `renderPage`'s disk-mode emit path further down uses for both
/// (identical logic; only the source field differs, see the two call sites).
/// `suffix` is the raw frontmatter string (`a` or `alt.output`): root-relative
/// (leading '/') suffixes are used verbatim (minus the leading '/', no locale
/// prefix -- they are declared relative to the SITE root, not the page);
/// anything else is joined onto `pageDir` (so it DOES pick up the locale prefix
/// on a `.Multilingual` site). See `pageDir`'s doc comment for why this is
/// extracted.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing), ALWAYS-OWNED in both branches.
/// The rooted branch could hand back `suffix[1..]` for free -- the inline code
/// this replaced did exactly that -- but as a *function* result that is the
/// borrowed-or-owned return §2.2a flags by name: the caller cannot free it
/// without knowing which branch ran, so it would only be sound where nobody
/// frees. One `dupe` of a short frontmatter string (root-relative aliases are
/// the rare spelling, and most pages declare no aliases at all) buys a result
/// every caller can treat identically. The joined branch is still the single
/// `allocPrint` it was before the extraction.
pub fn suffixedOutputPath(
    alloc: Allocator,
    cfg: *const root.Config,
    variant: *const Variant,
    page: *const Page,
    suffix: []const u8,
) ![]const u8 {
    if (suffix[0] == '/') return alloc.dupe(u8, suffix[1..]);
    return std.fmt.allocPrint(alloc, "{f}{s}", .{ urlFmt(cfg, variant, page), suffix });
}

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

/// The URL-pathname suffix for pagination page `n` — what the BROWSER's
/// window.location.pathname is for that page, passed to the island SSR pass
/// so `z.host.pathname()` agrees with it (see runtime/src/ssr-env.ts's
/// documented contract for that value). This differs from `paginationSuffix`
/// (the on-disk file suffix) only for the directory styles: a directory's
/// pathname has no `index.html` component, so it ends in `/` instead.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing). Delegates to
/// `Page.Pagination.UrlStyle.writePathnameTail`, the single formula also
/// used by `Paginator.printPageUrl` for link generation — H7 (issues
/// #45/#47): a link's href and the file it points at must agree, so they
/// cannot be two independently-maintained switch statements.
pub fn paginationPathnameTail(
    alloc: Allocator,
    style: Page.Pagination.UrlStyle,
    n: u32,
) ![]const u8 {
    // toOwnedSlice, not .written() (same reasoning as missingPageUrl's doc
    // comment above): .written() can return a slice shorter than the
    // backing allocation, which the regression test below cannot `free`
    // under std.testing.allocator's exact-size tracking.
    var aw: Writer.Allocating = .init(alloc);
    try style.writePathnameTail(&aw.writer, n);
    return aw.toOwnedSlice();
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

pub const RenderJobKind = union(enum) { main, alternative: u32, pagination: u32 };
const SuperVM = superhtml.VM(context.Value);
const ContentPropScriptyVM = scripty.VM(context.Value);

const ContentPropEvalContext = struct {
    root: *context.Root,
    vm: ContentPropScriptyVM = .{},
};

fn evalContentIslandProp(
    opaque_context: *anyopaque,
    arena: RenderArena,
    expression: []const u8,
) error{OutOfMemory}!islands.ContentPropEvalResult {
    const eval_ctx: *ContentPropEvalContext = @ptrCast(@alignCast(opaque_context));
    eval_ctx.vm.reset();
    const result = eval_ctx.vm.run(arena.a, eval_ctx.root, expression, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Quota => return .{ .err = "expression evaluation quota exceeded" },
    };
    return switch (result.value) {
        .string => |value| .{ .value = try arena.a.dupe(u8, value.value) },
        .int => |value| .{ .value = try std.fmt.allocPrint(arena.a, "{d}", .{value.value}) },
        .err => |message| .{ .err = try arena.a.dupe(u8, message) },
        else => .{ .err = try std.fmt.allocPrint(
            arena.a,
            "expression must evaluate to a string or integer, got {s}",
            .{@tagName(result.value)},
        ) },
    };
}

fn renderPage(
    io: Io,
    /// NO_SLOP.md §2.2a contract 4: the per-job arena, reset after every job.
    /// `islands.process` requires it by type; the plain contract-1 helpers here
    /// reach it through `arena.a`.
    arena: RenderArena,
    progress: std.Progress.Node,
    build: *Build,
    sites: *const std.StringArrayHashMapUnmanaged(context.Site),
    page: *Page,
    kind: RenderJobKind,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    const variant_id = page._scan.variant_id;
    const variant = &build.variants[variant_id];

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const page_path = std.fmt.bufPrint(&buf, "{f}", .{
        page._scan.file.fmt(
            &variant.string_table,
            &variant.path_table,
            variant.content_dir_path,
            "",
        ),
    }) catch unreachable;

    tracy.messageCopy(page_path);

    const progress_name = switch (kind) {
        .main => page_path,
        .alternative => |idx| blk: {
            const alt_name = page.alternatives[idx].name;
            break :blk try std.fmt.allocPrint(arena.a, "{s} (alternative '{s}')", .{
                page_path,
                alt_name,
            });
        },
        .pagination => |n| try std.fmt.allocPrint(arena.a, "{s} (page {d})", .{ page_path, n }),
    };

    const p = progress.start(progress_name, 0);
    defer p.end();

    // page._meta = .{
    //     // .is_root = true,
    //     .src = page._parse.full_src[page._parse.fm.offset..],
    //     .ast = page._parse.ast,
    //     .word_count = @intCast(page._parse.full_src[page._parse.fm.offset..].len / 6),
    //     // .index_in_section = 0,
    //     // .parent_section_path = "",
    // };

    var ctx: context.Root = .{
        .site = &sites.entries.items(.value)[variant_id],
        .page = page,
        .i18n = variant.i18n,
        .build = undefined,
        ._meta = .{
            .io = io,
            .build = build,
            .sites = sites,
        },
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
    };

    ctx.build.generated = .initNow(io);

    const layout_path = switch (kind) {
        .main => page.layout,
        .alternative => |idx| page.alternatives[idx].layout,
        .pagination => page.layout,
    };

    const layout_pn = PathName.get(&build.st, &build.pt, layout_path).?;
    const layout = build.templates.get(layout_pn).?;
    assert(layout.layout);

    var out_aw: Writer.Allocating = .init(gpa);
    // Uniform gpa-ownership (AUD-004): free the render scratch buffers on every
    // exit path in BOTH modes. In .memory mode the surviving output is a
    // standalone gpa dup stored into `page._render` below, so these buffers are
    // always redundant by function end and previously leaked per rebuild.
    defer out_aw.deinit();
    var err_aw: Writer.Allocating = .init(gpa);
    defer err_aw.deinit();

    var super_vm = SuperVM.init(
        arena.a,
        &ctx,
        layout_path,
        build.cfg.getLayoutsDirPath(),
        layout.src,
        layout.html_ast,
        layout.ast,
        std.mem.endsWith(u8, layout_path, ".xml"),
        page_path,
        &out_aw.writer,
        &err_aw.writer,
    );

    while (true) super_vm.run() catch |err| switch (err) {
        error.Done => break,
        error.Fatal => {
            std.debug.print("{s}\n", .{err_aw.written()});
            build.any_rendering_error.store(true, .release);
            if (build.mode == .memory) {
                // Dupe into a standalone gpa allocation owned by the page: the
                // err_aw buffer is freed by the defer above. See AUD-004.
                const errs = gpa.dupe(u8, err_aw.written()) catch fatal.oom();
                switch (kind) {
                    .main => page._render.errors = errs,
                    .alternative => |aidx| page._render.alternatives[aidx].errors = errs,
                    .pagination => |n| page._render.pagination[n - 2].errors = errs,
                }
            }
            return;
        },
        error.OutOfMemory => fatal.oom(),
        error.OutIO, error.ErrIO => fatal.msg("i/o error in superhtml", .{}),
        error.Quota => super_vm.setQuota(100),
        error.WantSnippet => @panic("TODO: looad snippet"),
        error.WantTemplate => {
            const template_subpath = super_vm.wantedTemplateName();
            const template_path = try root.join(
                arena.a,
                &.{
                    "templates",
                    template_subpath,
                },
                '/',
            );

            const template_pn = PathName.get(&build.st, &build.pt, template_path).?;
            const t = build.templates.get(template_pn).?;
            assert(!t.layout);

            super_vm.insertTemplate(
                // full template path
                try root.join(
                    arena.a,
                    &.{
                        build.cfg.getLayoutsDirPath(),
                        template_path,
                    },
                    '/',
                ),
                t.src,
                t.html_ast,
                t.ast,
                std.mem.endsWith(u8, template_subpath, ".xml"),
            );
        },
    };

    // Run the island SSR pass over the rendered HTML.
    // `result.html` is gpa-owned (same allocator as out_aw, so valid as long as
    // gpa lives — i.e. forever in .memory mode). On error we fall back to the raw
    // bytes (a slice into out_aw's buffer) and log the failure.
    // Skip the pass entirely when no sidecar is configured (build.island_sidecar == null);
    // that means islands aren't in use for this build, so raw HTML is correct.
    var rendered_html_is_gpa_owned = false;
    var rendered_html: []const u8 = blk: {
        const raw = out_aw.written();
        // Fast path: a page with no `<island` AND no `<z-island` tag has nothing
        // to rewrite and no runtime script to inject (`process` only injects when
        // instances are present). Skip the whole-page alloc+memcpy `rewrite`
        // would otherwise do (AUD-027). A false positive (e.g. the literal text
        // "<island" in content, or `<islandish>`) just falls through to the full
        // pass, which is a no-op rewrite — correct.
        //
        // `<z-island>` is the content-authoring alias recognized inside a `.smd`
        // page's `=html` fence (see docs/islands.md "Islands in content") — the
        // SAME islands.process pass handles it, so it must trip this fast-path
        // scan too. Checking only "<island" here used to let a page whose only
        // island was spelled `<z-island>` skip this whole block — including the
        // "no island sidecar is configured" build error five lines down — and
        // ship the literal `<z-island>` element inert with exit code 0: the same
        // AUD-027-adjacent failure class the comment below already guards
        // against for the `<island>` spelling, just reached via the other name.
        //
        // This scan runs BEFORE the sidecar-null check on purpose. The reverse
        // order silently shipped the literal `<island …></island>` element with no
        // SSR, no runtime script and exit code 0 whenever the sidecar was
        // unconfigured — and "unconfigured" includes the ordinary authoring
        // mistake of adding an `<island>` to a layout without passing an
        // `--island=` for it (root.zig's spawn guard needs all three of
        // bun_path/island_sidecar/island_src_dir, and quietly does nothing if any
        // is null). A page that asks for an island and gets an inert tag is a
        // build error, not a pass-through. Cost of the reordering: one memchr per
        // page on sites that use no islands at all, which is noise next to
        // rendering the page.
        if (std.mem.indexOf(u8, raw, "<island") == null and std.mem.indexOf(u8, raw, "<z-island") == null) break :blk raw;
        // build is *Build (non-const), so |*s| yields a *Sidecar into the real field
        // (not a copy). If renderPage's `build` ever becomes *const, this capture fails.
        const sc: *@import("islands/sidecar.zig").Sidecar = if (build.island_sidecar) |*s| s else {
            // Mirrors the render-error policy below: a disk build is a
            // release/deploy, so fail rather than publish a page whose island
            // never hydrates; a memory build keeps going so the author can see
            // the page, with the cause logged at .err (the CLI's level).
            //
            // `island_sidecar_optional` (validate/explain, see
            // root.Options.island_sidecar_optional): those commands
            // deliberately configure NO sidecar -- their whole point is
            // checking/reporting on a site without the Bun toolchain -- so "no
            // sidecar" is their normal state, not an authoring mistake.
            // Suppress the log line for them; everything else (release, dev)
            // keeps the diagnostic verbatim.
            if (!build.island_sidecar_optional) {
                log.err(
                    "island rendering error on {s}: the page uses <island> but no island sidecar is configured" ++
                        " — declare the island with `--island=<src>` (needs bun, the sidecar script," ++
                        " and the island source dir)",
                    .{page_path},
                );
                if (build.mode == .disk) build.any_rendering_error.store(true, .release);
            }
            break :blk raw;
        };
        // The page's URL path (leading slash; trailing slash; "" → "/"), passed to
        // the island SSR pass so `z.host.pathname()` matches the client's
        // window.location. Mirrors the canonical-URL formatting used for output dirs.
        const island_pathname_base = switch (build.cfg.*) {
            .Site => try std.fmt.allocPrint(arena.a, "/{f}", .{
                page._scan.url.fmt(&variant.string_table, &variant.path_table, null, true),
            }),
            .Multilingual => try std.fmt.allocPrint(arena.a, "/{f}", .{
                page._scan.url.fmt(&variant.string_table, &variant.path_table, variant.output_path_prefix, true),
            }),
        };
        // A .pagination job's browser URL is NOT `island_pathname_base` — that's
        // the section index's own URL (page 1). The browser loads page N at
        // base + the per-url_style tail (e.g. "page/2/"), so an island calling
        // `z.host.pathname()` on page 2+ must see that, or it mismatches
        // window.location at hydration. `.alternative` is untouched: it renders
        // a distinct artifact (e.g. an RSS feed) at its own declared output, not
        // a paginated view of this page's URL.
        const island_pathname = switch (kind) {
            .main, .alternative => island_pathname_base,
            .pagination => |n| try std.fmt.allocPrint(arena.a, "{s}{s}", .{
                island_pathname_base,
                try paginationPathnameTail(arena.a, page.pagination.?.url_style, n),
            }),
        };
        // Prefix emitted island asset URLs (runtime + island module scripts) with
        // the site's `url_path_prefix` (e.g. "zigapagos" for a GitHub Pages
        // project site served under `/zigapagos/`). Only single-site configs
        // carry this field today; multilingual sites don't (yet) support it —
        // which is exactly what `Config.getUrlPathPrefix` encodes, so go
        // through it rather than re-deriving the same switch here.
        const url_prefix = build.cfg.getUrlPathPrefix();
        // Render-error policy: a disk build is a release/deploy —
        // fail so broken output never ships (`process` returns the error, caught
        // below → any_rendering_error). A memory build reports rather than
        // ships — keep going with a visible per-island placeholder, so one
        // broken island doesn't blank the whole page. Either way `islands.process` records each failing
        // island's structured detail (src, route, JS message, source-mapped
        // stack) into `render_errors`, which we log here with page context —
        // instead of the message + stack being swallowed at the Zig↔Bun boundary.
        const on_render_error: islands.OnRenderError =
            switch (build.mode) {
                .disk => .fail,
                .memory => .placeholder,
            };
        var render_errors: std.ArrayListUnmanaged(islands.RenderErrorReport) = .empty;
        // Reports are logged synchronously below; the list backing (gpa) is freed
        // here — the string fields it points at are arena-owned (per-page arena).
        defer render_errors.deinit(gpa);
        var content_prop_eval_errors: std.ArrayListUnmanaged(islands.ContentPropEvalErrorReport) = .empty;
        defer content_prop_eval_errors.deinit(gpa);
        var content_prop_eval_ctx: ContentPropEvalContext = .{ .root = &ctx };
        const result = islands.process(gpa, arena, raw, island_pathname, sc, .{
            .url_prefix = url_prefix,
            .on_render_error = on_render_error,
            .render_errors = &render_errors,
            .content_prop_evaluator = .{
                .context = &content_prop_eval_ctx,
                .eval_fn = evalContentIslandProp,
            },
            .content_prop_eval_errors = &content_prop_eval_errors,
            // Null/empty on every build that produced no slice, which makes this
            // page's <head> byte-identical to the pre-slicing output.
            .sliced_runtime_url = build.islands_slice.url,
            .sliced_islands = build.islands_slice.islands,
        }) catch |err| {
            // Release/deploy: surface the real cause, attributed to the page, and
            // fail the build. `render_errors` holds the failing island's detail
            // (the render that aborted the pass); fall back to the bare name only
            // if the failure was something other than a render (e.g. malformed
            // markup) that left no report.
            if (content_prop_eval_errors.items.len > 0) {
                for (content_prop_eval_errors.items) |report| {
                    log.err(
                        "content-island prop evaluation failed on {s}: {s} in '{s}': {s}",
                        .{ page_path, report.src, report.expression, report.message },
                    );
                }
            } else if (render_errors.items.len == 0) {
                log.err("island rendering error on {s}: {s}", .{ page_path, @errorName(err) });
            } else for (render_errors.items) |re| {
                log.err(
                    "island SSR failed on {s}: {s} (route {s}): {s}\n{s}",
                    .{ page_path, re.src, re.route, re.message, re.stack orelse "(no stack)" },
                );
            }
            build.any_rendering_error.store(true, .release);
            break :blk raw;
        };
        // Dev serve (placeholder policy): the page rendered with visible
        // placeholders in place of the broken islands — warn (loudly, since the
        // CLI runs at .err level) so the author sees the message + stack too,
        // without failing the build.
        for (render_errors.items) |re| {
            log.err(
                "island SSR failed on {s}: {s} (route {s}) — rendered a dev placeholder: {s}\n{s}",
                .{ page_path, re.src, re.route, re.message, re.stack orelse "(no stack)" },
            );
        }
        if (build.island_props_check_mode != .off) {
            build.island_props_checks_mutex.lockUncancelable(io);
            defer build.island_props_checks_mutex.unlock(io);
            for (result.instances) |inst| {
                const duped_src = gpa.dupe(u8, inst.src) catch {
                    log.err("props-check collect OOM on {s}", .{page_path});
                    build.any_rendering_error.store(true, .release);
                    continue;
                };
                const duped_props = gpa.dupe(u8, inst.props_json) catch {
                    gpa.free(duped_src);
                    log.err("props-check collect OOM on {s}", .{page_path});
                    build.any_rendering_error.store(true, .release);
                    continue;
                };
                const duped_url = gpa.dupe(u8, island_pathname) catch {
                    gpa.free(duped_src);
                    gpa.free(duped_props);
                    log.err("props-check collect OOM on {s}", .{page_path});
                    build.any_rendering_error.store(true, .release);
                    continue;
                };
                const duped_id = gpa.dupe(u8, inst.id) catch {
                    gpa.free(duped_src);
                    gpa.free(duped_props);
                    gpa.free(duped_url);
                    log.err("props-check collect OOM on {s}", .{page_path});
                    build.any_rendering_error.store(true, .release);
                    continue;
                };
                build.island_props_checks.append(gpa, .{
                    .src = duped_src,
                    .props_json = duped_props,
                    .page_url = duped_url,
                    .island_id = duped_id,
                }) catch {
                    gpa.free(duped_src);
                    gpa.free(duped_props);
                    gpa.free(duped_url);
                    gpa.free(duped_id);
                    log.err("props-check collect OOM on {s}", .{page_path});
                    build.any_rendering_error.store(true, .release);
                };
            }
        }
        // Dev island-usage manifest: record which islands this
        // page mounts so `zigapagos dev` can map an island-source edit to
        // exactly the pages that need re-SSR. Gated on the dev loop having
        // asked for a manifest (release builds collect nothing). Duplicate
        // pairs from `.alternative` render jobs are deduped at assemble time.
        if (build.island_manifest_path != null and result.instances.len > 0) {
            // '/'-separated, content-dir-prefixed source path — the exact
            // string the incremental changed-files set matches on (see
            // root.zig's render loop).
            var src_buf: [std.fs.max_path_bytes]u8 = undefined;
            const page_src_path = std.fmt.bufPrint(&src_buf, "{f}", .{
                page._scan.file.fmt(
                    &variant.string_table,
                    &variant.path_table,
                    variant.content_dir_path,
                    "/",
                ),
            }) catch unreachable;
            build.island_page_usage_mutex.lockUncancelable(io);
            defer build.island_page_usage_mutex.unlock(io);
            for (result.instances) |inst| {
                const duped_src = try gpa.dupe(u8, inst.src);
                errdefer gpa.free(duped_src);
                const duped_page = try gpa.dupe(u8, page_src_path);
                errdefer gpa.free(duped_page);
                try build.island_page_usage.append(gpa, .{
                    .island_src = duped_src,
                    .page_path = duped_page,
                });
            }
        }
        rendered_html_is_gpa_owned = true;
        break :blk result.html;
    };

    // Issue #128: opt-in build-time `<script type="speculationrules">` head
    // injection (see `root.Site.speculation_rules`). Runs for BOTH `.main`
    // and `.alternative` outputs -- same precedent as the islands pass above
    // -- and is a no-op on head-less alternatives (RSS/XML feeds) via the
    // `null` return from `injectBeforeHeadEnd`. Applies in both `.memory`
    // (dev) and `.disk` (release) modes -- dev/release parity, matching how
    // `auto_heading_ids` behaves. The islands fast path (`break :blk raw`
    // above) already ran by the time we get here, so island-free pages are
    // covered too: this is a site-wide emission, not an islands-only one.
    if (build.cfg.getSpeculationRules()) {
        // Re-fetch the prefix: the `url_prefix` local the islands pass uses is
        // scoped to the `blk` above and out of reach here.
        const spec_tag = try islands.speculationRulesTag(gpa, build.cfg.getUrlPathPrefix());
        defer gpa.free(spec_tag);
        if (try islands.injectBeforeHeadEnd(gpa, rendered_html, spec_tag)) |spliced| {
            // `rendered_html` was either a gpa allocation from the islands
            // pass (freed here before replacing it) or a borrowed slice into
            // `out_aw`'s buffer (owned/freed by that arraylist, not by us --
            // leave it alone and just repoint the local).
            if (rendered_html_is_gpa_owned) gpa.free(rendered_html);
            rendered_html = spliced;
            rendered_html_is_gpa_owned = true;
        }
    }

    switch (build.mode) {
        .memory => switch (kind) {
            // Store a standalone gpa-owned copy of the output (AUD-004). When the
            // island pass produced a fresh gpa allocation we take it directly;
            // otherwise `rendered_html` is a slice into `out_aw` (freed by the
            // defer above), so it must be duped. Either way `page._render.out`
            // ends up gpa-owned and is freed exactly once in `Page.deinit`.
            .main => {
                page._render.out = if (rendered_html_is_gpa_owned)
                    rendered_html
                else
                    gpa.dupe(u8, rendered_html) catch fatal.oom();
                page._render.errors = "";
            },
            .alternative => |aidx| {
                page._render.alternatives[aidx].out = if (rendered_html_is_gpa_owned)
                    rendered_html
                else
                    gpa.dupe(u8, rendered_html) catch fatal.oom();
                page._render.alternatives[aidx].errors = "";
            },
            .pagination => |n| {
                page._render.pagination[n - 2].out = if (rendered_html_is_gpa_owned)
                    rendered_html
                else
                    gpa.dupe(u8, rendered_html) catch fatal.oom();
                page._render.pagination[n - 2].errors = "";
            },
        },
        .disk => |disk| {
            // Free the gpa-owned island-pass output once we're done writing.
            // (When the pass fell back to raw, rendered_html points into out_aw's
            // buffer which deinit() above will free — no extra free needed.)
            defer if (rendered_html_is_gpa_owned) gpa.free(rendered_html);
            const out_raw = switch (kind) {
                .main => blk: {
                    // aliases
                    for (page.aliases) |a| {
                        const out_path = try suffixedOutputPath(arena.a, build.cfg, variant, page, a);

                        if (std.fs.path.dirnamePosix(out_path)) |path| {
                            disk.output_dir.createDirPath(
                                io,
                                path,
                            ) catch |err| fatal.dir(path, err);
                        }

                        const f = disk.output_dir.createFile(
                            io,
                            out_path,
                            .{},
                        ) catch |err| fatal.file(out_path, err);
                        defer f.close(io);
                        var file_writer = f.writerStreaming(io, &.{});
                        file_writer.interface.writeAll(rendered_html) catch |err| fatal.file(
                            out_path,
                            err,
                        );
                    }

                    // main
                    {
                        const out_dir_path = try pageDir(arena.a, build.cfg, variant, page);

                        // note: do not close build.install_dir
                        var out_dir = if (out_dir_path.len == 0) disk.output_dir else disk.output_dir.createDirPathOpen(
                            io,
                            out_dir_path,
                            .{},
                        ) catch |err| fatal.dir(out_dir_path, err);
                        defer if (out_dir_path.len > 0) out_dir.close(io);

                        break :blk out_dir.createFile(
                            io,
                            "index.html",
                            .{},
                        ) catch |err| fatal.file("index.html", err);
                    }
                },

                .alternative => |idx| blk: {
                    const raw_path = page.alternatives[idx].output;
                    const out_path = try suffixedOutputPath(arena.a, build.cfg, variant, page, raw_path);

                    if (std.fs.path.dirnamePosix(out_path)) |path| {
                        disk.output_dir.createDirPath(
                            io,
                            path,
                        ) catch |err| fatal.dir(path, err);
                    }

                    break :blk disk.output_dir.createFile(
                        io,
                        out_path,
                        .{},
                    ) catch |err| fatal.file(out_path, err);
                },

                .pagination => |n| blk: {
                    const style = page.pagination.?.url_style;
                    const out_path = try paginationOutputPath(arena.a, build.cfg, variant, page, style, n);
                    if (std.fs.path.dirnamePosix(out_path)) |path| {
                        disk.output_dir.createDirPath(io, path) catch |err| fatal.dir(path, err);
                    }
                    break :blk disk.output_dir.createFile(io, out_path, .{}) catch |err| fatal.file(out_path, err);
                },
            };
            defer out_raw.close(io);

            var file_writer = out_raw.writer(io, &.{});
            file_writer.interface.writeAll(rendered_html) catch |err| fatal.file(
                page_path,
                err,
            );
        },
    }
}

// Null language evaluates to true for convenience.
pub fn languageExists(language: ?[]const u8) bool {
    const lang = language orelse return true;

    if (std.mem.eql(u8, lang, "=html")) return true;
    if (std.mem.eql(u8, lang, "=mathtex")) return true;

    if (syntax.FileType.get_by_name_static(lang) == null) {
        var buf: [1024]u8 = undefined;
        const filename = std.fmt.bufPrint(
            &buf,
            "file.{s}",
            .{lang},
        ) catch "<lang name too long>";

        const guess = syntax.FileType.guess_static(filename, "") orelse return false;
        log.debug("guessed '{?s}' as '{s}'", .{ language, guess.name });
    }

    return true;
}

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

test "pagination: pathname tail formats per url_style" {
    const t = std.testing;
    const cases = .{
        .{ Page.Pagination.UrlStyle.page_dir, 2, "page/2/" },
        .{ Page.Pagination.UrlStyle.plain_dir, 2, "2/" },
        .{ Page.Pagination.UrlStyle.page_html, 2, "page-2.html" },
        .{ Page.Pagination.UrlStyle.page_dir, 10, "page/10/" },
    };
    inline for (cases) |c| {
        const got = try paginationPathnameTail(t.allocator, c[0], c[1]);
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
