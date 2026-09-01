//! `zigapagos e2e` — the supported e2e harness.
//!
//! Production-faithful: the harness serves the RELEASE output tree with the
//! STOCK ZigBase binary — a real same-origin API plus the `.spa`-marker SPA
//! fallback (docs/spa.md, Tier 1) — so what the browser driver exercises is
//! what production serves. Orchestration:
//!
//!   1. locate zigbase (explicit → PATH → pinned cache; `zigbase.zig`),
//!   2. pick a free port and set up the data dir (default: a fresh temp dir
//!      per run, deleted on teardown, so runs are hermetic),
//!   3. boot `zigbase serve` over the site tree,
//!   4. readiness = the FIRST successful shell fetch: `GET ready-path` is
//!      polled until it returns 200 (drivers never hand-roll polling; the
//!      probe address is resolved once — a loopback literal, no DNS at all),
//!   5. run the user command with the origin exported as ZIGAPAGOS_ORIGIN,
//!   6. tear zigbase down (kill + reap on every path — success, failure, or a
//!      terminal signal, which hits the whole process group) and exit with
//!      the command's exit code.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
const zigbase = @import("zigbase.zig");
const root = @import("../root.zig");

/// Default `zigbase serve` invocation template, VERIFIED against the real
/// CLI (zigbase src/cli.zig `parse()` and `zigbase serve --help` of the
/// pinned release binary): flags are SPACE-SEPARATED — an exact-match flag
/// name whose value is the NEXT argv token, no `=` splitting — and unknown
/// flags are rejected (ParseError.UnknownFlag). `--serve-static` exists in
/// the stock/release binary because its comptime `static_mode` is `.default`
/// (zigbase src/main.zig wires no override; cli's ParseOpts gates the flag on
/// `static_mode == .default`); embedders who compile static serving out must
/// override this template via `--zigbase-arg=`. `{host}`,
/// `{port}`, `{site}` and `{data}` are substituted (see `substituteArg`;
/// e2e always substitutes `127.0.0.1` for `{host}` — its probe address is a
/// loopback literal — while the dev loop substitutes its `--host=`).
pub const default_zigbase_args: []const []const u8 = &.{
    "serve",
    "--http-host",
    "{host}",
    "--http-port",
    "{port}",
    "--data-dir",
    "{data}",
    "--serve-static",
    "{site}",
};

/// Poll interval for the readiness probe.
const poll_interval_ms = 250;

pub const Command = struct {
    /// The built site tree to serve (`--site=DIR`, required).
    site: []const u8,
    /// ZigBase data dir (`--data-dir=DIR`); null = fresh temp dir per run.
    data_dir: ?[]const u8,
    /// Explicit binary (`--zigbase=PATH`); null = PATH, then the pinned cache.
    zigbase_path: ?[]const u8,
    /// `--download-zigbase`: when the locator finds nothing, fetch the pinned
    /// release into the cache (SHA256-verified) instead of failing. Explicit
    /// opt-in — nothing is ever downloaded without it.
    download_zigbase: bool,
    /// Invocation template (`--zigbase-arg=`, repeatable; replaces the whole
    /// default template when at least one is given).
    zigbase_args: []const []const u8,
    /// The site's `url_path_prefix` (`--url-prefix=`, default ""; issue #152).
    /// When set, the built tree is mounted at `/<prefix>/` via a staged
    /// served root (`stageServedRoot`) instead of at the server root, so
    /// local URLs resolve the same way the site's own emitted hrefs do on a
    /// GitHub Pages project host.
    url_prefix: []const u8,
    /// Readiness probe path (`--ready-path=`, default "/", or
    /// "/<url_prefix>/" when `url_prefix` is set and this was never
    /// overridden -- see `ready_path_explicit`).
    ready_path: []const u8,
    /// True when `--ready-path=` was actually passed. `ready_path` above
    /// always holds SOME value (its plain "/" default predates url_prefix
    /// support and several tests pin it), so this is what lets `e2e()` tell
    /// "user override" from "compute the url_prefix-aware default" without
    /// changing that default or breaking those tests.
    ready_path_explicit: bool,
    /// Readiness budget in milliseconds (`--timeout-ms=`, default 120s).
    timeout_ms: u32,
    /// The user command (everything after `--`).
    argv: []const []const u8,

    /// Frees what `parse` allocated (unit tests only; the harness process
    /// exits with the child).
    pub fn deinit(cmd: *const Command, gpa: Allocator) void {
        if (cmd.zigbase_args.ptr != default_zigbase_args.ptr) gpa.free(cmd.zigbase_args);
        gpa.free(cmd.argv);
    }

    pub fn parse(gpa: Allocator, args: []const []const u8) error{OutOfMemory}!Command {
        var site: ?[]const u8 = null;
        var data_dir: ?[]const u8 = null;
        var zigbase_path: ?[]const u8 = null;
        var download_zigbase = false;
        var zigbase_args: std.ArrayListUnmanaged([]const u8) = .empty;
        var url_prefix: []const u8 = "";
        var ready_path: []const u8 = "/";
        var ready_path_explicit = false;
        var timeout_ms: u32 = 120_000;
        var argv: []const []const u8 = &.{};
        errdefer zigbase_args.deinit(gpa);
        errdefer if (argv.len != 0) gpa.free(argv);

        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.startsWith(u8, arg, "--site=")) {
                site = arg["--site=".len..];
            } else if (std.mem.startsWith(u8, arg, "--data-dir=")) {
                data_dir = arg["--data-dir=".len..];
            } else if (std.mem.startsWith(u8, arg, "--zigbase=")) {
                zigbase_path = arg["--zigbase=".len..];
            } else if (std.mem.eql(u8, arg, "--download-zigbase")) {
                download_zigbase = true;
            } else if (std.mem.startsWith(u8, arg, "--zigbase-arg=")) {
                try zigbase_args.append(gpa, arg["--zigbase-arg=".len..]);
            } else if (std.mem.startsWith(u8, arg, "--url-prefix=")) {
                url_prefix = arg["--url-prefix=".len..];
                // Same validation `zigapagos.ziggy`'s url_path_prefix gets at
                // config load (root.zig's Site-field validation loop) — this
                // flag skips that path entirely (e2e never loads a config),
                // so without its own check `--url-prefix=../../x` would
                // reach stageServedRoot's createDirPath/copyFile and stage
                // (and later, on the next call, deleteTree) a directory
                // OUTSIDE the intended staging root.
                if (root.validatePathMessage(url_prefix, .{ .empty = true })) |msg| fatal.usageError(
                    "error: --url-prefix '{s}': {s}\n",
                    .{ url_prefix, msg },
                );
            } else if (std.mem.startsWith(u8, arg, "--ready-path=")) {
                ready_path = arg["--ready-path=".len..];
                ready_path_explicit = true;
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
            } else if (std.mem.eql(u8, arg, "--")) {
                // Everything after `--` is the user command, verbatim.
                argv = try gpa.dupe([]const u8, args[idx + 1 ..]);
                break;
            } else fatal.usageError(
                "error: unexpected 'zigapagos e2e' argument '{s}'\n" ++ usage,
                .{arg},
            );
        }

        if (site == null or site.?.len == 0) fatal.usageError(
            "error: e2e needs --site=<built site dir>\n" ++ usage,
            .{},
        );
        if (argv.len == 0) fatal.usageError(
            "error: e2e mode needs a command to run after '--'\n" ++
                "usage: zigapagos e2e --site=DIR -- npx playwright test\n" ++ usage,
            .{},
        );

        const owned_zigbase_args = if (zigbase_args.items.len > 0)
            try zigbase_args.toOwnedSlice(gpa)
        else
            default_zigbase_args;
        errdefer if (owned_zigbase_args.ptr != default_zigbase_args.ptr)
            gpa.free(owned_zigbase_args);

        return .{
            .site = site.?,
            .data_dir = data_dir,
            .zigbase_path = zigbase_path,
            .download_zigbase = download_zigbase,
            .zigbase_args = owned_zigbase_args,
            .url_prefix = url_prefix,
            .ready_path = ready_path,
            .ready_path_explicit = ready_path_explicit,
            .timeout_ms = timeout_ms,
            .argv = argv,
        };
    }

    const usage =
        "usage: zigapagos e2e --site=DIR [--data-dir=DIR] [--zigbase=PATH]\n" ++
        "                     [--download-zigbase] [--zigbase-arg=ARG]...\n" ++
        "                     [--url-prefix=P] [--ready-path=/…]\n" ++
        "                     [--timeout-ms=N] -- CMD [ARGS...]\n";
};

pub fn e2e(
    io: Io,
    gpa: Allocator,
    args: []const []const u8,
    environ_map: *std.process.Environ.Map,
) error{OutOfMemory}!noreturn {
    const cmd: Command = try .parse(gpa, args);

    // (1) Locate zigbase (explicit → PATH → pinned cache). When nothing is
    // found, `--download-zigbase` — and only that explicit opt-in — fetches
    // the pinned release into the cache (SHA256-verified); otherwise fail
    // with instructions. No silent downloads — see zigbase.zig.
    const located: zigbase.Located = (try zigbase.locate(io, gpa, environ_map, cmd.zigbase_path)) orelse blk: {
        if (cmd.download_zigbase) break :blk .{
            .path = try zigbase.download(io, gpa, environ_map),
            .source = .cache,
        };
        const msg = try zigbase.missingMessage(gpa, environ_map);
        std.debug.print("{s}", .{msg});
        std.process.exit(1);
    };

    // (2) Free port + data dir.
    const port = pickFreePort(io);
    var port_buf: [5]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    const data_dir_is_temp = cmd.data_dir == null;
    const data_dir = cmd.data_dir orelse try makeFreshTempDataDir(io, gpa, environ_map);
    Io.Dir.cwd().createDirPath(io, data_dir) catch |err| fatal.msg(
        "error: e2e: unable to create the data dir '{s}': {s}\n",
        .{ data_dir, @errorName(err) },
    );

    // Mount at the url_path_prefix (issue #152): nested beside the data dir
    // so it shares its lifecycle (deleted with it when the data dir is the
    // per-run temp dir; reused across restarts otherwise) -- a no-op when
    // cmd.url_prefix is "" (see stageServedRoot's doc comment).
    const staging_root = std.fs.path.join(gpa, &.{ data_dir, ".served-root" }) catch fatal.oom();
    const served_root = stageServedRoot(io, gpa, staging_root, cmd.url_prefix, cmd.site) catch |err| fatal.msg(
        "error: e2e: unable to stage the served root: {s}\n",
        .{@errorName(err)},
    );
    const ready_path = if (cmd.ready_path_explicit)
        cmd.ready_path
    else
        try defaultReadyPath(gpa, cmd.url_prefix);

    // (3) Boot `zigbase serve` over the site tree.
    var zb_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try zb_argv.append(gpa, located.path);
    for (cmd.zigbase_args) |template| try zb_argv.append(
        gpa,
        try substituteArg(gpa, template, "127.0.0.1", port_str, served_root, data_dir),
    );

    std.debug.print("e2e: zigbase = {s} ({s}); serving {s} (data: {s})\ne2e: exec", .{
        located.path, @tagName(located.source), served_root, data_dir,
    });
    for (zb_argv.items) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});

    var harness: Harness = .{
        .io = io,
        .gpa = gpa,
        // stdio inherit (the spawn default): zigbase's own log streams through.
        .server = std.process.spawn(io, .{ .argv = zb_argv.items }) catch |err| fatal.msg(
            "error: e2e: failed to spawn zigbase ({s}): {s}\n",
            .{ located.path, @errorName(err) },
        ),
        .temp_data_dir = if (data_dir_is_temp) data_dir else null,
    };

    // (4) Readiness = the first successful shell fetch. The probe address is
    // resolved ONCE — and it is a loopback literal, so this never hits DNS.
    const address = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    waitReady(&harness, address, ready_path, cmd.timeout_ms);

    // (5) Run the user command with the origin exported.
    const origin = std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port}) catch fatal.oom();
    environ_map.put("ZIGAPAGOS_ORIGIN", origin) catch fatal.oom();

    std.debug.print("e2e: ready (GET {s} -> 200 at {s}); running:", .{ ready_path, origin });
    for (cmd.argv) |a| std.debug.print(" {s}", .{a});
    std.debug.print("\n", .{});

    // stdio inherit: the driver's output streams straight through this process
    // to whatever ran `zigapagos e2e`, so a failing test's output lands in the
    // terminal (or the CI log) unbuffered and in order rather than surfacing
    // only if this process chose to re-print it.
    var child = std.process.spawn(io, .{
        .argv = cmd.argv,
        .environ_map = environ_map,
    }) catch |err| harness.fail("failed to spawn '{s}': {s}", .{ cmd.argv[0], @errorName(err) });
    const term = child.wait(io) catch |err| harness.fail(
        "failed to wait for '{s}': {s}",
        .{ cmd.argv[0], @errorName(err) },
    );

    // (6) Teardown, then propagate the command's exit code.
    harness.teardown();
    switch (term) {
        .exited => |code| {
            std.debug.print("e2e: command exited with code {d}\n", .{code});
            std.process.exit(code);
        },
        else => {
            std.debug.print("e2e: command terminated abnormally ({s})\n", .{@tagName(term)});
            std.process.exit(1);
        },
    }
}

/// Everything that must be torn down once zigbase is running. All post-spawn
/// failure paths go through `fail`, so the server can never outlive the
/// harness on an orderly exit; a terminal SIGINT/SIGTERM reaches zigbase too
/// (same process group), and the harness process owns nothing else.
///
/// Shared with the `zigapagos dev` loop (`dev.zig`), which sets
/// `label = "dev"` and `temp_data_dir = null` (its data dir is persistent).
pub const Harness = struct {
    io: Io,
    gpa: Allocator,
    server: std.process.Child,
    /// Set when the data dir is the per-run temp dir (deleted on teardown).
    temp_data_dir: ?[]const u8,
    /// Prefix for `fail` diagnostics ("e2e" here, "dev" in the dev loop).
    label: []const u8 = "e2e",
    done: bool = false,

    /// Kill + reap zigbase (Child.kill blocks and is idempotent) and delete
    /// the per-run temp data dir. Safe to call more than once.
    pub fn teardown(h: *Harness) void {
        if (h.done) return;
        h.done = true;
        h.server.kill(h.io);
        if (h.temp_data_dir) |dir| Io.Dir.cwd().deleteTree(h.io, dir) catch {};
    }

    pub fn fail(h: *Harness, comptime fmt: []const u8, fail_args: anytype) noreturn {
        h.teardown();
        fatal.msg("error: {s}: " ++ fmt ++ "\n", .{h.label} ++ fail_args);
    }
};

/// Polls `GET ready_path` until the first 200 (readiness = first successful
/// shell fetch), failing through the harness after `timeout_ms`.
pub fn waitReady(h: *Harness, address: Io.net.IpAddress, ready_path: []const u8, timeout_ms: u32) void {
    const io = h.io;
    const start_ms = Io.Clock.awake.now(io).toMilliseconds();
    var last_status: ?u16 = null;
    var last_err: ?anyerror = null;
    while (true) {
        if (probeStatus(io, address, ready_path)) |status| {
            last_status = status;
            if (status == 200) return;
        } else |err| {
            last_err = err;
        }
        const passed = Io.Clock.awake.now(io).toMilliseconds() - start_ms;
        if (passed >= timeout_ms) {
            if (last_status) |status| h.fail(
                "'GET {s}' still answers {d} (want 200) after {d} ms\n" ++
                    "hint: point --ready-path at a page the site " ++
                    "actually serves, e.g. an SPA base like '/app/'",
                .{ ready_path, status, timeout_ms },
            ) else h.fail(
                "zigbase did not answer 'GET {s}' within {d} ms ({s})\n" ++
                    "hint: if your ZigBase spells its serve flags differently, override the " ++
                    "invocation via --zigbase-arg=",
                .{
                    ready_path,
                    timeout_ms,
                    if (last_err) |e| @errorName(e) else "no probe completed",
                },
            );
        }
        io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {};
    }
}

/// One readiness probe: `GET path` against the pre-resolved server address,
/// returning the HTTP status code. Any connect/read failure is an error (the
/// caller retries until its deadline).
fn probeStatus(io: Io, address: Io.net.IpAddress, path: []const u8) !u16 {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const out = &writer.interface;
    try out.print(
        "GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\nconnection: close\r\n\r\n",
        .{ path, address.getPort() },
    );
    try out.flush();

    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const in = &reader.interface;
    const status_line = try in.takeDelimiterInclusive('\n');
    return parseStatusCode(std.mem.trimEnd(u8, status_line, "\r\n"));
}

/// Parses the numeric code out of an HTTP status line ("HTTP/1.1 200 OK").
fn parseStatusCode(line: []const u8) !u16 {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedStatusLine;
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return std.fmt.parseInt(u16, rest[0..sp2], 10) catch error.MalformedStatusLine;
}

/// Binds 127.0.0.1:0, reads the OS-assigned port, and releases the socket for
/// zigbase to claim. The bind→spawn window is a benign race in practice (the
/// same pick-a-free-port approach the repo's own test scripts use).
pub fn pickFreePort(io: Io) u16 {
    const addr = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| fatal.msg(
        "error: unable to find a free port: {s}\n",
        .{@errorName(err)},
    );
    const port = server.socket.address.getPort();
    server.deinit(io);
    return port;
}

/// Creates the default per-run data dir under the OS temp dir (hermetic runs:
/// no state leaks between invocations). Deleted by `Harness.teardown`.
fn makeFreshTempDataDir(
    io: Io,
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) error{OutOfMemory}![]const u8 {
    const tmp_root = environ_map.get("TMPDIR") orelse
        environ_map.get("TEMP") orelse
        (if (builtin.os.tag == .windows) fatal.msg(
            "error: e2e: no TEMP dir in the environment; pass --data-dir=DIR\n",
            .{},
        ) else "/tmp");
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const name = try std.fmt.allocPrint(gpa, "zigapagos-e2e-{s}", .{hex});
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ tmp_root, name });
    Io.Dir.cwd().createDirPath(io, path) catch |err| fatal.msg(
        "error: e2e: unable to create the temp data dir '{s}': {s}\n",
        .{ path, @errorName(err) },
    );
    return path;
}

/// Substitutes every `{host}`, `{port}`, `{site}` and `{data}` in one
/// invocation-template arg. Caller owns the result. (`{host}` exists for the
/// dev loop, whose listen address is configurable; e2e always substitutes the
/// loopback literal its probe uses.)
pub fn substituteArg(
    gpa: Allocator,
    template: []const u8,
    host: []const u8,
    port_str: []const u8,
    site: []const u8,
    data: []const u8,
) error{OutOfMemory}![]const u8 {
    const step0 = try std.mem.replaceOwned(u8, gpa, template, "{host}", host);
    defer gpa.free(step0);
    const step1 = try std.mem.replaceOwned(u8, gpa, step0, "{port}", port_str);
    defer gpa.free(step1);
    const step2 = try std.mem.replaceOwned(u8, gpa, step1, "{site}", site);
    defer gpa.free(step2);
    return std.mem.replaceOwned(u8, gpa, step2, "{data}", data);
}

/// Stages a served root that mounts `site_dir_abs` at `/<prefix>/`, shared by
/// both `dev` (which threads `zigapagos.ziggy`'s `url_path_prefix` through)
/// and `e2e` (`--url-prefix=`, issue #152). Returns `site_dir_abs` UNCHANGED
/// when `prefix` trims to empty (the common, unprefixed case): no directory
/// is created and no filesystem work happens at all, so an unprefixed site's
/// `--serve-static` argument is byte-identical to what it was before this
/// existed.
///
/// The built tree deliberately contains no prefix directory (`url_path_prefix`
/// says where a host *mounts* it, not where files sit inside it -- see
/// `docs/spa.md`), so a root `--serve-static site_dir_abs` 404s every emitted
/// href/asset/island-module URL on a prefixed site. The obvious fix -- a
/// `<staging_root_abs>/<prefix>` SYMLINK into `site_dir_abs` -- does not work:
/// zigbase's static server canonicalizes every match and refuses to serve
/// anything whose real path escapes the served root (its own F10 hardening,
/// confirmed against zigbase's `static_files.zig` -- the F10 escape-guard and
/// its dedicated test), and a symlinked
/// prefix pointing outside the staging root is exactly that escape. It would
/// silently 404 every request instead of working. So the mirror has to be
/// REAL: every regular file under `site_dir_abs` is copied into
/// `<staging_root_abs>/<trimmed prefix>/`, preserving its relative path.
///
/// Each refresh is built completely at `<staging_root_abs>.next`, then swapped
/// into place with directory renames. A running zigbase therefore reads either
/// the last complete tree or the next complete tree, never a half-copied one.
/// The retired tree is removed after the swap; stale `.next`/`.previous` trees
/// from an interrupted prior refresh are removed before touching the live
/// tree. Re-copying also guarantees deleted pages and a prior, since-changed
/// `url_path_prefix` cannot linger.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): all joined paths are scratch
/// and freed before return; the only thing that escapes is `staging_root_abs`
/// or `site_dir_abs`, both borrowed from the caller.
pub fn stageServedRoot(
    io: Io,
    gpa: Allocator,
    staging_root_abs: []const u8,
    prefix: []const u8,
    site_dir_abs: []const u8,
) ![]const u8 {
    const trimmed = std.mem.trim(u8, prefix, "/");
    if (trimmed.len == 0) return site_dir_abs;

    const next_root_abs = try std.fmt.allocPrint(gpa, "{s}.next", .{staging_root_abs});
    defer gpa.free(next_root_abs);
    const previous_root_abs = try std.fmt.allocPrint(gpa, "{s}.previous", .{staging_root_abs});
    defer gpa.free(previous_root_abs);

    // Interrupted refreshes may leave either scratch tree behind. Remove them
    // before building, while the live tree remains untouched. `deleteTree`
    // deliberately treats FileNotFound as success, so this is also the normal
    // first-refresh path when neither scratch tree exists.
    try Io.Dir.cwd().deleteTree(io, next_root_abs);
    errdefer Io.Dir.cwd().deleteTree(io, next_root_abs) catch {};
    try Io.Dir.cwd().deleteTree(io, previous_root_abs);

    const prefix_dir_abs = try std.fs.path.join(gpa, &.{ next_root_abs, trimmed });
    defer gpa.free(prefix_dir_abs);
    try Io.Dir.cwd().createDirPath(io, prefix_dir_abs);

    // Close the directory handles before the rename, which is required on
    // platforms that do not permit renaming an open directory.
    {
        var src_dir = try Io.Dir.cwd().openDir(io, site_dir_abs, .{ .iterate = true });
        defer src_dir.close(io);
        var dst_dir = try Io.Dir.cwd().openDir(io, prefix_dir_abs, .{});
        defer dst_dir.close(io);

        var it = try src_dir.walk(gpa);
        defer it.deinit();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // `entry.dir`/`entry.basename` (not `site_dir_abs`/`entry.path`) as
            // the SOURCE side avoids `error.NameTooLong` on a deeply nested
            // tree -- see `Walker.Entry`'s own doc comment.
            try entry.dir.copyFile(entry.basename, dst_dir, entry.path, io, .{ .make_path = true });
        }
    }

    const moved_live = blk: {
        Io.Dir.renameAbsolute(staging_root_abs, previous_root_abs, io) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    Io.Dir.renameAbsolute(next_root_abs, staging_root_abs, io) catch |swap_err| {
        // Preserve the last good tree if publishing the completed replacement
        // fails after the first rename.
        if (moved_live) Io.Dir.renameAbsolute(previous_root_abs, staging_root_abs, io) catch {};
        return swap_err;
    };
    if (moved_live) Io.Dir.cwd().deleteTree(io, previous_root_abs) catch {};

    return staging_root_abs;
}

/// The readiness-probe path (and banner URL suffix) for a site with no
/// explicit `--ready-path=` override: `"/"` when unprefixed, or
/// `"/<trimmed prefix>/"` when a `url_path_prefix` is set. `GET /` 404s by
/// design on a prefixed site (`stageServedRoot`'s served root has no content
/// outside `/<prefix>/`), so probing bare `/` would spin until the timeout
/// waiting for a 200 that can never come.
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): `trimmed` borrows `prefix`;
/// only the formatted return value (or the static `"/"`) escapes.
pub fn defaultReadyPath(gpa: Allocator, prefix: []const u8) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, prefix, "/");
    if (trimmed.len == 0) return "/";
    return std.fmt.allocPrint(gpa, "/{s}/", .{trimmed});
}

// --- unit tests (run via `zig build test-e2e`, filter "e2e") -------------------
// fatal.usageError paths (missing --site, empty command, unknown arg) exit the
// process and are exercised by tests/dev/e2e.sh instead.

test "e2e stageServedRoot first use swaps complete trees and preserves the last good tree on failure" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_abs);
    const site_abs = try std.fs.path.join(gpa, &.{ root_abs, "site" });
    defer gpa.free(site_abs);
    const missing_site_abs = try std.fs.path.join(gpa, &.{ root_abs, "missing-site" });
    defer gpa.free(missing_site_abs);
    const staging_abs = try std.fs.path.join(gpa, &.{ root_abs, ".served-root" });
    defer gpa.free(staging_abs);
    const staged_page_abs = try std.fs.path.join(gpa, &.{ staging_abs, "docs/v2/index.html" });
    defer gpa.free(staged_page_abs);

    var site = try tmp.dir.createDirPathOpen(io, "site", .{});
    defer site.close(io);
    try site.writeFile(io, .{ .sub_path = "index.html", .data = "version one" });

    try std.testing.expectEqualStrings(
        staging_abs,
        try stageServedRoot(io, gpa, staging_abs, "/docs/v2/", site_abs),
    );
    var staged = try Io.Dir.cwd().readFileAlloc(io, staged_page_abs, gpa, .unlimited);
    try std.testing.expectEqualStrings("version one", staged);
    gpa.free(staged);

    try site.writeFile(io, .{ .sub_path = "index.html", .data = "version two" });
    _ = try stageServedRoot(io, gpa, staging_abs, "/docs/v2/", site_abs);
    staged = try Io.Dir.cwd().readFileAlloc(io, staged_page_abs, gpa, .unlimited);
    try std.testing.expectEqualStrings("version two", staged);
    gpa.free(staged);

    try std.testing.expectError(
        error.FileNotFound,
        stageServedRoot(io, gpa, staging_abs, "/docs/v2/", missing_site_abs),
    );
    staged = try Io.Dir.cwd().readFileAlloc(io, staged_page_abs, gpa, .unlimited);
    defer gpa.free(staged);
    try std.testing.expectEqualStrings("version two", staged);
}

test "e2e parse: site + '--' argv, with documented defaults" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{ "--site=/out/site", "--", "npx", "playwright", "test" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/out/site", cmd.site);
    try std.testing.expect(cmd.data_dir == null); // default: fresh temp per run
    try std.testing.expect(cmd.zigbase_path == null); // default: PATH, then cache
    try std.testing.expect(!cmd.download_zigbase); // default: never download
    try std.testing.expectEqual(default_zigbase_args.ptr, cmd.zigbase_args.ptr);
    try std.testing.expectEqualStrings("/", cmd.ready_path);
    try std.testing.expectEqual(@as(u32, 120_000), cmd.timeout_ms);
    try std.testing.expectEqual(@as(usize, 3), cmd.argv.len);
    try std.testing.expectEqualStrings("npx", cmd.argv[0]);
    try std.testing.expectEqualStrings("test", cmd.argv[2]);
}

test "e2e parse: allocation failures free partial command state" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            const cmd = try Command.parse(gpa, &.{
                "--site=public",
                "--zigbase-arg=serve",
                "--zigbase-arg=--port={port}",
                "--",
                "bun",
                "test",
            });
            defer cmd.deinit(gpa);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "e2e parse: every knob is threaded through" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{
        "--site=out",
        "--data-dir=/tmp/zb-data",
        "--zigbase=/opt/zigbase",
        "--download-zigbase",
        "--zigbase-arg=serve",
        "--zigbase-arg=--listen",
        "--zigbase-arg=127.0.0.1:{port}",
        "--ready-path=/app/",
        "--timeout-ms=5000",
        "--",
        "true",
    });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp/zb-data", cmd.data_dir.?);
    try std.testing.expectEqualStrings("/opt/zigbase", cmd.zigbase_path.?);
    try std.testing.expect(cmd.download_zigbase);
    // any --zigbase-arg replaces the WHOLE default template
    try std.testing.expectEqual(@as(usize, 3), cmd.zigbase_args.len);
    try std.testing.expectEqualStrings("serve", cmd.zigbase_args[0]);
    try std.testing.expectEqualStrings("--listen", cmd.zigbase_args[1]);
    try std.testing.expectEqualStrings("127.0.0.1:{port}", cmd.zigbase_args[2]);
    try std.testing.expectEqualStrings("/app/", cmd.ready_path);
    try std.testing.expectEqual(@as(u32, 5000), cmd.timeout_ms);
}

test "e2e default zigbase invocation matches the verified serve CLI" {
    // Pins the contract read from zigbase src/cli.zig and confirmed by
    // `zigbase serve --help` of the pinned release binary: space-separated,
    // exact-match flag names, value = next argv token (no '=' splitting).
    // `{host}` is substituted at boot (e2e: always "127.0.0.1"; dev: --host=).
    const want = [_][]const u8{
        "serve",
        "--http-host",
        "{host}",
        "--http-port",
        "{port}",
        "--data-dir",
        "{data}",
        "--serve-static",
        "{site}",
    };
    try std.testing.expectEqual(want.len, default_zigbase_args.len);
    for (want, default_zigbase_args) |w, got| try std.testing.expectEqualStrings(w, got);
    // No template token smuggles an '=' value — the real parser would treat
    // the whole token as an (unknown) flag name and reject it.
    for (default_zigbase_args) |a| {
        if (a[0] == '-') try std.testing.expect(std.mem.indexOfScalar(u8, a, '=') == null);
    }
}

test "e2e parse: everything after '--' is child argv verbatim (no flag parsing)" {
    const gpa = std.testing.allocator;
    const cmd = try Command.parse(gpa, &.{ "--site=out", "--", "bash", "-c", "exit 7", "--site=x" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("out", cmd.site);
    try std.testing.expectEqual(@as(usize, 4), cmd.argv.len);
    try std.testing.expectEqualStrings("--site=x", cmd.argv[3]);
}

test "e2e substituteArg replaces {host}/{port}/{site}/{data} everywhere" {
    const gpa = std.testing.allocator;
    const s = try substituteArg(gpa, "{host}:{port}", "127.0.0.1", "49213", "/out", "/data");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("127.0.0.1:49213", s);
    const s2 = try substituteArg(gpa, "{site}:{data}:{site}", "h", "0", "/out", "/d");
    defer gpa.free(s2);
    try std.testing.expectEqualStrings("/out:/d:/out", s2);
    const s3 = try substituteArg(gpa, "plain", "h", "0", "/out", "/d");
    defer gpa.free(s3);
    try std.testing.expectEqualStrings("plain", s3);
}

test "e2e parseStatusCode extracts the code" {
    try std.testing.expectEqual(@as(u16, 200), try parseStatusCode("HTTP/1.1 200 OK"));
    try std.testing.expectEqual(@as(u16, 404), try parseStatusCode("HTTP/1.0 404"));
    try std.testing.expectError(error.MalformedStatusLine, parseStatusCode("garbage"));
}
