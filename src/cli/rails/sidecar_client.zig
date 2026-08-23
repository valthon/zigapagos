//! The three helpers `routes.zig`'s `discoverRoutes` and `controllers.zig`'s
//! `discoverControllers` both need to talk to one `runtime/sidecar/rails/
//! analyze.rb` process for exactly one request/response pair: resolve the
//! app root to an absolute path, bound the blocking read with a watchdog,
//! and write the one NDJSON request line then read the one response line.
//!
//! Extracted here (fix round 1, task-2-fixes.md item 1) after review found
//! `resolveAbsRoot` and `killOnTimeout` byte-identical between the two
//! client files and `queryOnce` differing only in the wire `op` string --
//! now a parameter instead of a second hardcoded copy. This is a pure move:
//! neither `discoverRoutes`'s public signature nor its watchdog/stdin-close
//! semantics changed, so the earlier ruling that forbade touching
//! `routes.zig` to force PROCESS SHARING still stands untouched -- these
//! three functions were already private, self-contained, and impossible to
//! observe from outside their own call site; relocating them changes only
//! which file's brace-depth they live inside.
//!
//! Why worth doing at all: Stage 2 hit a subtle interaction where
//! `Child.kill` sends SIGTERM and the sidecar only actually dies because
//! `analyze.rb`'s dispatch loop re-raises `SignalException` past its own
//! broad `rescue Exception`. Two independent copies of `killOnTimeout` meant
//! the next fix to that interaction would have to be found and re-applied
//! twice, and duplicated code is exactly the shape of defect where the
//! second copy is the one that gets missed.
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` escapes this
//! directory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Generous but bounded: a real Prism-AST walk of one file, or of a whole
/// `app/controllers/` tree, is still milliseconds; this exists purely so a
/// wedged interpreter cannot hang the whole build. See `killOnTimeout`.
pub const sidecar_timeout_ms: i64 = 30_000;

/// Contract 1 (self-freeing): frees its own scratch (`cwd_str`, when the
/// relative-path branch is taken) and returns exactly one fresh `gpa`-owned
/// allocation -- a plain slice released by the caller's own `gpa.free`, not
/// an owned graph with a `deinit`. (Fix round 1: this was mislabeled
/// "Contract 2 (owned-result)" in both `routes.zig` and `controllers.zig`
/// before the move -- see task-2-fixes.md item 2. `check-allocator-
/// contracts.sh` passing was never evidence either way: that gate only
/// polices arena-wrapped testing allocators, contract 4, not label
/// accuracy.)
///
/// Returns a fresh `gpa`-owned absolute path for `root_path`, resolved
/// against the process cwd when relative. Mirrors `Sidecar.absSrc`
/// (`src/islands/sidecar.zig`) -- duplicated rather than imported, since
/// that file sits outside `src/cli/rails/` and this package is std-only.
pub fn resolveAbsRoot(io: Io, gpa: Allocator, root_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(root_path)) return try gpa.dupe(u8, root_path);
    const cwd_str = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_str);
    return try std.fs.path.resolve(gpa, &.{ cwd_str, root_path });
}

/// Runs on a dedicated thread for as long as the caller's blocking
/// write+read of the sidecar's one response line takes (`discoverRoutes` /
/// `discoverControllers`). If `done` is not signaled within
/// `sidecar_timeout_ms`, the sidecar is presumed hung and is killed so the
/// blocked read unblocks with an error instead of hanging the build
/// forever; the caller turns that into its own sidecar-failure blocker code
/// like any other spawn/response failure.
///
/// `child.kill`/`child.wait` are not safe to call from two threads at once
/// (`Child.id` is checked/cleared without its own synchronization), so the
/// caller signals `done` and `join`s this thread BEFORE it ever touches
/// `child` again -- by construction, only one of "this thread's timeout
/// kill" and "the caller's own child.kill/wait" can run.
///
/// Inspection-verified only: no test forces the real 30s timeout to fire.
/// Making that deterministic needs either an actual 30s CI run or a seam
/// that exists solely for the test, and this guard's failure mode -- the
/// build hangs instead of erroring -- isn't worth either cost. Every other
/// test using this watchdog completes in milliseconds and passes with it
/// wired in, which does exercise the FAST path (signal, join, no kill) on
/// every run; the kill-on-timeout branch itself is not covered.
///
/// Two known, narrow gaps (whole-branch review, deliberately left as-is --
/// fixing either would trade away the join-before-touch ordering the doc
/// above depends on to keep `kill`/`wait` single-threaded):
/// - The caller's own `child.wait(io)` runs AFTER this thread is joined, so
///   it is itself unbounded: a sidecar that answers the one response line
///   but then never exits hangs the build even though this watchdog fired
///   and returned cleanly (`done.set` + `join` only bound the write+read,
///   not the final wait).
/// - `std.process.Child.wait` asserts `child.id != null`; if `child.kill`
///   here and the caller's own `child.kill`/`child.wait` could ever race
///   (they cannot today, by construction -- see above), a kill landing in
///   the same instant as a response would be a potential panic, not just a
///   lost race.
pub fn killOnTimeout(io: Io, child: *std.process.Child, done: *Io.Event) void {
    const dur: Io.Clock.Duration = .{ .raw = .fromMilliseconds(sidecar_timeout_ms), .clock = .awake };
    done.waitTimeout(io, .{ .duration = dur }) catch |err| switch (err) {
        error.Timeout => child.kill(io),
        error.Canceled => {},
    };
}

/// Contract 1 (self-freeing): the only allocation that escapes is the
/// returned response-line slice, released by the caller's plain
/// `gpa.free(line)` -- there is no owned graph and no `deinit`. (Fix round
/// 1: see `resolveAbsRoot`'s doc above -- this carried the same mislabel
/// before the move.)
///
/// Writes the one NDJSON request line (`{"op":<op>,"root":<root_abs>}`),
/// closes stdin (`analyze.rb`'s loop treats EOF as an ordinary, expected
/// shutdown -- see its own module doc), and reads back the one response
/// line. `op` is `"routes"` or `"controllers"` today; nothing here
/// validates it against `analyze.rb`'s dispatch table -- an unrecognized op
/// simply comes back as that op's own `{"ok":false,"error":"unknown op..."}`
/// line, which `decodeResponse` on the caller's side turns into its usual
/// sidecar-failure blocker.
///
/// Split out purely to keep the caller's body readable; unlike
/// `decodeResponse` this half is not meant to be unit tested on its own; it
/// always needs a live process.
pub fn queryOnce(io: Io, gpa: Allocator, child: *std.process.Child, op: []const u8, root_abs: []const u8) ![]u8 {
    var wbuf: [4096]u8 = undefined;
    var fw = child.stdin.?.writer(io, &wbuf);
    const w = &fw.interface;
    try w.writeAll("{\"op\":");
    try std.json.Stringify.value(op, .{}, w);
    try w.writeAll(",\"root\":");
    try std.json.Stringify.value(root_abs, .{}, w);
    try w.writeAll("}\n");
    try w.flush();
    // Signals "no more requests" -- analyze.rb's `$stdin.gets` returns nil
    // and the process exits normally once it has answered this one. Both
    // callers spawn a process solely to answer this ONE request, so closing
    // immediately after is correct for either.
    child.stdin.?.close(io);
    child.stdin = null;

    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.reader(io, &rbuf);
    var line_aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer line_aw.deinit();
    _ = try fr.interface.streamDelimiter(&line_aw.writer, '\n');
    return line_aw.toOwnedSlice();
}
