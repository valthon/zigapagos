//! Configure-time inputs of the in-repo build: the `-D` user options and the
//! manifest version and Git commit. `parse` must be called first in `build()` — the order
//! of `b.option` calls is the order they appear in `zig build --help`.

const std = @import("std");
const exe = @import("exe.zig");

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    commit: []const u8,
    tsan: bool,
    enable_tracy: bool,
    highlight: bool,
    single_threaded: ?bool,
    scopes: []const []const u8,

    /// The dev executable's wiring, straight from the user options.
    pub fn exeConfig(cfg: Config) exe.ZigapagosExeConfig {
        return .{
            .commit = cfg.commit,
            .target = cfg.target,
            .optimize = cfg.optimize,
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
    const optimize = b.standardOptimizeOption(.{});

    const commit = b.option([]const u8, "commit", "Git commit SHA (CI/release override)") orelse gitCommit(b);

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
        .commit = commit,
        .tsan = tsan,
        .enable_tracy = enable_tracy,
        .highlight = highlight,
        .single_threaded = single_threaded,
        .scopes = scopes,
    };
}

fn gitCommit(b: *std.Build) []const u8 {
    return gitCommitFromFs(b) orelse "unknown";
}

// Adapted from ZigBase 9bd78289. Missing files must also invalidate configure:
// this compiler cannot hash an absent file, so track its nearest existing parent.
fn trackMissing(b: *std.Build, path: []const u8) void {
    var parent = std.fs.path.dirname(path) orelse ".";
    while (true) {
        if (std.Io.Dir.cwd().openDir(b.graph.io, parent, .{})) |opened| {
            var dir = opened;
            dir.close(b.graph.io);
            b.dependOnDirectoryContents(b.graph.cwdRelativePath(parent));
            return;
        } else |_| {}
        parent = std.fs.path.dirname(parent) orelse return;
    }
}

fn readGitFile(b: *std.Build, path: []const u8) ![]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(64 * 1024 * 1024)) catch |err| {
        trackMissing(b, path);
        return err;
    };
    b.dependOnFileMetadata(b.graph.cwdRelativePath(path));
    return bytes;
}

/// Spawn-free HEAD detection for normal repos, worktrees, loose and packed refs.
fn gitCommitFromFs(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const root = b.root.joinString(b.allocator, "") catch return null;
    const dot_git = b.fmt("{s}/.git", .{root});
    const git_dir: []const u8 = blk: {
        if (cwd.openDir(io, dot_git, .{})) |opened| {
            var dir = opened;
            dir.close(io);
            b.dependOnDirectoryMetadata(b.graph.cwdRelativePath(dot_git));
            break :blk dot_git;
        } else |_| {}
        const contents = readGitFile(b, dot_git) catch return null;
        const trimmed = std.mem.trim(u8, contents, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
        const path = std.mem.trim(u8, trimmed[7..], " \t\r\n");
        break :blk if (std.fs.path.isAbsolute(path)) path else b.fmt("{s}/{s}", .{ root, path });
    };
    _ = readGitFile(b, b.fmt("{s}/gitdir", .{git_dir})) catch "";
    const common_dir = blk: {
        const cd = readGitFile(b, b.fmt("{s}/commondir", .{git_dir})) catch break :blk git_dir;
        const trimmed = std.mem.trim(u8, cd, " \t\r\n");
        break :blk if (std.fs.path.isAbsolute(trimmed)) trimmed else b.fmt("{s}/{s}", .{ git_dir, trimmed });
    };
    const head = readGitFile(b, b.fmt("{s}/HEAD", .{git_dir})) catch return null;
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    const packed_refs = readGitFile(b, b.fmt("{s}/packed-refs", .{common_dir})) catch "";
    const commit = blk: {
        if (!std.mem.startsWith(u8, trimmed, "ref:")) break :blk trimmed;
        const ref = std.mem.trim(u8, trimmed[4..], " \t\r\n");
        if (readGitFile(b, b.fmt("{s}/{s}", .{ common_dir, ref }))) |loose| {
            break :blk std.mem.trim(u8, loose, " \t\r\n");
        } else |_| {}
        var lines = std.mem.tokenizeScalar(u8, packed_refs, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (std.mem.eql(u8, line[space + 1 ..], ref)) break :blk line[0..space];
        }
        return null;
    };
    if (commit.len != 40 and commit.len != 64) return null;
    for (commit) |ch| if (!std.ascii.isHex(ch)) return null;
    return b.allocator.dupe(u8, commit[0..@min(commit.len, 12)]) catch null;
}
