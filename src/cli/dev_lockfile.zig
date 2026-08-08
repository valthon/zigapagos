//! Session lockfile for `zigapagos dev` — see docs/superpowers/specs/
//! 2026-08-07-background-dev-design.md and docs/dev-server.md.
//!
//! Two files under the (unwatched, created-early) data dir:
//!   * `dev.lock` — an empty file the dev process holds an exclusive
//!     `flock(2)` on for its whole lifetime. Liveness IS the lock: the kernel
//!     drops it when the holder dies, so a try-lock is a race-free, PID-reuse-
//!     proof staleness check (unlike Astro's `kill(pid, 0)`).
//!   * `dev.json` — the session facts (pids, ports, url, started_at), written
//!     atomically AFTER the server is ready, so its appearance doubles as the
//!     `--background` parent's readiness handshake.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

test "dev lockfile: iso timestamp formatting" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatIso(&buf, 0));
    // 2026-08-07T12:34:56Z == 1786106096 (`date -u -d @1786106096` ==
    // "Fri Aug  7 12:34:56 UTC 2026"; the design doc's 1786451696 is off by
    // four days — that value is actually 2026-08-11).
    try std.testing.expectEqualStrings("2026-08-07T12:34:56Z", formatIso(&buf, 1786106096));
}

test "dev lockfile: write/read round-trip survives, corrupt json reads as absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing written yet: read is null.
    try std.testing.expect(read(arena, io, dir_abs) == null);

    try write(io, gpa, dir_abs, .{
        .pid = 1234,
        .zigbase_pid = 1235,
        .host = "127.0.0.1",
        .port = 1990,
        .url = "http://127.0.0.1:1990/",
        .control_port = 43121,
        .data_dir = dir_abs,
        .background = true,
        .started_at = "2026-08-07T12:34:56Z",
    });
    const lf = read(arena, io, dir_abs) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1234), lf.pid);
    try std.testing.expectEqual(@as(i64, 1235), lf.zigbase_pid);
    try std.testing.expectEqualStrings("127.0.0.1", lf.host);
    try std.testing.expectEqual(@as(u16, 1990), lf.port);
    try std.testing.expectEqualStrings("http://127.0.0.1:1990/", lf.url);
    try std.testing.expect(lf.background);

    // Corrupt content parses as absent, not as a crash.
    try tmp.dir.writeFile(io, .{ .sub_path = data_name, .data = "{not json" });
    try std.testing.expect(read(arena, io, dir_abs) == null);

    // A future/wrong version is treated as absent (forward-compat).
    try tmp.dir.writeFile(io, .{ .sub_path = data_name, .data =
        \\{"version":999,"pid":1,"zigbase_pid":1,"host":"127.0.0.1","port":1,"url":"u",
        \\ "control_port":1,"data_dir":"d","background":false,"started_at":"s"}
    });
    try std.testing.expect(read(arena, io, dir_abs) == null);

    // remove() deletes dev.json only — never dev.lock. Unlinking a lockfile
    // some process still holds the flock on wouldn't release that lock; it
    // would just let a fresh `create` race in behind it and take a SECOND,
    // independent lock on a new inode of the same name, so two "live" locks
    // would coexist and liveness detection would be defeated. dev.lock is
    // create-once and permanent, so it must survive remove() untouched.
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = "" });
    remove(io, gpa, dir_abs);
    try std.testing.expect(read(arena, io, dir_abs) == null);
    _ = try tmp.dir.statFile(io, lock_name, .{});
    remove(io, gpa, dir_abs); // idempotent
    _ = try tmp.dir.statFile(io, lock_name, .{});
}

test "dev lockfile: flock liveness — held lock reads live, released lock reads stale" {
    // flock locks belong to the OPEN FILE DESCRIPTION, so two independent
    // opens in ONE process conflict exactly like two processes do — this test
    // needs no child process.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    // No lock file at all: not live.
    try std.testing.expect(!isLive(io, gpa, dir_abs));

    var lock = (try acquire(io, dir_abs, gpa)) orelse return error.TestUnexpectedResult;
    // While held, the dir reads as live, and a second acquire is refused.
    try std.testing.expect(isLive(io, gpa, dir_abs));
    try std.testing.expect((try acquire(io, dir_abs, gpa)) == null);

    lock.release(io);
    try std.testing.expect(!isLive(io, gpa, dir_abs));
}

pub const lock_name = "dev.lock";
pub const data_name = "dev.json";

/// Everything `dev stop|status|logs` and the `--background` parent need to
/// know about a running session. Serialized as JSON via std.json.Stringify
/// (field order = declaration order); parsed with parseFromSliceLeaky.
pub const LockFile = struct {
    version: u32 = 1,
    pid: i64,
    zigbase_pid: i64,
    /// The session's `--host` (default `127.0.0.1`) — the bind address BOTH
    /// `port` and `control_port` listen on. Added PR #140 round 2 (P2c): every
    /// control verb used to hardcode `127.0.0.1` regardless of what a session
    /// actually bound, so a non-default `--host` broke `dev status`/`dev
    /// stop`'s orphan sweep against a session that was never on loopback in
    /// the first place. No version bump — v1 has never shipped, so a required
    /// field is free to add.
    host: []const u8,
    port: u16,
    url: []const u8,
    control_port: u16,
    data_dir: []const u8,
    background: bool,
    started_at: []const u8,
};

pub const current_version: u32 = 1;

/// The held session lock. Contract 3 (caller-buffer): allocates nothing;
/// owns only the open file whose flock is the liveness signal. Held for the
/// process lifetime in production; `release` exists for tests.
pub const Lock = struct {
    file: Io.File,

    pub fn release(l: *Lock, io: Io) void {
        // Closing the fd drops the flock.
        l.file.close(io);
    }
};

/// Open-or-create `dev.lock` and take the exclusive flock. Null means a LIVE
/// process holds it (EWOULDBLOCK). Contract 1 (self-freeing): the joined path
/// is scratch, freed before return.
pub fn acquire(io: Io, data_dir_abs: []const u8, gpa: Allocator) error{OutOfMemory}!?Lock {
    if (builtin.os.tag == .windows) return null; // no dev daemon on Windows (0.17 port)
    const path = try std.fs.path.join(gpa, &.{ data_dir_abs, lock_name });
    defer gpa.free(path);
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return null;
    if (std.c.flock(f.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        f.close(io);
        return null;
    }
    return .{ .file = f };
}

/// True when a live process holds the session flock. Contract 1.
pub fn isLive(io: Io, gpa: Allocator, data_dir_abs: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const path = std.fs.path.join(gpa, &.{ data_dir_abs, lock_name }) catch return false;
    defer gpa.free(path);
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    if (std.c.flock(f.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) return true;
    _ = std.c.flock(f.handle, std.posix.LOCK.UN);
    return false;
}

/// Parse `dev.json`. Null on missing/corrupt/version-mismatch — a broken
/// lockfile must read as "no session", never crash a control verb. Contract 4
/// by shape (arena-scoped result: the strings point into arena memory), but
/// takes a plain Allocator on purpose — callers pass an ArenaAllocator they
/// already own; nothing here frees.
pub fn read(arena: Allocator, io: Io, data_dir_abs: []const u8) ?LockFile {
    const path = std.fs.path.join(arena, &.{ data_dir_abs, data_name }) catch return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const lf = std.json.parseFromSliceLeaky(LockFile, arena, bytes, .{}) catch return null;
    if (lf.version != current_version) return null;
    return lf;
}

/// Atomically write `dev.json` (temp + rename, same pattern as
/// reload.zig's injectFile — readers see the whole old file or the whole new
/// one). Contract 1 (self-freeing).
pub fn write(io: Io, gpa: Allocator, data_dir_abs: []const u8, lf: LockFile) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(lf, .{ .whitespace = .indent_2 }, &aw.writer);

    const path = try std.fs.path.join(gpa, &.{ data_dir_abs, data_name });
    defer gpa.free(path);
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var w = af.file.writer(io, &.{});
    try w.interface.writeAll(aw.writer.buffered());
    try af.replace(io);
}

/// Best-effort cleanup of `dev.json` (post-stop, stale-session removal).
/// Contract 1.
///
/// Deliberately does NOT unlink `dev.lock`. Unlinking a file another process
/// still holds an `flock` on does not release that lock — it detaches the
/// name from the (still-locked) inode — so a `create` racing right behind the
/// unlink opens a brand-new inode and takes a SECOND, independent lock on it.
/// Two "live" locks under one name defeats the whole liveness scheme. `dev.lock`
/// is therefore create-once and permanent: an empty file lingering in the
/// (gitignored) data dir after the session ends is harmless, and `acquire`
/// already handles "file exists, nothing holds it" via `.truncate = false` +
/// a fresh non-blocking flock.
pub fn remove(io: Io, gpa: Allocator, data_dir_abs: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ data_dir_abs, data_name }) catch return;
    defer gpa.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// `YYYY-MM-DDTHH:MM:SSZ` from UTC epoch seconds. Contract 3 (caller-buffer).
pub fn formatIso(buf: *[20]u8, epoch_secs: u64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}
