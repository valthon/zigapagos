const std = @import("std");
const fatal = @import("../fatal.zig");
const cache = @import("../image/cache.zig");

/// Contract 1: all filesystem and candidate-list resources are released
/// before returning; the CLI operates only on the current site's cache.
pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) bool {
    var max_bytes: ?u64 = null;
    var apply = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) fatal.usage(help, .{});
        if (std.mem.eql(u8, arg, "--apply")) {
            if (apply) fatal.usageError("error: duplicate --apply\n", .{});
            apply = true;
        } else if (std.mem.startsWith(u8, arg, "--max-bytes=")) {
            if (max_bytes != null) fatal.usageError("error: duplicate --max-bytes\n", .{});
            const value = arg[12..];
            if (value.len == 0) fatal.usageError("error: --max-bytes requires an unsigned decimal byte count\n", .{});
            for (value) |c| if (!std.ascii.isDigit(c)) fatal.usageError("error: invalid --max-bytes\n", .{});
            max_bytes = std.fmt.parseInt(u64, value, 10) catch fatal.usageError("error: --max-bytes overflows u64\n", .{});
        } else fatal.usageError("error: unexpected cache-prune argument '{s}'\n", .{arg});
    }
    const limit = max_bytes orelse fatal.usageError("error: cache-prune requires --max-bytes=N (use --help)\n", .{});
    const opened = cache.open(io, std.Io.Dir.cwd(), false) catch |err| {
        if (err == error.WouldBlock) {
            std.debug.print("error: image cache is busy; wait for the active build or prune to finish\n", .{});
        } else std.debug.print("error opening image cache: {t}\n", .{err});
        return true;
    };
    const c = opened orelse {
        std.debug.print("image cache is absent; nothing to prune\n", .{});
        return false;
    };
    defer c.close(io);
    const report = cache.prune(io, gpa, c, limit, apply) catch |err| {
        std.debug.print("error pruning image cache: {t}; cleanup may be partial\n", .{err});
        return true;
    };
    std.debug.print("{s}: {d} files, {d} bytes; {d} encoded bytes remain; {d} unknown entries preserved\n", .{
        if (apply) "removed" else "would remove (pass --apply)",
        report.removed_files,
        report.removed_bytes,
        report.remaining_bytes,
        report.skipped_entries,
    });
    return false;
}

const help =
    \\Usage: zigapagos cache-prune --max-bytes=N [--apply]
    \\
    \\Preview cleanup of .zigapagos-cache/images in the current directory.
    \\--apply deletes the previewed class of files (not a saved selection).
    \\Remove orphan encoder temporaries and then the oldest encoded variants
    \\until their total size is at most N bytes. N=0 removes all variants.
    \\Unknown files, symlinks and subdirectories are preserved and excluded
    \\from the size budget. No recursion, source or published-output deletion.
    \\Fails when the cache is locked by another build or prune. Stop builds
    \\using older Zigapagos versions, which do not participate in locking.
    \\Dry-run may create the persistent .lock file, but deletes nothing.
    \\
;
