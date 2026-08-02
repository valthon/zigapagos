//! `zigapagos dev` — the zigbase-backed local dev loop.
//!
//! The STOCK ZigBase binary is THE server for local development: zigapagos
//! does no HTTP serving of its own. `dev` serves the site's real RELEASE
//! output tree with the real backend on the same origin, so what you develop
//! against is what production serves (real `/api`, admin UI at `/_/`,
//! `.spa`-marker fallback).
//!
//! It is ZERO-CONFIG by design — `zigapagos dev` with no arguments has to work
//! in a site directory that contains nothing but content, layouts and a
//! `zigapagos.ziggy`. Every default below exists to make that true, and each
//! one is still overridable by the corresponding flag.
//!
//! Orchestration:
//!
//!   1. run the rebuild command once (default: THIS binary's own `release`,
//!      resolved by absolute path — see `defaultRebuildArgv`),
//!   2. locate zigbase (explicit path → PATH → pinned cache) and, when nothing
//!      resolves, fetch the pinned release into the cache (`zigbase.zig`;
//!      `--no-download` turns that off), then boot it over the release tree
//!      (`e2e.zig`'s boot machinery: shared invocation template, readiness
//!      probe, teardown-owning harness),
//!   3. the data dir is PERSISTENT (default `.zigbase/` under the site root,
//!      gitignore it): collections/auth state survive across dev sessions,
//!   4. watch the site's inputs (assets + layouts + content (+ i18n/locales),
//!      plus the island/SPA source dirs — discovered when no `--watch-dir=` is
//!      given) via the per-OS watcher + debouncer,
//!   5. on change, re-run the rebuild command into the served tree; a failing
//!      rebuild keeps serving the last good tree and keeps watching. Changes
//!      are classified: a pure content-page edit — or an island-source edit
//!      resolvable through the dev island-usage manifest — re-renders only
//!      the affected pages (`ZIGAPAGOS_CHANGED_FILES`); everything else falls
//!      back to a full rebuild.
//!
//! Live reload (DEV-ONLY): zigbase serves the static tree verbatim and never
//! injects anything, so browser auto-reload runs as a SIDE CHANNEL owned by
//! this loop (`reload.zig`): a tiny SSE server on its own port, plus a small
//! `<script>` injected into every served `.html` after each build that opens
//! an `EventSource` and reloads on a rebuild. The snippet is added only to the
//! *installed* tree post-build, so `zigapagos release` output stays
//! clean. Disable with `--no-live-reload` (release-fidelity testing). When a
//! change is classified as island-only, the SSE channel broadcasts an island
//! hot-swap instead of a full reload, and — because dev builds bundle islands
//! with the fast-refresh transform (`hot_islands_env`) — plain
//! `useState`/`useReducer` state survives the swap when the component's hook
//! signature is unchanged.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const zigbase = @import("zigbase.zig");
const e2e = @import("e2e.zig");
const release_cli = @import("release.zig");
const reload = @import("reload.zig");
const islands_manifest = @import("../islands/manifest.zig");
const RenderArena = @import("../islands/render_arena.zig").RenderArena;
const Channel = @import("../channel.zig").Channel;
const watcher_mod = @import("watcher.zig");
const Debouncer = watcher_mod.Debouncer;
const Event = watcher_mod.Event;
const Watcher = watcher_mod.Watcher;

/// Default site tree: `zigapagos release`'s own default output directory, so
/// `zigapagos dev` with no flags rebuilds and serves the same tree a bare
/// `zigapagos release` writes. Overridable with `--site=DIR`.
pub const default_site = "public";

/// Default (PERSISTENT) ZigBase data dir, resolved under the site root (the
/// directory containing zigapagos.ziggy). Collections/auth state persist
/// across dev sessions; delete the directory for a fresh backend.
pub const default_data_dir = ".zigbase";

/// Fast-refresh island bundles. The dev loop sets this in the rebuild
/// command's environment (unless `--no-live-reload`, which is for
/// release-fidelity testing) and the rebuild reads it: `zigapagos release`
/// through `hotIslands` (release.zig, which owns the name). The island bundle
/// driver then gets `--hot`, so its components route through the hot
/// registry and a hot-swap preserves plain `useState` state. A rebuild that
/// does not inherit this environment never sees the variable, so plain release
/// bundles stay byte-identical.
pub const hot_islands_env = release_cli.hot_islands_env;

/// Default dev invocation: the shared `zigbase serve` template plus
/// `--insecure-cookies` — the dev loop serves plain `http://`, where ZigBase's
/// secure-by-default auth cookies would otherwise never round-trip.
pub const default_zigbase_args: []const []const u8 =
    e2e.default_zigbase_args ++ &[_][]const u8{"--insecure-cookies"};

pub const Command = struct {
    /// The built site tree zigbase serves (`--site=DIR`; defaults to
    /// `default_site`, matching `zigapagos release`'s own default output).
    site: []const u8,
    /// ZigBase data dir (`--data-dir=DIR`). PERSISTENT — never deleted by the
    /// dev loop. Relative paths resolve against the site root.
    data_dir: []const u8,
    /// Explicit binary (`--zigbase=PATH`); null = PATH, then the pinned cache.
    zigbase_path: ?[]const u8,
    /// `--no-download`: when the locator finds nothing, FAIL with instructions
    /// instead of fetching the pinned release into the cache. The escape hatch
    /// for offline/air-gapped machines and for CI that pins its own binary;
    /// the default is to fetch, because a dev loop that stops to explain how
    /// to install a server is not zero-config.
    no_download: bool,
    /// Invocation template (`--zigbase-arg=`, repeatable; replaces the whole
    /// default template when at least one is given).
    zigbase_args: []const []const u8,
    /// Readiness probe path (`--ready-path=`, default "/").
    ready_path: []const u8,
    /// Readiness budget in milliseconds (`--timeout-ms=`, default 120s).
    timeout_ms: u32,
    /// Listen host (`--host=`, default 127.0.0.1). Must be an IP literal —
    /// the readiness probe connects to it directly (no DNS).
    host: []const u8,
    /// Listen port (`--port=`, default 1990; 0 = pick a free port).
    port: u16,
    /// Watch-cascade quiet window in ms (`--debounce=`, default 25).
    debounce: u16,
    /// Browser live reload. On by default; `--no-live-reload`
    /// disables the SSE side channel + snippet injection (release-fidelity
    /// testing).
    live_reload: bool,
    /// SSE reload-server port (`--reload-port=`, default 0 = pick a free port).
    /// Ignored when `live_reload` is false.
    reload_port: u16,
    /// Extra directories to watch (`--watch-dir=`, repeatable), resolved
    /// against the site root. Empty means "derive them from the island/SPA
    /// sources found under the site root" (see `discoverWatchDirs`).
    watch_dirs: []const []const u8,
    /// The rebuild command (everything after `--`). Null until `defaultRebuildArgv`
    /// fills it in, which needs `io` and so cannot happen during `parse`.
    rebuild_argv: ?[]const []const u8,

    /// Frees what `parse` allocated (unit tests only; the dev loop runs until
    /// the process is killed).
    pub fn deinit(cmd: *const Command, gpa: Allocator) void {
        if (cmd.zigbase_args.ptr != default_zigbase_args.ptr) gpa.free(cmd.zigbase_args);
        if (cmd.rebuild_argv) |argv| gpa.free(argv);
        gpa.free(cmd.watch_dirs);
    }

    pub fn parse(gpa: Allocator, args: []const []const u8) error{OutOfMemory}!Command {
        var site: []const u8 = default_site;
        var data_dir: []const u8 = default_data_dir;
        var zigbase_path: ?[]const u8 = null;
        var no_download = false;
        var zigbase_args: std.ArrayListUnmanaged([]const u8) = .empty;
        var ready_path: []const u8 = "/";
        var timeout_ms: u32 = 120_000;
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 1990;
        var debounce: u16 = 25;
        var live_reload = true;
        var reload_port: u16 = 0;
        var watch_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        var rebuild_argv: ?[]const []const u8 = null;
        errdefer zigbase_args.deinit(gpa);
        errdefer watch_dirs.deinit(gpa);
        errdefer if (rebuild_argv) |argv| gpa.free(argv);

        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.startsWith(u8, arg, "--site=")) {
                site = arg["--site=".len..];
                if (site.len == 0) fatal.usageError(
                    "error: --site must not be empty\n",
                    .{},
                );
            } else if (std.mem.startsWith(u8, arg, "--data-dir=")) {
                data_dir = arg["--data-dir=".len..];
                if (data_dir.len == 0) fatal.usageError(
                    "error: --data-dir must not be empty\n",
                    .{},
                );
            } else if (std.mem.startsWith(u8, arg, "--zigbase=")) {
                zigbase_path = arg["--zigbase=".len..];
            } else if (std.mem.eql(u8, arg, "--no-download")) {
                no_download = true;
            } else if (std.mem.startsWith(u8, arg, "--zigbase-arg=")) {
                try zigbase_args.append(gpa, arg["--zigbase-arg=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--ready-path=")) {
                ready_path = arg["--ready-path=".len..];
                if (ready_path.len == 0 or ready_path[0] != '/') fatal.usageError(
                    "error: --ready-path must start with '/' (got '{s}')\n",
                    .{ready_path},
                );
            } else if (std.mem.startsWith(u8, arg, "--timeout-ms=")) {
                const v = arg["--timeout-ms=".len..];
                timeout_ms = std.fmt.parseInt(u32, v, 10) catch |err| fatal.usageError(
                    "error: bad --timeout-ms value '{s}': {s}\n",
                    .{ v, @errorName(err) },
                );
            } else if (std.mem.startsWith(u8, arg, "--host=")) {
                host = arg["--host=".len..];
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const v = arg["--port=".len..];
                port = std.fmt.parseInt(u16, v, 10) catch |err| fatal.usageError(
                    "error: bad --port value '{s}': {s}\n",
                    .{ v, @errorName(err) },
                );
            } else if (std.mem.startsWith(u8, arg, "--debounce=")) {
                const v = arg["--debounce=".len..];
                debounce = std.fmt.parseInt(u16, v, 10) catch |err| fatal.usageError(
                    "error: bad --debounce value '{s}': {s}\n",
                    .{ v, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--no-live-reload")) {
                live_reload = false;
            } else if (std.mem.startsWith(u8, arg, "--reload-port=")) {
                const v = arg["--reload-port=".len..];
                reload_port = std.fmt.parseInt(u16, v, 10) catch |err| fatal.usageError(
                    "error: bad --reload-port value '{s}': {s}\n",
                    .{ v, @errorName(err) },
                );
            } else if (std.mem.startsWith(u8, arg, "--watch-dir=")) {
                const d = arg["--watch-dir=".len..];
                if (d.len == 0) fatal.usageError(
                    "error: --watch-dir must not be empty\n",
                    .{},
                );
                try watch_dirs.append(gpa, d);
            } else if (std.mem.eql(u8, arg, "--")) {
                // Everything after `--` is the rebuild command, verbatim.
                if (args.len - (idx + 1) > 0)
                    rebuild_argv = try gpa.dupe([]const u8, args[idx + 1 ..]);
                break;
            } else fatal.usageError(
                "error: unexpected 'zigapagos dev' argument '{s}'\n" ++ usage,
                .{arg},
            );
        }

        const owned_zigbase_args = if (zigbase_args.items.len > 0)
            try zigbase_args.toOwnedSlice(gpa)
        else
            default_zigbase_args;
        errdefer if (owned_zigbase_args.ptr != default_zigbase_args.ptr)
            gpa.free(owned_zigbase_args);
        const owned_watch_dirs = try watch_dirs.toOwnedSlice(gpa);
        errdefer gpa.free(owned_watch_dirs);

        return .{
            .site = site,
            .data_dir = data_dir,
            .zigbase_path = zigbase_path,
            .no_download = no_download,
            .zigbase_args = owned_zigbase_args,
            .ready_path = ready_path,
            .timeout_ms = timeout_ms,
            .host = host,
            .port = port,
            .debounce = debounce,
            .live_reload = live_reload,
            .reload_port = reload_port,
            .watch_dirs = owned_watch_dirs,
            .rebuild_argv = rebuild_argv,
        };
    }

    const usage =
        "usage: zigapagos dev [--site=DIR] [--data-dir=DIR] [--zigbase=PATH]\n" ++
        "                     [--no-download] [--zigbase-arg=ARG]...\n" ++
        "                     [--host=IP] [--port=N] [--ready-path=/…]\n" ++
        "                     [--timeout-ms=N] [--debounce=MS]\n" ++
        "                     [--no-live-reload] [--reload-port=N]\n" ++
        "                     [--watch-dir=DIR]... [-- REBUILD-CMD [ARGS...]]\n" ++
        "\n" ++
        "Every option has a working default: with no arguments, dev rebuilds\n" ++
        "with 'zigapagos release --output=public --force', serves 'public' with\n" ++
        "zigbase (downloading the pinned release only if none is on PATH, in\n" ++
        "--zigbase= or already cached — pass --no-download to fail instead),\n" ++
        "and watches the site's content/layout/asset dirs plus the directories\n" ++
        "holding its *.island.tsx / *.spa.tsx sources.\n";
};

pub fn dev(
    io: Io,
    gpa: Allocator,
    args: []const []const u8,
    environ_map: *std.process.Environ.Map,
) error{OutOfMemory}!noreturn {
    if (builtin.single_threaded) {
        std.debug.print(
            "error: single-threaded zigapagos does not support the dev loop (the file watcher needs threads), sorry\n\n",
            .{},
        );
        fatal.helpError();
    }

    const cmd: Command = try .parse(gpa, args);

    // The first `dev:` line -- not the process's first output, which may be
    // main.zig's Debug/tracy/tsan banners. It comes after parse, matching
    // e2e.zig, so that a usage error is not preceded by a startup line for a
    // session that never starts.
    //
    // Everything from here to `dev: initial build:` below -- watch-dir
    // discovery, path resolution, the inside-a-watched-dir guards -- used to be
    // silent, so a dev that died or wedged in that window produced a log with
    // nothing in it at all. CI hit exactly that: a crash signature appeared in
    // dev's log with no dev output above it, and the absence of any startup
    // line made it impossible to tell whether dev had crashed, hung, or never
    // really started. Three diagnoses began from the wrong end.
    //
    // Parsing first costs nothing diagnostically: `parse` only reads argv and
    // fatals on bad input, so it is not where a hang lives. The work that can
    // is all below.
    //
    // The pid is here for the same reason as the line itself. dev spawns
    // children (the rebuild, then zigbase); when one of them dies, the reader's
    // first question is whether the corpse is dev or something dev started, and
    // a log that names dev's own pid answers it without guessing.
    std.debug.print("dev: starting (pid {d})\n", .{std.c.getpid()});

    // Input discovery: assets, layouts, content and i18n + per-locale content,
    // anchored at the site root — plus the island/SPA source dirs, either given
    // as --watch-dir or discovered below.
    const cfg, const base_dir_path = root.Config.load(io, gpa);
    var dirs_to_watch: std.ArrayListUnmanaged([:0]const u8) = .empty;

    // Incremental rebuild classification. The watcher itself
    // only signals "something changed"; on each signal we re-derive WHICH files
    // changed by walking these roots and comparing mtimes to the last build.
    //   - `content_roots`: page-content directories. A changed *page* file here
    //     (`.md`/`.smd`/`.markdown`) can be re-rendered in isolation.
    //   - `other_roots`: layouts, assets, and i18n — a change to ANY of these
    //     can affect arbitrarily many pages (a shared layout), so it forces a
    //     full rebuild.
    //   - `island_roots`: the island/SPA source dirs.
    //     A changed file here is resolved through the dev island-usage manifest
    //     (written by every disk build) to the exact set of pages mounting it;
    //     any file the manifest doesn't know (a helper module, a SPA source, a
    //     brand-new island) forces a full rebuild instead.
    // A change fully localizable to content pages and/or manifest-known island
    // sources is the incremental fast path; everything else falls back to the
    // rebuild.
    var content_roots: std.ArrayListUnmanaged(ContentRoot) = .empty;
    var other_roots: std.ArrayListUnmanaged([]const u8) = .empty;
    var island_roots: std.ArrayListUnmanaged(ContentRoot) = .empty;
    try appendOtherRoot(gpa, &other_roots, base_dir_path, cfg.getAssetsDirPath());
    try appendOtherRoot(gpa, &other_roots, base_dir_path, cfg.getLayoutsDirPath());
    try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, cfg.getAssetsDirPath());
    try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, cfg.getLayoutsDirPath());
    // The data dir belongs in `other_roots`, not `content_roots`: `$site.data(…)`
    // is readable from any layout, so one edit can affect arbitrarily many pages
    // and must force a full rebuild. It was in neither list, so a data edit
    // produced no rebuild at all and the preview silently served stale values.
    //
    // Gated on existence: `data_dir_path` defaults to "data" whether or not the
    // site has one, `Build.loadSiteData` treats a missing dir as "no data", and the
    // accessibility pre-check below fatals on an unwatchable dir — so appending it
    // unconditionally would break `dev` for every site without a data dir.
    {
        const data_abs = std.fs.path.join(gpa, &.{ base_dir_path, cfg.getDataDirPath() }) catch fatal.oom();
        defer gpa.free(data_abs);
        if (Io.Dir.cwd().access(io, data_abs, .{})) |_| {
            try appendOtherRoot(gpa, &other_roots, base_dir_path, cfg.getDataDirPath());
            try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, cfg.getDataDirPath());
        } else |_| {}
    }
    switch (cfg) {
        .Site => |s| {
            try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, s.content_dir_path);
            try appendContentRoot(gpa, &content_roots, base_dir_path, s.content_dir_path);
        },
        .Multilingual => |ml| {
            try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, ml.i18n_dir_path);
            try appendOtherRoot(gpa, &other_roots, base_dir_path, ml.i18n_dir_path);
            for (ml.locales) |l| {
                try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, l.content_dir_path);
                try appendContentRoot(gpa, &content_roots, base_dir_path, l.content_dir_path);
            }
        },
    }
    // Zero-config island/SPA watching. With no explicit --watch-dir, derive the
    // dirs from the entries `zigapagos release` will itself discover, so editing
    // a component rebuilds without the user having to enumerate anything.
    //
    // The DERIVED dirs are the entries' PARENT directories, never the scan root
    // ("." — see `discoverWatchDirs`): the output tree lives under the scan root,
    // so watching it would make every rebuild retrigger the watcher forever. The
    // output-tree-inside-a-watched-dir guard below is the backstop, but it
    // FATALS, and turning `zigapagos dev` into an immediate error in the default
    // layout is not an acceptable way to discover that.
    const derived_watch_dirs: []const []const u8 = if (cmd.watch_dirs.len > 0)
        cmd.watch_dirs
    else
        try discoverWatchDirs(io, gpa, base_dir_path);
    for (derived_watch_dirs) |d| {
        try appendWatchDir(gpa, &dirs_to_watch, base_dir_path, d);
        try appendContentRoot(gpa, &island_roots, base_dir_path, d);
    }

    for (dirs_to_watch.items) |d| {
        Io.Dir.cwd().access(io, d, .{}) catch |err| fatal.msg(
            "error: dev: watch dir '{s}' is not accessible: {s}\n",
            .{ d, @errorName(err) },
        );
    }

    // The served tree and the data dir must live OUTSIDE every watched dir,
    // or each rebuild / db write would retrigger the watcher forever.
    const site_abs = std.fs.path.resolve(gpa, &.{ base_dir_path, cmd.site }) catch fatal.oom();
    const data_dir_abs = std.fs.path.resolve(gpa, &.{ base_dir_path, cmd.data_dir }) catch fatal.oom();
    for (dirs_to_watch.items) |d| {
        if (pathIsInside(d, site_abs)) fatal.msg(
            "error: dev: the output tree '{s}' is inside the watched dir '{s}' — every rebuild would retrigger the watcher.\n" ++
                "hint: point --site at a directory outside your content/layout/asset/watch dirs (e.g. zig-out/site)\n",
            .{ site_abs, d },
        );
        if (pathIsInside(d, data_dir_abs)) fatal.msg(
            "error: dev: the zigbase data dir '{s}' is inside the watched dir '{s}' — every db write would retrigger a rebuild.\n" ++
                "hint: keep the default .zigbase/ at the site root, or pass --data-dir=<dir outside watched dirs>\n",
            .{ data_dir_abs, d },
        );
    }

    // Persistent data dir — created BEFORE the initial build (not in the boot
    // section below) so the very first build can already write the island
    // manifest into it.
    Io.Dir.cwd().createDirPath(io, data_dir_abs) catch |err| fatal.msg(
        "error: dev: unable to create the data dir '{s}': {s}\n",
        .{ data_dir_abs, @errorName(err) },
    );

    // Dev-only island-usage manifest, kept in the persistent
    // (unwatched) data dir. Set once for the whole session: EVERY disk build
    // (initial, full, incremental) refreshes it, and classifyChange reads it
    // to map island-source edits to the pages that mount them.
    const island_manifest_path = std.fs.path.join(
        gpa,
        &.{ data_dir_abs, "islands-manifest.json" },
    ) catch fatal.oom();
    environ_map.put(release_cli.island_manifest_env, island_manifest_path) catch fatal.oom();

    // Build island bundles with the fast-refresh transform for the
    // whole dev session, so the very first page load registers each entry's
    // components in the hot registry and a later island hot-swap preserves
    // plain useState/useReducer state. Skipped with --no-live-reload: that
    // flag exists for release-fidelity testing, where bundles must match
    // release output (and no SSE channel exists to hot-swap through anyway).
    if (cmd.live_reload) environ_map.put(hot_islands_env, "1") catch fatal.oom();

    // (1) Initial build, so the tree exists before zigbase boots.
    // Held for the process lifetime: `dev` is noreturn, so there is nothing to
    // free it back to (see `Argv`'s contract note).
    const rebuild_argv: []const []const u8 = cmd.rebuild_argv orelse
        (try defaultRebuildArgv(io, gpa, cmd.site)).items;

    std.debug.print("dev: initial build:", .{});
    for (rebuild_argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});
    // Wall-clock mtime cutoff for change detection: captured BEFORE
    // a build so the next change sees every file edited after it started. The
    // initial build is always full (no `changed_files` env), which stages the
    // whole tree that later incremental rebuilds patch in place.
    var last_build_ns: i128 = @intCast(Io.Clock.real.now(io).nanoseconds);
    if (!runRebuild(io, rebuild_argv, environ_map)) fatal.msg(
        "error: dev: the initial build failed (see output above); fix it and rerun\n",
        .{},
    );
    // AUD-017 baseline: the watched-file count right after the initial (full)
    // build. `classifyChange` compares each later walk against it to notice a
    // pure delete/rename the time scan can't localize, then refreshes it.
    // An unwalkable root leaves the baseline UNKNOWN; seeding it with maxInt
    // then makes the next classification see a decrease and rebuild fully,
    // which also replaces the baseline with a real count — conservative and
    // self-healing, where a 0 baseline would silently disable the check.
    var watched_file_count: usize = countWatchedFiles(
        io,
        gpa,
        content_roots.items,
        other_roots.items,
        island_roots.items,
    ) orelse std.math.maxInt(usize);
    Io.Dir.cwd().access(io, site_abs, .{}) catch fatal.msg(
        "error: dev: the build succeeded but '{s}' does not exist.\n" ++
            "hint: --site must match the rebuild command's output path\n",
        .{site_abs},
    );

    // Live-reload side channel, DEV-ONLY. Bring up the SSE server on
    // its own port and inject the reload snippet into the freshly-built tree.
    // `zigapagos release` never runs this, so release output stays clean;
    // `--no-live-reload` skips the whole thing.
    var reload_server: ?*reload.Server = null;
    var reload_port: u16 = 0;
    if (cmd.live_reload) {
        reload_port = if (cmd.reload_port == 0) e2e.pickFreePort(io) else cmd.reload_port;
        const reload_addr = Io.net.IpAddress.parse(cmd.host, reload_port) catch fatal.msg(
            "error: dev: --host must be an IP literal for the live-reload server (got '{s}')\n",
            .{cmd.host},
        );
        const srv = gpa.create(reload.Server) catch fatal.oom();
        srv.* = .init(io, gpa, reload_addr);
        srv.start() catch |err| fatal.msg(
            "error: dev: unable to start the live-reload server: {s}\n",
            .{@errorName(err)},
        );
        // Initial build re-emitted the whole tree: inject everything (null).
        reload.injectTree(io, gpa, site_abs, reload_port, null);
        reload_server = srv;
    }

    // (2) Locate zigbase (explicit → PATH → pinned cache) and, when nothing is
    // found, fetch the pinned release into the cache (SHA256-verified).
    //
    // Fetching is the DEFAULT here, unlike `e2e`. `dev` is the zero-config
    // entry point and its server is not optional: refusing to start until the
    // user has installed a second binary they were never told about is the
    // failure mode this default exists to remove. `--no-download` restores the
    // strict behaviour for offline/air-gapped machines and for CI that pins
    // its own binary; nothing is fetched when zigbase already resolves.
    const located: zigbase.Located = (try zigbase.locate(io, gpa, environ_map, cmd.zigbase_path)) orelse blk: {
        if (cmd.no_download) {
            const msg = try zigbase.missingMessage(gpa, environ_map);
            std.debug.print("{s}", .{msg});
            std.process.exit(1);
        }
        std.debug.print(
            "dev: no zigbase found — fetching the pinned {s} release (pass --no-download to fail instead)\n",
            .{zigbase.pinned_version},
        );
        break :blk .{
            .path = try zigbase.download(io, gpa, environ_map),
            .source = .cache,
        };
    };

    // (3) Port (the persistent data dir was created before the initial build).
    const port = if (cmd.port == 0) e2e.pickFreePort(io) else cmd.port;
    var port_buf: [5]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
    const address = Io.net.IpAddress.parse(cmd.host, port) catch fatal.msg(
        "error: dev: --host must be an IP literal the readiness probe can connect to (got '{s}')\n",
        .{cmd.host},
    );

    // (4) Boot `zigbase serve` over the release tree.
    var zb_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try zb_argv.append(gpa, located.path);
    for (cmd.zigbase_args) |template| try zb_argv.append(
        gpa,
        try e2e.substituteArg(gpa, template, cmd.host, port_str, site_abs, data_dir_abs),
    );

    std.debug.print("dev: zigbase = {s} ({s}); serving {s}\ndev: exec", .{
        located.path, @tagName(located.source), site_abs,
    });
    for (zb_argv.items) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});

    var harness: e2e.Harness = .{
        .io = io,
        .gpa = gpa,
        .label = "dev",
        // stdio inherit (the spawn default): zigbase's own log streams through.
        .server = std.process.spawn(io, .{ .argv = zb_argv.items }) catch |err| fatal.msg(
            "error: dev: failed to spawn zigbase ({s}): {s}\n",
            .{ located.path, @errorName(err) },
        ),
        // Persistent: the dev loop NEVER deletes the data dir.
        .temp_data_dir = null,
    };

    // Take zigbase down with us on SIGINT/SIGTERM/SIGHUP (see `reaper`).
    // Registered right after the spawn, before anything else can fail.
    reaper.track(harness.server);
    reaper.install();

    e2e.waitReady(&harness, address, cmd.ready_path, cmd.timeout_ms);

    std.debug.print(
        \\
        \\dev: ready — serving at http://{s}:{d}{s}
        \\dev: zigbase data dir: {s} (persistent — collections/auth state survive dev sessions)
        \\
    , .{ cmd.host, port, cmd.ready_path, data_dir_abs });
    if (reload_server != null) {
        std.debug.print(
            "dev: live-reload: http://{s}:{d} (SSE) — pages auto-reload on rebuild\n\n\n",
            .{ cmd.host, reload_port },
        );
    } else {
        std.debug.print("dev: no live reload (--no-live-reload): refresh the browser after a rebuild\n\n\n", .{});
    }

    // (5) Watch + rebuild loop.
    var buf: [64]Event = undefined;
    var channel: Channel(Event) = .init(&buf);
    var debouncer: Debouncer = .{
        .io = io,
        .cascade_window_ms = cmd.debounce,
        .channel = &channel,
    };
    debouncer.start() catch |err| harness.fail(
        "unable to start the debouncer: {s}",
        .{@errorName(err)},
    );
    var watcher: Watcher = .init(io, gpa, &debouncer, dirs_to_watch.items);
    watcher.start() catch |err| harness.fail(
        "unable to start the file watcher: {s}",
        .{@errorName(err)},
    );

    std.debug.print("dev: watching:", .{});
    for (dirs_to_watch.items) |d| std.debug.print(" {s}", .{d});
    std.debug.print("\n", .{});

    while (true) {
        const event = channel.get(io) catch unreachable;
        switch (event) {
            .change => {},
        }
        // Collapse a burst that outran the debounce window into ONE rebuild.
        while ((channel.getOrNull(io) catch null) != null) {}

        // Classify the change. Snapshot "now" BEFORE walking so an
        // edit that lands mid-walk is caught by the NEXT rebuild rather than
        // dropped; re-processing a file is harmless, missing one is not.
        const new_cutoff: i128 = @intCast(Io.Clock.real.now(io).nanoseconds);
        const change = classifyChange(
            io,
            gpa,
            content_roots.items,
            other_roots.items,
            island_roots.items,
            island_manifest_path,
            cfg.getUrlPathPrefix(),
            last_build_ns,
            &watched_file_count,
        );
        last_build_ns = new_cutoff;
        defer if (change == .incremental) freeIncremental(gpa, change.incremental);

        // Incremental rebuild: hand the changed content pages to `zigapagos
        // release` (via `ZIGAPAGOS_CHANGED_FILES`, which rides through the
        // intervening `zig build`), so it re-renders + re-emits ONLY them.
        // Always cleared afterwards so a later full rebuild never inherits it.
        const rebuild_ok = switch (change) {
            .incremental => |inc| blk: {
                const joined = std.mem.join(gpa, "\n", inc.pages) catch fatal.oom();
                defer gpa.free(joined);
                environ_map.put(release_cli.changed_files_env, joined) catch fatal.oom();
                if (inc.pages.len == 1) {
                    std.debug.print("dev: change detected, incremental rebuild of {s}...\n", .{inc.pages[0]});
                } else {
                    std.debug.print("dev: change detected, incremental rebuild of {d} pages...\n", .{inc.pages.len});
                }
                const ok = runRebuild(io, rebuild_argv, environ_map);
                _ = environ_map.swapRemove(release_cli.changed_files_env);
                break :blk ok;
            },
            .full => blk: {
                // A shared input changed (or a change we can't localize): rebuild
                // the whole site. Ensure no stale incremental hint lingers.
                _ = environ_map.swapRemove(release_cli.changed_files_env);
                std.debug.print("dev: change detected, rebuilding...\n", .{});
                break :blk runRebuild(io, rebuild_argv, environ_map);
            },
        };

        if (rebuild_ok) {
            if (reload_server) |srv| {
                // Re-inject (the rebuild rewrote the tree from clean HTML), then
                // notify every connected browser.
                //
                // Full reload is the safe default. When the classifier proved
                // that ONLY island sources changed, the
                // island module URLs ride along on the `.incremental` change and
                // `srv.notifyIslands` broadcasts them instead: the browser
                // hot-swaps just those modules in place (runtime hmr.ts) —
                // preserving plain useState via the fast-refresh registry when
                // the bundle was built `--hot` (see `hot_islands_env`), else via
                // the in-place remount. A browser on a page that doesn't
                // mount the module falls back to a full reload client-side. The
                // full-reload path preserves `useRestorableState` via the
                // `zigapagos:beforereload` event the injected snippet dispatches.
                // AUD-028: after an incremental rebuild only the changed pages
                // were re-emitted (mtime >= new_cutoff), so inject just those; a
                // full rebuild re-emitted everything, so inject the whole tree.
                const inject_since: ?i128 = switch (change) {
                    .incremental => new_cutoff,
                    .full => null,
                };
                reload.injectTree(io, gpa, site_abs, reload_port, inject_since);
                const island_modules: []const []const u8 = switch (change) {
                    .incremental => |inc| inc.island_modules,
                    .full => &.{},
                };
                if (island_modules.len > 0) {
                    srv.notifyIslands(island_modules);
                    std.debug.print(
                        "dev: rebuild OK — hot-swapping {d} island module(s)\n",
                        .{island_modules.len},
                    );
                } else {
                    srv.notify();
                    std.debug.print("dev: rebuild OK — reloading browsers\n", .{});
                }
            } else {
                std.debug.print("dev: rebuild OK — refresh the browser\n", .{});
            }
        } else {
            // Keep serving the last good tree; the next change retries.
            std.debug.print("dev: rebuild FAILED (see output above); still serving the previous build\n", .{});
        }
    }
}

/// Makes sure a terminated dev process takes zigbase down with it.
///
/// The watch loop below never returns, so `harness.teardown()` is reachable
/// ONLY through `harness.fail()`. Without this, a terminated dev process
/// ORPHANS zigbase, which keeps holding the serve port and the data dir — and
/// the next `zigapagos dev` fails to bind. `e2e.Harness`'s "a terminal
/// SIGINT/SIGTERM reaches zigbase too (same process group)" holds for an
/// interactive Ctrl-C only: `kill <dev-pid>`, and an IDE, task runner or CI
/// job that signals just its direct child, both signal this process alone.
///
/// Windows has no POSIX signals, so there this is a no-op pair and the loop
/// keeps its previous behaviour (Ctrl-C kills the whole console process group).
///
/// RESIDUAL GAP, stated so nothing here overclaims: a `SIGKILL` of the dev
/// process still orphans zigbase, because no handler can run. The kernel-side
/// answer is `PR_SET_PDEATHSIG` on the child, which must be set by the child
/// itself between fork and exec — and `std.process.spawn` exposes no post-fork
/// hook, so setting it would mean hand-rolling fork/exec for this one call. Not
/// done; `pkill zigbase` remains the recovery for a `kill -9`-ed session.
const reaper = if (builtin.os.tag == .windows) struct {
    pub fn track(_: std.process.Child) void {}
    pub fn install() void {}
} else struct {
    /// The spawned zigbase's pid, 0 when there is none (yet, or any more).
    /// Global because a signal handler takes no context; atomic because the
    /// handler can run on any thread at any point.
    var pid: std.atomic.Value(std.posix.pid_t) = .init(0);

    /// Start tracking `child` so a terminating signal can kill it.
    pub fn track(child: std.process.Child) void {
        if (child.id) |id| pid.store(id, .seq_cst);
    }

    /// Kills the tracked zigbase, if any, and forgets it. Idempotent, and safe
    /// to call from a signal handler: it does nothing but one `kill(2)`.
    ///
    /// Deliberately NOT `Harness.teardown` — that calls `Child.kill`, which
    /// blocks reaping the child through the `Io` implementation (mutexes,
    /// futexes, possibly this very thread's runtime), none of which is
    /// async-signal-safe. For the dev loop the two are equivalent in effect:
    /// its harness has `temp_data_dir = null` (the data dir is persistent), so
    /// killing the child IS the whole teardown, and the exiting process leaves
    /// the reaping to init.
    pub fn terminate() void {
        const target = pid.swap(0, .seq_cst);
        if (target <= 0) return;
        std.posix.kill(target, .TERM) catch |err| switch (err) {
            // Already gone: nothing left to tear down.
            error.ProcessNotFound => {},
            // Nothing else is actionable on the way out — but never pretend it
            // succeeded.
            error.PermissionDenied, error.Unexpected => std.debug.print(
                "dev: could not terminate zigbase (pid {d}): {s} — it may be left running\n",
                .{ target, @errorName(err) },
            ),
        };
    }

    fn onSignal(sig: std.posix.SIG) callconv(.c) void {
        terminate();
        // Restore the default disposition and re-raise, so the exit status
        // reports the signal instead of a synthetic code. The signal is blocked
        // while this handler runs, so the re-raised one lands on return.
        const dfl: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(sig, &dfl, null);
        std.posix.raise(sig) catch std.process.exit(1);
    }

    /// Installs `onSignal` for every signal that means "this dev session is
    /// over".
    pub fn install() void {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = &onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig|
            std.posix.sigaction(sig, &act, null);
    }
};

/// A page-content root: `abs` is the absolute directory the loop walks for
/// changes; `rel` is the base-relative prefix (the site's configured content
/// dir, e.g. `content`) that turns a walk-relative entry into the exact
/// base-relative path `zigapagos release` matches against a page's source
/// (`p._scan.file` formatted with the same content-dir prefix).
const ContentRoot = struct { abs: []const u8, rel: []const u8 };

/// Classification of a debounced change.
const Change = union(enum) {
    /// A shared/unlocalizable change — rebuild the whole site.
    full,
    /// Only these content pages need re-rendering.
    incremental: Incremental,
};

/// An `.incremental` classification's payload (all strings gpa-owned; see
/// `freeIncremental`).
const Incremental = struct {
    /// Base-relative source paths of the pages to re-render: pages whose own
    /// source changed, plus pages mounting a changed island source (resolved
    /// via the dev island-usage manifest).
    pages: []const []const u8,
    /// Served island module URLs (`/islands/<name>.js`) of the changed island
    /// entries — non-empty ONLY when every changed file was an island source
    /// (no content-page edit), so the browsers can hot-swap those modules in
    /// place instead of a full reload.
    island_modules: []const []const u8 = &.{},
};

/// Frees everything an `.incremental` classification owns.
fn freeIncremental(gpa: Allocator, inc: Incremental) void {
    for (inc.pages) |p| gpa.free(p);
    gpa.free(inc.pages);
    for (inc.island_modules) |m| gpa.free(m);
    if (inc.island_modules.len > 0) gpa.free(inc.island_modules);
}

/// Records `base/rel` (deduplicated) as a page-content root.
fn appendContentRoot(
    gpa: Allocator,
    roots: *std.ArrayListUnmanaged(ContentRoot),
    base_dir_path: []const u8,
    rel: []const u8,
) error{OutOfMemory}!void {
    const abs = try std.fs.path.join(gpa, &.{ base_dir_path, rel });
    for (roots.items) |r| if (std.mem.eql(u8, r.abs, abs)) {
        gpa.free(abs);
        return;
    };
    try roots.append(gpa, .{ .abs = abs, .rel = rel });
}

/// Records `base/rel` (deduplicated) as an absolute "any change here forces a
/// full rebuild" root (layouts, assets, i18n, island/SPA source dirs).
fn appendOtherRoot(
    gpa: Allocator,
    roots: *std.ArrayListUnmanaged([]const u8),
    base_dir_path: []const u8,
    rel: []const u8,
) error{OutOfMemory}!void {
    const abs = try std.fs.path.join(gpa, &.{ base_dir_path, rel });
    for (roots.items) |r| if (std.mem.eql(u8, r, abs)) {
        gpa.free(abs);
        return;
    };
    try roots.append(gpa, abs);
}

/// Decides how to rebuild after a debounced change by walking the watched roots
/// and comparing file times to `cutoff_ns` (nanoseconds since the Unix epoch,
/// the wall-clock time the previous build started). Returns `.full` when any
/// shared input changed, when ANY content file changed (a page's frontmatter
/// can be embedded in OTHER pages via `$page.subpages()`/`nextPage()`/section
/// listings, which `classifyChange` has no content model to localize —
/// AUD-016), when a changed island-source file can't be resolved through the
/// manifest, when another watched source file references a changed
/// island entry (the manifest can't see bundle-level imports — see
/// `otherWatchedSourceReferences`), when the total watched-file count dropped
/// since the last build (a delete/rename the time scan can't localize —
/// AUD-017), when any of the walks could not be completed (`nextWalkEntry`), or
/// when nothing newer is found at all.
///
/// Both mtime AND ctime are compared to the cutoff: userspace tools can
/// preserve mtime (`cp -p`, `rsync -a`, `tar`) but the kernel always bumps
/// ctime on a real write, so an mtime-preserving overwrite is still seen
/// (AUD-017).
///
/// Otherwise `.incremental` with the base-relative source paths of exactly the
/// pages that mount an edited island (deduped) — plus, for an island-ONLY
/// change, the served module URLs the browsers can hot-swap in place. `file_count`
/// is read for the delete check and written with the current count on return.
fn classifyChange(
    io: Io,
    gpa: Allocator,
    content_roots: []const ContentRoot,
    other_roots: []const []const u8,
    island_roots: []const ContentRoot,
    island_manifest_path: []const u8,
    url_path_prefix: []const u8,
    cutoff_ns: i128,
    file_count: *usize,
) Change {
    // AUD-017: a pure delete/rename-away leaves no newer-time file for the
    // walks below to find, but it strictly lowers the total watched-file
    // count. Refresh the stored count first (so every return path updates it)
    // and force a full rebuild on any net decrease. An ADD always surfaces as
    // a newer-time file and is handled by the normal walks, so only a decrease
    // is actionable here.
    // A truncated scan can't be compared against the baseline at all, and must
    // not overwrite it with a bogus low count — fall back to a full rebuild and
    // leave the last known-good count in place for the next round.
    const current_files = countWatchedFiles(io, gpa, content_roots, other_roots, island_roots) orelse
        return .full;
    const files_removed = current_files < file_count.*;
    file_count.* = current_files;
    if (files_removed) return .full;

    // Any change under a shared root ⇒ full rebuild (checked first so we can
    // bail before allocating the page list).
    for (other_roots) |dir| {
        if (dirHasChangeSince(io, gpa, dir, cutoff_ns)) return .full;
    }

    // Island-source roots: collect EVERY changed file (no page
    // filter; helpers and SPA sources land here too) as a base-relative
    // '/'-separated path — the same string space as the manifest's island keys
    // (both are website-root-relative).
    var island_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (island_files.items) |p| gpa.free(p);
        island_files.deinit(gpa);
    }
    for (island_roots) |ir| {
        var root_dir = Io.Dir.cwd().openDir(io, ir.abs, .{ .iterate = true }) catch continue;
        defer root_dir.close(io);
        var it = root_dir.walk(gpa) catch |err| {
            if (err == error.OutOfMemory) fatal.oom();
            continue;
        };
        defer it.deinit();
        var walk_failed = false;
        while (nextWalkEntry(&it, io, ir.abs, &walk_failed)) |entry| {
            if (entry.kind != .file) continue;
            const st = root_dir.statFile(io, entry.path, .{}) catch continue;
            if (!isNewer(st, cutoff_ns)) continue;
            island_files.append(gpa, relPagePath(gpa, ir.rel, entry.path)) catch fatal.oom();
        }
        // A partial island scan yields a partial changed set, and resolving a
        // partial set through the manifest would rebuild only SOME of the
        // affected pages while reporting success. Rebuild everything instead.
        if (walk_failed) return .full;
    }

    // The manifest maps an island ENTRY to the
    // pages that mount IT — it cannot see bundle-level imports. If any OTHER
    // watched source file (another island's entry, a helper, a SPA source)
    // imports a changed entry, the pages mounting THAT island would keep
    // stale SSR'd HTML under the incremental path. Detect the situation
    // conservatively and fall back to a full rebuild; a false positive only
    // costs speed, never correctness.
    if (island_files.items.len > 0 and
        otherWatchedSourceReferences(io, gpa, island_roots, island_files.items))
    {
        std.debug.print(
            "dev: a changed island entry is referenced by another watched source — full rebuild\n",
            .{},
        );
        return .full;
    }

    // Deduplicating page set (an edited page may ALSO mount an edited island).
    var pages: std.StringArrayHashMapUnmanaged(void) = .empty;

    // AUD-035: the per-file mounting-page counts, parallel to
    // `island_files.items`. Collected during resolution but NOT logged until
    // this call commits to `.incremental` below — a resolution the content-file
    // walk (or the empty-set check) later discards must leave no "island source
    // X -> N mounting page(s)" line claiming an incremental rebuild happened.
    var mount_counts: std.ArrayListUnmanaged(usize) = .empty;
    defer mount_counts.deinit(gpa);

    if (island_files.items.len > 0) {
        if (!resolveIslandPages(io, gpa, island_manifest_path, island_files.items, &pages, &mount_counts)) {
            // Manifest missing/stale, or a changed file that isn't a known
            // island src (helper module, SPA source, brand-new island) —
            // can't localize, never guess.
            freePageSet(gpa, &pages);
            return .full;
        }
    }

    // AUD-016: any content file change forces a full rebuild. Even an isolated
    // page edit can change frontmatter that OTHER pages embed via
    // `$page.subpages()`/`subpagesAlphabetic()`/`nextPage()`/`prevPage()` or a
    // section listing, and `classifyChange` has no content model to know which
    // pages those are. Re-rendering only the edited page (the old behavior)
    // left listing/prev-next pages showing stale titles/dates until an
    // unrelated full rebuild — the dev preview disagreed with a release build.
    // Rebuilding the whole site is correct over fast; island-source changes are
    // handled above and still take the incremental + hot-swap path.
    for (content_roots) |cr| {
        var root_dir = Io.Dir.cwd().openDir(io, cr.abs, .{ .iterate = true }) catch continue;
        defer root_dir.close(io);
        var it = root_dir.walk(gpa) catch |err| {
            if (err == error.OutOfMemory) fatal.oom();
            continue;
        };
        defer it.deinit();
        var walk_failed = false;
        while (nextWalkEntry(&it, io, cr.abs, &walk_failed)) |entry| {
            if (entry.kind != .file) continue;
            const st = root_dir.statFile(io, entry.path, .{}) catch continue;
            if (!isNewer(st, cutoff_ns)) continue;
            freePageSet(gpa, &pages);
            return .full;
        }
        // An unscanned content subtree may hold the page edit that makes this
        // change unlocalizable — never conclude "no content changed" from a
        // walk that stopped early.
        if (walk_failed) {
            freePageSet(gpa, &pages);
            return .full;
        }
    }

    if (pages.count() == 0) {
        pages.deinit(gpa);
        return .full;
    }

    // AUD-035: the change set resolved AND survived the full-rebuild fallback,
    // so the incremental resolution is real — log it now. `mount_counts` runs
    // parallel to `island_files.items` (empty when no island source changed).
    for (island_files.items, mount_counts.items) |cf, n| {
        std.debug.print("dev: island source {s} -> {d} mounting page(s)\n", .{ cf, n });
    }

    // Island-ONLY change: every changed file was an island
    // entry, so the browsers can hot-swap the rebuilt modules in place instead
    // of a full reload. The served URL is `/islands/<name>.js` where <name> is
    // the entry basename with its final extension stripped — the same mapping
    // as `release.zig`'s `bundleName` / the SSR pass's module URL — and it must
    // carry the site's `url_path_prefix` exactly as the SSR pass's
    // `data-z-module` does (AUD-021), or the browser's mounted `rec.moduleUrl`
    // never matches and the hot-swap silently falls back to a full reload.
    const island_modules: []const []const u8 = blk: {
        if (island_files.items.len == 0) break :blk &.{};
        var mods: std.ArrayListUnmanaged([]const u8) = .empty;
        for (island_files.items) |cf| mods.append(
            gpa,
            islandModuleUrl(gpa, url_path_prefix, moduleStem(cf)),
        ) catch fatal.oom();
        break :blk mods.toOwnedSlice(gpa) catch fatal.oom();
    };
    // Move the keys into an owned slice; the map storage is freed, the key
    // strings transfer to the returned `.incremental` set (see
    // `freeIncremental`).
    const paths = gpa.dupe([]const u8, pages.keys()) catch fatal.oom();
    pages.deinit(gpa);
    return .{ .incremental = .{ .pages = paths, .island_modules = island_modules } };
}

/// Advances a directory walk, reporting a walk FAILURE separately from the
/// end-of-iteration sentinel.
///
/// `Io.Dir.Walker.next` returns an error when it cannot descend into a
/// subdirectory (AccessDenied, SystemFdQuotaExceeded, …). Folding that into
/// `null` — the `it.next(io) catch null` idiom — makes the loop exit as if the
/// tree had been fully scanned, so a truncated walk is indistinguishable from
/// "nothing changed here". That is the wrong default in every caller: it
/// silently downgrades a full rebuild to an incremental one and the edit never
/// reaches the browser, while the loop still prints "rebuild OK".
///
/// So: on failure this logs, sets `failed`, and ends the walk — and EVERY
/// caller must then answer conservatively ("assume it changed"), never
/// "nothing changed".
fn nextWalkEntry(
    it: *Io.Dir.Walker,
    io: Io,
    dir_abs: []const u8,
    failed: *bool,
) ?Io.Dir.Walker.Entry {
    return it.next(io) catch |err| {
        std.debug.print(
            "dev: could not finish scanning '{s}' ({s}) — assuming it changed\n",
            .{ dir_abs, @errorName(err) },
        );
        failed.* = true;
        return null;
    };
}

/// `components/B.island.tsx` → `B.island`: the changed file's module name —
/// basename with only the FINAL extension stripped (matching `release.zig`'s
/// `bundleName`). Any import of the module must contain this substring
/// (`./B.island`, `../c/B.island.tsx`, …), extension or not.
fn moduleStem(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[0..dot];
    return name;
}

/// True when `st` was touched after `cutoff_ns`. Both mtime and ctime are
/// checked: `cp -p`/`rsync -a`/`tar` can preserve mtime, but the kernel always
/// bumps ctime on a real write, so an mtime-preserving overwrite is still
/// detected (AUD-017).
fn isNewer(st: Io.File.Stat, cutoff_ns: i128) bool {
    const newest = @max(st.mtime.nanoseconds, st.ctime.nanoseconds);
    return @as(i128, newest) > cutoff_ns;
}

/// Total regular-file count across every watched root, or null when some root
/// could not be walked to completion. Used only to detect a pure
/// delete/rename-away between rebuilds (AUD-017): such a change leaves no
/// newer-time file for `classifyChange`'s walk to find but strictly lowers this
/// count. A missing root counts as zero (consistent with the walks, which treat
/// it as "no change"), but a TRUNCATED walk yields null rather than a
/// short count: a short count would both force a full rebuild now (harmless)
/// and, by overwriting the stored baseline with a bogus low number, hide a real
/// deletion later (not harmless).
fn countWatchedFiles(
    io: Io,
    gpa: Allocator,
    content_roots: []const ContentRoot,
    other_roots: []const []const u8,
    island_roots: []const ContentRoot,
) ?usize {
    const countDir = struct {
        fn f(io_: Io, gpa_: Allocator, abs: []const u8) ?usize {
            var dir = Io.Dir.cwd().openDir(io_, abs, .{ .iterate = true }) catch return 0;
            defer dir.close(io_);
            var it = dir.walk(gpa_) catch |err| {
                if (err == error.OutOfMemory) fatal.oom();
                return 0;
            };
            defer it.deinit();
            var n: usize = 0;
            var walk_failed = false;
            while (nextWalkEntry(&it, io_, abs, &walk_failed)) |entry| {
                if (entry.kind == .file) n += 1;
            }
            return if (walk_failed) null else n;
        }
    }.f;
    var total: usize = 0;
    for (content_roots) |cr| total += countDir(io, gpa, cr.abs) orelse return null;
    for (island_roots) |ir| total += countDir(io, gpa, ir.abs) orelse return null;
    for (other_roots) |d| total += countDir(io, gpa, d) orelse return null;
    return total;
}

/// The browser-facing hot-swap module URL for a changed island entry. Mirrors
/// the SSR pass's `data-z-module` attribute (`islands/pass.zig`'s `prefixed` +
/// `/islands/<stem>.js`): with no prefix it is `/islands/<stem>.js`; with a
/// `url_path_prefix` of "docs" it is `/docs/islands/<stem>.js`. The prefix is
/// trimmed of leading/trailing '/' exactly as `prefixed` does (AUD-021).
fn islandModuleUrl(gpa: Allocator, url_prefix: []const u8, stem: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, url_prefix, "/");
    if (trimmed.len == 0)
        return std.fmt.allocPrint(gpa, "/islands/{s}.js", .{stem}) catch fatal.oom();
    return std.fmt.allocPrint(gpa, "/{s}/islands/{s}.js", .{ trimmed, stem }) catch fatal.oom();
}

/// True for files the island/SPA bundler can import (the only files whose
/// imports can pull a changed island entry into ANOTHER bundle).
fn isScriptFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const script_exts = [_][]const u8{
        ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
    };
    for (script_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// True when any watched source file OTHER THAN
/// the changed files themselves textually references a changed file's module
/// stem — the conservative signal that some other bundle (island or SPA)
/// imports a changed island entry, directly or through a re-export chain
/// (whose first hop is itself a watched source containing the stem). Changed
/// files are exempt: a changed file that imports another changed file already
/// contributes its own mounting pages. An unreadable file — or a subtree the
/// walk could not finish — counts as a reference (assume the worst). False
/// positives (the stem in a comment or string) only force a full rebuild —
/// safe, merely slower.
fn otherWatchedSourceReferences(
    io: Io,
    gpa: Allocator,
    island_roots: []const ContentRoot,
    changed_files: []const []const u8,
) bool {
    for (island_roots) |ir| {
        var root_dir = Io.Dir.cwd().openDir(io, ir.abs, .{ .iterate = true }) catch continue;
        defer root_dir.close(io);
        var it = root_dir.walk(gpa) catch |err| {
            if (err == error.OutOfMemory) fatal.oom();
            continue;
        };
        defer it.deinit();
        var walk_failed = false;
        while (nextWalkEntry(&it, io, ir.abs, &walk_failed)) |entry| {
            if (entry.kind != .file) continue;
            if (!isScriptFile(entry.path)) continue;
            const rel = relPagePath(gpa, ir.rel, entry.path);
            defer gpa.free(rel);
            const is_changed = for (changed_files) |cf| {
                if (std.mem.eql(u8, cf, rel)) break true;
            } else false;
            if (is_changed) continue;
            const text = root_dir.readFileAlloc(
                io,
                entry.path,
                gpa,
                .limited(16 * 1024 * 1024),
            ) catch return true;
            defer gpa.free(text);
            if (anyStemReferenced(text, changed_files)) return true;
        }
        // Same rule as the unreadable file above: a subtree we could not scan
        // may import a changed island entry, so assume it does.
        if (walk_failed) return true;
    }
    return false;
}

/// Pure core of `otherWatchedSourceReferences` (unit-tested): does `text`
/// contain any changed file's module stem?
fn anyStemReferenced(text: []const u8, changed_files: []const []const u8) bool {
    for (changed_files) |cf| {
        if (std.mem.indexOf(u8, text, moduleStem(cf)) != null) return true;
    }
    return false;
}

/// Frees a partially-built page set (keys + storage) on a `.full` bail-out.
fn freePageSet(gpa: Allocator, pages: *std.StringArrayHashMapUnmanaged(void)) void {
    for (pages.keys()) |k| gpa.free(k);
    pages.deinit(gpa);
}

/// io wrapper — read + parse the dev island-usage manifest, then
/// resolve `changed_files` through it into `pages`. Returns false — the caller
/// falls back to a full rebuild — when the manifest is missing, unreadable, or
/// malformed/stale (see `islands_manifest.parse`), or when any changed file
/// isn't a known island src.
///
/// On success `mount_counts` is filled with one entry per `changed_files` (in
/// order): the number of pages that file mounts on. The caller logs these only
/// after committing to `.incremental` (AUD-035) — resolving here does NOT mean
/// the classification survives; a later content edit still forces a full
/// rebuild, and logging inside this call would claim a discarded resolution.
fn resolveIslandPages(
    io: Io,
    gpa: Allocator,
    manifest_path: []const u8,
    changed_files: []const []const u8,
    pages: *std.StringArrayHashMapUnmanaged(void),
    mount_counts: *std.ArrayListUnmanaged(usize),
) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // `islands_manifest.parse` is contract 4 (NO_SLOP.md §2.2a) — the parsed
    // manifest is a leak-parsed graph reclaimed only by this arena, which is why
    // it takes a `RenderArena` and not an allocator.
    const arena = RenderArena.from(&arena_state);
    const text = Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        arena.a,
        .limited(16 * 1024 * 1024),
    ) catch return false;
    const parsed = islands_manifest.parse(arena, text) catch return false;
    if (!(islandPagesFromManifest(gpa, &parsed, changed_files, pages) catch fatal.oom()))
        return false;
    // Record the per-file mounting-page counts for the caller to log once the
    // whole change set has resolved AND survived the full-rebuild fallback
    // (AUD-035). `islandPagesFromManifest` returning true guarantees every
    // `changed_files` entry is a manifest key, so the lookups are total.
    mount_counts.ensureTotalCapacity(gpa, changed_files.len) catch fatal.oom();
    for (changed_files) |cf| {
        const mounts = parsed.islands.map.get(cf).?;
        mount_counts.appendAssumeCapacity(mounts.len);
    }
    return true;
}

/// Pure core of `resolveIslandPages` (unit-tested): EVERY changed file must be
/// a manifest key — a single unknown file (helper module, SPA source, island
/// added after the manifest was written) means the change can't be localized,
/// so the whole classification falls back to a full rebuild. Mounting pages
/// are inserted into `pages` with gpa-duped keys (deduplicated).
fn islandPagesFromManifest(
    gpa: Allocator,
    parsed: *const islands_manifest.Json,
    changed_files: []const []const u8,
    pages: *std.StringArrayHashMapUnmanaged(void),
) error{OutOfMemory}!bool {
    for (changed_files) |cf| {
        const mounts = parsed.islands.map.get(cf) orelse return false;
        for (mounts) |page| {
            const gop = try pages.getOrPut(gpa, page);
            if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, page);
        }
    }
    return true;
}

/// Joins a content root's base-relative prefix and a walk-relative entry path
/// into the '/'-separated base-relative page path the render pass matches on
/// (e.g. `content` + `blog/foo.md` → `content/blog/foo.md`). Any host
/// backslash separators in `entry_path` are normalized to '/'.
fn relPagePath(gpa: Allocator, rel_prefix: []const u8, entry_path: []const u8) []const u8 {
    const out = std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry_path }) catch fatal.oom();
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// True when any regular file under `dir_abs` has an mtime newer than
/// `cutoff_ns`. A missing dir counts as "no change" (its absence isn't a
/// content edit; a real problem surfaces at build time), but a walk that
/// cannot be COMPLETED counts as "changed": an unscanned subtree may hold the
/// very edit we are looking for, and this answer decides whether a shared-input
/// change forces a full rebuild.
fn dirHasChangeSince(io: Io, gpa: Allocator, dir_abs: []const u8, cutoff_ns: i128) bool {
    var dir = Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.walk(gpa) catch |err| {
        if (err == error.OutOfMemory) fatal.oom();
        return false;
    };
    defer it.deinit();
    var walk_failed = false;
    while (nextWalkEntry(&it, io, dir_abs, &walk_failed)) |entry| {
        if (entry.kind != .file) continue;
        const st = dir.statFile(io, entry.path, .{}) catch continue;
        if (isNewer(st, cutoff_ns)) return true;
    }
    return walk_failed;
}

/// The rebuild command when the user gave none: THIS binary's own `release`,
/// into `site`.
///
/// The executable is resolved by ABSOLUTE PATH rather than spawned as
/// "zigapagos", because the whole point of a standalone binary is that nothing
/// useful can be assumed to be on `PATH` — an npm install puts a shim in
/// `node_modules/.bin`, and a user who downloaded a release tarball may not
/// have put it anywhere at all.
///
/// No `--island=`/`--spa=` flags are needed: `release` discovers the site's
/// `*.island.tsx` / `*.spa.tsx` entries itself (release.zig's
/// `discoverEntries`), which is what keeps the SSR'd markup and the client
/// bundles in step without dev having to know the list.
///
/// NO_SLOP.md §2.2a contract 2 (owned-result): the returned `Argv` owns its
/// strings and the slice holding them, and the caller `deinit`s it. `dev()`
/// holds it for the process lifetime and never does — it is `noreturn` and a
/// `defer` there would never run — but the unit tests do, which is what keeps
/// leak detection meaningful on this path.
const Argv = struct {
    items: []const []const u8,

    fn deinit(a: Argv, gpa: Allocator) void {
        for (a.items) |it| gpa.free(it);
        gpa.free(a.items);
    }
};

fn defaultRebuildArgv(
    io: Io,
    gpa: Allocator,
    site: []const u8,
) error{OutOfMemory}!Argv {
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |it| gpa.free(it);
        items.deinit(gpa);
    }
    {
        // `executablePathAlloc` returns a SENTINEL slice (`[:0]u8`), whose
        // allocation is one byte longer than its `.len`. Freeing it through a
        // plain `[]const u8` therefore hands the allocator the wrong size —
        // DebugAllocator reports "Allocation size N does not match free size
        // N-1" — so the sentinel is dropped here, into an exactly-sized copy
        // the rest of the list can be freed uniformly.
        const self_z = std.process.executablePathAlloc(io, gpa) catch |err| fatal.msg(
            "error: dev: this executable's own path is unavailable ({s}); pass an " ++
                "explicit rebuild command after `--`\n",
            .{@errorName(err)},
        );
        defer gpa.free(self_z);
        try items.append(gpa, try gpa.dupe(u8, self_z));
    }
    try items.append(gpa, try gpa.dupe(u8, "release"));
    try items.append(gpa, try std.fmt.allocPrint(gpa, "--output={s}", .{site}));
    // `--force`: the output dir is rebuilt in place on every change, and the
    // very first rebuild of an existing tree would otherwise refuse to touch a
    // directory it did not create.
    try items.append(gpa, try gpa.dupe(u8, "--force"));
    return .{ .items = try items.toOwnedSlice(gpa) };
}

/// The island/SPA source directories to watch when the user gave no
/// `--watch-dir`: the PARENT directory of every `*.island.tsx` / `*.spa.tsx`
/// entry `zigapagos release` would discover, deduplicated and relative to the
/// site root.
///
/// The scan root itself (".") is deliberately never returned. It is what
/// `release` scans, but the built output tree lives under it, so watching it
/// would make every rebuild retrigger the watcher — an infinite rebuild loop.
/// An entry sitting directly at the site root therefore contributes nothing,
/// which is the conservative failure: no watching, not a loop.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): the discovered entry list is
/// scratch, freed here; the returned slice and its strings are the only
/// allocations that escape, and — like `defaultRebuildArgv`'s — the caller
/// holds them for the process lifetime.
fn discoverWatchDirs(
    io: Io,
    gpa: Allocator,
    base_dir_path: []const u8,
) error{OutOfMemory}![]const []const u8 {
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    for ([_][]const u8{ ".island.tsx", ".spa.tsx" }) |suffix| {
        const entries = release_cli.discoverEntries(io, gpa, base_dir_path, suffix) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer {
            for (entries) |e| gpa.free(e);
            gpa.free(entries);
        }
        for (entries) |e| {
            // `dirname` is null for a bare basename, i.e. an entry at the scan
            // root — the one case that must NOT be watched (see above).
            const parent = std.fs.path.dirname(e) orelse continue;
            if (parent.len == 0 or std.mem.eql(u8, parent, ".")) continue;
            for (dirs.items) |d| {
                if (std.mem.eql(u8, d, parent)) break;
            } else try dirs.append(gpa, try gpa.dupe(u8, parent));
        }
    }
    return dirs.toOwnedSlice(gpa);
}

/// Appends `base/dir` (deduplicated) to the watch list. Null-terminated
/// because the macOS watcher needs sentinel paths.
fn appendWatchDir(
    gpa: Allocator,
    dirs: *std.ArrayListUnmanaged([:0]const u8),
    base_dir_path: []const u8,
    dir: []const u8,
) error{OutOfMemory}!void {
    const candidate = try std.fs.path.joinZ(gpa, &.{ base_dir_path, dir });
    for (dirs.items) |d| if (std.mem.eql(u8, d, candidate)) {
        gpa.free(candidate);
        return;
    };
    try dirs.append(gpa, candidate);
}

/// True when `path` equals `dir` or lives underneath it. Both must already be
/// resolved/absolute. `resolve` strips trailing separators everywhere EXCEPT
/// the filesystem root ("/", or a drive root on Windows), so a dir already
/// ending in the separator needs no extra boundary byte after the prefix.
fn pathIsInside(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0) return false;
    if (std.mem.eql(u8, dir, path)) return true;
    if (path.len <= dir.len) return false;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return dir[dir.len - 1] == std.fs.path.sep or path[dir.len] == std.fs.path.sep;
}

/// Runs the rebuild command to completion with output streaming through.
/// Returns true when it exits 0.
fn runRebuild(
    io: Io,
    argv: []const []const u8,
    environ_map: *std.process.Environ.Map,
) bool {
    const start_ms = Io.Clock.awake.now(io).toMilliseconds();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
    }) catch |err| {
        std.debug.print("dev: failed to spawn '{s}': {s}\n", .{ argv[0], @errorName(err) });
        return false;
    };
    const term = child.wait(io) catch |err| {
        std.debug.print("dev: failed to wait for '{s}': {s}\n", .{ argv[0], @errorName(err) });
        return false;
    };
    const took_ms = Io.Clock.awake.now(io).toMilliseconds() - start_ms;
    switch (term) {
        .exited => |code| {
            std.debug.print("dev: build finished in {d} ms (exit code {d})\n", .{ took_ms, code });
            return code == 0;
        },
        else => {
            std.debug.print("dev: build terminated abnormally ({s})\n", .{@tagName(term)});
            return false;
        },
    }
}

// --- unit tests (run via `zig build test-dev`, filter "dev") -------------------
// fatal.usageError paths (unknown arg, bad values) exit the process and are
// exercised by tests/dev/dev.sh instead.

test "dev parse: NO arguments at all yields a runnable configuration" {
    // The zero-config contract: `zigapagos dev` in a site directory must work
    // with nothing supplied. Every field below is a default someone has to keep
    // working, so they are pinned here rather than left implicit -- `--site`
    // most of all, which used to be REQUIRED and fataled without it.
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{});
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("public", cmd.site); // = release's own default output
    try std.testing.expectEqualStrings(default_data_dir, cmd.data_dir); // persistent default
    try std.testing.expect(cmd.zigbase_path == null); // default: PATH, then cache
    try std.testing.expect(!cmd.no_download); // default: fetch the pinned release
    try std.testing.expectEqual(default_zigbase_args.ptr, cmd.zigbase_args.ptr);
    try std.testing.expectEqualStrings("/", cmd.ready_path);
    try std.testing.expectEqual(@as(u32, 120_000), cmd.timeout_ms);
    try std.testing.expectEqualStrings("127.0.0.1", cmd.host);
    try std.testing.expectEqual(@as(u16, 1990), cmd.port);
    try std.testing.expectEqual(@as(u16, 25), cmd.debounce);
    try std.testing.expect(cmd.live_reload); // on by default
    try std.testing.expectEqual(@as(u16, 0), cmd.reload_port); // 0 = pick a free port
    // Empty means "derive from the discovered island/SPA sources", not "watch
    // nothing" -- see discoverWatchDirs.
    try std.testing.expectEqual(@as(usize, 0), cmd.watch_dirs.len);
    // Null means "build the default argv", which needs `io` and so cannot
    // happen in parse; see defaultRebuildArgv.
    try std.testing.expect(cmd.rebuild_argv == null);
}

test "dev parse: allocation failures free partial command state" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            const cmd = try Command.parse(gpa, &.{
                "--zigbase-arg=serve",
                "--zigbase-arg=--port={port}",
                "--watch-dir=components",
                "--watch-dir=apps",
                "--",
                "zigapagos",
                "release",
            });
            defer cmd.deinit(gpa);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "dev parse: --site overrides the default" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{"--site=/out/site"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/out/site", cmd.site);
}

test "dev parse: every knob is threaded through" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{
        "--site=zig-out/site",
        "--data-dir=.zb-dev",
        "--zigbase=/opt/zigbase",
        "--no-download",
        "--zigbase-arg=serve",
        "--zigbase-arg=--http-port",
        "--zigbase-arg={port}",
        "--ready-path=/app/",
        "--timeout-ms=5000",
        "--host=127.0.0.2",
        "--port=0",
        "--debounce=150",
        "--no-live-reload",
        "--reload-port=1991",
        "--watch-dir=components",
        "--watch-dir=app",
        "--",
        "zig",
        "build",
        "-Dfoo",
    });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings(".zb-dev", cmd.data_dir);
    try std.testing.expectEqualStrings("/opt/zigbase", cmd.zigbase_path.?);
    try std.testing.expect(cmd.no_download);
    // any --zigbase-arg replaces the WHOLE default template
    try std.testing.expectEqual(@as(usize, 3), cmd.zigbase_args.len);
    try std.testing.expectEqualStrings("serve", cmd.zigbase_args[0]);
    try std.testing.expectEqualStrings("{port}", cmd.zigbase_args[2]);
    try std.testing.expectEqualStrings("/app/", cmd.ready_path);
    try std.testing.expectEqual(@as(u32, 5000), cmd.timeout_ms);
    try std.testing.expectEqualStrings("127.0.0.2", cmd.host);
    try std.testing.expectEqual(@as(u16, 0), cmd.port); // 0 = pick a free port
    try std.testing.expectEqual(@as(u16, 150), cmd.debounce);
    try std.testing.expect(!cmd.live_reload); // --no-live-reload
    try std.testing.expectEqual(@as(u16, 1991), cmd.reload_port);
    try std.testing.expectEqual(@as(usize, 2), cmd.watch_dirs.len);
    try std.testing.expectEqualStrings("components", cmd.watch_dirs[0]);
    try std.testing.expectEqual(@as(usize, 3), cmd.rebuild_argv.?.len);
    try std.testing.expectEqualStrings("-Dfoo", cmd.rebuild_argv.?[2]);
}

test "dev parse: everything after '--' is the rebuild command verbatim" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{ "--site=out", "--", "bash", "-c", "make site", "--site=x" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("out", cmd.site);
    try std.testing.expectEqual(@as(usize, 4), cmd.rebuild_argv.?.len);
    try std.testing.expectEqualStrings("--site=x", cmd.rebuild_argv.?[3]);
}

test "dev parse: a bare trailing '--' keeps the default rebuild command" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{ "--site=out", "--" });
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.rebuild_argv == null);
}

test "dev rebuild default is this binary's own release into --site" {
    // The default rebuild command must name THIS executable by absolute path,
    // not "zigapagos" on PATH: an npm install exposes only a shim under
    // node_modules/.bin, and a release-tarball user may have put the binary
    // nowhere at all. Spawning by name worked in a dev checkout and nowhere
    // else, which is the failure this pins.
    const gpa = std.testing.allocator;
    const argv = try defaultRebuildArgv(std.testing.io, gpa, "out/site");
    defer argv.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), argv.items.len);
    try std.testing.expect(std.fs.path.isAbsolute(argv.items[0]));
    try std.testing.expectEqualStrings("release", argv.items[1]);
    try std.testing.expectEqualStrings("--output=out/site", argv.items[2]);
    try std.testing.expectEqualStrings("--force", argv.items[3]);
}

test "dev default zigbase template appends --insecure-cookies to the shared template" {
    // Plain-HTTP local dev: without it, ZigBase's Secure-flagged auth cookies
    // never round-trip. The shared prefix must stay in sync with e2e's.
    try std.testing.expectEqual(e2e.default_zigbase_args.len + 1, default_zigbase_args.len);
    for (e2e.default_zigbase_args, 0..) |a, i|
        try std.testing.expectEqualStrings(a, default_zigbase_args[i]);
    try std.testing.expectEqualStrings(
        "--insecure-cookies",
        default_zigbase_args[default_zigbase_args.len - 1],
    );
}

test "dev pathIsInside detects equality and descendants only" {
    try std.testing.expect(pathIsInside("/a/b", "/a/b"));
    try std.testing.expect(pathIsInside("/a/b", "/a/b/c"));
    try std.testing.expect(!pathIsInside("/a/b", "/a/bc")); // sibling name-prefix
    try std.testing.expect(!pathIsInside("/a/b/c", "/a/b"));
    try std.testing.expect(!pathIsInside("/a/b", "/a"));
}

test "dev pathIsInside handles a trailing-separator dir (the filesystem root)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // `resolve` keeps the trailing separator ONLY for the root — and
    // everything lives inside "/".
    try std.testing.expect(pathIsInside("/", "/a"));
    try std.testing.expect(pathIsInside("/", "/a/b"));
    try std.testing.expect(pathIsInside("/", "/"));
    try std.testing.expect(!pathIsInside("", "/a")); // defensive: empty dir
}

// --- incremental-rebuild classification helpers -----------------------------

test "dev relPagePath joins with '/' and matches the render pass's source format" {
    const gpa = std.testing.allocator;
    // `content` + `blog/foo.md` → `content/blog/foo.md` — exactly the string
    // `p._scan.file.fmt(st, pt, content_dir_path, "/")` produces, so the render
    // pass's changed-set membership test hits.
    const a = relPagePath(gpa, "content", "blog/foo.md");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("content/blog/foo.md", a);

    const b = relPagePath(gpa, "content/en-US", "index.smd");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("content/en-US/index.smd", b);
}

test "dev appendContentRoot / appendOtherRoot deduplicate" {
    const gpa = std.testing.allocator;
    var croots: std.ArrayListUnmanaged(ContentRoot) = .empty;
    defer {
        for (croots.items) |r| gpa.free(r.abs);
        croots.deinit(gpa);
    }
    try appendContentRoot(gpa, &croots, "/site", "content");
    try appendContentRoot(gpa, &croots, "/site", "content"); // dup
    try std.testing.expectEqual(@as(usize, 1), croots.items.len);
    try std.testing.expectEqualStrings("/site/content", croots.items[0].abs);
    try std.testing.expectEqualStrings("content", croots.items[0].rel);

    var oroots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (oroots.items) |r| gpa.free(r);
        oroots.deinit(gpa);
    }
    try appendOtherRoot(gpa, &oroots, "/site", "assets");
    try appendOtherRoot(gpa, &oroots, "/site", "assets"); // dup
    try appendOtherRoot(gpa, &oroots, "/site", "layouts");
    try std.testing.expectEqual(@as(usize, 2), oroots.items.len);
}

// --- island-source incremental classification helpers -----------------------

test "dev island manifest: changed island resolves to its mounting pages (deduped)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const parsed = try islands_manifest.parse(arena,
        \\{"version":1,"islands":{
        \\  "components/Counter.island.tsx":["content/a.smd","content/b.smd"],
        \\  "components/Hero.island.tsx":["content/b.smd","content/c.smd"]}}
    );

    var pages: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer freePageSet(gpa, &pages);
    const ok = try islandPagesFromManifest(gpa, &parsed, &.{
        "components/Counter.island.tsx",
        "components/Hero.island.tsx",
    }, &pages);
    try std.testing.expect(ok);
    // content/b.smd mounts both edited islands but must appear once.
    try std.testing.expectEqual(@as(usize, 3), pages.count());
    try std.testing.expect(pages.contains("content/a.smd"));
    try std.testing.expect(pages.contains("content/b.smd"));
    try std.testing.expect(pages.contains("content/c.smd"));
}

test "dev island manifest: unknown changed file forces a full rebuild" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);

    const parsed = try islands_manifest.parse(arena,
        \\{"version":1,"islands":{"components/Counter.island.tsx":["content/a.smd"]}}
    );

    var pages: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer freePageSet(gpa, &pages);
    // A helper module (or a brand-new island) is not a manifest key: the whole
    // change set is unresolvable, even though the first file IS known.
    const ok = try islandPagesFromManifest(gpa, &parsed, &.{
        "components/Counter.island.tsx",
        "components/helper.ts",
    }, &pages);
    try std.testing.expect(!ok);
}

test "dev moduleStem strips the directory and only the FINAL extension" {
    // Must match release.zig's bundleName: /islands/<stem>.js is the served URL.
    try std.testing.expectEqualStrings("B.island", moduleStem("components/B.island.tsx"));
    try std.testing.expectEqualStrings("Counter", moduleStem("components/Counter.tsx"));
    try std.testing.expectEqualStrings("deep", moduleStem("a/b/c/deep.jsx"));
    try std.testing.expectEqualStrings("noext", moduleStem("x/noext"));
}

test "dev isScriptFile matches bundler-importable extensions only" {
    try std.testing.expect(isScriptFile("a/b.ts"));
    try std.testing.expect(isScriptFile("a/b.tsx"));
    try std.testing.expect(isScriptFile("a/b.jsx"));
    try std.testing.expect(isScriptFile("a/B.island.TSX")); // case-insensitive
    try std.testing.expect(isScriptFile("a/b.mjs"));
    try std.testing.expect(!isScriptFile("a/b.css"));
    try std.testing.expect(!isScriptFile("a/b.png"));
    try std.testing.expect(!isScriptFile("a/b")); // no extension
}

test "dev anyStemReferenced: cross-entry imports are detected, unrelated code is not" {
    const changed = [_][]const u8{"components/B.island.tsx"};
    // Any import form contains the stem — with or without the extension.
    try std.testing.expect(anyStemReferenced(
        "import B from './B.island.tsx';\nexport default () => <B/>;",
        &changed,
    ));
    try std.testing.expect(anyStemReferenced(
        "import B from \"../components/B.island\";",
        &changed,
    ));
    // Re-export chains hit too: the first hop textually names the module.
    try std.testing.expect(anyStemReferenced(
        "export { default as B } from './B.island.tsx';",
        &changed,
    ));
    // Unrelated sources don't (the incremental fast path stays available).
    try std.testing.expect(!anyStemReferenced(
        "import { useState } from '@z/runtime';\nexport default () => null;",
        &changed,
    ));
}

test "dev islandModuleUrl matches the SSR pass's data-z-module (with and without a prefix)" {
    // The URL shape notifyIslands broadcasts must equal what the SSR pass
    // injected as data-z-module (basename, final extension stripped) —
    // INCLUDING the site's url_path_prefix (AUD-021), or the browser never
    // matches the mounted module and the hot-swap silently full-reloads.
    const gpa = std.testing.allocator;
    const stem = moduleStem("components/Counter.island.tsx");

    // No prefix: bare /islands/<stem>.js.
    const bare = islandModuleUrl(gpa, "", stem);
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("/islands/Counter.island.js", bare);

    // A prefix is prepended exactly as islands/pass.zig's `prefixed` does,
    // and leading/trailing slashes are normalized to a single joined form.
    const prefixed = islandModuleUrl(gpa, "docs", stem);
    defer gpa.free(prefixed);
    try std.testing.expectEqualStrings("/docs/islands/Counter.island.js", prefixed);

    const trailing = islandModuleUrl(gpa, "/docs/", stem);
    defer gpa.free(trailing);
    try std.testing.expectEqualStrings("/docs/islands/Counter.island.js", trailing);

    // A "/" prefix normalizes to empty (no double slash).
    const root_slash = islandModuleUrl(gpa, "/", stem);
    defer gpa.free(root_slash);
    try std.testing.expectEqualStrings("/islands/Counter.island.js", root_slash);
}

test "dev isNewer treats an mtime-preserving write as changed via ctime (AUD-017)" {
    const stat = struct {
        fn at(mtime_ns: i96, ctime_ns: i96) Io.File.Stat {
            return std.mem.zeroInit(Io.File.Stat, .{
                .mtime = .{ .nanoseconds = mtime_ns },
                .ctime = .{ .nanoseconds = ctime_ns },
            });
        }
    }.at;
    const cutoff: i128 = 1000;
    // Normal edit: both newer.
    try std.testing.expect(isNewer(stat(2000, 2000), cutoff));
    // Untouched: both older.
    try std.testing.expect(!isNewer(stat(500, 500), cutoff));
    // `cp -p`/`rsync -a`: mtime preserved (older) but the kernel bumped ctime
    // — still detected, which is the whole point of the ctime check.
    try std.testing.expect(isNewer(stat(500, 2000), cutoff));
    // Exactly at the cutoff is NOT newer (strict >).
    try std.testing.expect(!isNewer(stat(1000, 1000), cutoff));
}

test "dev freeIncremental releases pages and island modules" {
    const gpa = std.testing.allocator;
    var pages: std.ArrayListUnmanaged([]const u8) = .empty;
    try pages.append(gpa, try gpa.dupe(u8, "content/a.md"));
    var mods: std.ArrayListUnmanaged([]const u8) = .empty;
    try mods.append(gpa, try gpa.dupe(u8, "/islands/A.js"));
    freeIncremental(gpa, .{
        .pages = try pages.toOwnedSlice(gpa),
        .island_modules = try mods.toOwnedSlice(gpa),
    });
    // The default (static empty) island_modules slice must also be safe.
    var only_pages: std.ArrayListUnmanaged([]const u8) = .empty;
    try only_pages.append(gpa, try gpa.dupe(u8, "content/b.md"));
    freeIncremental(gpa, .{ .pages = try only_pages.toOwnedSlice(gpa) });
}

// --- conservative failure handling: truncated walks and process teardown -----

test "dev watcher: the per-OS watcher is compiled into this test binary" {
    // `Watcher` is referenced only from `dev()`'s body, which no test calls, so
    // without this the watcher file is never analyzed here and its own test
    // blocks (e.g. LinuxWatcher's close-on-exec check, which exists because the
    // dev loop spawns a rebuild command per change) are silently absent from
    // `zig build test-dev`.
    //
    // The `comptime` condition is load-bearing, not decorative: the watchers'
    // `start()` bodies call `std.Thread.spawn`, which is a hard @compileError
    // under `-fsingle-threaded`, and `refAllDecls` forces every pub decl to be
    // analyzed. A runtime `return error.SkipZigTest` would NOT help — Zig
    // semantically analyzes the whole function body regardless of runtime
    // control flow — so the branch has to be pruned at comptime instead. There
    // is no watcher thread to reference in a single-threaded build anyway; the
    // `zig build check -Dsingle-threaded` gate covers this file.
    if (comptime !builtin.single_threaded) std.testing.refAllDecls(Watcher);
}

/// Points fd 2 at /dev/null for the lifetime of the value (POSIX only).
///
/// The walk-failure diagnostic these tests exist to provoke is written to
/// stderr on purpose, and Zig's build runner fails a test step that produces
/// ANY stderr output. Redirecting the descriptor keeps `zig build test-dev`
/// clean without weakening the diagnostic where it matters (a real dev
/// session). Only the tests below use it.
const SilencedStderr = struct {
    saved_fd: c_int,
    null_file: Io.File,

    const Error = Io.File.OpenError || error{DescriptorRedirectFailed};

    fn begin(io: Io) Error!SilencedStderr {
        const null_file = try Io.Dir.cwd().openFile(io, "/dev/null", .{ .mode = .write_only });
        errdefer null_file.close(io);

        const saved_fd = std.c.dup(std.posix.STDERR_FILENO);
        if (saved_fd < 0) return error.DescriptorRedirectFailed;
        errdefer _ = std.c.close(saved_fd);

        if (std.c.dup2(null_file.handle, std.posix.STDERR_FILENO) < 0)
            return error.DescriptorRedirectFailed;
        return .{ .saved_fd = saved_fd, .null_file = null_file };
    }

    fn end(s: SilencedStderr, io: Io) void {
        // Nothing useful can be reported if restoring fails — stderr is gone.
        _ = std.c.dup2(s.saved_fd, std.posix.STDERR_FILENO);
        _ = std.c.close(s.saved_fd);
        s.null_file.close(io);
    }
};

test "dev dirHasChangeSince: a walk it cannot finish answers 'changed', not 'unchanged'" {
    // `Io.Dir.Walker.next` fails when it cannot descend into a subdirectory
    // (AccessDenied here, but SystemFdQuotaExceeded is the same shape). Folding
    // that into the end-of-iteration sentinel would report "no shared input
    // changed" for a tree that was never fully scanned — and a layout edit in
    // the unscanned part would be classified `.incremental` and never reach the
    // browser, while the loop printed "rebuild OK".
    if (builtin.os.tag == .windows) return error.SkipZigTest else {
        const gpa = std.testing.allocator;
        const io = std.testing.io;

        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        // A layouts/partials subtree the walker can see but not open.
        var sub = try tmp.dir.createDirPathOpen(io, "partials", .{});
        sub.close(io);
        try tmp.dir.writeFile(io, .{ .sub_path = "partials/nav.html", .data = "<nav/>" });

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

        // Nothing in the tree is newer than this cutoff, so a COMPLETED walk
        // legitimately answers false; only a truncated one can answer true.
        const cutoff = std.math.maxInt(i128);
        try std.testing.expect(!dirHasChangeSince(io, gpa, abs, cutoff));

        const no_access: Io.File.Permissions = @enumFromInt(0);
        try tmp.dir.setFilePermissions(io, "partials", no_access, .{});
        // Restore before cleanup, or `deleteTree` cannot remove the subtree.
        defer tmp.dir.setFilePermissions(io, "partials", .default_dir, .{}) catch {};

        const changed = blk: {
            const silence = try SilencedStderr.begin(io); // the walk failure logs
            defer silence.end(io);
            break :blk dirHasChangeSince(io, gpa, abs, cutoff);
        };
        try std.testing.expect(changed);
    }
}

test "dev reaper: a terminating signal kills the tracked zigbase (no orphan on the port)" {
    // The watch loop never returns, so nothing else ever tears the child down:
    // without this the zigbase of a killed dev session keeps holding the serve
    // port and the data dir, and the next `zigapagos dev` cannot bind.
    if (builtin.os.tag == .windows) return error.SkipZigTest else {
        const io = std.testing.io;

        var child = try std.process.spawn(io, .{
            .argv = &.{ "sleep", "60" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        reaper.track(child);
        reaper.terminate();

        const term = try child.wait(io);
        try std.testing.expectEqual(std.process.Child.Term{ .signal = .TERM }, term);

        // Idempotent: the pid is forgotten, so a second signal (a second
        // Ctrl-C, or SIGHUP racing SIGTERM) cannot hit a recycled pid.
        try std.testing.expectEqual(@as(std.posix.pid_t, 0), reaper.pid.load(.seq_cst));
        reaper.terminate();
    }
}

test "dev island manifest: version mismatch is treated as no manifest" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = RenderArena.from(&arena_state);
    // classifyChange's resolveIslandPages maps ANY parse error to "full
    // rebuild"; the version gate is what protects a manifest written by an
    // older/newer zigapagos from being misread.
    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        islands_manifest.parse(arena, "{\"version\":2,\"islands\":{}}"),
    );
}
