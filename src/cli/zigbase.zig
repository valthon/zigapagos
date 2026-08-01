//! ZigBase binary locator — a standalone module shared by every workflow that
//! needs the production server (`zigapagos dev`, `zigapagos e2e`).
//!
//! Resolution order (`locate`):
//!   1. an explicit path (`--zigbase=`),
//!   2. `zigbase` on PATH,
//!   3. the pinned release in the zigapagos cache (see `cachedPath`).
//!
//! `locate` itself never downloads: fetching the pinned GitHub release into the
//! cache is the separate `download` step, SHA256-verified against the release's
//! published SHA256SUMS. WHO calls it differs by command, deliberately:
//!
//!   * `dev` calls it whenever `locate` comes up empty. It is the zero-config
//!     entry point and cannot start without a server, so the fetch is the
//!     default and `--no-download` opts out.
//!   * `e2e` never calls it unless asked (`--download-zigbase`). It runs in
//!     CI, where an unannounced
//!     network fetch is a supply-chain surprise rather than a convenience.
//!
//! `missingMessage` is what a user sees when nothing resolved AND no download
//! will be attempted — `dev --no-download`, `e2e` without the flag, or a
//! platform the release channel publishes no asset for.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");

/// The ZigBase release zigapagos is pinned to: the latest published release,
/// verified against this harness. (The `.spa`-marker contract needs >= 0.10.0;
/// the `serve` CLI flags used by e2e are identical from v0.10.0 through main.)
///
/// v0.12.0 ships four BREAKING changes, none of which reach this consumer:
/// they are all library/embedding API (`RequestArena` replacing bare
/// `Allocator` on the request seams, `jwt.sign` gaining `error.TokenTooLarge`),
/// a build option only a from-source embedder passes (`-Ddev-clock` renamed
/// `-Ddev-mode`), or a file-download token rule for hand-built URLs. zigapagos
/// drives a PREBUILT zigbase as a standalone binary over its `serve` CLI, and
/// that surface is byte-identical across the two tags: diffing `src/cli.zig`
/// between v0.11.0 and v0.12.0 shows the only additions are the new `import`
/// subcommand and `typegen --lang/--package`, with `serve`'s flags
/// (`--http-host`, `--http-port`, `--data-dir`, `--serve-static`,
/// `--insecure-cookies`) and their defaults untouched.
pub const pinned_version = "v0.12.0";

/// The GitHub repo the pinned release is published under.
pub const release_repo = "valthon/zigbase";

/// Platform spelling of the binary name.
pub const exe_name = if (builtin.os.tag == .windows) "zigbase.exe" else "zigbase";

/// This host's release-asset target (the release channel publishes
/// `zigbase-<ver>-<target>.tar.gz` for these), or null when the channel
/// ships no asset for this platform.
pub const asset_target: ?[]const u8 = switch (builtin.os.tag) {
    .linux => switch (builtin.cpu.arch) {
        .x86_64 => "x86_64-linux-musl",
        .aarch64 => "aarch64-linux-musl",
        else => null,
    },
    .macos => switch (builtin.cpu.arch) {
        .x86_64 => "x86_64-macos",
        .aarch64 => "aarch64-macos",
        else => null,
    },
    else => null,
};

pub const Source = enum { explicit, path_env, cache };

pub const Located = struct {
    /// Allocated with the `gpa` passed to `locate`.
    path: []const u8,
    source: Source,
};

/// Finds a zigbase binary, or returns null when none exists anywhere in the
/// resolution order (callers then either `download` — if the user asked — or
/// fail with `missingMessage`).
pub fn locate(
    io: Io,
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) error{OutOfMemory}!?Located {
    // 1. Explicit path: taken verbatim (spawn will surface a bad path loudly).
    if (explicit) |p| return .{ .path = try gpa.dupe(u8, p), .source = .explicit };

    // 2. PATH search for an executable `zigbase`.
    if (environ_map.get("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(gpa, &.{ dir, exe_name });
            if (isExecutable(io, candidate)) return .{ .path = candidate, .source = .path_env };
            gpa.free(candidate);
        }
    }

    // 3. The pinned release in the zigapagos cache.
    if (try cachedPath(gpa, environ_map)) |candidate| {
        if (isExecutable(io, candidate)) return .{ .path = candidate, .source = .cache };
        gpa.free(candidate);
    }

    return null;
}

fn isExecutable(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Where the pinned release lives in the cache:
/// `<cache-root>/zigapagos/zigbase/<pinned_version>/<exe_name>` with
/// cache-root = `$XDG_CACHE_HOME`, else `$HOME/.cache` (POSIX), or
/// `%LOCALAPPDATA%` (Windows). Returns null when no cache root can be derived
/// from the environment. Caller owns the returned path.
pub fn cachedPath(
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) error{OutOfMemory}!?[]const u8 {
    if (builtin.os.tag == .windows) {
        const root = environ_map.get("LOCALAPPDATA") orelse return null;
        return try std.fs.path.join(gpa, &.{ root, "zigapagos", "zigbase", pinned_version, exe_name });
    }
    if (environ_map.get("XDG_CACHE_HOME")) |root| {
        if (root.len > 0) return try std.fs.path.join(
            gpa,
            &.{ root, "zigapagos", "zigbase", pinned_version, exe_name },
        );
    }
    const home = environ_map.get("HOME") orelse return null;
    return try std.fs.path.join(gpa, &.{ home, ".cache", "zigapagos", "zigbase", pinned_version, exe_name });
}

/// `zigbase-<ver-sans-v>-<target>.tar.gz`, or null on platforms with no
/// published asset. Caller owns the result.
pub fn assetName(gpa: Allocator) error{OutOfMemory}!?[]const u8 {
    const target = asset_target orelse return null;
    return try std.fmt.allocPrint(gpa, "zigbase-{s}-{s}.tar.gz", .{ pinned_version[1..], target });
}

/// Download URL for one file of the pinned release. Caller owns the result.
pub fn releaseUrl(gpa: Allocator, file: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "https://github.com/{s}/releases/download/{s}/{s}",
        .{ release_repo, pinned_version, file },
    );
}

/// Downloads the pinned release into the cache: fetches the tarball +
/// SHA256SUMS via curl, verifies the tarball's SHA256 in-process against the
/// published sums, extracts (tar --strip-components=1, so the binary lands
/// exactly at `cachedPath`), and returns the binary path. All failures are
/// fatal with an actionable message.
///
/// Called implicitly by `dev` when nothing resolves, and only on explicit
/// request (`--download-zigbase`) by `e2e` —
/// see this file's module doc for why the two differ.
pub fn download(
    io: Io,
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) error{OutOfMemory}![]const u8 {
    const asset = (try assetName(gpa)) orelse fatal.msg(
        "error: the {s} release channel publishes no asset for this platform;\n" ++
            "install zigbase on PATH or pass --zigbase=<path> instead\n",
        .{pinned_version},
    );
    const exe_path = (try cachedPath(gpa, environ_map)) orelse fatal.msg(
        "error: cannot derive a cache dir (set HOME or XDG_CACHE_HOME), " ++
            "or pass --zigbase=<path>\n",
        .{},
    );
    const dir = std.fs.path.dirname(exe_path).?;
    Io.Dir.cwd().createDirPath(io, dir) catch |err| fatal.msg(
        "error: unable to create the zigbase cache dir '{s}': {s}\n",
        .{ dir, @errorName(err) },
    );

    const url = try releaseUrl(gpa, asset);
    const sums_url = try releaseUrl(gpa, "SHA256SUMS");
    const tar_path = try std.fs.path.join(gpa, &.{ dir, asset });
    const sums_path = try std.fs.path.join(gpa, &.{ dir, "SHA256SUMS" });

    std.debug.print("e2e: downloading {s}\n", .{url});
    runStep(io, &.{ "curl", "-fSL", "--retry", "2", "-o", tar_path, url }, "download the zigbase release");
    runStep(io, &.{ "curl", "-fSL", "--retry", "2", "-o", sums_path, sums_url }, "download the release SHA256SUMS");
    verifySha256(io, gpa, tar_path, sums_path, asset);
    // The tarball wraps everything in a `zigbase-<ver>-<target>/` directory;
    // strip it so the binary lands at `<dir>/zigbase` — the exact cachedPath.
    runStep(io, &.{ "tar", "-xzf", tar_path, "-C", dir, "--strip-components=1" }, "extract the zigbase release");
    Io.Dir.cwd().deleteFile(io, tar_path) catch {};
    Io.Dir.cwd().deleteFile(io, sums_path) catch {};

    if (!isExecutable(io, exe_path)) fatal.msg(
        "error: the extracted {s} release did not contain '{s}' at {s}\n",
        .{ pinned_version, exe_name, exe_path },
    );
    std.debug.print("e2e: verified and cached zigbase at {s}\n", .{exe_path});
    return exe_path;
}

/// Spawns one download/extract step (stdio inherited) and fatals on failure.
fn runStep(io: Io, argv: []const []const u8, what: []const u8) void {
    var child = std.process.spawn(io, .{ .argv = argv }) catch |err| fatal.msg(
        "error: unable to {s}: spawning '{s}' failed: {s}\n",
        .{ what, argv[0], @errorName(err) },
    );
    const term = child.wait(io) catch |err| fatal.msg(
        "error: unable to {s}: waiting for '{s}' failed: {s}\n",
        .{ what, argv[0], @errorName(err) },
    );
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    fatal.msg("error: failed to {s} ('{s}' exited non-zero)\n", .{ what, argv[0] });
}

/// Verifies `tar_path`'s SHA256 against the entry for `asset` in the release's
/// SHA256SUMS (lines are `<hex>  ./<file>`). In-process hashing — no external
/// sha tool needed. Fatal on mismatch or a missing entry.
fn verifySha256(io: Io, gpa: Allocator, tar_path: []const u8, sums_path: []const u8, asset: []const u8) void {
    const data = Io.Dir.cwd().readFileAlloc(io, tar_path, gpa, .unlimited) catch |err| fatal.msg(
        "error: unable to read the downloaded tarball '{s}': {s}\n",
        .{ tar_path, @errorName(err) },
    );
    defer gpa.free(data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);

    const sums = Io.Dir.cwd().readFileAlloc(io, sums_path, gpa, .unlimited) catch |err| fatal.msg(
        "error: unable to read the downloaded SHA256SUMS '{s}': {s}\n",
        .{ sums_path, @errorName(err) },
    );
    defer gpa.free(sums);
    var it = std.mem.splitScalar(u8, sums, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len < 64 + 1) continue;
        const hash = line[0..64];
        var name = std.mem.trimStart(u8, line[64..], " \t*");
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (!std.mem.eql(u8, name, asset)) continue;
        if (std.ascii.eqlIgnoreCase(hash, &got)) return;
        fatal.msg(
            "error: SHA256 mismatch for {s}\n  published: {s}\n  downloaded: {s}\n",
            .{ asset, hash, &got },
        );
    }
    fatal.msg("error: {s} is not listed in the release SHA256SUMS\n", .{asset});
}

/// The "no zigbase anywhere" guidance. Caller owns the returned message.
pub fn missingMessage(
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) error{OutOfMemory}![]const u8 {
    const cache = try cachedPath(gpa, environ_map);
    defer if (cache) |c| gpa.free(c);
    return std.fmt.allocPrint(gpa,
        \\error: zigbase binary not found
        \\
        \\This workflow serves the built site with the STOCK ZigBase binary
        \\(production-faithful: real same-origin API + '.spa'-marker SPA fallback),
        \\and this run will not fetch one for you. Pick one:
        \\
        \\  1. install zigbase on your PATH. In an npm project that is
        \\     `npm i -D @zigbase/server@{s}`, with no flag: npm puts
        \\     node_modules/.bin on PATH for `npm run` scripts and for `npx`, and
        \\     this search reads PATH. (A bare shell does not, so use one of
        \\     those.) The SCOPED package at that exact version, not the bare
        \\     `zigbase` alias -- the alias was published exactly once, so 0.12.0
        \\     is the only version it will ever have. It matches the pin above
        \\     only for as long as the pin stays there; the next bump leaves you
        \\     with a zigbase that is not the one option 3 downloads. Only the
        \\     scoped package carries the whole release history, so only it can
        \\     follow this pin. (Installing zigapagos itself from npm already brings
        \\     this along, so you are here only if you got zigapagos some other
        \\     way.) Or
        \\  2. point at a binary explicitly: --zigbase=/path/to/zigbase
        \\     or
        \\  3. let zigapagos fetch the pinned release ({s}) for you: that is what
        \\     `zigapagos dev` does by default (you are seeing this because of
        \\     --no-download), and what `zigapagos e2e --download-zigbase` does on
        \\     request. It
        \\     downloads github.com/{s} release {s} into
        \\       {s}
        \\     after verifying it against the release's SHA256SUMS. (Placing the
        \\     binary there yourself works too.)
        \\
    , .{
        pinned_version[1..],
        pinned_version,
        release_repo,
        pinned_version,
        cache orelse "<cache dir unavailable: set HOME/XDG_CACHE_HOME>",
    });
}

// --- unit tests (run via `zig build test-e2e`, filter "e2e") -------------------

test "e2e zigbase: explicit path wins without touching PATH or the cache" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const located = (try locate(std.testing.io, gpa, &env, "/opt/zb/zigbase")).?;
    defer gpa.free(located.path);
    try std.testing.expectEqualStrings("/opt/zb/zigbase", located.path);
    try std.testing.expectEqual(Source.explicit, located.source);
}

test "e2e zigbase: empty environment yields null (and a message that still guides)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try std.testing.expect((try locate(std.testing.io, gpa, &env, null)) == null);
    const msg = try missingMessage(gpa, &env);
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "zigbase binary not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, pinned_version) != null);
    // Both escape hatches are named, because this one message is reached from
    // BOTH commands and their download policies are opposites: `dev` fetches by
    // default (so the reader got here via --no-download) while `e2e` fetches
    // only on --download-zigbase. Naming just one leaves half the readers with
    // advice that does not apply to the command they ran.
    try std.testing.expect(std.mem.indexOf(u8, msg, "--download-zigbase") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--no-download") != null);
    // The npm route is a real answer to option 1, verified end to end: the
    // dependency's bin lands in node_modules/.bin, which `locate` scans, so `dev`
    // boots with no flag. It is named here because this message is where a user
    // actually is when they need it, and an npm project is now a first-class way
    // to get zigapagos (see npm/).
    //
    // The SCOPED package, at the pinned version. The bare `zigbase` alias was
    // published exactly once, so 0.12.0 is the only version it will ever have:
    // it happens to equal today's pin and stops matching at the next bump, at
    // which point advising it here would hand the user a different zigbase than
    // option 3 of this very message downloads -- the install-path split that
    // npm/check-toolchain.mjs exists to prevent, reintroduced through the
    // guidance instead of the manifest. That the two agree right now is exactly
    // why the wording has to name the alias rather than the version.
    try std.testing.expect(
        std.mem.indexOf(u8, msg, "npm i -D @zigbase/server@" ++ pinned_version[1..]) != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, msg, "not the bare") != null);
    // ...along with the one condition that makes it fail: outside `npm run`/`npx`,
    // node_modules/.bin is not on PATH, and then the advice above looks broken.
    try std.testing.expect(std.mem.indexOf(u8, msg, "node_modules/.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "bare shell") != null);
}

test "e2e zigbase: cachedPath honors XDG_CACHE_HOME, then HOME/.cache" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try env.put("HOME", "/home/u");
    {
        const p = (try cachedPath(gpa, &env)).?;
        defer gpa.free(p);
        try std.testing.expectEqualStrings(
            "/home/u/.cache/zigapagos/zigbase/" ++ pinned_version ++ "/zigbase",
            p,
        );
    }
    try env.put("XDG_CACHE_HOME", "/xdg");
    {
        const p = (try cachedPath(gpa, &env)).?;
        defer gpa.free(p);
        try std.testing.expectEqualStrings(
            "/xdg/zigapagos/zigbase/" ++ pinned_version ++ "/zigbase",
            p,
        );
    }
}

test "e2e zigbase: release asset name + URL match the channel's naming" {
    // Verified against `gh release view v0.12.0` (valthon/zigbase): assets are
    // zigbase-<ver>-<target>.tar.gz plus SHA256SUMS, under
    // github.com/valthon/zigbase/releases/download/<tag>/.
    const gpa = std.testing.allocator;
    if (try assetName(gpa)) |asset| {
        defer gpa.free(asset);
        try std.testing.expect(std.mem.startsWith(u8, asset, "zigbase-" ++ pinned_version[1..] ++ "-"));
        try std.testing.expect(std.mem.endsWith(u8, asset, ".tar.gz"));
        const url = try releaseUrl(gpa, asset);
        defer gpa.free(url);
        const want_prefix = "https://github.com/" ++ release_repo ++
            "/releases/download/" ++ pinned_version ++ "/";
        try std.testing.expect(std.mem.startsWith(u8, url, want_prefix));
    }
}
