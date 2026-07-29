const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const builtin = @import("builtin");
const supermd = @import("supermd");
const superhtml = @import("superhtml");
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

pub const RenderJobKind = union(enum) { main, alternative: u32 };
const SuperVM = superhtml.VM(context.Value);
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
    };

    ctx.build.generated = .initNow(io);

    const layout_path = switch (kind) {
        .main => page.layout,
        .alternative => |idx| page.alternatives[idx].layout,
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
    const rendered_html: []const u8 = blk: {
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
        // mistake of adding an `<island>` to a layout without declaring it in
        // build.zig's `.islands` (root.zig's spawn guard needs all three of
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
            // never hydrates; dev serve keeps going so the author can see the
            // page, with the cause logged at .err (the CLI's level).
            log.err(
                "island rendering error on {s}: the page uses <island> but no island sidecar is configured" ++
                    " — declare the island in build.zig's `.islands` (needs bun, the sidecar script," ++
                    " and the island source dir)",
                .{page_path},
            );
            if (build.mode == .disk) build.any_rendering_error.store(true, .release);
            break :blk raw;
        };
        // The page's URL path (leading slash; trailing slash; "" → "/"), passed to
        // the island SSR pass so `z.host.pathname()` matches the client's
        // window.location. Mirrors the canonical-URL formatting used for output dirs.
        const island_pathname = switch (build.cfg.*) {
            .Site => try std.fmt.allocPrint(arena.a, "/{f}", .{
                page._scan.url.fmt(&variant.string_table, &variant.path_table, null, true),
            }),
            .Multilingual => try std.fmt.allocPrint(arena.a, "/{f}", .{
                page._scan.url.fmt(&variant.string_table, &variant.path_table, variant.output_path_prefix, true),
            }),
        };
        // Prefix emitted island asset URLs (runtime + island module scripts) with
        // the site's `url_path_prefix` (e.g. "zigapagos" for a GitHub Pages
        // project site served under `/zigapagos/`). Only single-site configs
        // carry this field today; multilingual sites don't (yet) support it.
        const url_prefix: []const u8 = switch (build.cfg.*) {
            .Site => |s| s.url_path_prefix,
            .Multilingual => "",
        };
        // Render-error policy: a disk build is a release/deploy —
        // fail so broken output never ships (`process` returns the error, caught
        // below → any_rendering_error). A memory build is dev serve — keep going
        // with a visible per-island placeholder, so one broken island doesn't
        // blank the whole page. Either way `islands.process` records each failing
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
        const result = islands.process(gpa, arena, raw, island_pathname, sc, .{
            .url_prefix = url_prefix,
            .on_render_error = on_render_error,
            .render_errors = &render_errors,
        }) catch |err| {
            // Release/deploy: surface the real cause, attributed to the page, and
            // fail the build. `render_errors` holds the failing island's detail
            // (the render that aborted the pass); fall back to the bare name only
            // if the failure was something other than a render (e.g. malformed
            // markup) that left no report.
            if (render_errors.items.len == 0) {
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
                        const out_path = if (a[0] == '/') a[1..] else switch (build.cfg.*) {
                            .Site => try std.fmt.allocPrint(arena.a, "{f}{s}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    null,
                                    true,
                                ),
                                a,
                            }),
                            .Multilingual => try std.fmt.allocPrint(arena.a, "{f}{s}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    variant.output_path_prefix,
                                    true,
                                ),
                                a,
                            }),
                        };

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
                        const out_dir_path = switch (build.cfg.*) {
                            .Site => try std.fmt.allocPrint(arena.a, "{f}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    null,
                                    true,
                                ),
                            }),
                            .Multilingual => try std.fmt.allocPrint(arena.a, "{f}", .{
                                page._scan.url.fmt(
                                    &variant.string_table,
                                    &variant.path_table,
                                    variant.output_path_prefix,
                                    true,
                                ),
                            }),
                        };

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
                    const out_path = if (raw_path[0] == '/') raw_path[1..] else switch (build.cfg.*) {
                        .Site => try std.fmt.allocPrint(arena.a, "{f}{s}", .{
                            page._scan.url.fmt(
                                &variant.string_table,
                                &variant.path_table,
                                null,
                                true,
                            ),
                            raw_path,
                        }),
                        .Multilingual => try std.fmt.allocPrint(arena.a, "{f}{s}", .{
                            page._scan.url.fmt(
                                &variant.string_table,
                                &variant.path_table,
                                variant.output_path_prefix,
                                true,
                            ),
                            raw_path,
                        }),
                    };

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
