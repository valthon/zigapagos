//! Image-cache ownership and explicit pruning. All deriving builds and
//! pruners lock the same persistent inode; never unlink `.lock`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plan = @import("plan.zig");

pub const Cache = struct {
    dir: Io.Dir,
    lock: Io.File,
    nonce: u128,

    pub fn close(self: Cache, io: Io) void {
        self.lock.close(io);
        self.dir.close(io);
    }
};

/// Contract 3: no allocations. Caller closes the returned handles. Builds
/// create missing directories and wait; pruners leave absent caches absent
/// and fail with WouldBlock when another build/pruner owns the cache.
/// Both paths reject symlinks at each cache-directory and lock component.
pub fn open(io: Io, base: Io.Dir, build: bool) !?Cache {
    if (build) base.createDir(io, ".zigapagos-cache", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const parent = base.openDir(io, ".zigapagos-cache", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => if (!build) return null else return err,
        else => return err,
    };
    defer parent.close(io);
    if (build) parent.createDir(io, "images", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const dir = parent.openDir(io, "images", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => if (!build) return null else return err,
        else => return err,
    };
    errdefer dir.close(io);
    // Exclusive creation cannot follow an existing symlink. Open the
    // resulting persistent inode without following links, then lock it.
    if (dir.createFile(io, ".lock", .{ .exclusive = true })) |created| {
        created.close(io);
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    }
    const lock = try dir.openFile(io, ".lock", .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    errdefer lock.close(io);
    if ((try lock.stat(io)).kind != .file) return error.InvalidCacheLock;
    if (!try lock.tryLock(io, .exclusive)) {
        if (!build) return error.WouldBlock;
        // Progress belongs on stdout: release --format=json reserves
        // stderr for diagnostic records, and info logs are disabled.
        try Io.File.stdout().writeStreamingAll(io, "waiting for the image cache: another build or pruner owns it\n");
        try lock.lock(io, .exclusive);
    }
    var nonce: u128 = undefined;
    io.random(std.mem.asBytes(&nonce));
    return .{ .dir = dir, .lock = lock, .nonce = nonce };
}

const Entry = struct {
    name: []const u8,
    size: u64,
    mtime: i96,
    temporary: bool,

    fn older(_: void, a: Entry, b: Entry) bool {
        if (a.temporary != b.temporary) return a.temporary;
        if (a.mtime != b.mtime) return a.mtime < b.mtime;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

pub const Report = struct {
    removed_files: usize = 0,
    removed_bytes: u64 = 0,
    remaining_bytes: u64 = 0,
    skipped_entries: usize = 0,
};

/// Contract 1: frees the candidate list and all copied names on every exit.
/// Cache must remain locked throughout. Dry-run reports the same selection
/// as apply. Oldest encoded files go first (mtime, not access-time/LRU);
/// orphan encoder temporaries always go. Unknown files, links and subdirs
/// are never candidates and do not count toward the encoded-byte budget.
pub fn prune(io: Io, gpa: Allocator, cache: Cache, max_bytes: u64, apply: bool) !Report {
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
    }
    var report: Report = .{};
    var it = cache.dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, ".lock")) continue;
        const temporary = isTemporary(e.name);
        if (!temporary and !isVariant(e.name)) {
            report.skipped_entries += 1;
            continue;
        }
        const stat = cache.dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            // An orphaned encoder can remove its temporary after iteration.
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) {
            report.skipped_entries += 1;
            continue;
        }
        if (!temporary) report.remaining_bytes = try std.math.add(u64, report.remaining_bytes, stat.size);
        const name = try gpa.dupe(u8, e.name);
        errdefer gpa.free(name);
        try entries.append(gpa, .{
            .name = name,
            .size = stat.size,
            .mtime = stat.mtime.nanoseconds,
            .temporary = temporary,
        });
    }
    std.mem.sort(Entry, entries.items, {}, Entry.older);
    for (entries.items) |e| {
        if (!e.temporary and report.remaining_bytes <= max_bytes) continue;
        if (apply) cache.dir.deleteFile(io, e.name) catch |err| switch (err) {
            error.FileNotFound => {
                if (!e.temporary) report.remaining_bytes -= e.size;
                continue;
            },
            else => return err,
        };
        report.removed_files += 1;
        report.removed_bytes = try std.math.add(u64, report.removed_bytes, e.size);
        if (!e.temporary) report.remaining_bytes -= e.size;
    }
    return report;
}

/// Contract 3: recognize plan.variantBasename's suffix, allowing arbitrary
/// stems (including dots). Do not widen cleanup to arbitrary webp/avif files.
fn isVariant(name: []const u8) bool {
    var parts = std.mem.splitBackwardsScalar(u8, name, '.');
    const codec = parts.next() orelse return false;
    if (!std.mem.eql(u8, codec, "webp") and !std.mem.eql(u8, codec, "avif")) return false;
    const width = parts.next() orelse return false;
    if (!decimal(width) or (std.fmt.parseInt(u32, width, 10) catch return false) == 0) return false;
    const hash = parts.next() orelse return false;
    if (hash.len != plan.hash_hex_len) return false;
    for (hash) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return parts.next() != null;
}

fn decimal(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 1 and s[0] == '0') return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// derive.tmpName v2: a nonce, four job identifiers, width and codec, with
/// an optional interchange extension. Also accept legacy basename temps.
fn isTemporary(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, ".tmp.")) return false;
    var parts = std.mem.splitScalar(u8, name[5..], '.');
    if (std.mem.startsWith(u8, name, ".tmp.v2.")) {
        _ = parts.next();
        const nonce = parts.next() orelse return false;
        if (nonce.len != 32) return false;
        for (nonce) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    }
    for (0..4) |_| {
        const id = parts.next() orelse return false;
        if (!decimal(id)) return false;
        _ = std.fmt.parseInt(u32, id, 10) catch return false;
    }
    const rest = parts.rest();
    if (std.mem.startsWith(u8, name, ".tmp.v2.")) {
        const width = parts.next() orelse return false;
        if (!decimal(width) or (std.fmt.parseInt(u32, width, 10) catch return false) == 0) return false;
        const suffix = parts.rest();
        return std.mem.eql(u8, suffix, "webp") or std.mem.eql(u8, suffix, "avif.png") or std.mem.eql(u8, suffix, "avif.avif");
    }
    if (isVariant(rest)) return true;
    for ([_][]const u8{ ".png", ".avif" }) |ext| {
        if (std.mem.endsWith(u8, rest, ext) and isVariant(rest[0 .. rest.len - ext.len])) return true;
    }
    return false;
}

test "images: cache names match generated variants and encoder temporaries" {
    const gpa = std.testing.allocator;
    const name = try plan.variantBasename(gpa, "a.b.png", "bytes", 320, .webp, 80, 1);
    defer gpa.free(name);
    try std.testing.expect(isVariant(name));
    try std.testing.expect(isTemporary(".tmp.0.1.2.3.a.abcdef01.320.avif.png"));
    try std.testing.expect(isTemporary(".tmp.0.1.2.3.a.abcdef01.320.avif.avif"));
    try std.testing.expect(isTemporary(".tmp.0.1.2.3.a.abcdef01.320.webp"));
    try std.testing.expect(isTemporary(".tmp.v2.0123456789abcdef0123456789abcdef.0.1.2.3.320.webp"));
    try std.testing.expect(isTemporary(".tmp.v2.0123456789abcdef0123456789abcdef.0.1.2.3.320.avif.png"));
    try std.testing.expect(isTemporary(".tmp.v2.0123456789abcdef0123456789abcdef.0.1.2.3.320.avif.avif"));
    for ([_][]const u8{ "photo.webp", "a.abcdefgh.320.webp", "a.abcdef01.0.avif", "a.abcdef01.+1.webp" }) |bad|
        try std.testing.expect(!isVariant(bad));
    try std.testing.expect(!isTemporary(".tmp.notes"));
}

test "images: cache prune is bounded, dry-run first, and lock exclusive" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(null, try open(io, tmp.dir, false));
    const cache = (try open(io, tmp.dir, true)).?;
    defer cache.close(io);
    try std.testing.expectError(error.WouldBlock, open(io, tmp.dir, false));
    try cache.dir.writeFile(io, .{ .sub_path = "a.abcdef01.320.webp", .data = "123456" });
    try cache.dir.writeFile(io, .{ .sub_path = "b.abcdef01.320.webp", .data = "1234" });
    try cache.dir.writeFile(io, .{ .sub_path = ".tmp.0.1.2.3.a.abcdef01.320.avif.png", .data = "tmp" });
    try cache.dir.writeFile(io, .{ .sub_path = "notes", .data = "preserve" });
    const dry = try prune(io, std.testing.allocator, cache, 4, false);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pruneForOom, .{ io, cache });
    try std.testing.expectEqual(@as(usize, 2), dry.removed_files);
    try std.testing.expectEqual(@as(u64, 4), dry.remaining_bytes);
    try std.testing.expectEqual(@as(u64, 6), (try cache.dir.statFile(io, "a.abcdef01.320.webp", .{})).size);
    try std.testing.expectEqualDeep(dry, try prune(io, std.testing.allocator, cache, 4, true));
    try std.testing.expectError(error.FileNotFound, cache.dir.statFile(io, "a.abcdef01.320.webp", .{}));
    try std.testing.expectEqual(@as(u64, 8), (try cache.dir.statFile(io, "notes", .{})).size);
    const all = try prune(io, std.testing.allocator, cache, 0, true);
    try std.testing.expectEqual(@as(usize, 1), all.removed_files);
    try std.testing.expectEqual(@as(u64, 0), all.remaining_bytes);
}

/// Contract 1: exercise the self-freeing candidate collector under every
/// injected allocation failure without changing the filesystem fixture.
fn pruneForOom(gpa: Allocator, io: Io, cache: Cache) !void {
    _ = try prune(io, gpa, cache, 4, false);
}

test "images: cache prune preserves links and subdirectories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = (try open(io, tmp.dir, true)).?;
    defer cache.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "keep" });
    try cache.dir.symLink(io, "../../outside", "link.abcdef01.320.webp", .{});
    try cache.dir.createDir(io, "dir.abcdef01.320.avif", .default_dir);
    const report = try prune(io, std.testing.allocator, cache, 0, true);
    try std.testing.expectEqual(@as(usize, 0), report.removed_files);
    try std.testing.expectEqual(@as(usize, 2), report.skipped_entries);
    try std.testing.expectEqual(.sym_link, (try cache.dir.statFile(io, "link.abcdef01.320.webp", .{ .follow_symlinks = false })).kind);
    try std.testing.expectEqual(@as(u64, 4), (try tmp.dir.statFile(io, "outside", .{})).size);
}

test "images: cache prune tolerates disappearing entries but propagates other errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = (try open(io, tmp.dir, true)).?;
    defer cache.close(io);
    try cache.dir.writeFile(io, .{ .sub_path = "a.abcdef01.320.webp", .data = "1234" });

    // Inject at the filesystem boundary after real directory iteration;
    // avoid a timing-dependent race with a background deleting thread.
    const Race = struct {
        fn statMissing(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
            return error.FileNotFound;
        }
        fn statDenied(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
            return error.AccessDenied;
        }
        fn deleteMissing(_: ?*anyopaque, _: Io.Dir, _: []const u8) Io.Dir.DeleteFileError!void {
            return error.FileNotFound;
        }
        fn deleteDenied(_: ?*anyopaque, _: Io.Dir, _: []const u8) Io.Dir.DeleteFileError!void {
            return error.AccessDenied;
        }
    };
    var vtable = io.vtable.*;
    var raced_io = io;
    raced_io.vtable = &vtable;
    vtable.dirStatFile = Race.statMissing;
    for ([_]bool{ false, true }) |apply| {
        try std.testing.expectEqualDeep(Report{}, try prune(raced_io, std.testing.allocator, cache, 0, apply));
    }
    vtable.dirStatFile = Race.statDenied;
    try std.testing.expectError(error.AccessDenied, prune(raced_io, std.testing.allocator, cache, 0, true));
    vtable.dirStatFile = io.vtable.dirStatFile;
    vtable.dirDeleteFile = Race.deleteMissing;
    try std.testing.expectEqualDeep(Report{}, try prune(raced_io, std.testing.allocator, cache, 0, true));
    vtable.dirDeleteFile = Race.deleteDenied;
    try std.testing.expectError(error.AccessDenied, prune(raced_io, std.testing.allocator, cache, 0, true));
}
