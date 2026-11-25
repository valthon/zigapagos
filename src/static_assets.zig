//! Resolve static selections before rendering. Installation stays in the final
//! asset pass: these refcounts also exclude selected files from fingerprinting.
const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const root = @import("root.zig");
const Build = @import("Build.zig");
const PathName = @import("PathTable.zig").PathName;
const diag = @import("diag.zig");
const fatal = @import("fatal.zig");
const Allocator = std.mem.Allocator;

pub const Selection = struct {
    /// First selecting config entry, indexed in site_assets insertion order.
    owners: []?usize,
    errors: bool = false,

    pub fn deinit(self: Selection, gpa: Allocator) void {
        gpa.free(self.owners);
    }
};

/// Owned-result: caller deinitializes Selection; all other storage is scratch.
pub fn expand(io: std.Io, gpa: Allocator, build: *Build) Allocator.Error!Selection {
    const entries = build.cfg.getStaticAssets();
    var result: Selection = .{ .owners = try gpa.alloc(?usize, build.site_assets.count()) };
    errdefer result.deinit(gpa);
    @memset(result.owners, null);
    if (entries.len == 0) return result;

    const config_path = try std.Io.Dir.path.join(gpa, &.{ build.base_dir_path, "zigapagos.ziggy" });
    defer gpa.free(config_path);
    const source = build.base_dir.readFileAllocOptions(io, "zigapagos.ziggy", gpa, .limited(1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        // Library callers may supply a Config without a source file.
        error.FileNotFound => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => fatal.file(config_path, err),
    };
    defer if (source) |s| gpa.free(s);
    const reporter: Reporter = .{ .gpa = gpa, .build = build, .source = source, .config_path = config_path };

    for (entries, 0..) |entry, entry_idx| {
        const glob = std.mem.eql(u8, entry, "**") or std.mem.endsWith(u8, entry, "/**");
        const raw_path = if (glob) entry[0 .. entry.len - 2] else entry;
        const path = std.mem.trimEnd(u8, raw_path, "/");
        const invalid = root.validatePathMessage(raw_path, .{ .empty = glob and path.len == 0 }) orelse
            @as(?[]const u8, if (std.mem.findScalar(u8, path, 0) != null) "NUL is not allowed in a path" else null) orelse
            @as(?[]const u8, if (builtin.target.os.tag == .windows and path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') "drive-qualified paths are not allowed" else null);
        if (invalid) |reason| {
            try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "invalid static_assets entry '{s}': {s}", .{ entry, reason });
            result.errors = true;
            continue;
        }

        var directory = glob;
        if (!glob) {
            const link_stat = build.site_assets_dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
                try reporter.emit(entry_idx, if (err == error.FileNotFound) .ZP_STATIC_ASSET_MISSING else .ZP_STATIC_ASSET_INVALID, "static asset '{s}' does not exist or cannot be read: {s}", .{ entry, @errorName(err) });
                result.errors = true;
                continue;
            };
            const stat = build.site_assets_dir.statFile(io, path, .{}) catch |err| {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset '{s}' cannot be read: {s}", .{ entry, @errorName(err) });
                result.errors = true;
                continue;
            };
            directory = stat.kind == .directory;
            if (!directory and std.mem.endsWith(u8, entry, "/")) {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset '{s}' ends in '/' but is not a directory", .{entry});
                result.errors = true;
                continue;
            }
            if (directory and (link_stat.kind == .sym_link or hasSymlinkParent(io, build, path))) {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset directory '{s}' contains a symlink directory; directory symlinks are not traversed", .{entry});
                result.errors = true;
                continue;
            }
            if (!directory and stat.kind != .file) {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset '{s}' is not a regular file or directory", .{entry});
                result.errors = true;
                continue;
            }
        }

        // Preserve constant-time lookup for the existing file-only form.
        const start = if (directory) 0 else blk: {
            if (PathName.get(&build.st, &build.pt, path)) |pn| {
                if (build.site_assets.getIndex(pn)) |idx| break :blk idx;
            }
            try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset '{s}' is not a scanned regular file", .{entry});
            result.errors = true;
            continue;
        };
        const end = if (directory) build.site_assets.count() else start + 1;
        var matched: usize = 0;
        var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        for (build.site_assets.keys()[start..end], build.site_assets.values()[start..end], start..) |key, *rc, asset_idx| {
            const name = std.mem.print(&name_buf, "{f}", .{key.fmt(&build.st, &build.pt, null, "/")}) catch {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "asset path exceeds the filesystem path limit while expanding '{s}'", .{entry});
                result.errors = true;
                continue;
            };
            const selected = if (directory)
                path.len == 0 or (name.len > path.len and std.mem.startsWith(u8, name, path) and name[path.len] == '/')
            else
                std.mem.eql(u8, name, path);
            if (!selected) continue;
            matched += 1;
            // The scan records symlinks as potential assets. Resolve only files
            // selected for publication; unused broken links retain old behavior.
            const stat = build.site_assets_dir.statFile(io, name, .{}) catch |err| {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset '{s}' selected by '{s}' cannot be read: {s}", .{ name, entry, @errorName(err) });
                result.errors = true;
                continue;
            };
            // Spellings are contained by validation above. A selected file
            // symlink publishes its contents regardless of its target's location.
            if (stat.kind != .file) {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_INVALID, "static asset '{s}' selected by '{s}' is not a regular file", .{ name, entry });
                result.errors = true;
                continue;
            }
            if (result.owners[asset_idx]) |previous| {
                try reporter.emit(entry_idx, .ZP_STATIC_ASSET_DUPLICATE, "duplicate static asset '{s}' selected by static_assets entries '{s}' (entry {d}) and '{s}' (entry {d})", .{ name, entries[previous], previous + 1, entry, entry_idx + 1 });
                result.errors = true;
            } else result.owners[asset_idx] = entry_idx;
            rc.raw = 1;
        }
        if (glob and matched == 0) {
            try reporter.emit(entry_idx, .ZP_STATIC_ASSET_GLOB_EMPTY, "static asset glob '{s}' matched no assets", .{entry});
            result.errors = true;
        }
        // Existing empty directories are valid, unlike an empty glob.
    }
    return result;
}

/// Caller-buffer: the scanner never descends through directory symlinks, so a
/// directory reached through one must not silently masquerade as an empty tree.
fn hasSymlinkParent(io: std.Io, build: *const Build, path: []const u8) bool {
    for (path, 0..) |byte, idx| {
        if (byte != '/') continue;
        const stat = build.site_assets_dir.statFile(io, path[0..idx], .{ .follow_symlinks = false }) catch return true;
        if (stat.kind == .sym_link) return true;
    }
    return false;
}

const Reporter = struct {
    gpa: Allocator,
    build: *Build,
    source: ?[:0]const u8,
    config_path: []const u8,

    /// Owned-result: Build owns memory-mode error copies and frees them at
    /// deinit; the formatted message itself is self-freeing scratch.
    fn emit(self: Reporter, index: usize, code: diag.Code, comptime fmt: []const u8, args: anytype) !void {
        const message = try self.gpa.print(fmt, args);
        defer self.gpa.free(message);
        const pos = if (self.source) |source| entryPosition(source, index) else null;
        if (diag.format == .json) {
            diag.emit(.{
                .code = code,
                .severity = .@"error",
                .file = if (pos != null) self.config_path else null,
                .line = if (pos) |p| p.line else null,
                .col = if (pos) |p| p.col else null,
                .message = message,
            });
        } else if (pos) |p| {
            std.debug.print("{s}:{d}:{d}: error: [{s}] {s}\n", .{ self.config_path, p.line, p.col, @tagName(code), message });
        } else {
            std.debug.print("error: [{s}] {s}\n", .{ @tagName(code), message });
        }
        if (self.build.mode == .memory) {
            const copy = try self.gpa.dupe(u8, message);
            errdefer self.gpa.free(copy);
            try self.build.mode.memory.errors.append(self.gpa, .{ .ref = "", .msg = copy });
        }
    }
};

/// Caller-buffer: token locations handle comments and escaped string contents.
fn entryPosition(source: [:0]const u8, index: usize) ?ziggy.Tokenizer.Token.Loc.Selection.Position {
    var tokenizer: ziggy.Tokenizer = .init(.none);
    var in_entries = false;
    var current: usize = 0;
    var depth: usize = 0;
    while (true) {
        // Comments are skipped; depth 1 is the site struct inside
        // `.site = .simple(.{ ... })`, where an identifier keeps its dot.
        const token = tokenizer.next(source, true);
        switch (token.tag) {
            .eof, .eod => return null,
            .dotlb, .lb => depth += 1,
            .rb => depth -|= 1,
            .identifier => if (depth == 1 and std.mem.eql(u8, token.loc.slice(source), ".static_assets")) {
                in_entries = true;
            },
            .rsb => if (in_entries) return null,
            .comma => if (in_entries) {
                current += 1;
            },
            .bytes_no_escapes, .bytes_escapes_or_invalid, .bytes_line, .bytes_line_invalid => if (in_entries) {
                if (current == index) return token.loc.getSelection(source).start;
            },
            else => {},
        }
    }
}
