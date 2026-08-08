# Background Dev Server Management (#126) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zigapagos dev --background` detaches the dev loop with a lockfile, `dev stop|status|logs` control verbs, a build-aware `/_zigapagos/status` endpoint, and AI-agent auto-detection — per the approved spec `docs/superpowers/specs/2026-08-07-background-dev-design.md`.

**Architecture:** No supervisor. The parent re-execs its own binary detached (own pgid, stderr→log file), using lockfile appearance as the readiness handshake. Liveness is a kernel-held `flock` on `.zigbase/dev.lock` (dropped on death — no PID-reuse false positives); session facts live in `.zigbase/dev.json`. The SSE reload server becomes an always-on control server that also answers `GET /_zigapagos/status` with build generation/status/error fed by the rebuild loop.

**Tech Stack:** Zig 0.16.0 only (no new deps). `std.process.spawn` (`pgid`, `StdIo.file`), `std.c.flock` + `std.posix.LOCK`, `std.json.Stringify` / `std.json.parseFromSliceLeaky` (repo-established patterns), `std.http.Server` (already in `reload.zig`), bash e2e against `tests/dev/stub-zigbase.ts`.

## Global Constraints

- Zig is pinned to **0.16.0** (`mise.toml`, `build.zig.zon`); check `zig version` before believing configure-time errors.
- **`zig fmt` gate**: run `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` before every push; never reformat `zig-pkg/`.
- **`zig build check -Dsingle-threaded` must stay green.** The new control verbs (`stop|status|logs`) must be reachable and compiled under it; anything touching `std.Thread` must be comptime-pruned (`if (comptime !builtin.single_threaded)`), never runtime-skipped.
- **Test anchors**: every new `src/cli/*.zig` file needs a `_ = @import(...)` line in a `src/main.zig` test block whose name matches the suite filter, or its tests silently never compile (see `src/main.zig:246-256`). New dev tests are named `test "dev …"` to match `test-dev`'s `"dev"` filter (`build/tests.zig`).
- **Do not change these exact log strings** (parsed by `tests/dev/*.sh`): `dev: ready — serving at http://`, `dev: zigbase data dir: `, `dev: live-reload: http://`, `: connected`, `dev: rebuild OK`, `dev: rebuild FAILED`. Adding new lines is safe; editing these is not.
- All dev-loop output goes to **stderr** via `std.debug.print` — keep that for new lines (the background log file captures fd 2).
- **NO_SLOP.md §2.2a**: every new allocator-taking function declares its contract (default: contract 1, self-freeing) in its doc comment.
- Commit messages explain the defect/reasoning, reference **#126**, and end with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer. Commit with **explicit paths** (`git commit -m … -- <paths>`) — the index is shared across worktrees.
- Regression tests must be **verified to fail without the fix** (run the test before implementing, confirm the failure output).
- Windows is out of scope (0.17 port): POSIX-only code lives behind `if (builtin.os.tag == .windows) … else …` comptime branches, mirroring `reaper` (`src/cli/dev.zig:733`).
- New env var names (referenced across tasks): `ZIGAPAGOS_DEV_BACKGROUND_CHILD` (internal recursion guard), `ZIGAPAGOS_DEV_BACKGROUND` (user opt-out/force). Never merge them.
- File names (referenced across tasks): `.zigbase/dev.lock` (flock target, empty), `.zigbase/dev.json` (facts), `.zigbase/dev.log` (background log), `.zigbase/last-build.log` (rebuild capture).

---

### Task 1: Lockfile module (`src/cli/dev_lockfile.zig`)

**Files:**
- Create: `src/cli/dev_lockfile.zig`
- Modify: `src/main.zig:253-256` (add anchor line)
- Test: in-file `test "dev lockfile: …"` blocks

**Interfaces:**
- Produces (used by Tasks 4, 5, 6, 7, 8):
  - `pub const lock_name = "dev.lock"; pub const data_name = "dev.json";`
  - `pub const LockFile = struct { version: u32 = 1, pid: i64, zigbase_pid: i64, port: u16, url: []const u8, control_port: u16, data_dir: []const u8, background: bool, started_at: []const u8 };`
  - `pub const Lock = struct { file: Io.File, pub fn release(l: *Lock, io: Io) void };`
  - `pub fn acquire(io: Io, data_dir_abs: []const u8, gpa: Allocator) error{OutOfMemory}!?Lock` — null = another live process holds it
  - `pub fn isLive(io: Io, gpa: Allocator, data_dir_abs: []const u8) bool`
  - `pub fn read(arena: Allocator, io: Io, data_dir_abs: []const u8) ?LockFile` — null on missing/corrupt/wrong-version
  - `pub fn write(io: Io, gpa: Allocator, data_dir_abs: []const u8, lf: LockFile) !void` — atomic (temp+rename)
  - `pub fn remove(io: Io, gpa: Allocator, data_dir_abs: []const u8) void` — best-effort delete of `dev.json` only (`dev.lock` is create-once, never unlinked)
  - `pub fn formatIso(buf: *[20]u8, epoch_secs: u64) []const u8`

- [ ] **Step 1: Write the failing tests**

Create `src/cli/dev_lockfile.zig` with only the imports and the test blocks (so the file compiles enough to fail on missing decls):

```zig
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
    // 2026-08-07T12:34:56Z == 1786451696 (spot-checked against `date -u -d`).
    try std.testing.expectEqualStrings("2026-08-07T12:34:56Z", formatIso(&buf, 1786451696));
}

test "dev lockfile: write/read round-trip survives, corrupt json reads as absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nothing written yet: read is null.
    try std.testing.expect(read(arena, io, dir_abs) == null);

    try write(io, gpa, dir_abs, .{
        .pid = 1234,
        .zigbase_pid = 1235,
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
    try std.testing.expectEqual(@as(u16, 1990), lf.port);
    try std.testing.expectEqualStrings("http://127.0.0.1:1990/", lf.url);
    try std.testing.expect(lf.background);

    // Corrupt content parses as absent, not as a crash.
    try tmp.dir.writeFile(io, .{ .sub_path = data_name, .data = "{not json" });
    try std.testing.expect(read(arena, io, dir_abs) == null);

    // A future/wrong version is treated as absent (forward-compat).
    try tmp.dir.writeFile(io, .{ .sub_path = data_name, .data =
        \\{"version":999,"pid":1,"zigbase_pid":1,"port":1,"url":"u",
        \\ "control_port":1,"data_dir":"d","background":false,"started_at":"s"}
    });
    try std.testing.expect(read(arena, io, dir_abs) == null);

    // remove() deletes the facts file (NOT dev.lock — see its doc comment)
    // and is idempotent.
    remove(io, gpa, dir_abs);
    try std.testing.expect(read(arena, io, dir_abs) == null);
    remove(io, gpa, dir_abs);
}

test "dev lockfile: flock liveness — held lock reads live, released lock reads stale" {
    // flock locks belong to the OPEN FILE DESCRIPTION, so two independent
    // opens in ONE process conflict exactly like two processes do — this test
    // needs no child process.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathAlloc(io, ".", gpa);
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
```

- [ ] **Step 2: Add the main.zig anchor and run the tests to verify they fail**

In `src/main.zig`, extend the existing `test "dev"` block (line 253):

```zig
test "dev" {
    _ = @import("cli/dev.zig");
    _ = @import("cli/reload.zig");
    _ = @import("cli/dev_lockfile.zig");
}
```

Run: `zig build test-dev`
Expected: FAIL — compile errors for undeclared `formatIso`, `read`, `write`, `acquire`, `isLive`, `remove`, `data_name`.

- [ ] **Step 3: Implement the module**

Append to `src/cli/dev_lockfile.zig`:

```zig
pub const lock_name = "dev.lock";
pub const data_name = "dev.json";

/// Everything `dev stop|status|logs` and the `--background` parent need to
/// know about a running session. Serialized as JSON via std.json.Stringify
/// (field order = declaration order); parsed with parseFromSliceLeaky.
pub const LockFile = struct {
    version: u32 = 1,
    pid: i64,
    zigbase_pid: i64,
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

/// Best-effort cleanup of the FACTS file only (post-stop, stale removal).
/// `dev.lock` is create-once and never unlinked: unlinking a file another
/// process still holds the flock on lets a new session acquire a fresh inode
/// under the same name — two "live" locks at once, liveness defeated (the
/// classic flock+unlink footgun). An empty dev.lock lingering in the
/// gitignored data dir is harmless. Contract 1.
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
        yd.year,                md.month.numeric(),        md.day_index + 1,
        ds.getHoursIntoDay(),   ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(),
    }) catch unreachable;
}
```

Implementation notes for the engineer:
- If `Io.File` has no `.handle` field on this Zig version, find the fd accessor with `grep -n 'handle' <std>/Io/File.zig` — the flock call needs the raw `fd_t`.
- If `readFileAlloc`'s limit argument spelling differs, copy the call shape from `src/cli/reload.zig:314` (`.unlimited`) and use the bounded variant used elsewhere in the repo (`grep -rn 'readFileAlloc' src/`).
- If `std.Io.Writer.Allocating` is not the right allocating-writer spelling, copy the exact pattern from `src/islands/props.zig:28-31`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test-dev`
Expected: PASS (including the three new `dev lockfile:` tests).

- [ ] **Step 5: Verify the single-threaded gate and formatting**

Run: `zig build check -Dsingle-threaded && zig fmt --check src/cli/dev_lockfile.zig src/main.zig`
Expected: both succeed (the module uses no threads).

- [ ] **Step 6: Commit**

```bash
git add src/cli/dev_lockfile.zig src/main.zig
git commit -m "Add the dev session lockfile module (#126)

flock-held dev.lock is the liveness signal (kernel drops it on death, so
staleness detection is race-free and immune to PID reuse — the failure
mode Astro's kill(pid,0) check has); dev.json carries the session facts
and is written atomically so its appearance can double as the
--background readiness handshake. Corrupt or version-skewed lockfiles
read as absent by design: a control verb must never crash on one.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev_lockfile.zig src/main.zig
```

---

### Task 2: New dev flags, conflicts, and help text

**Files:**
- Modify: `src/cli/dev.zig:92-277` (`Command` struct + `parse` + `usage`)
- Modify: `src/fatal.zig:96-123` (help menu "Dev loop" section)
- Test: new `test "dev parse: …"` blocks at the bottom of `src/cli/dev.zig`; existing menu-sync test in `src/fatal.zig`

**Interfaces:**
- Produces (used by Tasks 4, 8, 9): `Command` gains `background: bool`, `force: bool`, `ignore_lock: bool` (all default false). Conflicts (`--ignore-lock` with `--background` or `--force`) are `fatal.usageError` at parse time.

- [ ] **Step 1: Write the failing tests**

At the bottom of `src/cli/dev.zig` (with the other unit tests, after line 1509):

```zig
test "dev parse: background/force/ignore-lock flags default off and parse on" {
    const gpa = std.testing.allocator;
    {
        const cmd = try Command.parse(gpa, &.{});
        defer cmd.deinit(gpa);
        try std.testing.expect(!cmd.background);
        try std.testing.expect(!cmd.force);
        try std.testing.expect(!cmd.ignore_lock);
    }
    {
        const cmd = try Command.parse(gpa, &.{ "--background", "--force" });
        defer cmd.deinit(gpa);
        try std.testing.expect(cmd.background);
        try std.testing.expect(cmd.force);
    }
    {
        const cmd = try Command.parse(gpa, &.{"--ignore-lock"});
        defer cmd.deinit(gpa);
        try std.testing.expect(cmd.ignore_lock);
    }
}
```

(The conflict paths call `fatal.usageError`, which exits the process — they are asserted in the e2e script (Task 10), the same division `dev.zig:1508` already documents for the other usage errors.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-dev`
Expected: FAIL — `Command` has no field `background`.

- [ ] **Step 3: Implement**

In `Command` (after the `rebuild_argv` field, `src/cli/dev.zig:134`):

```zig
    /// `--background`: detach the dev loop and return control to the caller
    /// once the server is ready (see dev_control.zig). Also implied by agent
    /// auto-detection (`ZIGAPAGOS_DEV_BACKGROUND` overrides).
    background: bool,
    /// `--force`: stop an already-running session for this project first.
    force: bool,
    /// `--ignore-lock`: run untracked — no lock taken, no lockfile written,
    /// no duplicate check. For deliberately running a second instance.
    ignore_lock: bool,
```

In `parse` (new locals default `false`; new branches before the final `else`, alongside the other `--no-download`-style bools):

```zig
            } else if (std.mem.eql(u8, arg, "--background")) {
                background = true;
            } else if (std.mem.eql(u8, arg, "--force")) {
                force = true;
            } else if (std.mem.eql(u8, arg, "--ignore-lock")) {
                ignore_lock = true;
```

After the parse loop, before building the result (the conflict must fire whatever the flag order was):

```zig
        // --ignore-lock means "untracked instance"; --background needs the
        // lockfile as its readiness handshake and --force needs it to find
        // the instance to stop. Both combinations are contradictions, not
        // no-ops — refuse them loudly (Astro shipped this same pair of
        // conflicts as a 7.1 follow-up; we start with them).
        if (ignore_lock and background) fatal.usageError(
            "error: --ignore-lock cannot be combined with --background " ++
                "(a background session needs the lockfile to report readiness)\n",
            .{},
        );
        if (ignore_lock and force) fatal.usageError(
            "error: --ignore-lock cannot be combined with --force " ++
                "(--force stops the tracked instance; --ignore-lock runs untracked)\n",
            .{},
        );
```

Add the three fields to the returned struct literal, extend `usage` (line 263) with:

```
        "                     [--background] [--force] [--ignore-lock]\n" ++
```

and in `src/fatal.zig`'s "Dev loop" section (after the `--watch-dir` line, 122-123) add:

```
    \\  --background      Detach: start the dev loop as a background process,
    \\                    print its URL/PID, and exit. Then: 'zigapagos dev
    \\                    stop|status|logs [--follow]' (auto-enabled when an
    \\                    AI-agent environment is detected; set
    \\                    ZIGAPAGOS_DEV_BACKGROUND=0 to disable)
    \\  --force           Stop an already-running dev session first
    \\  --ignore-lock     Run untracked alongside an existing session
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-dev`
Expected: PASS. Also run `zig build test-diag` if the fatal menu-sync test lives there — locate it first: `grep -rn 'help menu' src/fatal.zig` (the test at `src/fatal.zig:167` runs under any suite that compiles fatal.zig; `zig build check` covers compilation).

- [ ] **Step 5: Commit**

```bash
git add src/cli/dev.zig src/fatal.zig
git commit -m "Parse --background/--force/--ignore-lock for zigapagos dev (#126)

The --ignore-lock conflicts are refused at parse time from day one:
Astro shipped the same feature without them and had to follow up
(withastro/astro#17331) after users hit the contradictions.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev.zig src/fatal.zig
```

---

### Task 3: Build-aware status endpoint in the control server (`src/cli/reload.zig`)

**Files:**
- Modify: `src/cli/reload.zig` (Server fields + methods + `handle` routing)
- Test: new `test "dev live-reload: status …"` blocks in `src/cli/reload.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 4, 5, 10):
  - `pub const status_path = "/_zigapagos/status";`
  - `pub fn setIdentity(s: *Server, pid: i64, url: []const u8, started_at: []const u8) void` — slices must outlive the server (session lifetime)
  - `pub fn setBuilding(s: *Server) void`
  - `pub fn setBuildFinished(s: *Server, ok: bool, duration_ms: u64, error_tail: ?[]const u8) void` — bumps `generation`, dupes the tail
  - `fn renderStatusJson(s: *Server, gpa: Allocator) ![]u8` — the exact endpoint body
  - JSON shape (the contract, also documented in Task 11): `{"ok":true,"pid":N,"url":"…","started_at":"…","build":{"generation":N,"status":"ok"|"failed"|"building","duration_ms":N,"error":null|"…"}}`

- [ ] **Step 1: Write the failing tests**

Add to `src/cli/reload.zig`'s test section:

```zig
test "dev live-reload: status json reflects identity and build state" {
    const gpa = std.testing.allocator;
    var s: Server = .init(std.testing.io, gpa, undefined);
    s.setIdentity(4242, "http://127.0.0.1:1990/", "2026-08-07T12:34:56Z");

    // Before any build result: generation 0, building.
    {
        const json = try s.renderStatusJson(gpa);
        defer gpa.free(json);
        try std.testing.expectEqualStrings(
            "{\"ok\":true,\"pid\":4242,\"url\":\"http://127.0.0.1:1990/\"," ++
                "\"started_at\":\"2026-08-07T12:34:56Z\",\"build\":{\"generation\":0," ++
                "\"status\":\"building\",\"duration_ms\":0,\"error\":null}}",
            json,
        );
    }

    // A finished build bumps the generation and records the result.
    s.setBuildFinished(true, 412, null);
    {
        const json = try s.renderStatusJson(gpa);
        defer gpa.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"generation\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"duration_ms\":412") != null);
    }

    // A failed build carries a bounded, JSON-escaped error tail.
    s.setBuilding();
    s.setBuildFinished(false, 99, "boom: \"quoted\"\nline2");
    {
        const json = try s.renderStatusJson(gpa);
        defer gpa.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"generation\":2") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"failed\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\\\"quoted\\\"") != null);
    }
    // Free the duped error tail the server owns.
    s.setBuildFinished(true, 1, null);
}

test "dev live-reload: status error tail is bounded" {
    const gpa = std.testing.allocator;
    var s: Server = .init(std.testing.io, gpa, undefined);
    const big = "x" ** (Server.max_error_tail + 500);
    s.setBuildFinished(false, 1, big);
    const json = try s.renderStatusJson(gpa);
    defer gpa.free(json);
    try std.testing.expect(json.len < Server.max_error_tail + 512);
    s.setBuildFinished(true, 1, null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-dev`
Expected: FAIL — no `setIdentity`/`renderStatusJson` on `Server`.

- [ ] **Step 3: Implement**

In `Server` (fields after `payload`, `src/cli/reload.zig:88`):

```zig
    /// --- status endpoint state (GET /_zigapagos/status) -------------------
    /// Identity, set once by the dev loop before requests can care (guarded
    /// by `mutex` anyway; the slices are session-lifetime, owned by dev.zig).
    status_pid: i64 = 0,
    status_url: []const u8 = "",
    status_started_at: []const u8 = "",
    /// Monotonic completed-build counter — the agent primitive: edit, poll
    /// until this bumps, then branch on `build_status`.
    build_generation: u64 = 0,
    build_status: BuildStatus = .building,
    build_duration_ms: u64 = 0,
    /// Bounded tail of the last FAILED rebuild's output, gpa-owned.
    build_error: ?[]u8 = null,

    pub const BuildStatus = enum { building, ok, failed };
    /// Upper bound on the stored error tail (and thus on the endpoint body).
    pub const max_error_tail: usize = 2048;
```

Methods (after `notifyIslands`):

```zig
    pub const status_path = "/_zigapagos/status";

    pub fn setIdentity(s: *Server, pid: i64, url: []const u8, started_at: []const u8) void {
        s.mutex.lock(s.io) catch return;
        defer s.mutex.unlock(s.io);
        s.status_pid = pid;
        s.status_url = url;
        s.status_started_at = started_at;
    }

    pub fn setBuilding(s: *Server) void {
        s.mutex.lock(s.io) catch return;
        defer s.mutex.unlock(s.io);
        s.build_status = .building;
    }

    /// Records a completed rebuild and bumps the generation (ok AND failed
    /// builds both count — an agent polling for its edit needs the bump either
    /// way, and then branches on `status`). Dupes (a bounded prefix of) the
    /// tail; OOM degrades to "no tail", never drops the result itself.
    pub fn setBuildFinished(s: *Server, ok: bool, duration_ms: u64, error_tail: ?[]const u8) void {
        s.mutex.lock(s.io) catch return;
        defer s.mutex.unlock(s.io);
        s.build_generation += 1;
        s.build_status = if (ok) .ok else .failed;
        s.build_duration_ms = duration_ms;
        if (s.build_error) |old| {
            s.gpa.free(old);
            s.build_error = null;
        }
        if (!ok) if (error_tail) |tail| {
            const bounded = tail[tail.len -| max_error_tail ..];
            s.build_error = s.gpa.dupe(u8, bounded) catch null;
        };
    }

    /// The status endpoint body. Contract 1 (self-freeing): caller frees the
    /// returned JSON; the snapshot copies are scratch.
    fn renderStatusJson(s: *Server, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        {
            s.mutex.lock(s.io) catch return error.Canceled;
            defer s.mutex.unlock(s.io);
            try std.json.Stringify.value(.{
                .ok = true,
                .pid = s.status_pid,
                .url = s.status_url,
                .started_at = s.status_started_at,
                .build = .{
                    .generation = s.build_generation,
                    .status = @tagName(s.build_status),
                    .duration_ms = s.build_duration_ms,
                    .@"error" = s.build_error,
                },
            }, .{}, &aw.writer);
        }
        return aw.toOwnedSlice();
    }
```

Routing in `handle` (`src/cli/reload.zig:207`, right after `receiveHead`):

```zig
        var req = http.receiveHead() catch return;

        // The control server serves two things on this one port: the status
        // endpoint (a normal request/response) and, on every other path, the
        // SSE reload stream (EventSource never sets a path we care about).
        if (std.mem.startsWith(u8, req.head.target, status_path)) {
            const json = s.renderStatusJson(s.gpa) catch return;
            defer s.gpa.free(json);
            req.respond(json, .{ .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "cache-control", .value = "no-cache" },
            } }) catch return;
            return;
        }
```

Implementation notes:
- The anonymous-struct `Stringify.value` call must produce field order exactly as the test expects (declaration order — that is `std.json.Stringify`'s documented behavior, see `src/diag.zig:87`).
- If `aw.toOwnedSlice()` is not the allocating-writer's harvest method, use the same harvest the repo uses at `src/islands/props.zig:28-33`.
- `-|` is saturating subtraction (bounds the tail slice start at 0).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-dev`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/cli/reload.zig
git commit -m "Serve build-aware status from the reload server (#126)

/_zigapagos/status returns a monotonic build generation plus the last
rebuild's status/duration/error-tail — the agent loop is: edit, poll
until generation bumps, branch on status. This is the piece a bare
liveness ping (Astro's {\"ok\":true}) cannot provide, and the reload
server already holds the mutex + HTTP server to serve it for free.
Generation counts failed builds too: the poller needs the bump to know
its edit was seen at all.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/reload.zig
```

---

### Task 4: Wire the dev loop — always-on control server, build state, session lock, lockfile write

**Files:**
- Modify: `src/cli/dev.zig` (`dev()` body: lines ~420-712, `runRebuild`: 1477-1505)
- Test: `test "dev rebuild result carries duration and failure tail"` in `src/cli/dev.zig`; behavior asserts land in Task 10's e2e

**Interfaces:**
- Consumes: Task 1 (`dev_lockfile.acquire/write/read/remove/formatIso`), Task 2 (`cmd.force/ignore_lock`), Task 3 (`setIdentity/setBuilding/setBuildFinished`, `status_path`).
- Produces (used by Tasks 5-8, 10):
  - `runRebuild` becomes `fn runRebuild(io: Io, gpa: Allocator, argv: []const []const u8, environ_map: *std.process.Environ.Map, capture_path: ?[]const u8) RebuildResult` with `pub const RebuildResult = struct { ok: bool, duration_ms: u64, error_tail: ?[]u8 = null };` (tail gpa-owned, only set on failure with capture)
  - The lockfile on disk after `waitReady` (foreground and background sessions alike, unless `--ignore-lock`)
  - New banner line: `dev: control: http://{host}:{port}/_zigapagos/status` (always printed)
  - `dev_control.stopInstance` is FORWARD-REFERENCED here for `--force`; Task 6 implements it. Until Task 6 lands, `--force` calls a placeholder in `dev_control.zig` created in Task 5. Execute Tasks 5-6 before manually testing `--force`.

- [ ] **Step 1: Write the failing unit test for the runRebuild change**

```zig
test "dev rebuild result carries duration and failure tail" {
    if (comptime builtin.single_threaded) return; // spawn paths untested here anyway
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture = try tmp.dir.realPathAlloc(io, ".", gpa);
    defer gpa.free(capture);
    const capture_path = try std.fs.path.join(gpa, &.{ capture, "last-build.log" });
    defer gpa.free(capture_path);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();

    // A failing command yields ok=false and the tail of its output.
    const bad = runRebuild(io, gpa, &.{ "/bin/sh", "-c", "echo doomed >&2; exit 3" }, &environ, capture_path);
    defer if (bad.error_tail) |t| gpa.free(t);
    try std.testing.expect(!bad.ok);
    try std.testing.expect(bad.error_tail != null);
    try std.testing.expect(std.mem.indexOf(u8, bad.error_tail.?, "doomed") != null);

    // A succeeding command yields ok=true and no tail.
    const good = runRebuild(io, gpa, &.{ "/bin/sh", "-c", "exit 0" }, &environ, capture_path);
    try std.testing.expect(good.ok);
    try std.testing.expect(good.error_tail == null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-dev`
Expected: FAIL — `runRebuild` has 3 params and returns `bool`.

- [ ] **Step 3: Implement the runRebuild change**

Replace `runRebuild` (`src/cli/dev.zig:1475-1505`):

```zig
pub const RebuildResult = struct { ok: bool, duration_ms: u64, error_tail: ?[]u8 = null };

/// Runs the rebuild command to completion. With `capture_path` null the
/// child inherits stdio (output streams live — used for the initial build).
/// With a path, stdout+stderr are captured to that file, dumped to our
/// stderr afterwards (so the log reads the same), and on failure the tail
/// rides back for the status endpoint. Contract 1 (self-freeing) apart from
/// the returned tail, which the caller owns.
fn runRebuild(
    io: Io,
    gpa: Allocator,
    argv: []const []const u8,
    environ_map: *std.process.Environ.Map,
    capture_path: ?[]const u8,
) RebuildResult {
    const start_ms = Io.Clock.awake.now(io).toMilliseconds();
    const fail: RebuildResult = .{ .ok = false, .duration_ms = 0 };

    var capture_file: ?Io.File = if (capture_path) |p|
        Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch null
    else
        null;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdout = if (capture_file) |f| .{ .file = f } else .inherit,
        .stderr = if (capture_file) |f| .{ .file = f } else .inherit,
    }) catch |err| {
        std.debug.print("dev: failed to spawn '{s}': {s}\n", .{ argv[0], @errorName(err) });
        if (capture_file) |f| f.close(io);
        return fail;
    };
    const term = child.wait(io) catch |err| {
        std.debug.print("dev: failed to wait for '{s}': {s}\n", .{ argv[0], @errorName(err) });
        if (capture_file) |f| f.close(io);
        return fail;
    };
    if (capture_file) |f| f.close(io);
    const took_ms: u64 = @intCast(Io.Clock.awake.now(io).toMilliseconds() - start_ms);

    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };

    // Replay the captured output so the dev log reads exactly as it did when
    // the child inherited stderr, then keep a bounded tail for the status
    // endpoint when the build failed.
    var error_tail: ?[]u8 = null;
    if (capture_path) |p| {
        if (Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 * 1024 * 1024)) catch null) |out| {
            defer gpa.free(out);
            if (out.len > 0) std.debug.print("{s}", .{out});
            if (!ok) error_tail = gpa.dupe(u8, out[out.len -| 2048..]) catch null;
        }
    }

    switch (term) {
        .exited => |code| std.debug.print(
            "dev: build finished in {d} ms (exit code {d})\n",
            .{ took_ms, code },
        ),
        else => std.debug.print("dev: build terminated abnormally ({s})\n", .{@tagName(term)}),
    }
    return .{ .ok = ok, .duration_ms = took_ms, .error_tail = error_tail };
}
```

Update the two call sites:
- Initial build (`dev.zig:461`): `if (!runRebuild(io, gpa, rebuild_argv, environ_map, null).ok) fatal.msg(…)` — unchanged behavior, still streams.
- Watch loop (`dev.zig:653` and `:662`): both become `runRebuild(io, gpa, rebuild_argv, environ_map, capture_path)` where `capture_path` is computed once before the loop: `const capture_path = std.fs.path.join(gpa, &.{ data_dir_abs, "last-build.log" }) catch fatal.oom();`. The loop's `rebuild_ok` variable becomes `rebuild: RebuildResult`, and the `if (rebuild_ok)` checks become `if (rebuild.ok)`.

- [ ] **Step 4: Wire the session lock, control server, build state and lockfile into `dev()`**

All edits inside `dev()`; add `const dev_lockfile = @import("dev_lockfile.zig");` and `const dev_control = @import("dev_control.zig");` to the imports (dev_control is created in Task 5 — if executing this task standalone, create the file with just `pub fn stopInstance(io: Io, gpa: Allocator, data_dir_abs: []const u8) enum { stopped, none } { _ = io; _ = gpa; _ = data_dir_abs; return .none; }` plus imports; Task 6 replaces the body).

**(a) Session lock** — right after the data dir is created (`dev.zig:427`):

```zig
    // The session lock, held (as an flock) for the whole process lifetime.
    // Taken BEFORE any server starts — duplicate prevention has to win the
    // race, not report it (watchman's lock-before-fork lesson).
    var session_lock: ?dev_lockfile.Lock = null;
    if (!cmd.ignore_lock) {
        session_lock = try dev_lockfile.acquire(io, data_dir_abs, gpa);
        if (session_lock == null and cmd.force) {
            _ = dev_control.stopInstance(io, gpa, data_dir_abs);
            session_lock = try dev_lockfile.acquire(io, data_dir_abs, gpa);
        }
        if (session_lock == null) {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const existing = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs);
            fatal.msg(
                "error: dev: a dev server is already running for this project{s}{s}\n" ++
                    "hint: 'zigapagos dev stop' stops it; --force replaces it; " ++
                    "--ignore-lock runs a second, untracked instance\n",
                .{
                    if (existing != null) " at " else "",
                    if (existing) |lf| lf.url else "",
                },
            );
        }
        // A stale-but-unheld lockfile (a kill -9'd session) parses fine while
        // the flock was acquirable: we now own the session, so stale facts
        // must not linger for a status/stop racing our startup window.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        if (dev_lockfile.read(arena_state.allocator(), io, data_dir_abs) != null)
            dev_control.sweepOrphan(io, gpa, data_dir_abs);
    } else {
        std.debug.print(
            "dev: --ignore-lock — this instance is untracked ('dev stop|status|logs' will not see it)\n",
            .{},
        );
    }
    _ = &session_lock; // held for the process lifetime; released by process exit
```

(`sweepOrphan` is produced by Task 6 with signature `pub fn sweepOrphan(io: Io, gpa: Allocator, data_dir_abs: []const u8) void`; in the Task-5 placeholder file give it an empty body.)

**(b) Always-on control server** — replace the `if (cmd.live_reload)` block at `dev.zig:489-506`:

```zig
    // The control server: SSE live-reload on `/` plus the build-aware status
    // endpoint. ALWAYS started — background sessions without a health
    // endpoint are half a feature — while --no-live-reload now only disables
    // snippet injection and reload events, not the server.
    const reload_port: u16 = if (cmd.reload_port == 0) e2e.pickFreePort(io) else cmd.reload_port;
    const reload_addr = Io.net.IpAddress.parse(cmd.host, reload_port) catch fatal.msg(
        "error: dev: --host must be an IP literal for the control server (got '{s}')\n",
        .{cmd.host},
    );
    const reload_server: *reload.Server = gpa.create(reload.Server) catch fatal.oom();
    reload_server.* = .init(io, gpa, reload_addr);
    reload_server.start() catch |err| fatal.msg(
        "error: dev: unable to start the control server: {s}\n",
        .{@errorName(err)},
    );
    reload_server.setBuildFinished(true, 0, null); // the initial build (gen 1)
    if (cmd.live_reload) reload.injectTree(io, gpa, site_abs, reload_port, null);
```

Downstream uses of `reload_server` change from optional-unwrap to plain: the banner check at `dev.zig:582` becomes `if (cmd.live_reload)`, and the loop's `if (reload_server) |srv|` (`dev.zig:667`) becomes `if (cmd.live_reload) { const srv = reload_server; … }`.

**(c) Build-state wiring in the watch loop** — right before the `switch (change)` rebuild (`dev.zig:643`): `reload_server.setBuilding();`. Right after the rebuild result is known: `reload_server.setBuildFinished(rebuild.ok, rebuild.duration_ms, rebuild.error_tail); if (rebuild.error_tail) |t| gpa.free(t);` (the server duped it).

**(d) Identity, lockfile, banner** — after `waitReady` (`dev.zig:574`), before the ready banner:

```zig
    const self_pid: i64 = @intCast(std.c.getpid());
    const url = std.fmt.allocPrint(gpa, "http://{s}:{d}/", .{ cmd.host, port }) catch fatal.oom();
    const started_at = blk: {
        const buf = gpa.create([20]u8) catch fatal.oom();
        const secs: u64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
        break :blk dev_lockfile.formatIso(buf, secs);
    };
    reload_server.setIdentity(self_pid, url, started_at);

    const is_bg_child = environ_map.get(dev_control.background_child_env) != null;
    if (!cmd.ignore_lock) {
        dev_lockfile.write(io, gpa, data_dir_abs, .{
            .pid = self_pid,
            .zigbase_pid = if (harness.server.id) |id| @intCast(id) else 0,
            .port = port,
            .url = url,
            .control_port = reload_port,
            .data_dir = data_dir_abs,
            .background = is_bg_child,
            .started_at = started_at,
        }) catch |err| std.debug.print(
            "dev: warning: could not write the lockfile ({s}) — 'dev stop|status|logs' will not see this session\n",
            .{@errorName(err)},
        );
    }
```

(A failed lockfile write warns and keeps serving — bookkeeping never takes down a healthy server.) After the existing ready-banner block (`dev.zig:576-589`), add the always-printed control line:

```zig
    std.debug.print("dev: control: http://{s}:{d}{s}\n", .{ cmd.host, reload_port, reload.Server.status_path });
```

(`background_child_env` is produced by Task 5's `dev_control.zig`; the placeholder file must declare `pub const background_child_env = "ZIGAPAGOS_DEV_BACKGROUND_CHILD";`.)

- [ ] **Step 5: Compile-verify everything**

Run: `zig build check && zig build check -Dsingle-threaded && zig build test-dev`
Expected: all pass. The `-Dsingle-threaded` check matters here: `dev()`'s body is behind the runtime single-threaded gate but is still ANALYZED — any `std.Thread` reference introduced outside a comptime prune fails this step.

- [ ] **Step 6: Manual smoke test**

From `examples/tsx-site` (or any site fixture) with the stub on PATH (see `tests/dev/dev.sh` for the stub arrangement), run `zigapagos dev --port=0` briefly; verify with `curl` that `/_zigapagos/status` answers on the control port with `"generation":1`, that `.zigbase/dev.json` + `.zigbase/dev.lock` exist, and that a second `zigapagos dev` in the same project refuses with the already-running message.

- [ ] **Step 7: Commit**

```bash
git add src/cli/dev.zig src/cli/dev_control.zig
git commit -m "Hold the session lock, serve status always-on, write dev.json (#126)

The flock is taken before any server starts so duplicate prevention wins
the race rather than reporting it. dev.json is written only after
waitReady because both ports are late-bound — which is exactly what lets
the --background parent treat its appearance as the readiness signal.
The reload server is promoted to an always-on control server:
--no-live-reload now disables injection and reload events only, since a
background session without a health endpoint is half a feature.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev.zig src/cli/dev_control.zig
```

---

### Task 5: `dev status` verb + control-verb dispatch (`src/cli/dev_control.zig`)

**Files:**
- Create/replace placeholder: `src/cli/dev_control.zig`
- Modify: `src/cli/dev.zig:279-291` (sub-verb dispatch before the single-threaded gate)
- Modify: `src/main.zig` `test "dev"` block (anchor `dev_control.zig`)
- Test: `test "dev control: …"` blocks in `src/cli/dev_control.zig`

**Interfaces:**
- Consumes: Task 1 (`dev_lockfile.*`).
- Produces:
  - `pub const Verb = enum { stop, status, logs };`
  - `pub fn run(io: Io, gpa: Allocator, verb: Verb, args: []const []const u8, environ_map: *std.process.Environ.Map) error{OutOfMemory}!noreturn`
  - `pub const background_child_env = "ZIGAPAGOS_DEV_BACKGROUND_CHILD";`
  - `pub const background_optout_env = "ZIGAPAGOS_DEV_BACKGROUND";`
  - `fn fetchBody(io: Io, gpa: Allocator, address: Io.net.IpAddress, path: []const u8) ![]u8` (HTTP GET, headers stripped, 64 KiB cap — used by Tasks 6, 8)
  - `fn resolveDataDir(io: Io, gpa: Allocator, args: []const []const u8) []const u8` — parses an optional `--data-dir=DIR` (default `.zigbase`) and resolves it against the site root via `root.Config.load`
  - Keeps the Task-4 placeholders `stopInstance`/`sweepOrphan` (real bodies in Task 6)

- [ ] **Step 1: Write the failing tests**

In the new `src/cli/dev_control.zig`:

```zig
test "dev control: status text rendering" {
    const gpa = std.testing.allocator;
    const lf: dev_lockfile.LockFile = .{
        .pid = 4242,
        .zigbase_pid = 4243,
        .port = 1990,
        .url = "http://127.0.0.1:1990/",
        .control_port = 43121,
        .data_dir = "/tmp/x/.zigbase",
        .background = true,
        .started_at = "2026-08-07T12:34:56Z",
    };
    const text = try renderStatusText(gpa, lf, "{\"ok\":true,\"pid\":4242,\"url\":\"http://127.0.0.1:1990/\",\"started_at\":\"2026-08-07T12:34:56Z\",\"build\":{\"generation\":7,\"status\":\"ok\",\"duration_ms\":412,\"error\":null}}");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "http://127.0.0.1:1990/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pid 4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "background") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "build #7 ok (412 ms)") != null);

    // Control server unreachable → status still prints, degraded.
    const degraded = try renderStatusText(gpa, lf, null);
    defer gpa.free(degraded);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "build: unknown (control server unreachable)") != null);
}

test "dev control: status json rendering wraps running + lockfile + build" {
    const gpa = std.testing.allocator;
    const lf: dev_lockfile.LockFile = .{
        .pid = 1, .zigbase_pid = 2, .port = 3, .url = "u", .control_port = 4,
        .data_dir = "d", .background = false, .started_at = "s",
    };
    const json = try renderStatusJson(gpa, lf, "{\"ok\":true,\"pid\":1,\"url\":\"u\",\"started_at\":\"s\",\"build\":{\"generation\":2,\"status\":\"failed\",\"duration_ms\":9,\"error\":\"boom\"}}");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"running\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"generation\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"zigbase_pid\":2") != null);
}
```

- [ ] **Step 2: Anchor + run to verify failure**

Add `_ = @import("cli/dev_control.zig");` to `src/main.zig`'s `test "dev"` block. Run `zig build test-dev`. Expected: FAIL (missing `renderStatusText`/`renderStatusJson`).

- [ ] **Step 3: Implement the module**

```zig
//! Control-plane verbs for `zigapagos dev` — `stop`, `status`, `logs` — plus
//! the `--background` parent and agent-environment detection. Deliberately
//! thread-free: these verbs must work under -Dsingle-threaded, so dev.zig
//! dispatches here BEFORE its single-threaded gate.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const dev_lockfile = @import("dev_lockfile.zig");

/// Internal recursion guard: set on the background CHILD so it runs the
/// foreground path. A DIFFERENT variable from the user-facing opt-out below —
/// Astro conflated the two and its opt-out corrupts its own lockfile state.
pub const background_child_env = "ZIGAPAGOS_DEV_BACKGROUND_CHILD";
/// User-facing: "0" (or any value other than "1") disables agent
/// auto-backgrounding; "1" forces background mode.
pub const background_optout_env = "ZIGAPAGOS_DEV_BACKGROUND";

pub const Verb = enum { stop, status, logs };

pub fn run(
    io: Io,
    gpa: Allocator,
    verb: Verb,
    args: []const []const u8,
    environ_map: *std.process.Environ.Map,
) error{OutOfMemory}!noreturn {
    _ = environ_map;
    if (builtin.os.tag == .windows) fatal.msg(
        "error: dev {s} is not supported on Windows yet (see docs/ROADMAP.md)\n",
        .{@tagName(verb)},
    );
    switch (verb) {
        .status => try statusVerb(io, gpa, args),
        .stop => try stopVerb(io, gpa, args),
        .logs => try logsVerb(io, gpa, args),
    }
}

fn statusVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    var data_dir: []const u8 = ".zigbase";
    var json = false;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg["--data-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else fatal.usageError(
            "error: unexpected 'zigapagos dev status' argument '{s}'\n" ++
                "usage: zigapagos dev status [--json] [--data-dir=DIR]\n",
            .{arg},
        );
    }
    const data_dir_abs = resolveDataDir(io, gpa, data_dir);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const live = dev_lockfile.isLive(io, gpa, data_dir_abs);
    const lf = dev_lockfile.read(arena, io, data_dir_abs);
    if (!live or lf == null) {
        if (!live and lf != null) dev_lockfile.remove(io, gpa, data_dir_abs); // stale
        if (json) {
            std.debug.print("{{\"running\":false}}\n", .{});
        } else {
            std.debug.print("No dev server is running.\n", .{});
        }
        std.process.exit(1);
    }

    // Fetch the control endpoint (best-effort; a just-started session may not
    // answer yet — status still prints from the lockfile alone).
    const body: ?[]u8 = blk: {
        const addr = Io.net.IpAddress.parse("127.0.0.1", lf.?.control_port) catch break :blk null;
        break :blk fetchBody(io, gpa, addr, "/_zigapagos/status") catch null;
    };
    defer if (body) |b| gpa.free(b);

    const out = if (json)
        try renderStatusJson(gpa, lf.?, body)
    else
        try renderStatusText(gpa, lf.?, body);
    defer gpa.free(out);
    std.debug.print("{s}", .{out});
    std.process.exit(0);
}

/// Resolve the data dir against the site root (the dir holding
/// zigapagos.ziggy), exactly as dev() does. Fatals (via Config.load) when run
/// outside a site. Contract 1: result is gpa-owned, held to process exit.
fn resolveDataDir(io: Io, gpa: Allocator, data_dir: []const u8) []const u8 {
    _, const base_dir_path = root.Config.load(io, gpa);
    return std.fs.path.resolve(gpa, &.{ base_dir_path, data_dir }) catch fatal.oom();
}

/// Human `dev status` output. `endpoint_json` is the raw control-endpoint
/// body, null when unreachable. Contract 1: caller frees the result.
fn renderStatusText(gpa: Allocator, lf: dev_lockfile.LockFile, endpoint_json: ?[]const u8) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.print("dev server running at {s} (pid {d}{s})\n", .{
        lf.url, lf.pid, if (lf.background) ", background" else "",
    }) catch return error.OutOfMemory;
    w.print("  started: {s}\n", .{lf.started_at}) catch return error.OutOfMemory;

    build_line: {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const body = endpoint_json orelse break :build_line;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{}) catch
            break :build_line;
        const build = (parsed.object.get("build") orelse break :build_line).object;
        const generation = (build.get("generation") orelse break :build_line).integer;
        const status = (build.get("status") orelse break :build_line).string;
        const duration = (build.get("duration_ms") orelse break :build_line).integer;
        w.print("  build #{d} {s} ({d} ms)\n", .{ generation, status, duration }) catch
            return error.OutOfMemory;
        if (build.get("error")) |e| if (e == .string)
            w.print("  error: {s}\n", .{e.string}) catch return error.OutOfMemory;
        w.print("  control: http://127.0.0.1:{d}/_zigapagos/status\n  logs:    zigapagos dev logs\n", .{
            lf.control_port,
        }) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
    // Unreachable/unparseable endpoint: degrade, never fail — the session may
    // be mid-startup.
    w.print("  build: unknown (control server unreachable)\n", .{}) catch return error.OutOfMemory;
    w.print("  control: http://127.0.0.1:{d}/_zigapagos/status\n  logs:    zigapagos dev logs\n", .{
        lf.control_port,
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `dev status --json` body: {"running":true, ...lockfile fields...,
/// "build": <the endpoint's build object, or null>}. Contract 1.
fn renderStatusJson(gpa: Allocator, lf: dev_lockfile.LockFile, endpoint_json: ?[]const u8) error{OutOfMemory}![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const build_value: ?std.json.Value = blk: {
        const body = endpoint_json orelse break :blk null;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch break :blk null;
        break :blk parsed.object.get("build");
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try std.json.Stringify.value(.{
        .running = true,
        .pid = lf.pid,
        .zigbase_pid = lf.zigbase_pid,
        .url = lf.url,
        .port = lf.port,
        .control_port = lf.control_port,
        .background = lf.background,
        .started_at = lf.started_at,
        .build = build_value,
    }, .{}, &aw.writer);
    try aw.writer.writeAll("\n");
    return aw.toOwnedSlice();
}

/// One bounded HTTP GET: connect, send, strip headers, return the body.
/// Modeled on e2e.zig's probeStatus, which stops at the status line — this
/// reads to EOF (we send `connection: close`). Contract 1.
fn fetchBody(io: Io, gpa: Allocator, address: Io.net.IpAddress, path: []const u8) ![]u8 {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    try writer.interface.print(
        "GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\nconnection: close\r\n\r\n",
        .{ path, address.getPort() },
    );
    try writer.interface.flush();

    var in_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(gpa);
    while (all.items.len < 64 * 1024) {
        const chunk = reader.interface.peekGreedy(1) catch break;
        try all.appendSlice(gpa, chunk);
        reader.interface.toss(chunk.len);
    }
    const raw = all.items;
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    return gpa.dupe(u8, raw[split + 4 ..]);
}

// Task-4 forward decls, implemented for real in Task 6:
pub fn stopInstance(io: Io, gpa: Allocator, data_dir_abs: []const u8) enum { stopped, none } {
    _ = io; _ = gpa; _ = data_dir_abs;
    return .none;
}
pub fn sweepOrphan(io: Io, gpa: Allocator, data_dir_abs: []const u8) void {
    _ = io; _ = gpa; _ = data_dir_abs;
}
fn stopVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    _ = args; _ = gpa; _ = io;
    fatal.msg("error: dev stop: not implemented yet\n", .{}); // replaced in Task 6
}
fn logsVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    _ = args; _ = gpa; _ = io;
    fatal.msg("error: dev logs: not implemented yet\n", .{}); // replaced in Task 7
}
```

**Engineer note on `renderStatusText`:** if `std.Io.Writer.Allocating` is not the exact allocating-writer spelling on this Zig version, copy the pattern from `src/islands/props.zig:28-33`; the tests assert the `"pid 4242"`, `"background"`, and `"build #7 ok (412 ms)"` substrings, so keep those formats.

**Dispatch in `dev()`** — insert at the very top of `dev()` (`src/cli/dev.zig:284`), BEFORE the single-threaded gate:

```zig
    // Control verbs are thread-free and must stay usable (and compiled)
    // under -Dsingle-threaded, so they dispatch before the gate below.
    if (args.len > 0) {
        if (std.meta.stringToEnum(dev_control.Verb, args[0])) |verb|
            return dev_control.run(io, gpa, verb, args[1..], environ_map);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-dev && zig build check -Dsingle-threaded`
Expected: PASS — including compilation of `dev_control.zig` under single-threaded (this is the load-bearing check for the dispatch placement).

- [ ] **Step 5: Manual smoke test**

In a site fixture with no server running: `zigapagos dev status` prints `No dev server is running.` and exits 1; `zigapagos dev status --json` prints `{"running":false}` and exits 1. With a dev session running (Task 4 smoke setup): both print live data, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/cli/dev_control.zig src/cli/dev.zig src/main.zig
git commit -m "Add 'zigapagos dev status' and the control-verb dispatch (#126)

The verbs dispatch before dev()'s single-threaded gate: they are
thread-free and must work under -Dsingle-threaded, where the dev loop
itself refuses to run. status exits 1 when nothing is running so
scripts and agents can branch on the exit code, and it degrades to
lockfile-only output when the control endpoint isn't answering yet
rather than failing.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev_control.zig src/cli/dev.zig src/main.zig
```

---

### Task 6: `dev stop` with orphan sweep

**Files:**
- Modify: `src/cli/dev_control.zig` (replace `stopVerb`/`stopInstance`/`sweepOrphan` placeholders)
- Test: unit `test "dev control: stop parses args"`-level checks are thin here (the interesting behavior is process-level); e2e coverage in Task 10

**Interfaces:**
- Consumes: Tasks 1, 5.
- Produces:
  - `pub fn stopInstance(io: Io, gpa: Allocator, data_dir_abs: []const u8) enum { stopped, none }` — full stop path, shared by the verb and `dev --force`
  - `pub fn sweepOrphan(io: Io, gpa: Allocator, data_dir_abs: []const u8) void` — kill a health-verified orphaned zigbase from a stale lockfile, then remove the lockfile

- [ ] **Step 1: Implement**

```zig
fn stopVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    var data_dir: []const u8 = ".zigbase";
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg["--data-dir=".len..];
        } else fatal.usageError(
            "error: unexpected 'zigapagos dev stop' argument '{s}'\n" ++
                "usage: zigapagos dev stop [--data-dir=DIR]\n",
            .{arg},
        );
    }
    const data_dir_abs = resolveDataDir(io, gpa, data_dir);
    switch (stopInstance(io, gpa, data_dir_abs)) {
        .stopped => std.debug.print("Stopped.\n", .{}),
        .none => std.debug.print("No dev server is running.\n", .{}),
    }
    std.process.exit(0); // idempotent: nothing-to-stop is success
}

/// The whole stop path: TERM the dev pid (its reaper cascades to zigbase),
/// poll the flock up to 5s, escalate to KILL, then sweep any zigbase orphan
/// and remove the lockfile. Also handles the dev-already-dead (kill -9) case:
/// the sweep runs regardless. Contract 1.
pub fn stopInstance(io: Io, gpa: Allocator, data_dir_abs: []const u8) enum { stopped, none } {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs);
    const live = dev_lockfile.isLive(io, gpa, data_dir_abs);

    if (!live) {
        // Dev is dead. A lockfile left behind means a kill -9'd session —
        // its zigbase may still be squatting on the port.
        if (lf != null) {
            sweepOrphan(io, gpa, data_dir_abs);
            return .stopped;
        }
        return .none;
    }

    const target: std.posix.pid_t = @intCast(lf.?.pid);
    std.posix.kill(target, .TERM) catch {};
    // Poll the flock: it drops the instant the process dies — no PID-reuse
    // ambiguity, no zombie false-positives.
    var waited_ms: u64 = 0;
    while (waited_ms < 5000 and dev_lockfile.isLive(io, gpa, data_dir_abs)) {
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        waited_ms += 100;
    }
    if (dev_lockfile.isLive(io, gpa, data_dir_abs)) {
        std.debug.print("dev stop: no response to SIGTERM after 5s — escalating to SIGKILL\n", .{});
        std.posix.kill(target, .KILL) catch {};
        waited_ms = 0;
        while (waited_ms < 2000 and dev_lockfile.isLive(io, gpa, data_dir_abs)) {
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            waited_ms += 100;
        }
    }
    // SIGKILL means the reaper never ran → zigbase orphaned; SIGTERM usually
    // cascaded, making the sweep a cheap no-op. Run it either way.
    sweepOrphan(io, gpa, data_dir_abs);
    return .stopped;
}

/// Kill an orphaned zigbase recorded in the lockfile — but only after
/// confirming the process on that port really is our zigbase, by hitting its
/// /api/health (the endpoint the stock binary has served since v0.12.0's
/// pin). No match → warn and leave it (PID reuse: killing an innocent
/// process is worse than leaving a squatter). Always removes the lockfile.
/// Contract 1.
pub fn sweepOrphan(io: Io, gpa: Allocator, data_dir_abs: []const u8) void {
    defer dev_lockfile.remove(io, gpa, data_dir_abs);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs) orelse return;
    if (lf.zigbase_pid <= 0) return;
    const zb: std.posix.pid_t = @intCast(lf.zigbase_pid);
    std.posix.kill(zb, .{}) catch return; // signal 0: existence check — already gone

    const healthy = blk: {
        const addr = Io.net.IpAddress.parse("127.0.0.1", lf.port) catch break :blk false;
        const body = fetchBody(io, gpa, addr, "/api/health") catch break :blk false;
        defer gpa.free(body);
        break :blk std.mem.indexOf(u8, body, "\"status\"") != null;
    };
    if (!healthy) {
        std.debug.print(
            "dev stop: pid {d} is alive but {d} does not answer /api/health — " ++
                "not killing it (PID may have been reused); if a zigbase is stuck, " ++
                "'pkill zigbase' remains the manual recovery\n",
            .{ lf.zigbase_pid, lf.port },
        );
        return;
    }
    std.debug.print("dev stop: reaping orphaned zigbase (pid {d})\n", .{lf.zigbase_pid});
    std.posix.kill(zb, .TERM) catch return;
    // Brief grace, then KILL.
    var waited: u64 = 0;
    while (waited < 2000) : (waited += 100) {
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        std.posix.kill(zb, .{}) catch return; // gone
    }
    std.posix.kill(zb, .KILL) catch {};
}
```

Engineer notes:
- `std.posix.kill(pid, .{})` as signal-0 may need the actual spelling `std.posix.kill(pid, @enumFromInt(0))` or a raw `std.c.kill(pid, 0)` — check `std.posix.SIG`'s type in this Zig; the reaper (`dev.zig:760`) shows `.TERM` works as a member. Use `std.c.kill(pid, 0) == 0` if the enum has no zero member.
- The dev-pid host is always loopback-reachable for health because `dev stop` runs on the same machine; use the lockfile's port with `127.0.0.1` even when dev ran `--host=0.0.0.0`.

- [ ] **Step 2: Compile + unit-run**

Run: `zig build check && zig build test-dev && zig build check -Dsingle-threaded`
Expected: PASS.

- [ ] **Step 3: Manual verification of both paths**

(a) Normal: start a dev session (stub on PATH), `zigapagos dev stop` → "Stopped.", lockfiles gone, port free, second `stop` prints "No dev server is running." and exits 0.
(b) Orphan: start a session, `kill -9 <dev pid>` (from `dev: starting (pid N)`), confirm the stub still answers on the port, then `zigapagos dev stop` → reaps it, port free, lockfiles gone. This is the regression scenario Task 10 automates — do it by hand once here.

- [ ] **Step 4: Commit**

```bash
git add src/cli/dev_control.zig
git commit -m "Add 'zigapagos dev stop' with a health-verified orphan sweep (#126)

Liveness polling uses the flock, which the kernel drops at death — no
zombie or PID-reuse ambiguity. The sweep runs even when dev is already
dead: a kill -9'd session leaves zigbase squatting on the port (the
reaper's documented residual gap, dev.zig:727), and stop now retires
the 'pkill zigbase' manual recovery — but only after /api/health
confirms the recorded pid is really a zigbase, because killing a
PID-reuse victim is worse than leaving a squatter.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev_control.zig
```

---

### Task 7: `dev logs [--follow]`

**Files:**
- Modify: `src/cli/dev_control.zig` (replace `logsVerb` placeholder)
- Test: e2e in Task 10 (file-tail behavior is process-level); compile gates here

**Interfaces:**
- Consumes: Tasks 1, 5. The log file name is `dev.log` in the data dir (written by Task 8's parent).
- Produces: `pub const log_name = "dev.log";` (Task 8 uses it).

- [ ] **Step 1: Implement**

```zig
pub const log_name = "dev.log";

fn logsVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    var data_dir: []const u8 = ".zigbase";
    var follow = false;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg["--data-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
        } else fatal.usageError(
            "error: unexpected 'zigapagos dev logs' argument '{s}'\n" ++
                "usage: zigapagos dev logs [--follow] [--data-dir=DIR]\n",
            .{arg},
        );
    }
    const data_dir_abs = resolveDataDir(io, gpa, data_dir);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs);
    const live = dev_lockfile.isLive(io, gpa, data_dir_abs);
    if (live and lf != null and !lf.?.background) fatal.msg(
        "error: dev logs: this session runs in the FOREGROUND — its output is " ++
            "in the terminal that started it (only --background sessions log to a file)\n",
        .{},
    );

    const log_path = std.fs.path.join(gpa, &.{ data_dir_abs, log_name }) catch fatal.oom();
    const contents = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch fatal.msg(
        "error: dev logs: no log file at {s} (was a background session ever started?)\n",
        .{log_path},
    );
    std.debug.print("{s}", .{contents});
    var offset: usize = contents.len;
    gpa.free(contents);
    if (!follow) std.process.exit(0);

    // Poll-tail: stat-and-read-the-delta every 200ms; when the session dies,
    // flush whatever appeared and exit. Boring and portable — no fs-events
    // machinery for a dev-log tail.
    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        const now = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch break;
        defer gpa.free(now);
        if (now.len > offset) {
            std.debug.print("{s}", .{now[offset..]});
            offset = now.len;
        } else if (now.len < offset) {
            // Truncated (a --force restart): dump the fresh file from the top.
            std.debug.print("{s}", .{now});
            offset = now.len;
        }
        if (!dev_lockfile.isLive(io, gpa, data_dir_abs)) {
            // One final delta read, then done.
            const last = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch break;
            defer gpa.free(last);
            if (last.len > offset) std.debug.print("{s}", .{last[offset..]});
            break;
        }
    }
    std.process.exit(0);
}
```

(Re-reading the whole file each tick is deliberate simplicity: dev logs are small — bounded by session length — and it sidesteps `seek` API differences. If the 16 MiB cap is ever hit, the message tells the user the file is oversized.)

- [ ] **Step 2: Compile-verify**

Run: `zig build check && zig build check -Dsingle-threaded && zig build test-dev`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/cli/dev_control.zig
git commit -m "Add 'zigapagos dev logs' with a poll-tail --follow (#126)

A foreground session errors with a pointer at its owning terminal
rather than showing a stale or missing file. --follow re-reads and
prints the delta rather than seeking — dev logs are session-bounded and
small, and this keeps the tail immune to truncate-on-restart (--force),
which it detects and replays from the top.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev_control.zig
```

---

### Task 8: `--background` daemonization

**Files:**
- Modify: `src/cli/dev_control.zig` (add `background()` + `logTail` helper)
- Modify: `src/cli/dev.zig` (dispatch to it after parse)
- Test: `test "dev control: background argv filter drops the mode flags"` unit test; lifecycle e2e in Task 10

**Interfaces:**
- Consumes: Tasks 1, 2, 4, 5, 7 (`log_name`).
- Produces:
  - `pub fn background(io: Io, gpa: Allocator, cmd: anytype, raw_args: []const []const u8, environ_map: *std.process.Environ.Map) error{OutOfMemory}!noreturn` — `cmd` is `dev.Command` (passed `anytype` to avoid an import cycle dev.zig↔dev_control.zig; it reads only `.data_dir`)
  - `fn filterBackgroundArgs(gpa: Allocator, raw_args: []const []const u8) error{OutOfMemory}![]const []const u8` — drops `--background` and `--force`

- [ ] **Step 1: Write the failing unit test**

```zig
test "dev control: background argv filter drops the mode flags" {
    const gpa = std.testing.allocator;
    const filtered = try filterBackgroundArgs(gpa, &.{
        "--background", "--port=0", "--force", "--no-live-reload",
    });
    defer gpa.free(filtered);
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("--port=0", filtered[0]);
    try std.testing.expectEqualStrings("--no-live-reload", filtered[1]);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-dev`
Expected: FAIL — `filterBackgroundArgs` undeclared.

- [ ] **Step 3: Implement**

```zig
/// Drop the flags that must not recurse into the background child: the child
/// runs the plain foreground path (guarded by background_child_env), and
/// --force was already consumed by the parent. Contract 1: caller frees the
/// slice (the strings are borrowed from raw_args).
fn filterBackgroundArgs(gpa: Allocator, raw_args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--background")) continue;
        if (std.mem.eql(u8, arg, "--force")) continue;
        try out.append(gpa, arg);
    }
    return out.toOwnedSlice(gpa);
}

/// Bounded tail of a file, for failure diagnostics. Contract 1.
fn printLogTail(io: Io, gpa: Allocator, log_path: []const u8) void {
    const contents = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch return;
    defer gpa.free(contents);
    const tail = contents[contents.len -| 4096..];
    if (tail.len > 0) std.debug.print("--- last {d} bytes of {s} ---\n{s}\n", .{ tail.len, log_path, tail });
}

/// The --background PARENT: spawn the child detached (own pgid, stdio to the
/// log file), wait for the lockfile to appear with the child's pid (that IS
/// the readiness handshake — dev.json is only written after waitReady), print
/// the summary, exit 0. Never returns. Contract 1.
pub fn background(
    io: Io,
    gpa: Allocator,
    cmd: anytype,
    raw_args: []const []const u8,
    environ_map: *std.process.Environ.Map,
) error{OutOfMemory}!noreturn {
    if (builtin.os.tag == .windows) fatal.msg(
        "error: dev --background is not supported on Windows yet (see docs/ROADMAP.md)\n",
        .{},
    );
    const data_dir_abs = resolveDataDir(io, gpa, cmd.data_dir);
    Io.Dir.cwd().createDirPath(io, data_dir_abs) catch |err| fatal.msg(
        "error: dev: unable to create the data dir '{s}': {s}\n",
        .{ data_dir_abs, @errorName(err) },
    );

    // Fast-feedback idempotency: a live session means "already running", exit
    // 0 with its facts (--force stops it instead). The child re-checks under
    // its own flock, so a race here is caught authoritatively there.
    if (dev_lockfile.isLive(io, gpa, data_dir_abs)) {
        if (cmd.force) {
            _ = stopInstance(io, gpa, data_dir_abs);
        } else {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            if (dev_lockfile.read(arena_state.allocator(), io, data_dir_abs)) |lf| {
                std.debug.print("dev: already running at {s} (pid {d})\n", .{ lf.url, lf.pid });
            } else {
                std.debug.print("dev: already running (lockfile unreadable — try 'zigapagos dev stop')\n", .{});
            }
            std.process.exit(0);
        }
    }

    const log_path = std.fs.path.join(gpa, &.{ data_dir_abs, log_name }) catch fatal.oom();
    const log_file = Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch |err| fatal.msg(
        "error: dev: unable to open the log file '{s}': {s}\n",
        .{ log_path, @errorName(err) },
    );

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    const self_z = std.process.executablePathAlloc(io, gpa) catch |err| fatal.msg(
        "error: dev: this executable's own path is unavailable ({s})\n",
        .{@errorName(err)},
    );
    try argv.append(gpa, self_z);
    try argv.append(gpa, "dev");
    const filtered = try filterBackgroundArgs(gpa, raw_args);
    try argv.appendSlice(gpa, filtered);

    environ_map.put(background_child_env, "1") catch fatal.oom();
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = environ_map,
        .pgid = 0, // own process group: survives our exit and terminal SIGHUP
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch |err| fatal.msg(
        "error: dev: failed to spawn the background dev process: {s}\n",
        .{@errorName(err)},
    );
    const child_pid: std.posix.pid_t = child.id orelse fatal.msg(
        "error: dev: spawned child has no pid\n",
        .{},
    );

    // Readiness = dev.json appears bearing the child's pid. 30s deadline,
    // 200ms poll — matching Astro's envelope, which proved comfortable.
    var waited_ms: u64 = 0;
    while (waited_ms < 30_000) : (waited_ms += 200) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        if (dev_lockfile.read(arena_state.allocator(), io, data_dir_abs)) |lf| {
            if (lf.pid == child_pid) {
                std.debug.print(
                    "dev: running in the background at {s} (pid {d})\n" ++
                        "dev: control:  http://127.0.0.1:{d}/_zigapagos/status\n" ++
                        "dev: log file: {s}\n" ++
                        "dev: manage:   zigapagos dev stop | status | logs [--follow]\n",
                    .{ lf.url, lf.pid, lf.control_port, log_path },
                );
                std.process.exit(0);
            }
        }

        // Child death check: waitpid(WNOHANG) — kill(pid,0) is not enough,
        // a zombie still "exists" to it.
        const res = std.posix.waitpid(child_pid, std.posix.W.NOHANG);
        if (res.pid == child_pid) {
            std.debug.print("error: dev: the background dev process exited before becoming ready\n", .{});
            printLogTail(io, gpa, log_path);
            std.process.exit(1);
        }
    }

    // Timeout: kill the child's whole group (it leads its own), clean up.
    std.debug.print("error: dev: the background dev process did not become ready within 30s\n", .{});
    std.posix.kill(-child_pid, .TERM) catch {};
    dev_lockfile.remove(io, gpa, data_dir_abs);
    printLogTail(io, gpa, log_path);
    std.process.exit(1);
}
```

**Dispatch in `dev()`** — after `Command.parse` and the `dev: starting` print is NOT yet reached; insert immediately after `const cmd: Command = try .parse(gpa, args);` (`dev.zig:293`):

```zig
    const is_bg_child = environ_map.get(dev_control.background_child_env) != null;
    if (cmd.background and !is_bg_child)
        return dev_control.background(io, gpa, cmd, args, environ_map);
```

(The single-threaded gate stays where it is — ABOVE parse it would block `--help`-style paths; the background parent itself is thread-free, but it re-execs a child that will hit the gate and die fast with a clear log, which the parent then reports. Simpler: also duplicate the gate check before `background()` dispatch — add `if (builtin.single_threaded)` fatal above the dispatch so the parent refuses immediately rather than via a dead child. Implement it that way: the parse-then-gate order in current code already prints usage errors before the gate anyway.)

Engineer notes:
- `std.posix.waitpid` return shape: check the 0.16 signature (`grep -n 'pub fn waitpid' <std>/posix.zig`); adjust the `res.pid` check accordingly.
- `child.id` is optional (`?pid_t`) per `reaper.track` (`dev.zig:743-745`).
- `kill(-pid, …)`: negative-pid group kill needs `@intCast`; if `std.posix.kill` rejects negatives by type, use `std.c.kill(-child_pid, SIG.TERM)`.

- [ ] **Step 4: Run tests + gates**

Run: `zig build test-dev && zig build check && zig build check -Dsingle-threaded`
Expected: PASS.

- [ ] **Step 5: Manual lifecycle test**

With the stub on PATH in a fixture site: `zigapagos dev --background --port=0` prints the running-at summary and EXITS; `zigapagos dev status` shows it; `curl` the control URL; `zigapagos dev logs` dumps the log; edit a content file, poll status until `generation` bumps; `zigapagos dev stop`; verify port free + lockfiles gone. Then `zigapagos dev --background` twice: the second prints "already running" and exits 0.

- [ ] **Step 6: Commit**

```bash
git add src/cli/dev_control.zig src/cli/dev.zig
git commit -m "Add 'zigapagos dev --background' (#126)

No supervisor: the parent re-execs this binary detached in its own
process group with stdio on .zigbase/dev.log, then treats dev.json's
appearance (written only after waitReady) as the readiness handshake —
lockfile-as-handshake means 'parent exited 0' is 'server answers'.
The recursion guard is a dedicated env var, ZIGAPAGOS_DEV_BACKGROUND_CHILD,
kept separate from the user-facing ZIGAPAGOS_DEV_BACKGROUND opt-out;
Astro overloads one variable for both and its opt-out corrupts the
lockfile's background field. Child death is detected with
waitpid(WNOHANG), not kill(pid,0), which a zombie still satisfies.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev_control.zig src/cli/dev.zig
```

---

### Task 9: Agent auto-detection

**Files:**
- Modify: `src/cli/dev_control.zig` (add `detectAgent`)
- Modify: `src/cli/dev.zig` (auto-background decision)
- Test: `test "dev control: agent detection …"` blocks

**Interfaces:**
- Consumes: Task 8's dispatch point.
- Produces: `pub fn detectAgent(environ_map: *const std.process.Environ.Map) ?[]const u8` — returns the provider name, or null.

- [ ] **Step 1: Write the failing tests**

```zig
test "dev control: agent detection recognizes agent env vars, not hybrids" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    // Clean environment: no agent.
    try std.testing.expect(detectAgent(&env) == null);

    // Claude Code.
    try env.put("CLAUDECODE", "1");
    try std.testing.expectEqualStrings("Claude Code", detectAgent(&env).?);
    _ = env.swapRemove("CLAUDECODE");

    // An EMPTY value does not count (unset-but-exported shells).
    try env.put("GEMINI_CLI", "");
    try std.testing.expect(detectAgent(&env) == null);
    try env.put("GEMINI_CLI", "1");
    try std.testing.expectEqualStrings("Gemini CLI", detectAgent(&env).?);
    _ = env.swapRemove("GEMINI_CLI");

    // Cursor: TRACE_ID alone is the interactive terminal — NOT an agent
    // (Astro's Warp false-positive lesson, applied). With the agent's PAGER
    // rewrite it is.
    try env.put("CURSOR_TRACE_ID", "abc");
    try std.testing.expect(detectAgent(&env) == null);
    try env.put("PAGER", "head -n 10000 | cat");
    try std.testing.expectEqualStrings("Cursor agent", detectAgent(&env).?);
    _ = env.swapRemove("CURSOR_TRACE_ID");
    _ = env.swapRemove("PAGER");

    // The emerging generic convention.
    try env.put("AI_AGENT", "crush");
    try std.testing.expect(detectAgent(&env) != null);
}
```

(If `Environ.Map` has no `swapRemove`, check `dev.zig:654` — it uses `environ_map.swapRemove`; the API exists.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-dev`
Expected: FAIL — `detectAgent` undeclared.

- [ ] **Step 3: Implement**

```zig
/// Agent-environment sniff, ported from am-i-vibing's AGENT-type table (the
/// package Astro's own detection delegates to) — env-var checks only, no
/// process-ancestry, and NO hybrid/interactive entries: Warp-the-terminal
/// detecting as an agent produced Astro's first post-release fix (#17151),
/// and a human in a Cursor terminal must never get a surprise background
/// server. Deliberately conservative: heuristic entries that key on PAGER
/// rewrites alone (Zed, VS Code Copilot) and ambient platform vars that are
/// set for HUMAN users too (Replit's REPL_ID) are excluded. Contract 3
/// (caller-buffer): allocates nothing.
pub fn detectAgent(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    const simple = [_]struct { env: []const u8, provider: []const u8 }{
        .{ .env = "CLAUDECODE", .provider = "Claude Code" },
        .{ .env = "CODEX_THREAD_ID", .provider = "OpenAI Codex" },
        .{ .env = "GEMINI_CLI", .provider = "Gemini CLI" },
        .{ .env = "CODEIUM_EDITOR_APP_ROOT", .provider = "Windsurf" },
        .{ .env = "AIDER_API_KEY", .provider = "Aider" },
        .{ .env = "OZ_RUN_ID", .provider = "Warp agent" },
        .{ .env = "AMP_CURRENT_THREAD_ID", .provider = "Amp" },
        .{ .env = "AUGMENT_AGENT", .provider = "Auggie" },
        .{ .env = "QWEN_CODE", .provider = "Qwen Code" },
        .{ .env = "ANTIGRAVITY_AGENT", .provider = "Antigravity" },
        .{ .env = "PI_CODING_AGENT", .provider = "Pi" },
        .{ .env = "OPENCODE", .provider = "OpenCode" },
        .{ .env = "CRUSH", .provider = "Crush" },
    };
    for (simple) |s| {
        if (environ_map.get(s.env)) |v| if (v.len != 0) return s.provider;
    }
    // Cursor agent = trace id AND the agent-mode PAGER rewrite; the trace id
    // alone is the interactive terminal.
    if (environ_map.get("CURSOR_TRACE_ID") != null) {
        if (environ_map.get("PAGER")) |p|
            if (std.mem.eql(u8, p, "head -n 10000 | cat")) return "Cursor agent";
    }
    // Generic convention (Crush and Amp set these alongside their own vars).
    if (environ_map.get("AGENT")) |v| if (v.len != 0) return "agent (AGENT env)";
    if (environ_map.get("AI_AGENT")) |v| if (v.len != 0) return "agent (AI_AGENT env)";
    return null;
}
```

Wire the decision into `dev()` — extend the Task-8 dispatch block:

```zig
    const is_bg_child = environ_map.get(dev_control.background_child_env) != null;
    var want_background = cmd.background;
    if (!want_background and !is_bg_child and !cmd.ignore_lock) {
        if (environ_map.get(dev_control.background_optout_env)) |v| {
            // "1" forces background; anything else disables auto-detection.
            if (std.mem.eql(u8, v, "1")) want_background = true;
        } else if (dev_control.detectAgent(environ_map)) |provider| {
            want_background = true;
            std.debug.print(
                "dev: agent environment detected ({s}) — starting in the background " ++
                    "(set {s}=0 to disable)\n",
                .{ provider, dev_control.background_optout_env },
            );
        }
    }
    if (want_background and !is_bg_child)
        return dev_control.background(io, gpa, cmd, args, environ_map);
```

**Important:** the e2e harness itself runs under CI/agents — `tests/dev/dev.sh` and friends must keep launching FOREGROUND dev sessions. Task 10's script exports `ZIGAPAGOS_DEV_BACKGROUND=0` at the top, and this task must add the same export to the three existing scripts (`tests/dev/dev.sh`, `tests/dev/dev-incremental.sh`, `tests/dev/dev-island-incremental.sh`) right after their `set -euo pipefail` line, with a one-line comment: `# keep dev foreground: this harness manages the process itself` — otherwise a maintainer running the suite from Claude Code would trip auto-backgrounding and every launch/teardown assert breaks.

- [ ] **Step 4: Run tests + regression check**

Run: `zig build test-dev && bash tests/dev/dev.sh`
Expected: unit tests PASS; the e2e script still passes with the opt-out export in place. (Run `bash tests/dev/dev.sh` once WITHOUT the export while `CLAUDECODE` is set to see it fail — that verifies the export is load-bearing, i.e. the regression test fails without the fix.)

- [ ] **Step 5: Commit**

```bash
git add src/cli/dev_control.zig src/cli/dev.zig tests/dev/dev.sh tests/dev/dev-incremental.sh tests/dev/dev-island-incremental.sh
git commit -m "Auto-background zigapagos dev in agent environments (#126)

Ported from am-i-vibing's agent-type table (what Astro's detection
delegates to), env sniff only, agent-type entries only: hybrid and
interactive signals are excluded because a human in an AI-flavored
terminal must never get a surprise background server (Astro's Warp
incident, withastro/astro#17151). ZIGAPAGOS_DEV_BACKGROUND=0 opts out;
=1 forces. The dev e2e harness scripts export the opt-out because they
manage the dev process themselves — and they run under CI and agents.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- src/cli/dev_control.zig src/cli/dev.zig tests/dev/dev.sh tests/dev/dev-incremental.sh tests/dev/dev-island-incremental.sh
```

---

### Task 10: End-to-end test — `tests/dev/background.sh`

**Files:**
- Create: `tests/dev/background.sh` (picked up by CI's `tests/*/*.sh` glob automatically)
- Modify: `tests/dev/stub-zigbase.ts` — IF it lacks an `/api/health` route, add one returning `200 {"status":"ok","backend":"stub","versions":{}}` (the real binary serves this shape; check with `grep -n 'api/health' tests/dev/stub-zigbase.ts` first)

**Interfaces:**
- Consumes: every prior task. Model the harness scaffolding (stub-on-PATH, `mktemp` workdir, `cleanup` trap, fixture site) directly on `tests/dev/dev.sh:33-126` — copy its `launch_group`/`stop_dev`/poll helpers where useful.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# e2e for `zigapagos dev --background` + `dev stop|status|logs` + the
# build-aware status endpoint (#126). Hermetic via tests/dev/stub-zigbase.ts.
#
# Asserts:
#   (a) --background: parent exits 0 printing url+pid; server answers; dev.json
#       + dev.lock exist; dev.log captures the session output
#   (b) status: exit 0 + url/pid/build info while running; --json is parseable
#       and carries "running":true and a numeric build generation
#   (c) build-aware loop: a content edit bumps build.generation on the status
#       endpoint; a BROKEN edit flips status to "failed" with an error tail,
#       and fixing it flips back to "ok" (this is the agent workflow)
#   (d) duplicate start: second --background exits 0 with "already running";
#       plain foreground dev REFUSES (exit != 0) on the same project;
#       --ignore-lock runs untracked; --ignore-lock --background errors
#   (e) logs: dumps the log; logs --follow sees a new rebuild line arrive
#   (f) stop: exit 0, port freed, lockfiles gone; second stop exits 0 with
#       "No dev server is running."
#   (g) orphan sweep: kill -9 the dev pid, stub keeps serving, dev stop reaps
#       it via /api/health verification, port freed
#   (h) status endpoint exists under --no-live-reload
#   (i) auto-background: CLAUDECODE=1 backgrounds without --background;
#       ZIGAPAGOS_DEV_BACKGROUND=0 keeps it foreground
set -euo pipefail
cd "$(dirname "$0")"
# keep dev foreground unless a scenario opts in: this harness manages the
# process itself
export ZIGAPAGOS_DEV_BACKGROUND=0
```

Continue the script following `tests/dev/dev.sh`'s established patterns; the load-bearing scenario bodies:

```bash
# --- helpers (copy launch/port/poll conventions from dev.sh) -----------------
status_json() { curl -sf "http://127.0.0.1:$CONTROL_PORT/_zigapagos/status"; }
generation() { status_json | grep -o '"generation":[0-9]*' | cut -d: -f2; }
build_status() { status_json | grep -o '"status":"[a-z]*"' | head -1 | cut -d'"' -f4; }

wait_for_generation_past() {
  local prev="$1" deadline=$((SECONDS + 30))
  while [ "$(generation)" -le "$prev" ]; do
    [ $SECONDS -lt $deadline ] || { echo "FAIL: generation never passed $prev"; exit 1; }
    sleep 0.2
  done
}

# (a) background lifecycle
ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 >| "$WORK/bg-out.txt" 2>&1
grep -q 'dev: running in the background at http://' "$WORK/bg-out.txt"
test -f "$SITE_DIR/.zigbase/dev.json"
test -f "$SITE_DIR/.zigbase/dev.lock"
test -f "$SITE_DIR/.zigbase/dev.log"
SERVE_PORT="$(grep -o '"port": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | head -1 | grep -o '[0-9]*')"
CONTROL_PORT="$(grep -o '"control_port": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | grep -o '[0-9]*')"
DEV_PID="$(grep -o '"pid": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | head -1 | grep -o '[0-9]*')"
curl -sf "http://127.0.0.1:$SERVE_PORT/" > /dev/null

# (b) status
"$ZIGAPAGOS" dev status > "$WORK/status.txt" 2>&1
grep -q "pid $DEV_PID" "$WORK/status.txt"
"$ZIGAPAGOS" dev status --json > "$WORK/status.json" 2>&1
grep -q '"running":true' "$WORK/status.json"
grep -q '"generation":' "$WORK/status.json"

# (c) build-aware loop — the agent workflow
GEN="$(generation)"
echo "edited" >> "$SITE_DIR/content/index.smd"
wait_for_generation_past "$GEN"
[ "$(build_status)" = "ok" ]
GEN="$(generation)"
printf '%s\n' '---broken frontmatter' >> "$SITE_DIR/content/index.smd"
wait_for_generation_past "$GEN"
[ "$(build_status)" = "failed" ]
status_json | grep -q '"error":"'
git -C "$REPO" checkout -- "$SITE_DIR/content/index.smd" 2>/dev/null || \
  restore_fixture_index   # restore however the fixture was created
GEN="$(generation)"
wait_for_generation_past "$GEN" || true  # the restore itself is an edit
[ "$(build_status)" = "ok" ]

# (d) duplicates
ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background >| "$WORK/dup.txt" 2>&1
grep -q 'already running' "$WORK/dup.txt"
if "$ZIGAPAGOS" dev --port=0 >| "$WORK/fg-dup.txt" 2>&1; then
  echo "FAIL: foreground dev started over a live session"; exit 1
fi
grep -q 'already running' "$WORK/fg-dup.txt"
if "$ZIGAPAGOS" dev --ignore-lock --background >| "$WORK/conflict.txt" 2>&1; then
  echo "FAIL: --ignore-lock --background did not conflict"; exit 1
fi

# (e) logs
"$ZIGAPAGOS" dev logs > "$WORK/logs.txt" 2>&1
grep -q 'dev: ready — serving at http://' "$WORK/logs.txt"

# (f) stop
"$ZIGAPAGOS" dev stop
! test -f "$SITE_DIR/.zigbase/dev.json"
if curl -sf --max-time 2 "http://127.0.0.1:$SERVE_PORT/" > /dev/null 2>&1; then
  echo "FAIL: port still serving after stop"; exit 1
fi
"$ZIGAPAGOS" dev stop > "$WORK/stop2.txt" 2>&1
grep -q 'No dev server is running' "$WORK/stop2.txt"

# (g) orphan sweep: background again, kill -9 dev, stub survives, stop reaps
ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --port=0 >| "$WORK/bg2.txt" 2>&1
DEV_PID="$(grep -o '"pid": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | head -1 | grep -o '[0-9]*')"
ZB_PID="$(grep -o '"zigbase_pid": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | grep -o '[0-9]*$')"
SERVE_PORT="$(grep -o '"port": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | head -1 | grep -o '[0-9]*')"
kill -9 "$DEV_PID"
sleep 0.5
kill -0 "$ZB_PID"   # the orphan is alive — this is the documented reaper gap
"$ZIGAPAGOS" dev stop > "$WORK/sweep.txt" 2>&1
grep -q 'reaping orphaned zigbase' "$WORK/sweep.txt"
if kill -0 "$ZB_PID" 2>/dev/null; then echo "FAIL: orphan survived stop"; exit 1; fi

# (h) status endpoint under --no-live-reload
ZIGAPAGOS_DEV_BACKGROUND= "$ZIGAPAGOS" dev --background --no-live-reload --port=0 >| "$WORK/bg3.txt" 2>&1
CONTROL_PORT="$(grep -o '"control_port": *[0-9]*' "$SITE_DIR/.zigbase/dev.json" | grep -o '[0-9]*')"
status_json | grep -q '"ok":true'
"$ZIGAPAGOS" dev stop

# (i) agent auto-detection
env -u ZIGAPAGOS_DEV_BACKGROUND CLAUDECODE=1 "$ZIGAPAGOS" dev --port=0 >| "$WORK/agent.txt" 2>&1
grep -q 'agent environment detected (Claude Code)' "$WORK/agent.txt"
grep -q 'dev: running in the background' "$WORK/agent.txt"
"$ZIGAPAGOS" dev stop
# opt-out: with the var set to 0 it must stay foreground → launch_group +
# assert the READY banner appears in ITS OWN output, then tear down via the
# group-kill helper (copy from dev.sh's launch_group/stop_dev).

echo "PASS tests/dev/background.sh"
```

Adapt paths/helpers to the fixture arrangement `dev.sh` actually uses (`$ZIGAPAGOS` binary location, fixture site creation, stub-on-PATH shim) — copy, don't reinvent. Every `grep` against `dev.json` must tolerate the `indent_2` pretty-printing (the `": *"` patterns above do).

- [ ] **Step 2: Verify the script fails before the feature ... and passes after**

The feature is already implemented by Tasks 1-9, so instead verify the script's own teeth: temporarily stub one assert (e.g. point `status_json` at the wrong port) and confirm the script FAILS loudly, then restore. Then:

Run: `bash tests/dev/background.sh`
Expected: `PASS tests/dev/background.sh`, no stray processes after (`pgrep -f stub-zigbase` empty).

- [ ] **Step 3: Run the whole dev e2e family**

Run: `bash tests/dev/dev.sh && bash tests/dev/dev-incremental.sh && bash tests/dev/dev-island-incremental.sh && bash tests/dev/background.sh`
Expected: all PASS (regression: the Task 4-9 changes didn't disturb the existing scripts).

- [ ] **Step 4: Commit**

```bash
git add tests/dev/background.sh tests/dev/stub-zigbase.ts
git commit -m "e2e: background dev lifecycle, orphan sweep, agent detection (#126)

Covers the full agent workflow the feature exists for (edit → poll
generation → branch on status → read error), plus the failure paths
that made comparable tools grow escape hatches after release: duplicate
starts, kill -9 orphans (asserts the orphan IS alive first, so the
sweep is proven to do something), --ignore-lock conflicts, and the
--no-live-reload mode that must keep its status endpoint. The stub
gains /api/health because the sweep refuses to kill anything that
doesn't answer it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- tests/dev/background.sh tests/dev/stub-zigbase.ts
```

---

### Task 11: Docs, changelog fragment, roadmap, final gates

**Files:**
- Create: `docs/dev-server.md`
- Create: `changelog.d/background-dev.md`
- Modify: `docs/ROADMAP.md` (the "Router and DX paper cuts" planned-work area)
- Modify: `README.md` only if it documents dev flags inline (check first: `grep -n 'zigapagos dev' README.md`)

**Interfaces:** consumes everything; produces the documented contracts (status JSON shape, lockfile fields, env vars).

- [ ] **Step 1: Write `docs/dev-server.md`**

Sections (concise, in the repo's documentation voice):
1. **Foreground vs background** — `zigapagos dev` vs `dev --background`; parent prints URL/PID/log/manage lines and exits 0 only when the server answers.
2. **Control verbs** — `stop` (idempotent, orphan-sweeping), `status [--json]` (exit 1 when not running; the full `--json` shape with every field listed), `logs [--follow]`.
3. **The status endpoint** — URL shape, the exact JSON contract (copy from Task 3), and **the agent workflow**: edit → poll `/_zigapagos/status` until `build.generation` bumps → branch on `build.status` → read `build.error` or fetch the page. Include a curl example.
4. **The lockfile** — `.zigbase/dev.json` fields (document as a read-only contract for tooling), `dev.lock` flock liveness, `dev.log`.
5. **Agent auto-detection** — the provider table, `ZIGAPAGOS_DEV_BACKGROUND=0|1`, and that `ZIGAPAGOS_DEV_BACKGROUND_CHILD` is internal.
6. **Conventions for ZigBase** — copy the "Conventions for zigbase (portability, not v1 work)" section from the spec verbatim.
7. **Out of scope / v1.1** — `dev wait`, NDJSON logs (pointer to the spec).

- [ ] **Step 2: Write `changelog.d/background-dev.md`**

Follow `changelog.d/README.md`'s format (check an existing fragment for the exact header shape). Content: `zigapagos dev --background` + `dev stop|status|logs [--follow]` + `/_zigapagos/status` (build generation/status/error) + agent auto-detection with `ZIGAPAGOS_DEV_BACKGROUND=0` opt-out + `--force`/`--ignore-lock`; `dev stop` also reaps zigbase orphans from `kill -9`'d sessions (retires the `pkill zigbase` recovery).

- [ ] **Step 3: Update `docs/ROADMAP.md`**

Add one line under the DX area noting background dev-server management shipped (#126), and move/annotate per the file's existing conventions (read the surrounding entries first and match them).

- [ ] **Step 4: Run the full gate suite**

```bash
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
zig build check
zig build check -Dsingle-threaded
zig build test
zig build test-islands test-props test-migrate test-sidecar test-init \
  test-release test-debug test-spa test-assets test-e2e test-dev \
  test-doctor test-slugs test-validate test-explain test-diag test-summary
bash tests/branding.sh
bash tests/dev/dev.sh
bash tests/dev/background.sh
```
Expected: every command exits 0 — check `$?` per command, unpiped (zsh: no `${PIPESTATUS}`). The branding gate matters: the new docs mention Astro/upstream names — use them factually; if the gate flags one, add an inline `<!-- branding-ok: competitive comparison -->` with the reason rather than rewording into vagueness.

- [ ] **Step 5: Commit**

```bash
git add docs/dev-server.md changelog.d/background-dev.md docs/ROADMAP.md
git commit -m "Document background dev server management (#126)

docs/dev-server.md is the contract doc: the status JSON shape and
dev.json fields are read-only interfaces for agents and tooling, and
the ZigBase portability conventions are recorded so a future
'zigbase serve --background' adopts this pattern instead of inventing
a second one. Also the seed content for the issue #131 init-generated
AGENTS.md.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- docs/dev-server.md changelog.d/background-dev.md docs/ROADMAP.md
```

---

## Self-Review (performed at plan-writing time)

- **Spec coverage:** CLI surface (T2, T5-8), daemonization + guard var (T8), lockfile + flock + atomic write (T1), write-after-waitReady + foreground duplicate refusal + `--force`/`--ignore-lock` (T4), control server always-on + build-aware status incl. generation semantics (T3, T4), `stop` orphan sweep via `/api/health` (T6), `status` exit codes + `--json` (T5), `logs` foreground error + `--follow` (T7), agent detection + opt-out + never-for-subverbs (T9, dispatch order in T5/T8), error-handling table rows (spread: corrupt→T1, stale→T5/T6, timeout/death→T8, lockfile-write-warns→T4, conflicts→T2), testing incl. fail-first verification (each task + T10), docs/changelog/roadmap + portability conventions (T11). Windows comptime branches: T1, T5, T8. No gaps found.
- **Placeholder scan:** the `VerbArgs` sketch in Task 5 is explicitly marked for removal and `renderStatusText`'s body is specified line-by-line in its engineer note (exact output lines + assertion strings); everything else is concrete code. Steps that depend on version-exact std APIs carry explicit verification instructions rather than guesses.
- **Type consistency:** `RebuildResult` (T4) consumed in T4's loop wiring; `dev_lockfile.LockFile` fields identical across T1/T4/T5/T6/T8; `background_child_env`/`background_optout_env` declared once (T5) and referenced in T4/T8/T9; `log_name` declared in T7, used in T8; `stopInstance`/`sweepOrphan` signatures identical in T4 (placeholder) and T6 (real).
