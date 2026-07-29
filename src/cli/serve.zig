const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const WebSocket = std.http.Server.WebSocket;
const builtin = @import("builtin");
const mime = @import("mime");
const tracy = @import("tracy");
const root = @import("../root.zig");
const spa_mod = @import("../spa.zig");
const RenderArena = @import("../islands/render_arena.zig").RenderArena;
const BuildAsset = root.BuildAsset;
const worker = @import("../worker.zig");
const fatal = @import("../fatal.zig");
const Build = @import("../Build.zig");
const PathTable = @import("../PathTable.zig");
const PathName = PathTable.PathName;
const StringTable = @import("../StringTable.zig");
const Path = PathTable.Path;
const String = StringTable.String;
const Channel = @import("../channel.zig").Channel;
const PageAnalysisError = @import("../context/Page.zig").PageAnalysisError;

const zigapagos_reload_js = @embedFile("serve/zigapagos-reload.js");
const not_found_html = @embedFile("serve/404.html");
const error_html = @embedFile("serve/error.html");
const outside_html = @embedFile("serve/outside.html");
/// Per-OS file watcher, shared with the `zigapagos dev` loop (dev.zig).
///
/// FreeBSD is routed to the inotify-based `LinuxWatcher`. inotify entered the
/// FreeBSD base system in FreeBSD 15, so live reload requires **FreeBSD 15 or
/// newer**; there is no native kqueue backend. On FreeBSD < 15 the inotify
/// symbols resolve to nothing and the watcher never delivers events.
pub const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("serve/watcher/LinuxWatcher.zig"),
    // Requires FreeBSD 15+ (inotify in base); no kqueue backend.
    .freebsd => @import("serve/watcher/LinuxWatcher.zig"),
    .macos => @import("serve/watcher/MacosWatcher.zig"),
    .windows => @import("serve/watcher/WindowsWatcher.zig"),
    else => @compileError("unsupported platform"),
};

const log = std.log.scoped(.serve);

pub const ServeEvent = union(enum) {
    change,
    connect: WebSocket,
    disconnect: WebSocket,
};

pub fn serve(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    if (builtin.single_threaded) {
        std.debug.print(
            "error: single-threaded zigapagos does not yet support running the live server, sorry\n\n",
            .{},
        );

        fatal.helpError();
    }

    const cmd: Command = try .parse(gpa, args);

    worker.start(io);
    defer if (builtin.mode == .Debug) worker.stopWaitAndDeinit(io);

    var buf: [64]ServeEvent = undefined;
    var channel: Channel(ServeEvent) = .init(&buf);

    var debouncer: Debouncer = .{
        .io = io,
        .cascade_window_ms = cmd.debounce,
        .channel = &channel,
    };

    debouncer.start() catch |err| fatal.msg(
        "error: unable to start debouncer: {s}",
        .{@errorName(err)},
    );
    var cfg, const base_dir_path = root.Config.load(io, gpa);
    switch (cfg) {
        .Site => |*s| s.host_url = try std.fmt.allocPrint(
            gpa,
            "http://{s}:{}/",
            .{ cmd.host, cmd.port },
        ),

        .Multilingual => |*ml| {
            ml.host_url = try std.fmt.allocPrint(
                gpa,
                "http://{s}:{}/",
                .{ cmd.host, cmd.port },
            );

            for (ml.locales) |l| if (l.host_url_override != null) {
                fatal.msg("error: host_url_override is not yet supported by the zigapagos live server, sorry!", .{});
            };
        },
    }

    var dirs_to_watch: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer if (builtin.mode == .Debug) dirs_to_watch.deinit(gpa);

    try dirs_to_watch.appendSlice(
        gpa,
        &.{
            try std.fs.path.joinZ(gpa, &.{
                base_dir_path,
                cfg.getAssetsDirPath(),
            }),
            try std.fs.path.joinZ(gpa, &.{
                base_dir_path,
                cfg.getLayoutsDirPath(),
            }),
        },
    );
    // The data dir is a first-class site input — parsed at build time and exposed
    // to every layout via `$site.data(…)` — so an edit to it must rebuild like a
    // layout edit. Without this, editing data/*.ziggy under `zigapagos serve`
    // produced no rebuild and no reload, and every layout kept rendering the
    // previous values until an unrelated content edit forced one: the dev preview
    // silently disagreed with a release build.
    //
    // Gated on existence, unlike assets/ and layouts/ which `Build.load`
    // auto-creates. `data_dir_path` defaults to "data" whether or not the site has
    // one, and `Build.loadSiteData` treats a missing dir as "no data" rather than
    // an error — so watching it unconditionally would fail the watcher (and
    // `dev.zig`'s accessibility pre-check) for every site that simply has no data.
    {
        const data_abs = try std.fs.path.joinZ(gpa, &.{ base_dir_path, cfg.getDataDirPath() });
        if (Io.Dir.cwd().access(io, data_abs, .{})) |_| {
            try dirs_to_watch.append(gpa, data_abs);
        } else |_| gpa.free(data_abs);
    }
    switch (cfg) {
        .Site => |s| try dirs_to_watch.append(
            gpa,
            try std.fs.path.joinZ(gpa, &.{
                base_dir_path,
                s.content_dir_path,
            }),
        ),
        .Multilingual => |ml| {
            try dirs_to_watch.append(gpa, try std.fs.path.joinZ(gpa, &.{
                base_dir_path,
                ml.i18n_dir_path,
            }));
            for (ml.locales) |l| try dirs_to_watch.append(
                gpa,
                try std.fs.path.joinZ(gpa, &.{
                    base_dir_path,
                    l.content_dir_path,
                }),
            );
        },
    }

    // Watch island source dirs so edits trigger a rebundle + reload (Task 3).
    if (cmd.islands.len > 0) {
        const isl_src_dir = cmd.island_src_dir orelse ".";
        for (cmd.islands) |isl| {
            // Compute the subdir of this island relative to island_src_dir.
            // e.g. "components/Hero.island.tsx" → "components"; "Hero.island.tsx" → "."
            const rel_dir = std.fs.path.dirname(isl) orelse ".";
            // Full watch path: base_dir_path / island_src_dir / rel_dir
            const candidate = try std.fs.path.joinZ(
                gpa,
                &.{ base_dir_path, isl_src_dir, rel_dir },
            );
            // Dedup: skip if an identical path is already in the list.
            const already = for (dirs_to_watch.items) |d| {
                if (std.mem.eql(u8, d, candidate)) break true;
            } else false;
            if (already) {
                gpa.free(candidate);
            } else {
                try dirs_to_watch.append(gpa, candidate);
            }
        }
    }

    // Watch SPA source dirs too, so editing a `.spa.tsx` (or a sibling view it
    // imports) triggers a rebundle + shell re-render + reload. Same dedupe
    // pattern as islands above.
    if (cmd.spas.len > 0) {
        const spa_src_dir = cmd.island_src_dir orelse ".";
        for (cmd.spas) |sp| {
            const rel_dir = std.fs.path.dirname(sp.src) orelse ".";
            const candidate = try std.fs.path.joinZ(
                gpa,
                &.{ base_dir_path, spa_src_dir, rel_dir },
            );
            const already = for (dirs_to_watch.items) |d| {
                if (std.mem.eql(u8, d, candidate)) break true;
            } else false;
            if (already) {
                gpa.free(candidate);
            } else {
                try dirs_to_watch.append(gpa, candidate);
            }
        }
    }

    var watcher: Watcher = .init(
        io,
        gpa,
        &debouncer,
        dirs_to_watch.items,
    );

    watcher.start() catch |err| fatal.msg(
        "error: unable to start file watcher: {s}",
        .{@errorName(err)},
    );

    var build_lock: Io.RwLock = .init;
    var build = root.run(io, gpa, &cfg, .{
        .base_dir_path = base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .memory,
        .bun_path = cmd.bun_path,
        .island_sidecar = cmd.island_sidecar,
        .island_src_dir = cmd.island_src_dir,
        .island_props_check = cmd.island_props_check,
        .allow_missing_pages = cmd.allow_missing_pages,
    }) catch fatal.oom();

    // Bundle the runtime + each island at startup so the dev server can serve
    // them.  Happens after the first root.run so SSR is also ready before we
    // start listening.
    var island_cache_dir: ?Io.Dir = null;
    // Absolute path to the island cache dir — kept alive for on-change rebundling.
    var island_cache_abs: ?[]const u8 = null;
    defer if (builtin.mode == .Debug) if (island_cache_abs) |p| gpa.free(p);
    if (cmd.islands.len > 0) {
        const bun_path = cmd.bun_path orelse "bun";
        const src_dir = cmd.island_src_dir orelse ".";

        // Wipe-on-start so stale bundles from a previous session never sneak in.
        Io.Dir.cwd().deleteTree(io, ".zig-cache/zigapagos-serve-islands") catch {};
        const cache_dir = Io.Dir.cwd().createDirPathOpen(
            io,
            ".zig-cache/zigapagos-serve-islands",
            .{},
        ) catch |err| fatal.msg(
            "error: island cache dir '.zig-cache/zigapagos-serve-islands': {s}",
            .{@errorName(err)},
        );
        cache_dir.createDirPath(io, "islands") catch |err| fatal.msg(
            "error: island cache subdirectory 'islands/': {s}",
            .{@errorName(err)},
        );

        // Absolute path for --outfile so bun writes to the right place
        // regardless of its own cwd.
        const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| fatal.msg(
            "error: unable to get current working directory: {s}",
            .{@errorName(err)},
        );
        defer gpa.free(cwd_path);
        // Note: NOT deferred free — we store this in island_cache_abs so the
        // change handler can rebundle without recomputing the cwd.
        const cache_abs = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "zigapagos-serve-islands" });

        // Runtime: bun build <entry> --format=esm --outfile <cache>/zigapagos-runtime.js
        // (no --minify — dev bundle; matches build.zig minus --minify)
        const rt_outfile = try std.fs.path.join(gpa, &.{ cache_abs, "zigapagos-runtime.js" });
        defer gpa.free(rt_outfile);
        bunBuild(io, gpa, bun_path, src_dir, &.{
            "build",
            cmd.island_runtime_entry.?,
            "--format=esm",
            "--outfile",
            rt_outfile,
        }, null) catch |err| fatal.msg(
            "error: bun build (runtime) failed: {s}",
            .{@errorName(err)},
        );

        // Per-island builds with NODE_ENV=production to force production JSX
        // (jsx/jsxs, not jsxDEV) — matches build.zig setEnvironmentVariable.
        bundleIslands(io, gpa, bun_path, src_dir, cmd.islands, cache_abs) catch |err| fatal.msg(
            "error: bun build (islands) failed: {s}",
            .{@errorName(err)},
        );

        island_cache_abs = cache_abs;
        island_cache_dir = cache_dir;
    }

    // SPA serve cache: shells + entry/chunk bundles + (for an SPA-only site) the
    // shared runtime.  Mirrors the island cache above.  The route TABLES
    // (`serve_spas`) are built once here and treated as immutable — adding or
    // removing a route needs a dev-server restart (like the runtime bundle); an
    // on-change edit only re-renders the existing shells' contents.  A
    // process-lifetime arena backs the tables so the router can read them
    // lock-free.
    var spa_cache_dir: ?Io.Dir = null;
    var spa_cache_abs: ?[]const u8 = null;
    defer if (builtin.mode == .Debug) if (spa_cache_abs) |p| gpa.free(p);
    var serve_spas: []const spa_mod.ServeSpa = &.{};
    var spa_arena_state = std.heap.ArenaAllocator.init(gpa);
    // Typed as the contract-4 boundary it is (NO_SLOP.md §2.2a): the `ServeSpa`
    // graph `describeAndRenderServe` returns lives here for the whole session.
    const spa_arena = RenderArena.from(&spa_arena_state);
    if (cmd.spas.len > 0) {
        const bun_path = cmd.bun_path orelse "bun";
        const src_dir = cmd.island_src_dir orelse ".";
        const driver = cmd.spa_bundle_driver orelse fatal.msg(
            "error: --spa requires --spa-bundle-driver=<path> (normally supplied by build.zig's serve())",
            .{},
        );
        const runtime_entry = cmd.island_runtime_entry orelse fatal.msg(
            "error: --spa requires --island-runtime-entry=<path> to build the shared runtime",
            .{},
        );

        Io.Dir.cwd().deleteTree(io, ".zig-cache/zigapagos-serve-spa") catch {};
        const cache_dir = Io.Dir.cwd().createDirPathOpen(
            io,
            ".zig-cache/zigapagos-serve-spa",
            .{},
        ) catch |err| fatal.msg(
            "error: spa cache dir '.zig-cache/zigapagos-serve-spa': {s}",
            .{@errorName(err)},
        );
        cache_dir.createDirPath(io, "spa") catch |err| fatal.msg(
            "error: spa cache subdirectory 'spa/': {s}",
            .{@errorName(err)},
        );

        const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| fatal.msg(
            "error: unable to get current working directory: {s}",
            .{@errorName(err)},
        );
        defer gpa.free(cwd_path);
        const cache_abs = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "zigapagos-serve-spa" });

        // Build the shared runtime into the SPA cache ONLY if islands didn't
        // already build one (the router serves /zigapagos-runtime.js from
        // whichever cache has it). Same bun invocation as the island runtime.
        if (island_cache_abs == null) {
            const rt_outfile = try std.fs.path.join(gpa, &.{ cache_abs, "zigapagos-runtime.js" });
            defer gpa.free(rt_outfile);
            bunBuild(io, gpa, bun_path, src_dir, &.{
                "build",
                runtime_entry,
                "--format=esm",
                "--outfile",
                rt_outfile,
            }, null) catch |err| fatal.msg(
                "error: bun build (spa runtime) failed: {s}",
                .{@errorName(err)},
            );
        }

        // Bundle each SPA entry + its code-split chunks into <cache>/spa via the
        // shared driver (prod JSX, dev = no --minify).
        bundleSpas(io, gpa, bun_path, driver, src_dir, cmd.spas, cache_abs) catch |err| fatal.msg(
            "error: bun build (spa bundles) failed: {s}",
            .{@errorName(err)},
        );

        // Prerender each SPA's shells and capture its routing table. Same
        // `url_path_prefix` derivation `prerenderAll` uses (issue #26) — a
        // prefixed dev session must agree with release byte-for-byte.
        const spa_url_path_prefix = switch (cfg) {
            .Site => |s| s.url_path_prefix,
            .Multilingual => "",
        };
        if (build.island_sidecar) |*sc| {
            var list: std.ArrayList(spa_mod.ServeSpa) = .empty;
            for (cmd.spas) |sp| {
                const entry = spa_mod.describeAndRenderServe(io, spa_arena, sc, sp.src, cache_dir, spa_url_path_prefix) catch |err| fatal.msg(
                    "error: spa prerender for '{s}' failed: {s}",
                    .{ sp.src, @errorName(err) },
                );
                list.append(spa_arena.a, entry) catch fatal.oom();
            }
            serve_spas = list.toOwnedSlice(spa_arena.a) catch fatal.oom();
        } else fatal.msg(
            "error: --spa requires the render sidecar (missing --island-sidecar)",
            .{},
        );

        spa_cache_abs = cache_abs;
        spa_cache_dir = cache_dir;
    }

    var server: Server = .init(io, gpa, &channel, &build, &build_lock, island_cache_dir, cmd.proxies, spa_cache_dir, serve_spas);
    server.start(cmd) catch |err| fatal.msg(
        "error: unable to start live webserver: {s}",
        .{@errorName(err)},
    );

    std.debug.print(
        \\Starting the Zigapagos development server.
        \\
        \\DEPRECATED: this bundled live server is deprecated and will be removed
        \\in a future release. Use 'zigapagos dev' (build.zig: zigapagos.dev(),
        \\i.e. 'zig build dev'), which serves the real release output with the
        \\stock ZigBase binary — real same-origin /api, no --proxy shims.
        \\
        \\Run 'zigapagos help' to learn more about available options.
        \\
        \\
    , .{});

    const name = switch (cfg) {
        .Site => |s| try std.fmt.allocPrint(
            gpa,
            "Listening at http://{s}:{}{f}",
            .{ cmd.host, cmd.port, root.fmtJoin('/', &.{ "/", s.url_path_prefix, "/" }) },
        ),
        .Multilingual => try std.fmt.allocPrint(
            gpa,
            "Listening at http://{s}:{}/",
            .{ cmd.host, cmd.port },
        ),
    };

    const node = root.progress.start(name, 0);
    defer node.end();

    var websockets: std.AutoArrayHashMapUnmanaged(
        [*]const u8,
        WebSocket,
    ) = .empty;

    while (true) {
        const event = channel.get(io) catch unreachable;
        log.debug("new event: {s}", .{@tagName(event)});
        switch (event) {
            .change => {
                build_lock.lock(io) catch unreachable;
                build.deinit(io, gpa);
                build = root.run(io, gpa, &cfg, .{
                    .base_dir_path = base_dir_path,
                    .build_assets = &cmd.build_assets,
                    .drafts = cmd.drafts,
                    .mode = .memory,
                    .bun_path = cmd.bun_path,
                    .island_sidecar = cmd.island_sidecar,
                    .island_src_dir = cmd.island_src_dir,
                    .island_props_check = cmd.island_props_check,
                    .allow_missing_pages = cmd.allow_missing_pages,
                }) catch fatal.oom();
                build_lock.unlock(io);

                // Rebundle islands on change (Fork A — full rebundle, non-fatal).
                // Runs after the site rebuild so SSR and JS are in sync.
                if (cmd.islands.len > 0) {
                    if (island_cache_abs) |cache_abs| {
                        const bun_path = cmd.bun_path orelse "bun";
                        const src_dir = cmd.island_src_dir orelse ".";
                        bundleIslands(io, gpa, bun_path, src_dir, cmd.islands, cache_abs) catch |err| {
                            log.debug("on-change island rebundle failed: {s}", .{@errorName(err)});
                            // Surface the error to connected browsers via the
                            // existing build-error overlay ({"command":"build","err":...}).
                            for (websockets.entries.items(.value)) |*conn| {
                                var aw: Writer.Allocating = .init(gpa);
                                defer aw.deinit();
                                aw.writer.print("{f}", .{std.json.fmt(.{
                                    .command = "build",
                                    .err = @errorName(err),
                                }, .{})}) catch continue;
                                conn.writeMessage(aw.written(), .text) catch |we| {
                                    log.debug("error writing bundle-error to ws: {s}", .{@errorName(we)});
                                };
                            }
                        };
                    }
                }

                // Rebundle + re-render SPAs on change (non-fatal, mirrors the
                // island path). Bundles + shell files are rewritten in place;
                // the in-memory route tables stay valid (route structure is
                // fixed at startup). Errors surface to the build-error overlay.
                if (cmd.spas.len > 0) {
                    if (spa_cache_abs) |cache_abs| {
                        const bun_path = cmd.bun_path orelse "bun";
                        const src_dir = cmd.island_src_dir orelse ".";
                        var spa_err: ?anyerror = null;
                        if (cmd.spa_bundle_driver) |driver| {
                            bundleSpas(io, gpa, bun_path, driver, src_dir, cmd.spas, cache_abs) catch |err| {
                                log.debug("on-change spa rebundle failed: {s}", .{@errorName(err)});
                                spa_err = err;
                            };
                        }
                        if (spa_cache_dir) |sd| if (build.island_sidecar) |*sc| {
                            for (serve_spas) |*sp| {
                                var ta = std.heap.ArenaAllocator.init(gpa);
                                defer ta.deinit();
                                spa_mod.rerenderServe(io, RenderArena.from(&ta), sc, sp, sd) catch |err| {
                                    log.debug("on-change spa re-render failed: {s}", .{@errorName(err)});
                                    spa_err = err;
                                };
                            }
                        };
                        if (spa_err) |err| {
                            for (websockets.entries.items(.value)) |*conn| {
                                var aw: Writer.Allocating = .init(gpa);
                                defer aw.deinit();
                                aw.writer.print("{f}", .{std.json.fmt(.{
                                    .command = "build",
                                    .err = @errorName(err),
                                }, .{})}) catch continue;
                                conn.writeMessage(aw.written(), .text) catch |we| {
                                    log.debug("error writing spa-build-error to ws: {s}", .{@errorName(we)});
                                };
                            }
                        }
                    }
                }

                for (websockets.entries.items(.value)) |*conn| {
                    conn.writeMessage(
                        \\{ "command": "reload_all" }
                    , .text) catch |err| {
                        log.debug(
                            "error writing to ws: {s}",
                            .{@errorName(err)},
                        );
                    };
                }
            },
            .connect => |ws| {
                var conn = ws;
                try websockets.put(gpa, conn.key.ptr, conn);
                // We don't lock the build because this thread is the only writer

                for (build.mode.memory.errors.items) |build_err| {
                    var aw: Writer.Allocating = .init(gpa);
                    defer aw.deinit();

                    aw.writer.print("{f}", .{
                        std.json.fmt(.{
                            .command = "build",
                            .err = build_err.msg,
                        }, .{}),
                    }) catch return error.OutOfMemory;

                    conn.writeMessage(aw.written(), .text) catch |err| {
                        log.debug(
                            "error writing to ws: {s}",
                            .{@errorName(err)},
                        );
                    };
                }

                if (build.any_rendering_error.load(.acquire)) {
                    outer: for (build.variants) |*v| {
                        for (v.pages.items) |*p| {
                            if (!p._parse.active) continue;
                            if (p._parse.status != .parsed) continue;
                            if (p._analysis.frontmatter.items.len > 0) continue;
                            // Error-severity check: a warning-only page (e.g.
                            // unknown code-fence language) still rendered and may
                            // still have a genuine render error to report below.
                            if (PageAnalysisError.anyError(p._analysis.page.items)) continue;

                            if (p._render.errors.len > 0) {
                                var aw: Writer.Allocating = .init(gpa);
                                defer aw.deinit();

                                aw.writer.print("{f}", .{
                                    std.json.fmt(.{
                                        .command = "build",
                                        .err = p._render.errors,
                                    }, .{}),
                                }) catch return error.OutOfMemory;

                                conn.writeMessage(
                                    aw.written(),
                                    .text,
                                ) catch |err| {
                                    log.debug(
                                        "error writing to ws: {s}",
                                        .{@errorName(err)},
                                    );
                                };

                                break :outer;
                            }

                            for (p._render.alternatives) |alt| {
                                if (alt.errors.len > 0) {
                                    var aw: Writer.Allocating = .init(gpa);
                                    defer aw.deinit();

                                    aw.writer.print("{f}", .{
                                        std.json.fmt(.{
                                            .command = "build",
                                            .err = alt.errors,
                                        }, .{}),
                                    }) catch return error.OutOfMemory;
                                    conn.writeMessage(aw.written(), .text) catch |err| {
                                        log.debug(
                                            "error writing to ws: {s}",
                                            .{@errorName(err)},
                                        );
                                    };

                                    break :outer;
                                }
                            }
                        }
                    }
                }
            },
            .disconnect => |conn| {
                // the server thread will take care of closing the connection
                // as the corresponding thread shuts down
                _ = websockets.swapRemove(conn.key.ptr);
            },
        }
    }
}

/// A parsed `--proxy PREFIX=UPSTREAM` rule. `prefix` is a URL path prefix that
/// always starts with `/`; `host`/`port` are the resolved upstream authority
/// (`port` defaults to 80). See `Command.parseProxyRule` for the parse rules
/// and `Server.proxyPass` for how requests are forwarded.
pub const ProxyRule = struct {
    prefix: []const u8,
    host: []const u8,
    port: u16,
};

/// A parsed `--spa=<src>|<base>` value. Same encoding release uses; `base` is
/// "" when the value carried no '|' (a hand-written CLI invocation). The dev
/// server derives the authoritative base from the module's own `spa.base` via
/// the sidecar, so `base` here is informational only.
pub const SpaArg = struct {
    src: []const u8,
    base: []const u8,
};

pub const Command = struct {
    host: []const u8,
    port: u16,
    debounce: u16,
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,
    bun_path: ?[]const u8,
    island_sidecar: ?[]const u8,
    island_src_dir: ?[]const u8,
    island_props_check: @import("../islands/props_check.zig").Mode = .off,
    island_runtime_entry: ?[]const u8,
    islands: []const []const u8,
    proxies: []const ProxyRule,
    /// Native SPAs to serve (`--spa=<src>|<base>`, repeatable).
    spas: []const SpaArg,
    /// The code-splitting bundle driver (`runtime/sidecar/bundle-island.ts`)
    /// serve runs to build SPA entry + chunks (`--spa-bundle-driver=<path>`).
    spa_bundle_driver: ?[]const u8,
    /// `--allow-missing-pages`: see `root.Options.allow_missing_pages`.
    /// Same tolerance `release` applies -- see that field's doc comment for
    /// why it is not mode-dependent, and why `dev` takes it from the
    /// project's `build.zig` rather than its own argv.
    allow_missing_pages: bool = false,

    /// Frees the slices `parse` allocated. The live server never calls this
    /// (the Command lives for the whole process), but the unit tests do so the
    /// testing allocator stays leak-clean.
    pub fn deinit(cmd: *const Command, gpa: Allocator) void {
        gpa.free(cmd.islands);
        // Every rule owns its decoded `host` (see `parseProxyRule`); `prefix`
        // borrows from argv and must not be freed.
        for (cmd.proxies) |rule| gpa.free(rule.host);
        gpa.free(cmd.proxies);
        gpa.free(cmd.spas);
    }

    /// Parses one `--proxy` value (`PREFIX=UPSTREAM`, e.g.
    /// `/api=http://127.0.0.1:8090`). Splits on the FIRST '=' so upstream query
    /// strings survive. `fatal.msg` (which exits) on any malformed input:
    /// missing '=', empty prefix, prefix without a leading '/', an unparseable
    /// URL, or a non-`http` scheme (https upstreams are v1 out of scope).
    ///
    /// Ownership: the returned rule's `host` is allocated from `gpa` and freed
    /// by `Command.deinit`; `prefix` borrows from `value` (argv).
    fn parseProxyRule(gpa: Allocator, value: []const u8) error{OutOfMemory}!ProxyRule {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse fatal.msg(
            "error: --proxy expects PREFIX=UPSTREAM (e.g. /api=http://127.0.0.1:8090), got '{s}'",
            .{value},
        );
        const prefix = value[0..eq];
        const upstream = value[eq + 1 ..];

        if (prefix.len == 0) fatal.msg(
            "error: --proxy prefix is empty in '{s}'",
            .{value},
        );
        if (prefix[0] != '/') fatal.msg(
            "error: --proxy prefix must start with '/' (got '{s}')",
            .{prefix},
        );

        const uri = std.Uri.parse(upstream) catch |err| fatal.msg(
            "error: --proxy upstream '{s}' is not a valid URL: {s}",
            .{ upstream, @errorName(err) },
        );
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) fatal.msg(
            "error: --proxy upstream '{s}' must use the http:// scheme (https upstreams are not supported yet)",
            .{upstream},
        );
        const host_comp = uri.host orelse fatal.msg(
            "error: --proxy upstream '{s}' is missing a host",
            .{upstream},
        );
        // Percent-decode the host into an allocation OWNED by this rule.
        // `Component.toRawMaybeAlloc` allocates only when the component
        // contains a '%' and otherwise borrows from `value`, so its result has
        // two different lifetimes and no single free rule — which is how the
        // decoded copy leaked. Rendering `formatRaw` ourselves makes `host`
        // unconditionally owned, so `Command.deinit` can always free it.
        var host_buf: Writer.Allocating = .init(gpa);
        errdefer host_buf.deinit();
        host_comp.formatRaw(&host_buf.writer) catch return error.OutOfMemory;
        const host = try host_buf.toOwnedSlice();

        return .{ .prefix = prefix, .host = host, .port = uri.port orelse 80 };
    }

    fn parseAddress(arg: []const u8) struct { []const u8, ?u16 } {
        if (arg.len <= 0) {
            fatal.msg(
                "error: missing argument to '--host='",
                .{},
            );
        }

        const host = if (arg[0] == '[') ipv6: {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                if (arg[i] == ']') {
                    break :ipv6 arg[0 .. i + 1];
                }
            }
            fatal.msg(
                "error: unmatched '[' in '--host='",
                .{},
            );
        } else arg[0 .. std.mem.indexOfScalar(u8, arg, ':') orelse arg.len];

        var port: ?u16 = null;
        const maybe_port = arg[host.len..];
        if (maybe_port.len > 0 and maybe_port[0] == ':') {
            port = std.fmt.parseInt(u16, maybe_port[1..], 10) catch |err| fatal.msg(
                \\error: bad port in '{s}': {s}
                \\hint: if you meant to use IPv6, wrap it in square brackets, e.g. --host=[::1]
                \\
            ,
                .{ arg, @errorName(err) },
            );
        }

        return .{ host, port };
    }
    pub fn parse(
        gpa: Allocator,
        args: []const []const u8,
    ) error{OutOfMemory}!Command {
        var host: ?[]const u8 = null;
        var port: ?u16 = null;
        var debounce: ?u16 = null;
        var build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
        var drafts: ?bool = null;
        var bun_path: ?[]const u8 = null;
        var island_sidecar: ?[]const u8 = null;
        var island_src_dir: ?[]const u8 = null;
        var island_props_check: @import("../islands/props_check.zig").Mode = .off;
        var island_runtime_entry: ?[]const u8 = null;
        var islands: std.ArrayListUnmanaged([]const u8) = .empty;
        var proxies: std.ArrayListUnmanaged(ProxyRule) = .empty;
        var spas: std.ArrayListUnmanaged(SpaArg) = .empty;
        var spa_bundle_driver: ?[]const u8 = null;
        var allow_missing_pages = false;

        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.startsWith(u8, arg, "--host=")) {
                const suffix = arg["--host=".len..];
                host, const maybe_port = parseAddress(suffix);
                if (maybe_port) |p| port = p;
            } else if (std.mem.eql(u8, arg, "--host")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--host'",
                    .{},
                );
                host, const maybe_port = parseAddress(args[idx]);
                if (maybe_port) |p| port = p;
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const suffix = arg["--port=".len..];
                port = std.fmt.parseInt(u16, suffix, 10) catch |err| fatal.msg(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--port")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--port'",
                    .{},
                );
                port = std.fmt.parseInt(u16, args[idx], 10) catch |err| fatal.msg(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.startsWith(u8, arg, "--debounce=")) {
                const suffix = arg["--debounce=".len..];
                debounce = std.fmt.parseInt(u16, suffix, 10) catch |err| fatal.msg(
                    "error: bad debounce value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--debounce")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--debounce'",
                    .{},
                );
                debounce = std.fmt.parseInt(u16, args[idx], 10) catch |err| fatal.msg(
                    "error: bad debounce value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "-h") or
                std.mem.eql(u8, arg, "--help"))
            {
                fatal.help();
            } else if (std.mem.startsWith(u8, arg, "--build-asset=")) {
                const name = arg["--build-asset=".len..];

                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing build asset sub-argument for '{s}'",
                    .{name},
                );

                const input_path = args[idx];

                idx += 1;
                var install_path: ?[]const u8 = null;
                var install_always = false;
                if (idx < args.len) {
                    const next = args[idx];
                    if (std.mem.startsWith(u8, next, "--install=")) {
                        install_path = next["--install=".len..];
                    } else if (std.mem.startsWith(u8, next, "--install-always=")) {
                        install_always = true;
                        install_path = next["--install-always=".len..];
                    } else {
                        idx -= 1;
                    }
                }

                const gop = try build_assets.getOrPut(gpa, name);
                if (gop.found_existing) fatal.msg(
                    "error: duplicate build asset name '{s}'",
                    .{name},
                );

                gop.value_ptr.* = .{
                    .input_path = input_path,
                    .install_path = install_path,
                    .install_always = install_always,
                    .rc = .{ .raw = @intFromBool(install_always) },
                };
            } else if (std.mem.eql(u8, arg, "--drafts")) {
                drafts = true;
            } else if (std.mem.eql(u8, arg, "--allow-missing-pages")) {
                allow_missing_pages = true;
            } else if (std.mem.startsWith(u8, arg, "--bun=")) {
                bun_path = arg["--bun=".len..];
            } else if (std.mem.startsWith(u8, arg, "--island-sidecar=")) {
                island_sidecar = arg["--island-sidecar=".len..];
            } else if (std.mem.startsWith(u8, arg, "--island-src-dir=")) {
                island_src_dir = arg["--island-src-dir=".len..];
            } else if (std.mem.startsWith(u8, arg, "--island-props-check=")) {
                const v = arg["--island-props-check=".len..];
                island_props_check = @import("../islands/props_check.zig").parseMode(v) orelse {
                    fatal.msg("error: invalid --island-props-check value '{s}' (want off|warn|error)\n", .{v});
                };
            } else if (std.mem.startsWith(u8, arg, "--island-runtime-entry=")) {
                island_runtime_entry = arg["--island-runtime-entry=".len..];
            } else if (std.mem.startsWith(u8, arg, "--island=")) {
                try islands.append(gpa, arg["--island=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--spa-bundle-driver=")) {
                spa_bundle_driver = arg["--spa-bundle-driver=".len..];
            } else if (std.mem.startsWith(u8, arg, "--spa=")) {
                // `<src>|<base>` — split on the FIRST '|' (src never contains
                // one; build.zig's validateSpas asserts this). A value with no
                // '|' (hand-written CLI) yields an empty base.
                const v = arg["--spa=".len..];
                if (std.mem.indexOfScalar(u8, v, '|')) |bar| {
                    try spas.append(gpa, .{ .src = v[0..bar], .base = v[bar + 1 ..] });
                } else {
                    try spas.append(gpa, .{ .src = v, .base = "" });
                }
            } else if (std.mem.startsWith(u8, arg, "--proxy=")) {
                try proxies.append(gpa, try parseProxyRule(gpa, arg["--proxy=".len..]));
            } else if (std.mem.eql(u8, arg, "--proxy")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '--proxy'",
                    .{},
                );
                try proxies.append(gpa, try parseProxyRule(gpa, args[idx]));
            } else {
                std.debug.print("error: unexpected cli argument '{s}'\n\n", .{arg});
                fatal.helpError();
            }
        }

        return .{
            .host = host orelse "localhost",
            .port = port orelse 1990,
            .debounce = debounce orelse 25,
            .build_assets = build_assets,
            .drafts = drafts orelse false,
            .bun_path = bun_path,
            .island_sidecar = island_sidecar,
            .island_src_dir = island_src_dir,
            .island_props_check = island_props_check,
            .island_runtime_entry = island_runtime_entry,
            .islands = try islands.toOwnedSlice(gpa),
            .proxies = try proxies.toOwnedSlice(gpa),
            .spas = try spas.toOwnedSlice(gpa),
            .spa_bundle_driver = spa_bundle_driver,
            .allow_missing_pages = allow_missing_pages,
        };
    }
};
/// like fs.path.dirname but ensures a final `/`
// fn dirNameWithSlash(path: []const u8) []const u8 {
//     const d = std.fs.path.dirname(path).?;
//     if (d.len > 1) {
//         return path[0 .. d.len + 1];
//     } else {
//         return "/";
//     }
// }

pub const Server = struct {
    io: Io,
    gpa: Allocator,
    channel: *Channel(ServeEvent),
    build: *const Build,
    build_lock: *Io.RwLock,
    addresses_buffer: [16]Io.net.HostName.LookupResult = undefined,
    canon_name_buffer: [Io.net.HostName.max_len]u8 = undefined,
    /// Opened over `.zig-cache/zigapagos-serve-islands/`; non-null when islands are
    /// configured.  The router serves `/zigapagos-runtime.js` and
    /// `/islands/*.js` from this directory.
    island_cache_dir: ?Io.Dir,
    /// Reverse-proxy rules (from `--proxy`). Consulted in `handleRequest`
    /// BEFORE any static handling; empty means zero behaviour change.
    proxies: []const ProxyRule,
    /// Opened over `.zig-cache/zigapagos-serve-spa/`; non-null when SPAs are
    /// configured. Serves `/spa/*.js`, the shared runtime (when no island
    /// cache), and every SPA shell.
    spa_cache_dir: ?Io.Dir,
    /// Per-SPA routing tables (built once at startup; immutable — the router
    /// reads them lock-free). Empty when no SPAs are configured.
    spa_namespaces: []const spa_mod.ServeSpa,

    pub const max_connection_header_size: usize = 8 * 1024;

    pub fn init(
        io: Io,
        gpa: Allocator,
        channel: *Channel(ServeEvent),
        build: *const Build,
        build_lock: *Io.RwLock,
        island_cache_dir: ?Io.Dir,
        proxies: []const ProxyRule,
        spa_cache_dir: ?Io.Dir,
        spa_namespaces: []const spa_mod.ServeSpa,
    ) Server {
        return .{
            .io = io,
            .gpa = gpa,
            .channel = channel,
            .build = build,
            .build_lock = build_lock,
            .island_cache_dir = island_cache_dir,
            .proxies = proxies,
            .spa_cache_dir = spa_cache_dir,
            .spa_namespaces = spa_namespaces,
        };
    }

    pub fn start(s: *Server, cmd: Command) !void {
        const host = if (cmd.host[0] == '[')
            cmd.host[1..][0 .. cmd.host.len - 2] // Strip brackets from IPv6
        else
            cmd.host;

        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&s.addresses_buffer);
        try Io.net.HostName.lookup(try .init(host), s.io, &queue, .{
            .port = cmd.port,
            .canonical_name_buffer = &s.canon_name_buffer,
        });

        const result = s.addresses_buffer[0];
        const t = try std.Thread.spawn(.{}, Server.serve, .{ s, result.address });
        t.detach();
    }

    fn serve(s: *Server, address: Io.net.IpAddress) void {
        errdefer |err| switch (err) {
            error.OutOfMemory => fatal.oom(),
        };

        var tcp_server = address.listen(
            s.io,
            .{ .reuse_address = true },
        ) catch |err| fatal.msg(
            "error: unable to bind to '{any}': {s}",
            .{ address, @errorName(err) },
        );
        defer tcp_server.deinit();

        // const server_port = tcp_server.listen_address.in.getPort();

        while (true) {
            const stream = tcp_server.accept(s.io) catch |err| switch (err) {
                error.SystemResources,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.Unexpected,
                error.SocketNotListening,
                error.ProtocolFailure,
                error.BlockedByFirewall,
                error.WouldBlock,
                error.Canceled,
                => fatal.msg(
                    "error: critical failure while opening new live server tcp connection: {s}",
                    .{@errorName(err)},
                ),
                error.ConnectionAborted,
                error.NetworkDown,
                => {
                    log.debug("non-fatal tcp error: {s}", .{@errorName(err)});
                    continue;
                },
            };

            // Shed load instead of dying: exhausting the process thread/FD
            // limit is remotely triggerable (open enough connections), so a
            // spawn failure must drop THAT connection, not the whole dev
            // server. Same pattern as reload.zig's accept loop.
            const t = std.Thread.spawn(.{}, Server.handleConnection, .{
                s,
                stream,
            }) catch |err| {
                log.warn(
                    "unable to spawn connection thread ({s}); dropping connection",
                    .{@errorName(err)},
                );
                stream.close(s.io);
                continue;
            };
            t.detach();
        }
    }

    fn handleConnection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);

        var bufin: [4096 * 4]u8 = undefined;
        var in = stream.reader(s.io, &bufin);
        var bufout: [4096]u8 = undefined;
        var out = stream.writer(s.io, &bufout);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var http_server = std.http.Server.init(&in.interface, &out.interface);

        while (true) {
            var request = http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    log.debug("connection error: {s}\n", .{@errorName(err)});
                }
                return;
            };

            log.debug("request: {s}", .{request.head.target});
            s.handleRequest(arena, &request) catch |err| {
                log.debug("failed request: {s}", .{@errorName(err)});
                return;
            };
            _ = arena_state.reset(.retain_capacity);
        }
    }

    fn handleRequest(
        server: *Server,
        arena: Allocator,
        req: *std.http.Server.Request,
    ) !void {
        var path_with_query = req.head.target;

        // Percent-decode BEFORE the traversal check so an encoded `%2e%2e`
        // can't slip past it, and never `@panic` on an untrusted request
        // target (that would abort the whole server).
        if (std.mem.indexOfScalar(u8, path_with_query, '%')) |_| {
            const buffer = try arena.dupe(u8, path_with_query);
            path_with_query = std.Uri.percentDecodeInPlace(buffer);
        }

        var path = path_with_query[0 .. std.mem.indexOfScalar(
            u8,
            path_with_query,
            '?',
        ) orelse path_with_query.len];

        // Path-traversal guard: reject `.`/`..` path segments on the decoded
        // path (not the query string, where `..` is a legitimate value) before
        // it can reach any file sink. Respond 400, never panic.
        if (hasTraversalSegment(path)) {
            return sendBadRequest(arena, req, "Invalid path: '.'/'..' segments are not allowed.");
        }

        // Same contract, second failure mode: PathTable aborts the PROCESS on a
        // >512-component path and asserts on a trailing `/\`, so those shapes
        // must never reach `PathName.get` either. 400, never exit.
        if (isUnservablePath(path)) {
            return sendBadRequest(arena, req, "Invalid path: too many path components, or an unsupported trailing separator.");
        }

        // Reverse-proxy dispatch runs BEFORE any static handling / path-prefix
        // rewrite, on the raw request path, so `/api/*` reaches the upstream
        // exactly as it would behind nginx/ZigBase in prod. Longest matching
        // prefix wins; empty `proxies` means this is a no-op.
        if (matchProxy(server.proxies, path)) |rule| {
            return server.proxyPass(arena, req, rule);
        }

        switch (server.build.cfg.*) {
            .Site => |s| {
                if (s.url_path_prefix.len > 0) {
                    // Segment-boundary strip: see `stripPathPrefix`. The old
                    // byte-offset slice accepted "/docs../foo" for prefix
                    // "docs" and rewrote it to "../foo" — a traversal the guard
                    // above had already cleared and never re-runs on.
                    path = stripPathPrefix(path, s.url_path_prefix) orelse {
                        return sendOutsideOfPathPrefix(
                            arena,
                            req,
                            s.url_path_prefix,
                        );
                    };

                    if (path.len == 0) {
                        return appendSlashRedirect(
                            arena,
                            req,
                            path_with_query,
                        ) catch |err| fatal.file(path, err);
                    }
                }
            },
            .Multilingual => {},
        }

        const path_ends_with_slash = std.mem.endsWith(u8, path, "/");

        if (path_ends_with_slash) {
            path = try std.fmt.allocPrint(arena, "{s}{s}", .{
                path,
                "index.html",
            });
        }

        if (std.mem.eql(u8, path, "/__zigapagos/zigapagos-reload.js")) {
            req.respond(zigapagos_reload_js, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/javascript" },
                    // .{ .name = "connection", .value = "close" },
                },
            }) catch |err| log.debug(
                "error while sending http response: {}",
                .{err},
            );

            log.debug("sent livereload script", .{});
            return;
        }

        if (std.mem.eql(u8, path, "/__zigapagos/ws")) {
            server.handleWebsocket(req);
            return error.Websocket;
        }

        // Island bundle routes — serve pre-built bundles from the startup cache
        // (Task 2).  Must be checked BEFORE the site-asset search so the
        // bundled JS takes precedence.
        if (server.island_cache_dir) |cache_dir| {
            if (std.mem.eql(u8, path, "/zigapagos-runtime.js"))
                return sendFile(server.io, arena, req, cache_dir, .@"application/javascript", "zigapagos-runtime.js");
            if (std.mem.startsWith(u8, path, "/islands/") and std.mem.endsWith(u8, path, ".js"))
                return sendFile(server.io, arena, req, cache_dir, .@"application/javascript", path[1..]);
            // Source maps: the shared runtime's and each island's `.js.map`,
            // served as JSON next to the bundle so the client symbolicator can
            // fetch `<script>.map`. Tolerant: a bundle built without maps (dev
            // default) yields a clean 404 the symbolicator handles gracefully,
            // not a dropped connection. Matched here (not the append-slash tier)
            // for the same reason the `.js` routes are.
            if (std.mem.eql(u8, path, "/zigapagos-runtime.js.map") or
                (std.mem.startsWith(u8, path, "/islands/") and std.mem.endsWith(u8, path, ".js.map")))
                return sendMap(server.io, arena, req, cache_dir, path[1..]);
        }

        // SPA bundle + runtime routes — serve pre-built JS from the SPA cache.
        // These MUST win over the append-slash (303) heuristic below (the bug
        // this task fixes: `/spa/App.js` was 303-redirected). `/spa/*.js`
        // covers both the entry bundle and content-hashed code-split chunks.
        if (server.spa_cache_dir) |spa_dir| {
            // Shared runtime: only when islands didn't already serve it above.
            if (server.island_cache_dir == null and std.mem.eql(u8, path, "/zigapagos-runtime.js"))
                return sendFile(server.io, arena, req, spa_dir, .@"application/javascript", "zigapagos-runtime.js");
            if (std.mem.startsWith(u8, path, "/spa/") and std.mem.endsWith(u8, path, ".js"))
                return sendFile(server.io, arena, req, spa_dir, .@"application/javascript", path[1..]);
            // Source maps: the shared runtime's (SPA-only site) + every SPA
            // entry/chunk `.js.map`. Tolerant 404 as in the island block above.
            if ((server.island_cache_dir == null and std.mem.eql(u8, path, "/zigapagos-runtime.js.map")) or
                (std.mem.startsWith(u8, path, "/spa/") and std.mem.endsWith(u8, path, ".js.map")))
                return sendMap(server.io, arena, req, spa_dir, path[1..]);
        }

        const ext = std.fs.path.extension(path);
        const mime_type = mime.extension_map.get(ext) orelse
            .@"application/octet-stream";

        server.build_lock.lockShared(server.io) catch unreachable;
        defer server.build_lock.unlockShared(server.io);

        if (server.build.any_prerendering_error) return sendError(
            arena,
            req,
            "No page was built because of a pre-rendering error.",
        );

        // Site asset search
        not_found: {
            const site_asset = server.build.site_assets.get(PathName.get(
                &server.build.st,
                &server.build.pt,
                path,
            ) orelse break :not_found) orelse break :not_found;

            if (site_asset.load(.acquire) == 0) {
                return sendNotFound(
                    arena,
                    req,
                    true,
                ) catch |err| fatal.file(path, err);
            }

            return sendFile(
                server.io,
                arena,
                req,
                server.build.site_assets_dir,
                mime_type,
                path[1..],
            ) catch |err| fatal.file(path, err);
        }

        for (server.build.variants) |*v| {
            // Segment-boundary strip, same hazard as the url_path_prefix strip
            // above: a byte-offset slice turns "/it../foo" into "../foo" for
            // the locale prefix "it".
            const after_prefix = stripPathPrefix(path, v.output_path_prefix) orelse continue;
            const subpath = after_prefix[@intFromBool(v.output_path_prefix.len > 0 and path_ends_with_slash)..];

            const hint = v.urls.get(PathName.get(
                &v.string_table,
                &v.path_table,
                subpath,
            ) orelse continue) orelse continue;

            const page = &v.pages.items[hint.id];
            if (hint.kind != .page_asset) {
                if (!page._parse.active) return sendError(
                    arena,
                    req,
                    "This page is not active",
                );

                if (page._parse.status != .parsed) return sendError(
                    arena,
                    req,
                    "This page failed to parse",
                );

                if (page._analysis.frontmatter.items.len > 0) return sendError(
                    arena,
                    req,
                    "This page has frontmatter errors",
                );

                // Error-severity check: a warning-only page (e.g. unknown
                // code-fence language) still rendered successfully.
                if (PageAnalysisError.anyError(page._analysis.page.items)) return sendError(
                    arena,
                    req,
                    "This page contains SuperMD errors",
                );

                // TODO: why not just send the error directly for good measure?
                if (page._render.errors.len > 0) return sendError(
                    arena,
                    req,
                    "This page contains rendering errors",
                );
            }

            switch (hint.kind) {
                .page_main, .page_alias => {
                    return sendHtml(
                        arena,
                        req,
                        page._render.out,
                    ) catch |err| fatal.file(path, err);
                },
                .page_alternative => |name| {
                    const idx = for (page.alternatives, 0..) |alt, idx| {
                        if (std.mem.eql(u8, alt.name, name)) {
                            break idx;
                        }
                    } else unreachable;

                    // NOTE: some alternatives might be XML!
                    return sendAlternative(
                        arena,
                        req,
                        subpath,
                        page._render.alternatives[idx].out,
                    ) catch |err| fatal.file(path, err);
                },
                .page_asset => |pa| {
                    if (pa.load(.acquire) == 0) {
                        return sendNotFound(
                            arena,
                            req,
                            true,
                        ) catch |err| fatal.file(path, err);
                    }

                    return sendFile(
                        server.io,
                        arena,
                        req,
                        v.content_dir,
                        mime_type,
                        subpath,
                    ) catch |err| fatal.file(path, err);
                },
            }
        }

        for (server.build.build_assets.entries.items(.value)) |ba| {
            const raw_install_path = ba.install_path orelse continue;
            const install_path = std.mem.trimStart(u8, raw_install_path, "/");
            // skip leading slash in url path
            if (!std.mem.eql(u8, path[1..], install_path)) continue;
            return sendFile(
                server.io,
                arena,
                req,
                server.build.base_dir,
                mime_type,
                ba.input_path,
            ) catch |err| fatal.file(path, err);
        }

        // SPA shell dispatch — the LAST resort before the append-slash/404
        // tiers, so it runs only after every real-file search above (site
        // assets, page variants, build assets) has missed. This mirrors release
        // routing, where real files always win over the SPA shell tiers: nginx
        // emits `try_files $uri $uri/ …/_shell.html …/index.html` and Apache
        // gates the shell rewrites on `!-f`/`!-d`; ZigBase's `.spa` marker
        // serves index.html only on a miss (docs/spa.md). (This block used to
        // run BEFORE the site-asset search, so the fallback tier swallowed
        // real files staged under the base — a stylesheet, or every sibling
        // asset of a root-mounted "/" SPA.)
        //
        // One DELIBERATE dev-only divergence from that parity: an asset that
        // exists under assets/ but is never referenced (refcount 0, so it would
        // not be installed) 404s from the site-asset search above with the
        // "exists but was never referenced" diagnostic (sendNotFound's
        // `not_installed`) and never reaches this block. Release would serve
        // the shell there — the file isn't deployed, so try_files misses — but
        // dev keeps the diagnostic because it flags the authoring mistake
        // instead of silently masking it with a 200 shell.
        //
        // A path under a SPA base resolves to: its exact static route's shell;
        // else a dynamic pattern's `_shell.html`; else the namespace fallback
        // shell (NOT the 404 page). Absolute shell asset URLs (/spa/*,
        // /zigapagos-runtime.js) are served far above.
        if (server.spa_namespaces.len > 0) {
            // Reconstruct the logical URL path: the request-normalization
            // step near the top of this handler appends "index.html" to any
            // trailing-slash path, so undo that to recover the "/app/" form
            // the static route table keys on.
            const logical = if (path_ends_with_slash)
                path[0 .. path.len - "index.html".len]
            else
                path;
            if (resolveSpaShell(server.spa_namespaces, logical)) |shell_rel| {
                if (server.spa_cache_dir) |spa_dir| {
                    // This is the one request-reachable file sink that the
                    // request-path traversal guard does not cover — the path
                    // comes from the SPA route table, not the request — so run
                    // the guard on the shell path itself before opening it.
                    if (!spaShellIsServable(shell_rel)) {
                        log.warn("spa shell path rejected: '{s}'", .{shell_rel});
                        return sendNotFound(arena, req, false);
                    }
                    // text/html => sendFile routes through sendHtml, which
                    // injects the livereload hook exactly like every dev page.
                    //
                    // A missing or unreadable shell 404s: `fatal.file` here
                    // killed the whole dev server over one bad request.
                    return sendFile(server.io, arena, req, spa_dir, .@"text/html", shell_rel) catch |err| {
                        log.warn("spa shell '{s}': {s}", .{ shell_rel, @errorName(err) });
                        return sendNotFound(arena, req, false);
                    };
                }
            }
        }

        if (!path_ends_with_slash) {
            return appendSlashRedirect(
                arena,
                req,
                path_with_query,
            ) catch |err| fatal.file(path, err);
        } else {
            return sendNotFound(
                arena,
                req,
                false,
            ) catch |err| fatal.file(path, err);
        }
    }

    fn sendAlternative(
        arena: Allocator,
        req: *std.http.Server.Request,
        path: []const u8,
        src: []const u8,
    ) !void {
        const ext = std.fs.path.extension(path);
        const mime_type = mime.extension_map.get(ext) orelse
            .@"application/octet-stream";

        if (mime_type == .@"text/html") {
            return sendHtml(arena, req, src);
        }

        req.respond(src, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(mime_type) },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
    }

    fn sendHtml(
        arena: Allocator,
        req: *std.http.Server.Request,
        src: []const u8,
    ) !void {
        const injection =
            \\<script defer src="/__zigapagos/zigapagos-reload.js"></script>
        ;
        const head = "</head>";
        const head_pos = std.mem.indexOf(u8, src, head) orelse src.len;

        const injected = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            src[0..head_pos],
            injection,
            src[head_pos..],
        });

        req.respond(injected, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
    }

    fn sendOutsideOfPathPrefix(
        arena: Allocator,
        req: *std.http.Server.Request,
        path: []const u8,
    ) !void {
        const data = try std.fmt.allocPrint(arena, outside_html, .{path});

        req.respond(data, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("outside of perfix path", .{});
    }

    fn sendError(
        arena: Allocator,
        req: *std.http.Server.Request,
        msg: []const u8,
    ) !void {
        const data = try std.fmt.allocPrint(arena, error_html, .{msg});

        req.respond(data, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("not found", .{});
    }

    /// Upper bound on `/`-separated components in a request path we are willing
    /// to hand to `PathName.get`. `PathTable.getPathNoName` (inherited from
    /// upstream verbatim, so not modified here) prints a diagnostic and calls
    /// `std.process.exit(1)` above 512 components — a single `curl` of a
    /// 514-segment path would otherwise kill the dev server. Kept well under
    /// 512 so the prefix components `getPathNoName` prepends, and the
    /// `index.html` this handler appends to directory paths, still fit.
    const max_path_components: usize = 256;

    /// True when `path` must not reach `PathName.get`, because `PathTable`
    /// aborts the process on it rather than returning an error:
    ///
    ///  * more than `max_path_components` components — `getPathNoName`'s
    ///    `std.process.exit(1)`;
    ///  * a trailing `/\` — `PathName.get`'s Debug-mode
    ///    `assert(!endsWith(src, "/\\"))`, and Debug is the default build.
    ///
    /// Both are reachable with no flags and no `.`/`..` segment, so
    /// `hasTraversalSegment` does not cover them. The caller answers 400.
    fn isUnservablePath(path: []const u8) bool {
        if (std.mem.endsWith(u8, path, "/\\")) return true;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        var count: usize = 0;
        while (it.next() != null) {
            count += 1;
            if (count > max_path_components) return true;
        }
        return false;
    }

    /// True if any path segment of `path` is exactly `.` or `..`. Split on both
    /// `/` and `\`: backslash isn't a separator on our Linux/macOS targets (it's
    /// a legal filename byte), but the file-system APIs on other platforms honor
    /// it, so a separator-correct guard rejects `..\` traversal defensively too.
    /// Run on the percent-decoded path so encoded traversal (`%2e%2e`) is caught.
    ///
    /// `src/cli/explain.zig` reuses this same guard for its route argument —
    /// same reason `stripPathPrefix` above is `pub`: a second hand-rolled
    /// traversal check is how the two copies drift.
    pub fn hasTraversalSegment(path: []const u8) bool {
        var it = std.mem.splitAny(u8, path, "/\\");
        while (it.next()) |seg| {
            if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return true;
        }
        return false;
    }

    fn sendBadRequest(
        arena: Allocator,
        req: *std.http.Server.Request,
        msg: []const u8,
    ) !void {
        const data = try std.fmt.allocPrint(arena, error_html, .{msg});

        req.respond(data, .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("bad request: {s}", .{msg});
    }

    fn sendNotFound(
        arena: Allocator,
        req: *std.http.Server.Request,
        /// Set to true when the asset exists but it was not referenced anywhere
        /// and thus would not be installed.
        not_installed: bool,
    ) !void {
        const msg = switch (not_installed) {
            true => "This path does exist but it was never referenced in the build!",
            false => "This path does not exist!",
        };

        const data = try std.fmt.allocPrint(arena, not_found_html, .{msg});

        req.respond(data, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
                // .{ .name = "connection", .value = "close" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("not found", .{});
    }

    fn sendFile(
        io: Io,
        arena: Allocator,
        req: *std.http.Server.Request,
        dir: Io.Dir,
        mime_type: mime.Type,
        file_path: []const u8,
    ) !void {
        assert(file_path[0] != '/');

        const contents = try dir.readFileAlloc(
            io,
            file_path,
            arena,
            .unlimited,
        );

        if (mime_type == .@"text/html") {
            return sendHtml(arena, req, contents);
        }

        req.respond(contents, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(mime_type) },
                // .{ .name = "connection", .value = "close" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
    }

    /// Serve a source map as `application/json`, tolerating absence: a dev
    /// bundle built without maps (the default) has no `.js.map` in the cache, so
    /// a read miss becomes a clean 404 the client symbolicator handles (it treats
    /// a non-ok `.map` fetch as "no map, pass the frame through unchanged") rather
    /// than a dropped connection. Any other read error still propagates.
    fn sendMap(
        io: Io,
        arena: Allocator,
        req: *std.http.Server.Request,
        dir: Io.Dir,
        file_path: []const u8,
    ) !void {
        assert(file_path[0] != '/');
        const contents = dir.readFileAlloc(io, file_path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return sendNotFound(arena, req, false),
            else => return err,
        };
        req.respond(contents, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(mime.Type.@"application/json") },
            },
        }) catch |err| log.debug("error while sending http response: {}", .{err});
    }

    fn appendSlashRedirect(
        arena: std.mem.Allocator,
        req: *std.http.Server.Request,
        path_with_query: []const u8,
    ) !void {
        // convert `foo/bar?query=1` to `foo/bar/?query=1`
        const query_start = std.mem.indexOfScalar(u8, path_with_query, '?') orelse path_with_query.len;
        const location = try std.fmt.allocPrint(
            arena,
            "{s}/{s}",
            .{ path_with_query[0..query_start], path_with_query[query_start..] },
        );

        req.respond(not_found_html, .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "location", .value = location },
                .{ .name = "content-type", .value = "text/html" },
                .{ .name = "connection", .value = "close" },
            },
        }) catch |err| log.debug(
            "error while sending http response: {}",
            .{err},
        );
        log.debug("append final slash redirect", .{});
    }

    fn handleWebsocket(s: *Server, req: *std.http.Server.Request) void {
        const up = req.upgradeRequested();
        const wsup = switch (up) {
            .none, .other => return req.respond("error: must request websocket upgrade", .{
                .status = .bad_request,
            }) catch {},

            .websocket => |wsup| wsup orelse "<no key provided>",
        };

        var ws = req.respondWebSocket(.{ .key = wsup }) catch return;
        s.channel.put(s.io, .{ .connect = ws }) catch return;

        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                log.debug("readWs error: {s} {any}", .{ @errorName(err), ws });
                s.channel.put(s.io, .{ .disconnect = ws }) catch return;
                return;
            };
            _ = msg;
        }
    }

    /// Forwards a matched request to its upstream and streams the response back
    /// on the same connection. Manual HTTP/1.1: opens a fresh TCP connection,
    /// sends the request with `Connection: close`, reads the response until EOF
    /// (valid under close-framing, and sidesteps chunked/content-length), and
    /// pumps the body to the client flushing each chunk so SSE stays live.
    /// `Set-Cookie` and other end-to-end headers relay verbatim; hop-by-hop
    /// headers are dropped. Upstream connect/DNS failure → 502; a WebSocket
    /// upgrade request → 501 (out of scope for v1).
    /// Cap on a proxied request body we buffer to re-frame with Content-Length.
    /// Dev backends never see uploads near this; anything larger → 413.
    ///
    /// This bound is a memory bound, not a politeness one: the body is buffered
    /// whole into the PER-CONNECTION arena, and `handleConnection` recycles that
    /// arena with `.retain_capacity`, so a connection's peak stays resident for
    /// its whole life. With `--proxy` on, any page the developer has open can
    /// POST a CORS-simple `text/plain` body of this size with no preflight, so
    /// N keep-alive connections pin N × this. At the old 256 MiB, ten
    /// connections were 2.5 GB.
    const max_proxy_request_body: usize = 8 * 1024 * 1024;

    /// Bound on the upstream response head we will read, mirroring the 8 KiB
    /// `max_connection_header_size` std applies to the CLIENT head. Without it,
    /// an upstream streaming header lines forever grows the per-connection arena
    /// until OOM. Past either bound → 502.
    const max_upstream_header_bytes: usize = 8 * 1024;
    const max_upstream_header_count: usize = 128;

    /// Bound on 1xx interim responses we skip before giving up, so an upstream
    /// streaming `HTTP/1.1 100` forever cannot pin a connection thread → 502.
    const max_upstream_interim_responses: usize = 8;

    fn proxyPass(
        server: *Server,
        arena: Allocator,
        req: *std.http.Server.Request,
        rule: ProxyRule,
    ) !void {
        const io = server.io;

        // WebSocket upgrades are not proxied in v1 (SSE covers the live-flags
        // need). Answer 501 rather than silently mishandling the upgrade.
        switch (req.upgradeRequested()) {
            .websocket => return sendProxyError(
                arena,
                req,
                .not_implemented,
                "WebSocket proxying is not supported by the Zigapagos dev server yet.",
            ),
            .none, .other => {},
        }

        // Capture everything we need from `req.head` NOW: the body reader
        // (below) invalidates the head strings AND may overwrite the connection
        // buffer they point into, so dup the raw target and every forwarded
        // header value into the arena before touching the body.
        //
        // C1: forward the ORIGINAL still-encoded target (`req.head.target`), NOT
        // the percent-decoded copy used for routing. A decoded target would (a)
        // break any %-encoded path/query upstream and (b) let a decoded CRLF
        // inject headers into the upstream request. The std parser guarantees the
        // raw target has no literal CRLF, so writing it verbatim is injection-safe.
        const method = req.head.method;
        const raw_target = try arena.dupe(u8, req.head.target);

        // Copy forwardable request headers (dropping Host — rewritten to the
        // upstream authority — Expect, Content-Length, and hop-by-hop, which we
        // re-derive). Must run before the body reader invalidates head strings.
        var fwd_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
        var had_forwarded_for = false;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "expect")) continue; // M1: never forward Expect
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) continue; // re-derived below
            if (isHopByHop(h.name)) continue; // incl. transfer-encoding, connection
            if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) had_forwarded_for = true;
            try fwd_headers.append(arena, .{
                .name = try arena.dupe(u8, h.name),
                .value = try arena.dupe(u8, h.value),
            });
        }

        // Request body framing.
        //
        // I1: when the client declares a length/encoding, buffer the (dechunked)
        // body so we can forward it with an explicit Content-Length. Streaming
        // the dechunked bytes unframed — as before — reached the upstream as a
        // body-less request (the bytes were then parsed as the next request:
        // request smuggling). Content-Length uploads were fine; chunked broke.
        //
        // Keep-alive bodyless body-method: a POST/PUT/PATCH with NO
        // Content-Length AND NO Transfer-Encoding has a zero-length body per RFC
        // 7230. We must NOT read it — std's bodyReader hands back the raw
        // connection reader (read-until-close) for that case, which hangs a
        // keep-alive client that holds the socket open. Instead we forward
        // `content-length: 0` and answer the client with `Connection: close`
        // (see `keep_alive` on respondStreaming below). Leaving the reader in
        // `.received_head` and responding keep-alive would trip discardBody's
        // body-method assert and abort the whole dev server — the regression.
        const has_framing = req.head.content_length != null or req.head.transfer_encoding != .none;
        const bodyless_body_method = !has_framing and req.head.method.requestHasBody();
        var req_body: []const u8 = "";
        if (has_framing) {
            // readerExpectContinue drives an `Expect: 100-continue` client by
            // sending the interim 100 so it uploads; we dropped Expect upstream.
            var req_body_buf: [64 * 1024]u8 = undefined;
            const body_reader = req.readerExpectContinue(&req_body_buf) catch {
                return sendProxyError(arena, req, .bad_gateway, "Bad Gateway: failed reading the request body.");
            };
            req_body = body_reader.allocRemaining(arena, .limited(max_proxy_request_body)) catch |err| switch (err) {
                error.StreamTooLong => return sendProxyError(arena, req, .payload_too_large, "Payload Too Large: request body exceeds the dev proxy limit."),
                else => {
                    log.warn("proxy: reading request body failed: {s}", .{@errorName(err)});
                    return sendProxyError(arena, req, .bad_gateway, "Bad Gateway: failed reading the request body.");
                },
            };
        }
        // Forward a Content-Length whenever there is a (possibly empty) body:
        // real framing, or the zero-length bodyless-body-method case.
        const forward_body = has_framing or bodyless_body_method;

        // --- Resolve + connect to the upstream (both failures → 502) ---------
        const address = resolveUpstream(io, rule.host, rule.port) catch |err| {
            log.warn("proxy: cannot resolve upstream {s}:{d}: {s}", .{
                rule.host, rule.port, @errorName(err),
            });
            return sendProxyError(arena, req, .bad_gateway, "Bad Gateway: upstream host could not be resolved.");
        };
        var stream = address.connect(io, .{ .mode = .stream }) catch |err| {
            log.warn("proxy: connect to {s}:{d} failed: {s}", .{
                rule.host, rule.port, @errorName(err),
            });
            return sendProxyError(arena, req, .bad_gateway, "Bad Gateway: could not connect to the upstream.");
        };
        defer stream.close(io);

        // --- Send request to upstream ---------------------------------------
        var up_out_buf: [4096]u8 = undefined;
        var up_writer = stream.writer(io, &up_out_buf);
        const up_out = &up_writer.interface;

        const authority = try std.fmt.allocPrint(arena, "{s}:{d}", .{ rule.host, rule.port });

        try up_out.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(method), raw_target });
        for (fwd_headers.items) |h| try up_out.print("{s}: {s}\r\n", .{ h.name, h.value });
        try up_out.print("host: {s}\r\n", .{authority});
        try up_out.writeAll("connection: close\r\n");
        // The dev server always sits at loopback, so the client is 127.0.0.1.
        // Preserve a client-supplied chain rather than overwriting it.
        if (!had_forwarded_for) try up_out.writeAll("x-forwarded-for: 127.0.0.1\r\n");
        try up_out.writeAll("x-forwarded-proto: http\r\n");
        try up_out.print("x-forwarded-host: {s}\r\n", .{authority});
        if (forward_body) try up_out.print("content-length: {d}\r\n", .{req_body.len});
        try up_out.writeAll("\r\n");
        if (forward_body) try up_out.writeAll(req_body);
        up_out.flush() catch |err| {
            log.warn("proxy: flushing upstream request failed: {s}", .{@errorName(err)});
            return sendProxyError(arena, req, .bad_gateway, "Bad Gateway: upstream write failed.");
        };

        // --- Read the upstream response head (bounded) ----------------------
        var up_in_buf: [16 * 1024]u8 = undefined;
        var up_reader = stream.reader(io, &up_in_buf);
        const up_in = &up_reader.interface;

        const up_head = readUpstreamHead(arena, up_in) catch |err| {
            log.warn("proxy: bad upstream response head: {s}", .{@errorName(err)});
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return sendProxyError(arena, req, .bad_gateway, upstreamHeadErrorMessage(err));
        };

        // --- Relay status + headers, then stream the body (SSE-safe) ---------
        var resp_buf: [16 * 1024]u8 = undefined;
        var body = req.respondStreaming(&resp_buf, .{
            .respond_options = .{
                .status = @enumFromInt(up_head.status_code),
                .reason = up_head.reason,
                .extra_headers = up_head.headers,
                // For the bodyless body-method case we deliberately left the
                // request reader in `.received_head`; a `Connection: close`
                // response makes discardBody take its non-keep-alive path and
                // skip the body-method assert (see the framing note above).
                .keep_alive = !bodyless_body_method,
            },
        }) catch |err| {
            log.warn("proxy: starting client response failed: {s}", .{@errorName(err)});
            return;
        };

        if (up_head.chunked) {
            // C2: DECHUNK. Relay only chunk DATA — respondStreaming re-frames it
            // as chunked for the client. Pumping the raw upstream bytes (as
            // before) leaked the upstream's `1a`/`0` chunk-size lines into the
            // body, corrupting every chunked response (notably SSE, which Bun
            // sends chunked even under Connection: close). Flush per chunk so
            // each SSE event reaches the client live.
            relayChunked(up_in, &body) catch |err| {
                log.warn("proxy: relaying chunked upstream body failed: {s}", .{@errorName(err)});
            };
        } else if (up_head.content_length) |len| {
            // Relay exactly `len` bytes (the upstream may keep the socket open).
            relayExact(up_in, &body, len) catch |err| {
                log.warn("proxy: relaying content-length body failed: {s}", .{@errorName(err)});
            };
        } else {
            // Close-delimited: read until EOF, flushing each read.
            while (true) {
                _ = up_in.stream(&body.writer, .unlimited) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => {
                        log.warn("proxy: upstream read failed mid-body: {s}", .{
                            if (up_reader.err) |e| @errorName(e) else "unknown",
                        });
                        break;
                    },
                    error.WriteFailed => break,
                };
                flushChunk(&body) catch break;
            }
        }
        body.end() catch {};
    }

    /// Two-layer flush of one relayed chunk: `body.writer.flush()` drains the
    /// body buffer through the chunked framing into the protocol output, then
    /// `body.flush()` pushes the protocol output to the socket. Flushing only
    /// the latter leaves the chunk buffered and defeats SSE streaming.
    fn flushChunk(body: *std.http.BodyWriter) !void {
        try body.writer.flush();
        try body.flush();
    }

    /// Relays a `Transfer-Encoding: chunked` upstream body, emitting only the
    /// decoded chunk DATA (respondStreaming re-frames). Flushes after each chunk
    /// so streamed responses (SSE) arrive live.
    fn relayChunked(up_in: *Io.Reader, body: *std.http.BodyWriter) !void {
        while (true) {
            const size_line_raw = try up_in.takeDelimiterInclusive('\n');
            const size_line = std.mem.trimEnd(u8, size_line_raw, "\r\n");
            // A chunk-size line may carry `;ext` extensions after the hex size.
            const hex = size_line[0 .. std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len];
            const size = std.fmt.parseInt(u64, std.mem.trim(u8, hex, " \t"), 16) catch return error.MalformedChunk;
            if (size == 0) {
                // Last chunk: consume trailer headers up to the terminating blank line.
                while (true) {
                    const t = try up_in.takeDelimiterInclusive('\n');
                    if (std.mem.trimEnd(u8, t, "\r\n").len == 0) break;
                }
                return;
            }
            try up_in.streamExact64(&body.writer, size);
            // Consume the CRLF that terminates the chunk data.
            _ = try up_in.takeDelimiterInclusive('\n');
            try flushChunk(body);
        }
    }

    /// Relays exactly `len` bytes from `up_in` to the client, flushing as it goes.
    fn relayExact(up_in: *Io.Reader, body: *std.http.BodyWriter, len: u64) !void {
        var remaining = len;
        while (remaining > 0) {
            const n = try up_in.stream(&body.writer, .limited64(remaining));
            remaining -= n;
            try flushChunk(body);
        }
    }

    /// What `readUpstreamHead` can fail with. Explicit (not `anyerror`) so
    /// `upstreamHeadErrorMessage` can switch exhaustively.
    const UpstreamHeadError = error{
        /// The upstream closed, stalled, or overran the read buffer mid-head.
        Truncated,
        MalformedStatusLine,
        /// Outside 100–599; `@enumFromInt` on `std.http.Status` (u10) would panic.
        StatusOutOfRange,
        HeadersTooLarge,
        TooManyHeaders,
        TooManyInterimResponses,
        OutOfMemory,
    };

    /// NO_SLOP contract 2 (owned-result): every slice below is allocated from
    /// the allocator handed to `readUpstreamHead` and released by `deinit`, so
    /// the parser is correct under ANY allocator — not just the per-connection
    /// arena `proxyPass` happens to pass.
    const UpstreamHead = struct {
        status_code: u16,
        /// Owned copy — the reader buffer holding it is reused by the next read.
        reason: []const u8,
        /// Owned; hop-by-hop and framing headers already dropped.
        headers: []const std.http.Header,
        /// The upstream framed its body as `Transfer-Encoding: chunked`.
        chunked: bool,
        /// The upstream's `Content-Length`, when it sent a parseable one.
        content_length: ?u64,

        /// `proxyPass` does NOT call this: its `headers` are still referenced by
        /// the in-flight `respondStreaming` response, and the per-connection
        /// arena reclaims them with everything else when the request ends. It
        /// exists so `readUpstreamHead` can be exercised with the raw testing
        /// allocator, leak detection ON.
        fn deinit(h: UpstreamHead, gpa: Allocator) void {
            gpa.free(h.reason);
            for (h.headers) |x| {
                gpa.free(x.name);
                gpa.free(x.value);
            }
            gpa.free(h.headers);
        }
    };

    fn upstreamHeadErrorMessage(err: UpstreamHeadError) []const u8 {
        return switch (err) {
            error.Truncated => "Bad Gateway: truncated response from upstream.",
            error.MalformedStatusLine => "Bad Gateway: malformed response from upstream.",
            error.StatusOutOfRange => "Bad Gateway: invalid status code from upstream.",
            error.HeadersTooLarge => "Bad Gateway: response headers from upstream are too large.",
            error.TooManyHeaders => "Bad Gateway: too many response headers from upstream.",
            error.TooManyInterimResponses => "Bad Gateway: too many interim (1xx) responses from upstream.",
            error.OutOfMemory => "Bad Gateway: out of memory reading the upstream response.",
        };
    }

    /// Reads an upstream HTTP/1.1 response head: skips 1xx interim responses
    /// (respondStreaming asserts `status != .continue`), parses the status line,
    /// and collects the headers worth relaying — dropping hop-by-hop ones and
    /// noting the upstream's own framing so the caller can dechunk.
    ///
    /// Every read is BOUNDED (`max_upstream_header_bytes`,
    /// `max_upstream_header_count`, `max_upstream_interim_responses`). The
    /// client-side head is already bounded by std at
    /// `max_connection_header_size`; the upstream side was not, so a broken or
    /// hostile upstream could grow the per-connection arena until OOM (endless
    /// header lines) or pin the connection thread forever (endless `100`s).
    ///
    /// Ownership: contract 2 — `takeDelimiterInclusive` hands back slices of the
    /// reader buffer that the next read invalidates, so `reason` and every
    /// header name/value are copied out of `gpa`; the caller releases them with
    /// `UpstreamHead.deinit`, and every error path unwinds its own allocations.
    fn readUpstreamHead(gpa: Allocator, up_in: *Io.Reader) UpstreamHeadError!UpstreamHead {
        var status_code: u16 = 0;
        var reason: []const u8 = "";
        var interim_seen: usize = 0;
        // One budget for the whole head (status line + every header line, incl.
        // skipped interim blocks), mirroring the client-side head bound.
        var head_bytes: usize = 0;

        // Status line: "HTTP/1.1 <code> <reason>". takeDelimiterInclusive
        // consumes the '\n' (Exclusive would leave it, stalling the next read).
        while (true) {
            const status_line = up_in.takeDelimiterInclusive('\n') catch return error.Truncated;
            head_bytes += status_line.len;
            if (head_bytes > max_upstream_header_bytes) return error.HeadersTooLarge;

            // The error is not swallowed: the sole caller logs it by name and
            // answers 502 with `upstreamHeadErrorMessage`, so logging here too
            // would just double-report the same event.
            status_code, reason = parseStatusLine(std.mem.trimEnd(u8, status_line, "\r\n")) catch
                return error.MalformedStatusLine;
            if (status_code < 100 or status_code > 599) return error.StatusOutOfRange;
            if (status_code >= 200) break;

            interim_seen += 1;
            if (interim_seen > max_upstream_interim_responses) return error.TooManyInterimResponses;
            // Consume this interim response's header block, then read the next
            // status line.
            while (true) {
                const l = up_in.takeDelimiterInclusive('\n') catch return error.Truncated;
                head_bytes += l.len;
                if (head_bytes > max_upstream_header_bytes) return error.HeadersTooLarge;
                if (std.mem.trimEnd(u8, l, "\r\n").len == 0) break;
            }
        }
        const reason_owned = try gpa.dupe(u8, reason);
        errdefer gpa.free(reason_owned);

        var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
        errdefer {
            for (headers.items) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            headers.deinit(gpa);
        }
        var chunked = false;
        var content_length: ?u64 = null;
        while (true) {
            const line_raw = up_in.takeDelimiterInclusive('\n') catch return error.Truncated;
            head_bytes += line_raw.len;
            if (head_bytes > max_upstream_header_bytes) return error.HeadersTooLarge;

            const line = std.mem.trimEnd(u8, line_raw, "\r\n");
            if (line.len == 0) break; // end of headers

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trimEnd(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (name.len == 0) continue;

            // Note the upstream framing, then drop it — the caller always
            // re-frames the relayed body as chunked via respondStreaming.
            if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                // `chunked`, if present, is always the final transfer-coding.
                if (std.ascii.endsWithIgnoreCase(value, "chunked")) chunked = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(u64, value, 10) catch null;
                continue;
            }
            if (isHopByHop(name)) continue;

            if (headers.items.len >= max_upstream_header_count) return error.TooManyHeaders;
            const name_owned = try gpa.dupe(u8, name);
            errdefer gpa.free(name_owned);
            const value_owned = try gpa.dupe(u8, value);
            errdefer gpa.free(value_owned);
            try headers.append(gpa, .{ .name = name_owned, .value = value_owned });
        }

        return .{
            .status_code = status_code,
            .reason = reason_owned,
            // Exact-sized so `deinit` can free it under any allocator.
            .headers = try headers.toOwnedSlice(gpa),
            .chunked = chunked,
            .content_length = content_length,
        };
    }

    fn sendProxyError(
        arena: Allocator,
        req: *std.http.Server.Request,
        status: std.http.Status,
        msg: []const u8,
    ) !void {
        // Render through `arena` like the sibling sendBadRequest/sendError, so a
        // proxy failure is the same styled dev-server error page as every other
        // one (this used to discard the parameter with `_ = arena;` and reply
        // with a bare text/plain line).
        const data = try std.fmt.allocPrint(arena, error_html, .{msg});

        req.respond(data, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
            },
        }) catch |err| log.debug(
            "error while sending proxy error response: {}",
            .{err},
        );
        log.debug("proxy error: {s}", .{msg});
    }
};

/// Strips a leading URL path `prefix` (no leading slash, optional trailing
/// slash — the `url_path_prefix` / `output_path_prefix` spelling) from a request
/// `path` (which starts with '/'), returning the remainder: "" when `path` is
/// exactly the prefix, otherwise a slice that starts with '/'. Returns null when
/// `path` is NOT under `prefix`.
///
/// The point is the segment boundary. Slicing at the prefix's BYTE length —
/// what this replaces — accepted "/docs../foo" for prefix "docs" and handed the
/// rest of the handler "../foo", a traversal that the guard at the top of
/// `handleRequest` had already cleared and does not re-run. An empty prefix
/// matches everything and strips only the leading '/' (the single-variant case).
///
/// `src/cli/explain.zig` resolves a route through this same helper — the
/// segment-boundary rule is a traversal guard, and a second copy would drift.
pub fn stripPathPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    const body = path[1..];
    if (!std.mem.startsWith(u8, body, prefix)) return null;

    var len = prefix.len;
    if (len > 0 and prefix[len - 1] == '/') len -= 1;
    const rest = body[len..];
    // The byte after the prefix must end the path or start a new segment.
    if (len != 0 and rest.len != 0 and rest[0] != '/') return null;
    return rest;
}

/// Selects the longest `--proxy` prefix that `path` matches at a segment
/// boundary (`path == prefix` or the char after the prefix is '/'), so `/apiary`
/// does not match `/api`. Returns null when nothing matches.
fn matchProxy(proxies: []const ProxyRule, path: []const u8) ?ProxyRule {
    var best: ?ProxyRule = null;
    for (proxies) |rule| {
        if (!std.mem.startsWith(u8, path, rule.prefix)) continue;
        // Segment-boundary check: exact match, or the prefix is followed by '/'.
        if (path.len != rule.prefix.len and path[rule.prefix.len] != '/') continue;
        if (best == null or rule.prefix.len > best.?.prefix.len) best = rule;
    }
    return best;
}

/// True for HTTP/1.1 hop-by-hop headers, which must not be forwarded through a
/// proxy (RFC 7230 §6.1). `Proxy-*` headers are also stripped defensively.
fn isHopByHop(name: []const u8) bool {
    const hop = [_][]const u8{
        "connection",
        "keep-alive",
        "transfer-encoding",
        "te",
        "trailer",
        "upgrade",
        "proxy-connection",
        "proxy-authenticate",
        "proxy-authorization",
    };
    for (hop) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

/// Resolves an upstream host to an `IpAddress`. Tries a literal-IP fast path
/// first (no DNS for `127.0.0.1`), then falls back to a DNS lookup (so
/// `localhost` and real hostnames work). Returns the first address result.
fn resolveUpstream(io: Io, host: []const u8, port: u16) !Io.net.IpAddress {
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        return addr;
    } else |_| {}

    var backing: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&backing);
    var canon_buf: [Io.net.HostName.max_len]u8 = undefined;
    try Io.net.HostName.lookup(try .init(host), io, &queue, .{
        .port = port,
        .canonical_name_buffer = &canon_buf,
    });

    // The queue is closed on return; drain it without blocking (min = 0) and
    // return the first address result (lookup may also enqueue a canonical
    // name, which we skip).
    var results: [16]Io.net.HostName.LookupResult = undefined;
    const n = queue.get(io, &results, 0) catch return error.UnknownHostName;
    for (results[0..n]) |r| switch (r) {
        .address => |a| return a,
        .canonical_name => {},
    };
    return error.NoAddressReturned;
}

/// Parses an HTTP status line ("HTTP/1.1 200 OK") into the numeric status code
/// and reason phrase. The trailing CR must already be trimmed by the caller.
fn parseStatusLine(line: []const u8) !struct { u16, []const u8 } {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedStatusLine;
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const code = std.fmt.parseInt(u16, rest[0..sp2], 10) catch return error.MalformedStatusLine;
    const reason = if (sp2 < rest.len) rest[sp2 + 1 ..] else "";
    return .{ code, reason };
}

/// Strips only the final extension (lastIndexOf '.') so multi-dot basenames
/// like "Hero.island.tsx" → "Hero.island".
/// Byte-identical to build.zig `islandName`; must stay in lockstep with
/// `pass.zig`'s `moduleUrl` and `build.zig`'s `addIslandAssets`.
fn islandName(src: []const u8) []const u8 {
    var name = src;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[0..dot];
    return name;
}

/// Spawns `bun_path build …argv…` in `cwd`, waits for exit, and returns
/// `error.BundleFailed` on non-zero status.  Matches the sidecar.zig spawn
/// pattern.  Pass `env_map = null` to inherit the parent environment.
fn bunBuild(
    io: Io,
    gpa: Allocator,
    bun_path: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    // std.ArrayList in Zig 0.16 is the unmanaged Aligned variant; deinit needs gpa.
    var args = try std.ArrayList([]const u8).initCapacity(gpa, 1 + argv.len);
    defer args.deinit(gpa);
    args.appendAssumeCapacity(bun_path);
    for (argv) |a| args.appendAssumeCapacity(a);
    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .cwd = .{ .path = cwd },
        .environ_map = env_map,
        .stderr = .inherit, // surface bun errors in the build log
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.BundleFailed,
        else => return error.BundleFailed,
    }
}

/// Returns an `Environ.Map` seeded from the current process environment with
/// `NODE_ENV=production` added (or overridden).
///
/// On Linux the current env is read from `/proc/self/environ`.  On other
/// platforms the map only contains NODE_ENV=production, which is sufficient
/// because bun resolves everything from its CWD.
///
/// Matches `build.zig`'s `bun_isl.setEnvironmentVariable("NODE_ENV","production")`.
fn buildProdEnvMap(io: Io, gpa: Allocator) error{OutOfMemory}!std.process.Environ.Map {
    var env_map = std.process.Environ.Map.init(gpa);
    errdefer env_map.deinit();
    // Populate from the running process so bun has PATH etc.
    if (comptime builtin.target.os.tag == .linux) {
        if (Io.Dir.cwd().readFileAlloc(io, "/proc/self/environ", gpa, .unlimited)) |data| {
            defer gpa.free(data);
            var iter = std.mem.splitScalar(u8, data, 0);
            while (iter.next()) |entry| {
                if (entry.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                try env_map.put(entry[0..eq], entry[eq + 1 ..]);
            }
        } else |err| {
            log.debug("buildProdEnvMap: /proc/self/environ: {s}", .{@errorName(err)});
        }
    }
    try env_map.put("NODE_ENV", "production");
    return env_map;
}

/// Rebuilds every island JS bundle into `<cache_abs>/islands/<Name>.js`.
/// Called at startup (caller wraps with `fatal.msg` on error) and on-change
/// (caller catches errors, surfaces them, then still broadcasts reload_all).
/// Skips the runtime bundle — the runtime source is library-side and rarely
/// changes during a dev session; restart to pick up runtime changes.
fn bundleIslands(
    io: Io,
    gpa: Allocator,
    bun_path: []const u8,
    src_dir: []const u8,
    islands: []const []const u8,
    cache_abs: []const u8,
) !void {
    // NODE_ENV=production forces production JSX (jsx/jsxs, not jsxDEV) —
    // matches build.zig's `bun_isl.setEnvironmentVariable("NODE_ENV","production")`.
    var prod_env = try buildProdEnvMap(io, gpa);
    defer prod_env.deinit();

    for (islands) |isl| {
        const name = islandName(isl);
        const outfile = try std.fmt.allocPrint(gpa, "{s}/islands/{s}.js", .{ cache_abs, name });
        defer gpa.free(outfile);
        try bunBuild(io, gpa, bun_path, src_dir, &.{
            "build",
            isl,
            "--external=@z/runtime",
            "--external=@z/runtime/jsx-runtime",
            "--format=esm",
            "--outfile",
            outfile,
        }, &prod_env);
    }
}

/// Bundles each SPA's entry + code-split chunks into `<cache_abs>/spa/` using the
/// SAME driver release uses (`bundle-island.ts` in code-splitting mode: entry
/// naming, chunk hashing, `spa-chunks.json`), so the dev bundle matches release
/// minus `--minify`. `@z/runtime` is kept external (one Preact via the import
/// map). NODE_ENV=production forces production JSX. Called at startup (caller
/// fatals on error) and on-change (caller surfaces the error, still reloads).
fn bundleSpas(
    io: Io,
    gpa: Allocator,
    bun_path: []const u8,
    driver: []const u8,
    src_dir: []const u8,
    spas: []const SpaArg,
    cache_abs: []const u8,
) !void {
    var prod_env = try buildProdEnvMap(io, gpa);
    defer prod_env.deinit();

    const outdir = try std.fmt.allocPrint(gpa, "{s}/spa", .{cache_abs});
    defer gpa.free(outdir);

    for (spas) |sp| {
        const name = spa_mod.spaName(sp.src);
        const entry_arg = try std.fmt.allocPrint(gpa, "--entry={s}", .{sp.src});
        defer gpa.free(entry_arg);
        const outdir_arg = try std.fmt.allocPrint(gpa, "--outdir={s}", .{outdir});
        defer gpa.free(outdir_arg);
        const entry_name = try std.fmt.allocPrint(gpa, "--entry-name={s}.js", .{name});
        defer gpa.free(entry_name);
        // The driver requires --chunks-json and --depfile; dev never reads them
        // back (no per-route chunk preload, no Zig cache tracking) but they must
        // be written somewhere, so stash them in the cache dir.
        const chunks_arg = try std.fmt.allocPrint(gpa, "--chunks-json={s}/{s}-chunks.json", .{ cache_abs, name });
        defer gpa.free(chunks_arg);
        const depfile_arg = try std.fmt.allocPrint(gpa, "--depfile={s}/{s}.d", .{ cache_abs, name });
        defer gpa.free(depfile_arg);

        try bunBuild(io, gpa, bun_path, src_dir, &.{
            driver,
            entry_arg,
            outdir_arg,
            entry_name,
            chunks_arg,
            depfile_arg,
            "--external=@z/runtime",
            "--external=@z/runtime/jsx-runtime",
            // Emit linked `.js.map`s into the SPA cache so `serve` can serve
            // them for client-side symbolication in dev, mirroring release. The
            // driver writes maps via Bun.write (raw `bun build --outfile` can't),
            // so this works here where the SPA path uses the driver + --outdir.
            "--sourcemap",
        }, &prod_env);
    }
}

/// True when a logical request `path` (leading slash) falls under a SPA's URL
/// `base` ("/app", or "" for a root-mounted SPA that owns every path), at a
/// segment boundary so "/apple" does NOT fall under "/app".
fn spaUnderBase(path: []const u8, base: []const u8) bool {
    if (base.len == 0) return true; // root-mounted: catches all
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path.len == base.len or path[base.len] == '/';
}

/// Advance a '/'-split iterator to the next NON-empty segment (skipping the
/// empties that leading/trailing/duplicate slashes produce). Null at the end.
fn nextSeg(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |s| if (s.len != 0) return s;
    return null;
}

/// Segment-wise match of a dynamic route `pattern` ("/app/club/:id",
/// "/app/admin/*") against a logical request `path`. `:seg` matches exactly one
/// segment; a trailing `*` matches zero-or-more trailing segments; literals must
/// be equal. Empty segments are ignored on both sides. Mirrors the runtime
/// router (runtime/src/router.ts `matchInto`), which binds `*` to
/// `segs.slice(i).join("/")` and so accepts an empty remainder.
fn spaMatchPattern(pattern: []const u8, path: []const u8) bool {
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var xit = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pseg = nextSeg(&pit);
        // A trailing `*` consumes zero-or-more remaining segments, so it matches
        // even when the path is already exhausted (`/admin/*` matches `/admin`).
        // Checked before demanding a path segment — this is the runtime parity
        // fix; the previous code required at least one remaining segment here.
        if (pseg != null and std.mem.eql(u8, pseg.?, "*")) return true;
        const xseg = nextSeg(&xit);
        if (pseg == null and xseg == null) return true;
        if (pseg == null or xseg == null) return false;
        if (pseg.?[0] == ':') continue; // :param matches one segment
        if (!std.mem.eql(u8, pseg.?, xseg.?)) return false;
    }
}

/// True when a resolved SPA shell path is safe to hand to `sendFile`. Shell
/// paths (`ServeShell.out_path` / `ServeSpa.fallback_rel`) are derived from the
/// route pathnames in the user's `.spa.tsx` via the sidecar, so they are the one
/// file-sink input that never passed through the request-path traversal guard.
/// Rejects:
///   * the empty path — `sendFile` indexes `file_path[0]`;
///   * an absolute path — `sendFile` asserts `file_path[0] != '/'`;
///   * any `.`/`..` segment — escapes the SPA cache dir.
fn spaShellIsServable(shell_rel: []const u8) bool {
    if (shell_rel.len == 0) return false;
    if (shell_rel[0] == '/' or shell_rel[0] == '\\') return false;
    return !Server.hasTraversalSegment(shell_rel);
}

/// Resolve a logical request `path` to a SPA shell's cache-relative disk path:
/// exact static route -> its shell; else dynamic pattern -> that pattern's
/// `_shell.html`; else the owning namespace's fallback shell. Null when `path`
/// is under no SPA base (falls through to the regular static handler).
fn resolveSpaShell(spas: []const spa_mod.ServeSpa, path: []const u8) ?[]const u8 {
    for (spas) |sp| {
        if (!spaUnderBase(path, sp.base_url)) continue;
        // 1. exact static route
        for (sp.shells) |sh| {
            const u = sh.static_url orelse continue;
            if (std.mem.eql(u8, u, path)) return sh.out_path;
        }
        // 2. dynamic pattern
        for (sp.shells) |sh| {
            const pat = sh.dynamic_pattern orelse continue;
            if (spaMatchPattern(pat, path)) return sh.out_path;
        }
        // 3. namespace fallback (the "/" route's shell)
        return sp.fallback_rel;
    }
    return null;
}

pub const Debouncer = struct {
    cascade_window_ms: i64,

    io: Io,
    cascade_mutex: Io.Mutex = .init,
    cascade_condition: Io.Condition = .init,
    cascade_start_ms: i64 = 0,
    channel: *Channel(ServeEvent),

    /// Thread-safe. To be called when a new event comes in
    pub fn newEvent(d: *Debouncer) void {
        {
            d.cascade_mutex.lock(d.io) catch unreachable;
            defer d.cascade_mutex.unlock(d.io);
            d.cascade_start_ms = Io.Clock.awake.now(d.io).toMilliseconds();
        }
        d.cascade_condition.signal(d.io);
    }

    pub fn start(d: *Debouncer) !void {
        const t = try std.Thread.spawn(.{}, Debouncer.notify, .{d});
        t.detach();
    }

    pub fn notify(d: *Debouncer) !void {
        while (true) {
            try d.cascade_mutex.lock(d.io);
            defer d.cascade_mutex.unlock(d.io);

            while (d.cascade_start_ms == 0) {
                // no active cascade
                try d.cascade_condition.wait(d.io, &d.cascade_mutex);
            }
            // cascade != 0
            while (true) {
                const time_passed = Io.Clock.awake.now(d.io).toMilliseconds() - d.cascade_start_ms;
                if (time_passed >= d.cascade_window_ms) break;
                d.cascade_mutex.unlock(d.io);
                const sleep_ms = d.cascade_window_ms - time_passed;
                try d.io.sleep(.fromMilliseconds(sleep_ms), .awake);
                try d.cascade_mutex.lock(d.io);
            }

            // We have slept enough, "commit" the cascade window and
            // trigger a new build.
            d.cascade_start_ms = 0;
            try d.channel.put(d.io, .change);
        }
    }
};

// --- serve --proxy CLI parse tests --------------------------------------------
// Run via `zig build test-serve` (filter "serve"). These exercise only the
// SUCCESS/parsing paths: every malformed-input branch of parseProxyRule calls
// `fatal.msg`, which exits the process and so cannot be unit-tested here.

test "serve --proxy parses prefix + host + port" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{"--proxy=/api=http://127.0.0.1:8090"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cmd.proxies.len);
    try std.testing.expectEqualStrings("/api", cmd.proxies[0].prefix);
    try std.testing.expectEqualStrings("127.0.0.1", cmd.proxies[0].host);
    try std.testing.expectEqual(@as(u16, 8090), cmd.proxies[0].port);
}

test "serve --proxy host is an owned copy, never a borrow into argv (AUDF: hidden page_allocator)" {
    const gpa = std.testing.allocator;
    // parseProxyRule used to decode the host with std.heap.page_allocator — a
    // hidden global allocation (NO_SLOP 2.1) that Command.deinit never freed, so
    // `--proxy=/api=http://%6cocalhost:8090` leaked on every parse, invisibly to
    // std.testing.allocator. Now the caller's allocator owns the host and deinit
    // frees it, which requires the host to ALWAYS be an owned copy: the old code
    // returned a borrowed slice into argv whenever the host had no '%', and
    // freeing that would be a free of non-heap memory.
    //
    // Heap-allocate the argument so the borrow is observable by pointer identity.
    const arg = try gpa.dupe(u8, "--proxy=/api=http://127.0.0.1:8090");
    defer gpa.free(arg);
    const cmd = try Command.parse(gpa, &.{arg});
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("127.0.0.1", cmd.proxies[0].host);
    // The host must NOT point into `arg` (it did before the fix).
    const inside = @intFromPtr(cmd.proxies[0].host.ptr) >= @intFromPtr(arg.ptr) and
        @intFromPtr(cmd.proxies[0].host.ptr) < @intFromPtr(arg.ptr) + arg.len;
    try std.testing.expect(!inside);

    // A percent-encoded host decodes through the caller's allocator too; deinit
    // frees it, so std.testing.allocator reports no leak.
    const enc = try Command.parse(gpa, &.{"--proxy=/api=http://%6cocalhost:8090"});
    defer enc.deinit(gpa);
    try std.testing.expectEqualStrings("localhost", enc.proxies[0].host);
    try std.testing.expectEqual(@as(u16, 8090), enc.proxies[0].port);
}

test "serve --proxy defaults the port to 80 when omitted" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{"--proxy=/api=http://example.test"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cmd.proxies.len);
    try std.testing.expectEqualStrings("example.test", cmd.proxies[0].host);
    try std.testing.expectEqual(@as(u16, 80), cmd.proxies[0].port);
}

test "serve --proxy is repeatable and preserves order" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{
        "--proxy=/api=http://127.0.0.1:8090",
        "--proxy=/auth=http://127.0.0.1:9000",
    });
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), cmd.proxies.len);
    try std.testing.expectEqualStrings("/api", cmd.proxies[0].prefix);
    try std.testing.expectEqual(@as(u16, 8090), cmd.proxies[0].port);
    try std.testing.expectEqualStrings("/auth", cmd.proxies[1].prefix);
    try std.testing.expectEqual(@as(u16, 9000), cmd.proxies[1].port);
}

test "serve --proxy splits on the first '=' so upstream queries survive" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{"--proxy=/api=http://127.0.0.1:8090/base?k=v"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/api", cmd.proxies[0].prefix);
    try std.testing.expectEqualStrings("127.0.0.1", cmd.proxies[0].host);
    try std.testing.expectEqual(@as(u16, 8090), cmd.proxies[0].port);
}

test "serve --proxy accepts the spaced form" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{ "--proxy", "/api=http://127.0.0.1:8090" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cmd.proxies.len);
    try std.testing.expectEqualStrings("/api", cmd.proxies[0].prefix);
}

test "serve defaults proxies to empty" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), cmd.proxies.len);
}

test "serve parse recognizes --allow-missing-pages (and defaults it to false)" {
    // Mirrors src/cli/release.zig's identically-named test: `serve` gained
    // this flag with no unit test of its own. `test-serve` filters on the
    // string "serve" (build/tests.zig), so this name must contain it.
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{"--allow-missing-pages"});
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.allow_missing_pages);

    const cmd_default = try Command.parse(gpa, &.{});
    defer cmd_default.deinit(gpa);
    try std.testing.expect(!cmd_default.allow_missing_pages);
}

test "serve matchProxy picks the longest prefix at a segment boundary" {
    const rules = [_]ProxyRule{
        .{ .prefix = "/api", .host = "127.0.0.1", .port = 8090 },
        .{ .prefix = "/api/v2", .host = "127.0.0.1", .port = 9000 },
    };
    // exact prefix match
    try std.testing.expectEqual(@as(u16, 8090), matchProxy(&rules, "/api").?.port);
    // sub-path of /api
    try std.testing.expectEqual(@as(u16, 8090), matchProxy(&rules, "/api/users").?.port);
    // longest-prefix wins for /api/v2/*
    try std.testing.expectEqual(@as(u16, 9000), matchProxy(&rules, "/api/v2/thing").?.port);
    // segment boundary: /apiary must NOT match /api
    try std.testing.expect(matchProxy(&rules, "/apiary") == null);
    // unrelated path
    try std.testing.expect(matchProxy(&rules, "/static/app.js") == null);
}

test "serve parseStatusLine extracts code and reason" {
    {
        const code, const reason = try parseStatusLine("HTTP/1.1 200 OK");
        try std.testing.expectEqual(@as(u16, 200), code);
        try std.testing.expectEqualStrings("OK", reason);
    }
    {
        const code, const reason = try parseStatusLine("HTTP/1.1 204 No Content");
        try std.testing.expectEqual(@as(u16, 204), code);
        try std.testing.expectEqualStrings("No Content", reason);
    }
    {
        // Missing reason phrase is tolerated.
        const code, const reason = try parseStatusLine("HTTP/1.0 500");
        try std.testing.expectEqual(@as(u16, 500), code);
        try std.testing.expectEqualStrings("", reason);
    }
    try std.testing.expectError(error.MalformedStatusLine, parseStatusLine("garbage"));
}

// --- serve SPA route-matcher unit tests ---------------------------------------
// Pure functions (no I/O), so directly testable. Named "serve …" so the
// `test-serve` filter picks them up alongside the --proxy parse tests.

test "serve spaUnderBase respects segment boundaries and root mount" {
    try std.testing.expect(spaUnderBase("/app/", "/app"));
    try std.testing.expect(spaUnderBase("/app", "/app"));
    try std.testing.expect(spaUnderBase("/app/club/42", "/app"));
    try std.testing.expect(!spaUnderBase("/apple/", "/app")); // segment boundary
    try std.testing.expect(!spaUnderBase("/other", "/app"));
    try std.testing.expect(spaUnderBase("/anything/at/all", "")); // root mount
}

test "serve spaMatchPattern matches params and wildcards segment-wise" {
    try std.testing.expect(spaMatchPattern("/app/club/:id", "/app/club/42"));
    try std.testing.expect(spaMatchPattern("/app/club/:id", "/app/club/42/")); // trailing slash ignored
    try std.testing.expect(!spaMatchPattern("/app/club/:id", "/app/club/42/extra")); // too many segments
    try std.testing.expect(!spaMatchPattern("/app/club/:id", "/app/shop/42")); // literal mismatch
    try std.testing.expect(!spaMatchPattern("/app/club/:id", "/app/club")); // too few segments
    try std.testing.expect(spaMatchPattern("/app/admin/*", "/app/admin/users/roles")); // wildcard rest
    try std.testing.expect(spaMatchPattern("/app/admin/*", "/app/admin")); // trailing '*' matches zero-or-more (runtime parity)
    try std.testing.expect(spaMatchPattern("/app/admin/*", "/app/admin/")); // trailing slash -> still an empty remainder
    try std.testing.expect(!spaMatchPattern("/app/admin/*", "/app")); // the literal prefix must still be present
    try std.testing.expect(spaMatchPattern("/*", "/")); // '*' as the only segment, empty path
    try std.testing.expect(spaMatchPattern("/*", "/anything/here")); // and it consumes the rest
}

test "serve hasTraversalSegment rejects . and .. path segments (AUD-013/014)" {
    // Rejected: a `.`/`..` as a whole path segment, at any position. The guard
    // runs on the percent-DECODED path, so `%2e%2e` (which decodes to `..`)
    // is caught by the caller decoding first.
    try std.testing.expect(Server.hasTraversalSegment("/islands/../../secret/foo.js"));
    try std.testing.expect(Server.hasTraversalSegment("/../etc/passwd"));
    try std.testing.expect(Server.hasTraversalSegment("/a/b/.."));
    try std.testing.expect(Server.hasTraversalSegment(".."));
    try std.testing.expect(Server.hasTraversalSegment("/a/./b")); // a `.` segment too
    // Allowed: `..`/`.` as a SUBSTRING of a real segment is not traversal, so
    // a legitimate filename must not be rejected (no false-positive DoS —
    // AUD-014's `x..y`, `photo..jpg`).
    try std.testing.expect(!Server.hasTraversalSegment("/x..y"));
    try std.testing.expect(!Server.hasTraversalSegment("/img/photo..jpg"));
    try std.testing.expect(!Server.hasTraversalSegment("/islands/Counter.island.js"));
    try std.testing.expect(!Server.hasTraversalSegment("/"));
    try std.testing.expect(!Server.hasTraversalSegment("/a/b/c"));
    // Backslash is also a segment separator for the guard: a `..`/`.` delimited
    // by `\` (which the file-system APIs on non-POSIX platforms honor) must be
    // rejected too, so the guard can't be bypassed with `\`.
    try std.testing.expect(Server.hasTraversalSegment("/islands\\..\\..\\secret.js"));
    try std.testing.expect(Server.hasTraversalSegment("\\..\\etc\\passwd"));
    try std.testing.expect(Server.hasTraversalSegment("/a/b\\.."));
    // …but `..` as a substring of a real segment is still allowed with `\` too.
    try std.testing.expect(!Server.hasTraversalSegment("/img\\photo..jpg"));
}

test "serve resolveSpaShell picks static, then dynamic, then fallback" {
    const shells = [_]spa_mod.ServeShell{
        .{ .ssr_pathname = "/app/", .out_path = "app/index.html", .static_url = "/app/", .dynamic_pattern = null },
        .{ .ssr_pathname = "/app/settings/", .out_path = "app/settings/index.html", .static_url = "/app/settings/", .dynamic_pattern = null },
        .{ .ssr_pathname = "/app/club/_", .out_path = "app/club/_shell.html", .static_url = null, .dynamic_pattern = "/app/club/:id" },
    };
    const spas = [_]spa_mod.ServeSpa{.{
        .src = "app/App.spa.tsx",
        .base_url = "/app",
        .title = "App",
        .noindex = true,
        .head = null,
        .flags = null,
        .bundle_url = "/spa/App.js",
        .url_prefix = "",
        .shells = &shells,
        .fallback_rel = "app/index.html",
    }};

    // exact static routes
    try std.testing.expectEqualStrings("app/index.html", resolveSpaShell(&spas, "/app/").?);
    try std.testing.expectEqualStrings("app/settings/index.html", resolveSpaShell(&spas, "/app/settings/").?);
    // dynamic pattern
    try std.testing.expectEqualStrings("app/club/_shell.html", resolveSpaShell(&spas, "/app/club/42").?);
    // any other in-namespace path -> fallback (NOT null / 404)
    try std.testing.expectEqualStrings("app/index.html", resolveSpaShell(&spas, "/app/nope").?);
    try std.testing.expectEqualStrings("app/index.html", resolveSpaShell(&spas, "/app/deep/unknown/").?);
    // outside the namespace -> null (falls through to static handler)
    try std.testing.expect(resolveSpaShell(&spas, "/other/") == null);
    try std.testing.expect(resolveSpaShell(&spas, "/") == null);
}

test "serve resolveSpaShell root-mounted SPA owns every path" {
    const shells = [_]spa_mod.ServeShell{
        .{ .ssr_pathname = "/", .out_path = "index.html", .static_url = "/", .dynamic_pattern = null },
    };
    const spas = [_]spa_mod.ServeSpa{.{
        .src = "App.spa.tsx",
        .base_url = "", // root mount
        .title = "App",
        .noindex = true,
        .head = null,
        .flags = null,
        .bundle_url = "/spa/App.js",
        .url_prefix = "",
        .shells = &shells,
        .fallback_rel = "index.html",
    }};
    try std.testing.expectEqualStrings("index.html", resolveSpaShell(&spas, "/").?);
    try std.testing.expectEqualStrings("index.html", resolveSpaShell(&spas, "/anything/here").?);
}

test "serve root-mounted SPA: real files must be searched before the shell tiers" {
    // This precedence — real files beat every SPA shell tier — is the tier
    // ORDER in handleRequest: shell dispatch is the LAST resort, running only
    // after the site-asset, page-variant and build-asset searches all missed
    // (mirroring release: nginx `try_files $uri …`, Apache `!-f`, ZigBase
    // .spa-marker-on-miss). tests/serve/spa.sh proves that order end-to-end
    // (/app/real-asset.css returns the CSS, not the shell).
    //
    // This test pins WHY the ordering is load-bearing at root mount, where the
    // stakes are highest: base "" catches EVERY path, and resolveSpaShell has
    // (deliberately) no real-file knowledge, so it claims even sibling asset
    // paths — css, images, favicon — for the namespace fallback shell. If
    // either invariant changes (a file/extension guard creeps into the
    // resolver, or root mount stops catching asset paths), this fails and the
    // ordering contract must be revisited together with the e2e assertion.
    const shells = [_]spa_mod.ServeShell{
        .{ .ssr_pathname = "/", .out_path = "index.html", .static_url = "/", .dynamic_pattern = null },
        .{ .ssr_pathname = "/club/_", .out_path = "club/_shell.html", .static_url = null, .dynamic_pattern = "/club/:id" },
    };
    const spas = [_]spa_mod.ServeSpa{.{
        .src = "App.spa.tsx",
        .base_url = "", // root mount: spaUnderBase("", …) catches all
        .title = "App",
        .noindex = true,
        .head = null,
        .flags = null,
        .bundle_url = "/spa/App.js",
        .url_prefix = "",
        .shells = &shells,
        .fallback_rel = "index.html",
    }};
    // Sibling real-file paths resolve to the FALLBACK shell (tier 3)…
    try std.testing.expectEqualStrings("index.html", resolveSpaShell(&spas, "/css/site.css").?);
    try std.testing.expectEqualStrings("index.html", resolveSpaShell(&spas, "/favicon.ico").?);
    // …and a dynamic pattern claims asset-looking paths too (tier 2) — release
    // still serves the real file first (`try_files $uri` precedes the shell),
    // which is why the whole dispatch block sits after the real-file searches
    // rather than only guarding the fallback tier.
    try std.testing.expectEqualStrings("club/_shell.html", resolveSpaShell(&spas, "/club/logo.png").?);
}

// --- serve request-guard / bounded-proxy regression tests ---------------------

test "serve isUnservablePath rejects the paths PathTable aborts on (AUDF: curl kills the dev server)" {
    const gpa = std.testing.allocator;

    // (1) Component count. `PathTable.getPathNoName` prints a diagnostic and
    // calls std.process.exit(1) above 512 components, so a single
    //   curl "http://localhost:1990/$(printf 'a/%.0s' {1..514})"
    // used to terminate the whole dev server: the request is ~1 KB (inside
    // max_connection_header_size), carries no '.'/'..' segment so
    // hasTraversalSegment passes it, and then reaches PathName.get.
    var deep: std.ArrayListUnmanaged(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..514) |_| try deep.appendSlice(gpa, "/a");
    try std.testing.expect(Server.isUnservablePath(deep.items));

    // Exactly at the bound is still servable; one past it is not.
    var at_bound: std.ArrayListUnmanaged(u8) = .empty;
    defer at_bound.deinit(gpa);
    for (0..Server.max_path_components) |_| try at_bound.appendSlice(gpa, "/a");
    try std.testing.expect(!Server.isUnservablePath(at_bound.items));
    try at_bound.appendSlice(gpa, "/a");
    try std.testing.expect(Server.isUnservablePath(at_bound.items));

    // (2) Trailing "/\": PathName.get asserts !endsWith(src, "/\\") in Debug,
    // which is the default build, and a Debug assert aborts the process. The
    // traversal guard does not catch it — there is no '.'/'..' segment.
    try std.testing.expect(!Server.hasTraversalSegment("/foo/\\")); // guard misses it…
    try std.testing.expect(Server.isUnservablePath("/foo/\\")); // …this catches it
    try std.testing.expect(Server.isUnservablePath("/\\"));

    // Ordinary paths stay servable.
    try std.testing.expect(!Server.isUnservablePath("/"));
    try std.testing.expect(!Server.isUnservablePath("/a/b/c/index.html"));
    try std.testing.expect(!Server.isUnservablePath("/islands/Counter.island.js"));
    try std.testing.expect(!Server.isUnservablePath("/a\\b")); // a lone backslash is a legal byte
}

test "serve stripPathPrefix only strips at a segment boundary (AUDF: byte-offset rewrite)" {
    // The old `path = path[1 + len ..]` sliced at the prefix's BYTE length, so
    // "/docs../foo" (which has no exact ".." segment, hence passes the traversal
    // guard) was rewritten to "../foo" — a traversal the guard never re-runs on.
    try std.testing.expect(stripPathPrefix("/docs../foo", "docs") == null);
    try std.testing.expect(stripPathPrefix("/docsy/foo", "docs") == null);
    try std.testing.expect(stripPathPrefix("/docs.zip", "docs") == null);

    // Real matches keep their exact previous result.
    try std.testing.expectEqualStrings("/foo", stripPathPrefix("/docs/foo", "docs").?);
    try std.testing.expectEqualStrings("", stripPathPrefix("/docs", "docs").?);
    try std.testing.expectEqualStrings("/", stripPathPrefix("/docs/", "docs").?);
    // A prefix written with a trailing slash strips the same way.
    try std.testing.expectEqualStrings("/foo", stripPathPrefix("/docs/foo", "docs/").?);
    try std.testing.expect(stripPathPrefix("/docs", "docs/") == null);
    // Not under the prefix at all.
    try std.testing.expect(stripPathPrefix("/other/foo", "docs") == null);
    // Empty prefix (the single-variant case) matches everything and only strips
    // the leading '/', exactly like the `path[1..]` it replaces.
    try std.testing.expectEqualStrings("foo/bar", stripPathPrefix("/foo/bar", "").?);
    try std.testing.expectEqualStrings("", stripPathPrefix("/", "").?);
    // A target that is not origin-form has nothing to strip.
    try std.testing.expect(stripPathPrefix("*", "docs") == null);
    try std.testing.expect(stripPathPrefix("", "docs") == null);
}

test "serve spaShellIsServable guards the one unguarded file sink (AUDF: SPA shell)" {
    // sh.out_path / sp.fallback_rel reached readFileAlloc without ever passing
    // through hasTraversalSegment — the only one of the request-reachable file
    // sinks that was unguarded.
    try std.testing.expect(!spaShellIsServable("../../etc/passwd"));
    try std.testing.expect(!spaShellIsServable("app/../../secret.html"));
    try std.testing.expect(!spaShellIsServable("app/./index.html"));
    // sendFile asserts file_path[0] != '/' and indexes file_path[0], so an
    // absolute or empty shell path would abort the server before it ever read.
    try std.testing.expect(!spaShellIsServable("/etc/passwd"));
    try std.testing.expect(!spaShellIsServable("\\etc\\passwd"));
    try std.testing.expect(!spaShellIsServable(""));
    // The real shapes the SPA route table produces stay servable.
    try std.testing.expect(spaShellIsServable("index.html"));
    try std.testing.expect(spaShellIsServable("app/index.html"));
    try std.testing.expect(spaShellIsServable("app/club/_shell.html"));
}

test "serve proxy request-body cap fits a retained per-connection arena (AUDF: 256 MiB OOM)" {
    // handleConnection recycles the per-connection arena with `.retain_capacity`,
    // so whatever a connection buffered at peak stays resident for that
    // connection's life. With --proxy on, any page the developer has open can
    // POST a CORS-simple `text/plain` body (no preflight, the body IS sent) of
    // this size, so N keep-alive connections pin N × the cap: at the old
    // 256 MiB, ten connections were 2.5 GB.
    try std.testing.expect(Server.max_proxy_request_body <= 8 * 1024 * 1024);
}

test "serve readUpstreamHead parses a normal response head" {
    const gpa = std.testing.allocator;
    var r = std.Io.Reader.fixed(
        "HTTP/1.1 200 OK\r\n" ++
            "content-type: application/json\r\n" ++
            "set-cookie: a=b\r\n" ++
            "content-length: 17\r\n" ++
            "connection: close\r\n" ++ // hop-by-hop: dropped
            "\r\n",
    );
    const head = try Server.readUpstreamHead(gpa, &r);
    defer head.deinit(gpa);

    try std.testing.expectEqual(@as(u16, 200), head.status_code);
    try std.testing.expectEqualStrings("OK", head.reason);
    try std.testing.expectEqual(@as(?u64, 17), head.content_length);
    try std.testing.expect(!head.chunked);
    try std.testing.expectEqual(@as(usize, 2), head.headers.len);
    try std.testing.expectEqualStrings("content-type", head.headers[0].name);
    try std.testing.expectEqualStrings("application/json", head.headers[0].value);
    try std.testing.expectEqualStrings("set-cookie", head.headers[1].name);
}

test "serve readUpstreamHead notes chunked framing and skips one interim response" {
    const gpa = std.testing.allocator;
    var r = std.Io.Reader.fixed(
        "HTTP/1.1 100 Continue\r\n\r\n" ++
            "HTTP/1.1 200 OK\r\n" ++
            "transfer-encoding: chunked\r\n" ++
            "content-type: text/event-stream\r\n" ++
            "\r\n",
    );
    const head = try Server.readUpstreamHead(gpa, &r);
    defer head.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), head.status_code);
    try std.testing.expect(head.chunked);
    try std.testing.expectEqual(@as(?u64, null), head.content_length);
    try std.testing.expectEqual(@as(usize, 1), head.headers.len);
}

test "serve readUpstreamHead bounds the relayed header block (AUDF: unbounded arena growth)" {
    const gpa = std.testing.allocator;
    // The relay loop had no byte or count cap, so an upstream streaming header
    // lines forever grew the per-connection arena until OOM — while the CLIENT
    // head is bounded by std at max_connection_header_size. Mirror that bound.
    var src: Writer.Allocating = .init(gpa);
    defer src.deinit();
    try src.writer.writeAll("HTTP/1.1 200 OK\r\n");
    // ~90 bytes per line; 200 lines is ~18 KiB, well past the 8 KiB bound.
    for (0..200) |i| {
        try src.writer.print("x-pad-{d}: {s}\r\n", .{ i, "0123456789" ** 8 });
    }
    try src.writer.writeAll("\r\n");

    var r = std.Io.Reader.fixed(src.written());
    try std.testing.expectError(
        error.HeadersTooLarge,
        Server.readUpstreamHead(gpa, &r),
    );
}

test "serve readUpstreamHead bounds the header COUNT as well as the bytes" {
    const gpa = std.testing.allocator;
    // Many short header lines stay under the byte bound but must still be
    // capped, so the relayed `extra_headers` slice cannot grow without limit.
    var src: Writer.Allocating = .init(gpa);
    defer src.deinit();
    try src.writer.writeAll("HTTP/1.1 200 OK\r\n");
    for (0..Server.max_upstream_header_count + 5) |i| {
        try src.writer.print("h{d}:v\r\n", .{i});
    }
    try src.writer.writeAll("\r\n");

    var r = std.Io.Reader.fixed(src.written());
    try std.testing.expectError(
        error.TooManyHeaders,
        Server.readUpstreamHead(gpa, &r),
    );
}

test "serve readUpstreamHead bounds 1xx interim responses (AUDF: pinned connection thread)" {
    const gpa = std.testing.allocator;
    // The interim-skip loop was unbounded: an upstream streaming
    // `HTTP/1.1 100 Continue` forever pinned a connection thread for good.
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(gpa);
    for (0..Server.max_upstream_interim_responses + 3) |_| {
        try src.appendSlice(gpa, "HTTP/1.1 100 Continue\r\n\r\n");
    }
    try src.appendSlice(gpa, "HTTP/1.1 200 OK\r\n\r\n");

    var r = std.Io.Reader.fixed(src.items);
    try std.testing.expectError(
        error.TooManyInterimResponses,
        Server.readUpstreamHead(gpa, &r),
    );

    // One below the bound still resolves to the real response.
    var ok_src: std.ArrayListUnmanaged(u8) = .empty;
    defer ok_src.deinit(gpa);
    for (0..Server.max_upstream_interim_responses) |_| {
        try ok_src.appendSlice(gpa, "HTTP/1.1 100 Continue\r\n\r\n");
    }
    try ok_src.appendSlice(gpa, "HTTP/1.1 204 No Content\r\n\r\n");
    var ok_r = std.Io.Reader.fixed(ok_src.items);
    const head = try Server.readUpstreamHead(gpa, &ok_r);
    defer head.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 204), head.status_code);
}

test "serve readUpstreamHead rejects a truncated or out-of-range head" {
    const gpa = std.testing.allocator;
    {
        var r = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\n" ++ "content-type: text/html\r\n");
        try std.testing.expectError(error.Truncated, Server.readUpstreamHead(gpa, &r));
    }
    {
        // 999 would panic `@enumFromInt` on std.http.Status (u10) downstream.
        var r = std.Io.Reader.fixed("HTTP/1.1 9999 Nope\r\n\r\n");
        try std.testing.expectError(error.StatusOutOfRange, Server.readUpstreamHead(gpa, &r));
    }
    {
        var r = std.Io.Reader.fixed("garbage\r\n\r\n");
        try std.testing.expectError(error.MalformedStatusLine, Server.readUpstreamHead(gpa, &r));
    }
}
