//! Configure-time inputs of the in-repo build: the `-D` user options and the
//! git-derived version. `parse` must be called first in `build()` — the order
//! of `b.option` calls is the order they appear in `zig build --help`.

const std = @import("std");
const exe = @import("exe.zig");

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: Version,
    tsan: bool,
    enable_tracy: bool,
    highlight: bool,
    single_threaded: ?bool,
    scopes: []const []const u8,

    /// The dev executable's wiring, straight from the user options.
    pub fn exeConfig(cfg: Config) exe.ZigapagosExeConfig {
        return .{
            .target = cfg.target,
            .optimize = cfg.optimize,
            .version_string = cfg.version.string(),
            .tsan = cfg.tsan,
            .enable_tracy = cfg.enable_tracy,
            .highlight = cfg.highlight,
            .scopes = cfg.scopes,
            .single_threaded = cfg.single_threaded,
        };
    }
};

pub fn parse(b: *std.Build) Config {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        // .preferred_optimize_mode = .ReleaseFast,
    });

    const version: Version = if (b.option(
        bool,
        "preview",
        "Make a preview release of Zigapagos",
    ) orelse false) .{
        .tag = getVersion(b).commit,
    } else getVersion(b);

    const tsan = b.option(
        bool,
        "tsan",
        "enable thread sanitizer",
    ) orelse false;

    const enable_tracy = b.option(
        bool,
        "tracy",
        "Enable Tracy profiling",
    ) orelse false;

    const highlight = b.option(
        bool,
        "highlight",
        "Include treesitter grammars for build-time syntax highlighting (enabled by default). Disabling reduces executable size significantly.",
    ) orelse true;

    const single_threaded = b.option(
        bool,
        "single-threaded",
        "build Zigapagos in single-threaded mode",
    );

    const scopes: []const []const u8 = b.option(
        []const []const u8,
        "scope",
        "logging scopes to enable",
    ) orelse &.{};

    return .{
        .target = target,
        .optimize = optimize,
        .version = version,
        .tsan = tsan,
        .enable_tracy = enable_tracy,
        .highlight = highlight,
        .single_threaded = single_threaded,
        .scopes = scopes,
    };
}

pub const Version = union(Kind) {
    tag: []const u8,
    commit: []const u8,
    // not in a git repo
    unknown,

    pub const Kind = enum { tag, commit, unknown };

    pub fn string(v: Version) []const u8 {
        return switch (v) {
            .tag, .commit => |tc| tc,
            .unknown => "unknown",
        };
    }
};

fn getVersion(b: *std.Build) Version {
    const git_path = b.findProgram(&.{"git"}, &.{}) catch return .unknown;
    var out: u8 = undefined;
    const git_describe = std.mem.trim(
        u8,
        b.runAllowFail(&[_][]const u8{
            git_path,            "-C",
            b.build_root.path.?, "describe",
            "--match",           "*.*.*",
            "--tags",
        }, &out, .ignore) catch return .unknown,
        " \n\r",
    );

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => return .{ .tag = git_describe },
        2 => {
            // Untagged development build (e.g. 0.8.0-684-gbbe2cca1a).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.next() orelse unreachable;
            const commit_height = it.next() orelse unreachable;
            const commit_id = it.next() orelse unreachable;

            // Check that the commit hash is prefixed with a 'g'
            // (it's a Git convention)
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.panic("Unexpected `git describe` output: {s}\n", .{git_describe});
            }

            // The version is reformatted in accordance with
            // the https://semver.org specification.
            return .{
                .commit = b.fmt("{s}-dev.{s}+{s}", .{
                    tagged_ancestor,
                    commit_height,
                    commit_id[1..],
                }),
            };
        },
        else => unreachable,
    }
}
