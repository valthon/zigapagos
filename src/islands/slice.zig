//! The Zig side of the per-SITE islands runtime slice (#52).
//!
//! `runtime/scripts/build-islands-runtime.ts` analyses every island's BUILT
//! bundle and either emits a sliced runtime at `/islands/_runtime.js` covering
//! a proven subset of the site's islands, or bails to `{"fallback": true}`.
//! This module reads that manifest so `src/islands/pass.zig` can decide, per
//! page, whether every island on it is covered.
//!
//! Module-root constraint (Zig 0.16): `src/islands/tests.zig` is `test-islands`'s
//! root, so nothing here may `@import` outside `src/islands/` — in particular
//! not `../fatal.zig`. Failures are therefore returned as errors and `root.zig`
//! turns them into the `fatal.msg` exit.
const std = @import("std");

/// Shape of the islands runtime SLICE manifest.
/// `runtime` names the sliced bundle when one was built; `fallback` is true when
/// every island bailed. The driver also writes `exports`/`bailed` for the build
/// log; they are ignored here, and the parse sets `ignore_unknown_fields` so
/// they need no placeholder fields.
const SliceJson = struct {
    runtime: ?[]const u8 = null,
    islands: []const []const u8 = &.{},
    fallback: bool = false,
};

/// Cap on the manifest file: it holds one URL plus one name per island. A
/// megabyte is four orders of magnitude of headroom and bounds a corrupt file.
const max_manifest_bytes = 1024 * 1024;

/// The resolved slice for one build.
///
/// NO_SLOP.md §2.2a contract 2 (owned-result): the Manifest owns `url`, every
/// string in `islands`, and the outer slice; the caller calls `deinit(gpa)`.
/// Owned-result rather than contract 1 because the result is a small graph (a
/// slice of slices) that outlives the call — it is read by every render worker
/// for the life of the build, so it cannot borrow the parse buffer.
pub const Manifest = struct {
    /// The sliced runtime URL, un-prefixed (`pass.process` applies the site's
    /// `url_path_prefix` itself). Null when this build produced no slice.
    url: ?[]const u8 = null,
    /// Island module names (`pass.islandModuleName`) the slice provably serves.
    islands: []const []const u8 = &.{},

    pub fn deinit(m: Manifest, gpa: std.mem.Allocator) void {
        if (m.url) |u| gpa.free(u);
        for (m.islands) |n| gpa.free(n);
        gpa.free(m.islands);
    }
};

/// Read + parse the slice manifest at `path`.
/// Contract 2 (owned-result): the returned Manifest owns everything reachable
/// from it; the parse buffer and the parsed tree are freed here.
pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Manifest {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_manifest_bytes));
    defer gpa.free(data);

    var parsed = try std.json.parseFromSlice(SliceJson, gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // A fallback manifest names no runtime, so the null URL alone carries the
    // decision — `fallback` is read only to reject a manifest that claims both.
    if (parsed.value.fallback and parsed.value.runtime != null) return error.ContradictorySliceManifest;

    const url = if (parsed.value.runtime) |u| try gpa.dupe(u8, u) else null;
    errdefer if (url) |u| gpa.free(u);

    // A fallback manifest's `islands` (if any) is meaningless without a runtime
    // to point at, so it is dropped rather than kept as a trap for the per-page
    // selection in `pass.zig`.
    if (url == null) return .{};

    const names = try gpa.alloc([]const u8, parsed.value.islands.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |n| gpa.free(n);
        gpa.free(names);
    }
    for (parsed.value.islands, 0..) |n, i| {
        names[i] = try gpa.dupe(u8, n);
        filled = i + 1;
    }
    return .{ .url = url, .islands = names };
}

/// Delete a stale `islands/_runtime.js` (+ its `.map`) left by a PREVIOUS build
/// whose decision was SLICED, now that this build's decision is FALLBACK.
///
/// Nothing prunes the output tree (`addInstallDirectory` only copies, and
/// `--force` only skips the empty-output check), so without this the stale slice
/// would linger — a runtime no page's import map points at any more, and a
/// hazard for deploys that sync without deleting first. Same treatment, and the
/// same rationale, as `src/spa.zig`'s `deleteStaleSlicedRuntime` (AUDF-015),
/// including its `error.FileNotFound`-is-success semantics: a slice built
/// without `--sourcemap` has no `.map`, and a first build has neither.
///
/// A no-op when `fallback` is false (still sliced: the file is current) — which
/// leaves one gap, shared with `src/spa.zig`'s slicer: a `--sourcemap` build
/// followed by a non-`--sourcemap` one is sliced BOTH times, so the now-orphaned
/// `islands/_runtime.js.map` is not pruned. It is inert (nothing references it,
/// and the next `--sourcemap` build overwrites it) and pruning it would mean
/// deleting a file this function cannot tell apart from one the current build is
/// about to write, so it is left alone deliberately.
/// NO_SLOP.md §2.2a contract 3 (caller-buffer): takes no allocator at all — the
/// two relative paths are comptime literals — so there is nothing to own.
pub fn deleteStaleRuntime(io: std.Io, out_dir: std.Io.Dir, fallback: bool) !void {
    if (!fallback) return;
    for ([_][]const u8{ "islands/_runtime.js", "islands/_runtime.js.map" }) |rel| {
        out_dir.deleteFile(io, rel) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

// --- tests ---

/// Build a cwd-relative path into a `std.testing.tmpDir`: `load` reads through
/// `Io.Dir.cwd()`, so the manifest must be addressable from the process cwd, and
/// `tmpDir` places its tree at `.zig-cache/tmp/<sub_path>`. (Same helper shape as
/// `src/cli/migrate.zig`'s `testTmpPath`, which exists for the same reason.)
///
/// NO_SLOP.md §2.2a contract 1 (self-freeing): one allocation escapes as the
/// return; every caller frees it.
fn testTmpPath(gpa: std.mem.Allocator, tmp: *const std.testing.TmpDir, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, rel });
}

test "a sliced manifest parses into an owned url + island list" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "slice.json",
        .data =
        \\{"runtime":"/islands/_runtime.js","islands":["Clean.island","Also.island"]}
        ,
    });
    const path = try testTmpPath(gpa, &tmp, "slice.json");
    defer gpa.free(path);

    const m = try load(io, gpa, path);
    defer m.deinit(gpa);

    try std.testing.expectEqualStrings("/islands/_runtime.js", m.url.?);
    try std.testing.expectEqual(@as(usize, 2), m.islands.len);
    try std.testing.expectEqualStrings("Clean.island", m.islands[0]);
    try std.testing.expectEqualStrings("Also.island", m.islands[1]);
    // The per-page decision itself lives in `pass.zig` (see `containsName` and
    // the head injection in `process`); this type only carries the manifest.
}

test "a fallback manifest yields a null url and an empty island list" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "slice.json", .data = "{\"fallback\":true}" });
    const path = try testTmpPath(gpa, &tmp, "slice.json");
    defer gpa.free(path);

    const m = try load(io, gpa, path);
    defer m.deinit(gpa);

    try std.testing.expect(m.url == null);
    try std.testing.expectEqual(@as(usize, 0), m.islands.len);
}

test "the driver's diagnostic keys (exports/bailed) do not break the parse" {
    // The driver writes `exports` and `bailed` for the build log. They have no
    // field here, so the parse must ignore them rather than fail the build.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "slice.json",
        .data =
        \\{"runtime":"/islands/_runtime.js","islands":["A.island"],
        \\ "exports":["useState"],"bailed":{"W.island":"imports react"}}
        ,
    });
    const path = try testTmpPath(gpa, &tmp, "slice.json");
    defer gpa.free(path);

    const m = try load(io, gpa, path);
    defer m.deinit(gpa);
    try std.testing.expectEqualStrings("/islands/_runtime.js", m.url.?);
    try std.testing.expectEqualStrings("A.island", m.islands[0]);
}

test "a manifest claiming BOTH a runtime and fallback is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "slice.json",
        .data = "{\"runtime\":\"/islands/_runtime.js\",\"fallback\":true}",
    });
    const path = try testTmpPath(gpa, &tmp, "slice.json");
    defer gpa.free(path);

    try std.testing.expectError(error.ContradictorySliceManifest, load(io, gpa, path));
}

test "an absent manifest surfaces as an error rather than a silent no-slice" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testTmpPath(gpa, &tmp, "nope.json");
    defer gpa.free(path);
    try std.testing.expectError(error.FileNotFound, load(io, gpa, path));
}

test "deleteStaleRuntime removes a stale slice only on a fallback decision" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "islands");
    try tmp.dir.writeFile(io, .{ .sub_path = "islands/_runtime.js", .data = "stale" });

    // Still sliced: the file is current, not stale.
    try deleteStaleRuntime(io, tmp.dir, false);
    const kept = try tmp.dir.readFileAlloc(io, "islands/_runtime.js", gpa, .limited(64));
    gpa.free(kept);

    // Flipped to fallback: prune it.
    try deleteStaleRuntime(io, tmp.dir, true);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(io, "islands/_runtime.js", gpa, .limited(64)),
    );

    // A second prune (nothing left, and no `.map` was ever written) is success.
    try deleteStaleRuntime(io, tmp.dir, true);
}
