//! Control-plane verbs for `zigapagos dev` — `stop`, `status`, `logs`, `wait` — plus
//! the `--background` parent and agent-environment detection. Deliberately
//! thread-free: these verbs must work under -Dsingle-threaded, so dev.zig
//! dispatches here BEFORE its single-threaded gate.
//!
//! `stopInstance`/`sweepOrphan` stop a session found via `dev_lockfile.zig`
//! (graceful-then-forceful signal, wait for the flock to clear) and sweep a
//! `dev.json` whose `dev.lock` nobody currently holds — see
//! `dev_lockfile.zig`'s `remove()`, which deletes `dev.json` only and never
//! touches `dev.lock`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const dev_lockfile = @import("dev_lockfile.zig");

test "dev control: status text rendering" {
    const gpa = std.testing.allocator;
    const lf: dev_lockfile.LockFile = .{
        .pid = 4242,
        .zigbase_pid = 4243,
        .host = "127.0.0.1",
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
        .pid = 1,
        .zigbase_pid = 2,
        .host = "127.0.0.1",
        .port = 3,
        .url = "u",
        .control_port = 4,
        .data_dir = "d",
        .background = false,
        .started_at = "s",
    };
    const json = try renderStatusJson(gpa, lf, "{\"ok\":true,\"pid\":1,\"url\":\"u\",\"started_at\":\"s\",\"build\":{\"generation\":2,\"status\":\"failed\",\"duration_ms\":9,\"error\":\"boom\"}}");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"running\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"generation\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"zigbase_pid\":2") != null);
}

test "dev control: renderStatusText degrades (never panics) on a malformed control-endpoint body" {
    // PR #140 round 2, P2d: `std.json.Value` is a tagged union, and indexing
    // the wrong active field (`.integer` on a `.string`, `.object` on an
    // `.array`) is a hard panic, not a catchable error. The control endpoint
    // is OUR OWN server, but "syntactically valid JSON" and "the exact shape
    // this function assumes" are different guarantees -- every case here
    // used to panic `dev status` outright; all must now degrade instead.
    const gpa = std.testing.allocator;
    const lf: dev_lockfile.LockFile = .{
        .pid = 1,
        .zigbase_pid = 2,
        .host = "127.0.0.1",
        .port = 3,
        .url = "u",
        .control_port = 4,
        .data_dir = "d",
        .background = false,
        .started_at = "s",
    };
    const degraded_marker = "build: unknown (control server unreachable)";
    const bodies = [_][]const u8{
        "[1,2,3]", // root is an array, not an object
        "{}", // no "build" key at all
        "{\"build\":5}", // "build" present but not an object
        "{\"build\":{\"generation\":\"seven\",\"status\":\"ok\",\"duration_ms\":1,\"error\":null}}", // generation not an integer
        "{\"build\":{\"generation\":1,\"status\":5,\"duration_ms\":1,\"error\":null}}", // status not a string
    };
    for (bodies) |body| {
        const text = try renderStatusText(gpa, lf, body);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, degraded_marker) != null);
    }
}

test "dev control: renderStatusJson degrades (never panics) when the root isn't an object" {
    // The one `.object` access left in renderStatusJson after the P2d fix is
    // on the ROOT value; a body like "[1,2,3]" pre-fix panicked reading
    // `parsed.object` while `.array` was the active tag.
    const gpa = std.testing.allocator;
    const lf: dev_lockfile.LockFile = .{
        .pid = 1,
        .zigbase_pid = 2,
        .host = "127.0.0.1",
        .port = 3,
        .url = "u",
        .control_port = 4,
        .data_dir = "d",
        .background = false,
        .started_at = "s",
    };
    for ([_][]const u8{ "[1,2,3]", "{}", "{\"build\":5}" }) |body| {
        const json = try renderStatusJson(gpa, lf, body);
        defer gpa.free(json);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"running\":true") != null);
    }
}

test "dev control: classifySession covers all 4 live/has-facts combinations" {
    // (false, false): no lock, no facts -- nothing running.
    try std.testing.expectEqual(.none, classifySession(false, false));
    // (false, true): a lockfile survived a dead session (kill -9) -- still
    // "nothing running" to the caller, but statusVerb sweeps the stale file
    // in this branch (see the `.none` case in statusVerb).
    try std.testing.expectEqual(.none, classifySession(false, true));
    // (true, false): THE regression this pins -- the flock is live but
    // dev.json hasn't been published yet (the window between
    // dev_lockfile.acquire and a session's own waitReady). Pre-fix,
    // statusVerb folded this into the same branch as (false, false)/(false,
    // true) and reported "No dev server is running." — flatly wrong, since
    // a session genuinely holds the lock. stopInstance already treats this
    // exact combination as `.starting` (see its own poll loop); status must
    // agree instead of contradicting it.
    try std.testing.expectEqual(.starting, classifySession(true, false));
    // (true, true): the normal case -- a live lock and readable dev.json.
    try std.testing.expectEqual(.running, classifySession(true, true));
}

test "dev control: stopInstance on a live flock with no dev.json yet does not panic (returns .starting)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);

    // Simulates the window between `dev_lockfile.acquire` and a session's own
    // `waitReady`: the flock is held, but dev.json has not been written yet.
    // `stopInstance` used to force-unwrap the (null) lockfile read here and
    // panic (Debug/ReleaseSafe) on exactly this race — this pins the fix: it
    // must poll instead of assuming, and report `.starting` rather than
    // crash.
    var lock = (try dev_lockfile.acquire(io, dir_abs, gpa)) orelse return error.TestUnexpectedResult;
    defer lock.release(io);

    try std.testing.expectEqual(.starting, stopInstance(io, gpa, dir_abs));
}

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

test "dev control: decideBackground applies the explicit > opt-out > detection precedence, gated by is_bg_child/ignore_lock" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    // Clean environment, nothing set: no explicit flag, no opt-out, no agent -> foreground.
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }

    try env.put("CLAUDECODE", "1");

    // Explicit --background wins outright, no provider attribution -- even
    // with an agent env present (detection never runs; this is not a
    // "detected" background).
    {
        const d = decideBackground(true, false, false, &env);
        try std.testing.expect(d.background);
        try std.testing.expect(d.detected_provider == null);
    }

    // is_bg_child suppresses everything -- even explicit --background (the
    // child re-exec strips --background before dev.zig ever calls this
    // function, but the contract here is unconditional) -- and even with
    // CLAUDECODE still set.
    {
        const d = decideBackground(true, true, false, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }

    // ignore_lock suppresses AUTO-detection (CLAUDECODE is set) but NOT
    // explicit --background. PRECONDITION: dev.zig's own Command.parse
    // already fatals `--background` combined with `--ignore-lock` before
    // this function is ever reached, so this exact combination cannot occur
    // in practice; decideBackground still resolves it deterministically
    // (explicit wins, checked before ignore_lock) rather than leaving it to
    // whatever order the branches happened to be written in.
    {
        const d = decideBackground(true, false, true, &env);
        try std.testing.expect(d.background);
        try std.testing.expect(d.detected_provider == null);
    }
    // ignore_lock alone (no explicit flag) suppresses detection outright.
    {
        const d = decideBackground(false, false, true, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }
    _ = env.swapRemove("CLAUDECODE");

    // Opt-out "0" with CLAUDECODE set: the explicit override wins over
    // detection -> foreground, no provider.
    try env.put("CLAUDECODE", "1");
    try env.put(background_optout_env, "0");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }
    _ = env.swapRemove(background_optout_env);
    _ = env.swapRemove("CLAUDECODE");

    // Opt-out "1" with nothing else set -> forced background, no provider
    // (an explicit override is not a "detection").
    try env.put(background_optout_env, "1");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(d.background);
        try std.testing.expect(d.detected_provider == null);
    }
    _ = env.swapRemove(background_optout_env);

    // No opt-out, CLAUDECODE set -> auto-background WITH provider attribution.
    try env.put("CLAUDECODE", "1");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(d.background);
        try std.testing.expectEqualStrings("Claude Code", d.detected_provider.?);
    }
    _ = env.swapRemove("CLAUDECODE");

    // An EMPTY CLAUDECODE value does not count as detection (detectAgent's
    // own empty-value exclusion) -> foreground, no provider.
    try env.put("CLAUDECODE", "");
    {
        const d = decideBackground(false, false, false, &env);
        try std.testing.expect(!d.background);
        try std.testing.expect(d.detected_provider == null);
    }
    _ = env.swapRemove("CLAUDECODE");
}

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

test "dev control: probeHost maps unspecified binds to loopback, passes everything else through" {
    // PR #140 round 2, P2c: a session bound to an unspecified address (the
    // default for "listen on every interface") cannot be dialed AT that
    // address -- the loopback the OS also answers on is what every control
    // verb actually needs to connect to.
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("0.0.0.0"));
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("::"));
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("[::]"));
    // Anything else -- the common default, or a LAN IP the developer
    // explicitly bound with --host -- passes through untouched: it IS a
    // connectable address, unlike the unspecified ones above.
    try std.testing.expectEqualStrings("127.0.0.1", probeHost("127.0.0.1"));
    try std.testing.expectEqualStrings("192.168.1.5", probeHost("192.168.1.5"));
}

test "dev control: scanDataDirArg stops at the -- rebuild-command separator" {
    // PR #140 round 2, P2a: a `--data-dir=` AFTER `--` belongs to the user's
    // rebuild command (`dev --background -- tool --data-dir=tmp`), not to
    // `dev` itself -- pre-fix, this scan kept going past `--` and picked up
    // the rebuild command's own flag.
    try std.testing.expectEqualStrings(".zigbase", scanDataDirArg(&.{}));
    try std.testing.expectEqualStrings("custom", scanDataDirArg(&.{"--data-dir=custom"}));
    try std.testing.expectEqualStrings(".zigbase", scanDataDirArg(&.{
        "--background", "--", "tool", "--data-dir=tmp",
    }));
    // One before AND a different one after "--": only the one before `dev`
    // itself ever sees counts.
    try std.testing.expectEqualStrings("real", scanDataDirArg(&.{
        "--data-dir=real", "--", "tool", "--data-dir=tmp",
    }));
}

test "dev control: background argv filter copies everything after the -- rebuild separator verbatim" {
    // PR #140 round 2, P1: `zigapagos dev --background -- zigapagos release
    // --force` must re-exec the child with the rebuild command's own
    // `--force` intact -- pre-fix, filterBackgroundArgs scanned the whole
    // argv unconditionally and silently dropped it (and any `--background`
    // after `--`), corrupting a command the user asked to run verbatim.
    const gpa = std.testing.allocator;
    const filtered = try filterBackgroundArgs(gpa, &.{
        "--background", "--port=0", "--", "tool", "--force", "--background",
    });
    defer gpa.free(filtered);
    try std.testing.expectEqual(@as(usize, 5), filtered.len);
    try std.testing.expectEqualStrings("--port=0", filtered[0]);
    try std.testing.expectEqualStrings("--", filtered[1]);
    try std.testing.expectEqualStrings("tool", filtered[2]);
    try std.testing.expectEqualStrings("--force", filtered[3]);
    try std.testing.expectEqualStrings("--background", filtered[4]);
}

/// Internal recursion guard: set on the background CHILD so it runs the
/// foreground path. A DIFFERENT variable from the user-facing opt-out below —
/// Astro conflated the two and its opt-out corrupts its own lockfile state.
pub const background_child_env = "ZIGAPAGOS_DEV_BACKGROUND_CHILD";
/// User-facing: "0" (or any value other than "1") disables agent
/// auto-backgrounding; "1" forces background mode.
pub const background_optout_env = "ZIGAPAGOS_DEV_BACKGROUND";

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

/// Result of `decideBackground`: whether to run backgrounded, and — only when
/// that answer came from `detectAgent` rather than an explicit flag/env —
/// which provider was detected, so `dev()` can print attribution. Whenever
/// `detected_provider != null`, `background` is always `true`; the reverse
/// is not true (explicit `--background` and the "1" opt-out both background
/// with no provider, since neither is a "detection").
pub const BackgroundDecision = struct { background: bool, detected_provider: ?[]const u8 };

/// Pure background-mode decision, pinned by the precedence test below —
/// `dev()` calls this once and only acts on (prints/backgrounds from) the
/// result; no I/O happens in here. Contract 3 (caller-buffer): allocates
/// nothing.
///
/// Precedence: `is_bg_child` forces foreground unconditionally — it IS the
/// recursion guard, so it is checked before anything else, including an
/// explicit `explicit_background` (moot in practice: the child re-exec's
/// `filterBackgroundArgs` strips `--background` before dev.zig ever gets
/// this far, so a true child never carries one, but this function's own
/// contract does not lean on that fact to be correct). Short of that,
/// `explicit_background` (`--background`) wins outright, with no provider
/// attribution — nothing was "detected". PRECONDITION: dev.zig's own
/// `Command.parse` already fatals `--background` combined with
/// `--ignore-lock` before this function is ever reached, so that exact
/// combination cannot occur in practice; `explicit_background` is still
/// checked (and wins) before `ignore_lock` below, so the combination
/// resolves deterministically rather than by branch-order accident, should
/// that precondition ever lapse. Short of an explicit flag, `ignore_lock`
/// suppresses AUTO-detection (both the opt-out env and the agent sniff): an
/// untracked instance has no lockfile for `background()`'s readiness
/// handshake to poll, so silently backgrounding it would hang forever
/// waiting for a `dev.json` that is never written. Absent all of the above,
/// `background_optout_env` is an explicit user override ("1" forces
/// background, any other value — including empty, so an exported-but-unset
/// shell var doesn't silently enable this — forces foreground), again with
/// no provider attribution. Only when none of those apply does `detectAgent`
/// get to decide, and only then is a provider ever attributed.
pub fn decideBackground(
    explicit_background: bool,
    is_bg_child: bool,
    ignore_lock: bool,
    environ_map: *const std.process.Environ.Map,
) BackgroundDecision {
    if (is_bg_child) return .{ .background = false, .detected_provider = null };
    if (explicit_background) return .{ .background = true, .detected_provider = null };
    if (ignore_lock) return .{ .background = false, .detected_provider = null };
    if (environ_map.get(background_optout_env)) |v| {
        return .{ .background = std.mem.eql(u8, v, "1"), .detected_provider = null };
    }
    if (detectAgent(environ_map)) |provider|
        return .{ .background = true, .detected_provider = provider };
    return .{ .background = false, .detected_provider = null };
}

pub const log_name = "dev.log";

/// Write `bytes` to stdout and flush before returning. This is the ONE
/// stream-selection choice this file makes: `status`/`logs` route their
/// primary payload (the human answer / the JSON body / the log content)
/// through here so `zigapagos dev status --json | jq .` and `zigapagos dev
/// logs | grep` have something to read — every other message in this file
/// (progress, warnings, the "Stopped."/"No dev server is running." replies
/// from `stop`) is a diagnostic and stays on `std.debug.print` (stderr), by
/// design, unchanged.
///
/// Streaming, not positional (`Io.File.writer`'s default): on `cmd >f 2>&1`,
/// both fds share one open file description, and a positional flush from
/// offset zero would stomp whatever stderr already committed there —
/// exactly the corruption issue #78 fixed for doctor.zig/explain.zig/
/// validate.zig's stdout reports; this file's stdout writes need the same
/// fix. Contract 1 (self-freeing): allocates nothing, `bytes` is
/// caller-owned.
fn writeStdout(io: Io, bytes: []const u8) void {
    var out_buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &out_buf);
    fw.interface.writeAll(bytes) catch |err| fatal.msg("error writing to stdout: {t}\n", .{err});
    fw.interface.flush() catch |err| fatal.msg("error writing to stdout: {t}\n", .{err});
}

pub const Verb = enum { stop, status, logs, wait };

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
        .wait => try waitVerb(io, gpa, args),
    }
}

/// The three states `status` can report, decided from the same two facts
/// `stopInstance` already resolves (`dev_lockfile.isLive` + whether
/// `dev_lockfile.read` found a parseable `dev.json`). Split out as a pure,
/// directly-testable function so the live/has-facts truth table has one
/// place to get right, rather than being re-derived inline at every call
/// site of a snapshot verb that must never poll.
///
/// `.starting` is the race window `stopInstance` already knows about: the
/// flock is acquired BEFORE a session writes `dev.json` (it appears only
/// after that session's own `waitReady`), so a live flock with no readable
/// facts is a session mid-boot, not "nothing running". Reporting it as "No
/// dev server is running." (the pre-fix behavior) was factually wrong and
/// disagreed with `stopInstance`, which already resolves this exact
/// combination as `.starting` rather than `.none`.
pub fn classifySession(live: bool, has_facts: bool) enum { none, starting, running } {
    if (!live) return .none;
    return if (has_facts) .running else .starting;
}

/// Null means a build is pending or the endpoint is not a v1.1 status.
/// Contract 1: parse scratch is released before returning.
fn settledBuild(gpa: Allocator, body: []const u8) !?bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const build = parsed.value.object.get("build") orelse return null;
    if (build != .object) return null;
    const pending = build.object.get("pending") orelse return null;
    if (pending != .bool or pending.bool) return null;
    const status = build.object.get("status") orelse return null;
    if (status != .string) return null;
    if (std.mem.eql(u8, status.string, "ok")) return true;
    if (std.mem.eql(u8, status.string, "failed")) return false;
    return null;
}

fn waitVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    var timeout_ms: u32 = 30000;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) continue;
        if (std.mem.startsWith(u8, arg, "--timeout-ms=")) {
            timeout_ms = std.fmt.parseInt(u32, arg["--timeout-ms=".len..], 10) catch
                fatal.usageError("error: invalid wait timeout\n", .{});
        } else fatal.usageError("usage: zigapagos dev wait [--timeout-ms=N] [--data-dir=DIR]\n", .{});
    }
    const data_dir = resolveDataDir(io, gpa, args);
    defer gpa.free(data_dir);
    const start = Io.Clock.awake.now(io).toMilliseconds();
    while (Io.Clock.awake.now(io).toMilliseconds() - start < timeout_ms) {
        if (!dev_lockfile.isLive(io, gpa, data_dir)) fatal.msg("error: no dev server is running\n", .{});
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (dev_lockfile.read(arena.allocator(), io, data_dir)) |lf| {
            const addr = Io.net.IpAddress.parse(probeHost(lf.host), lf.control_port) catch
                fatal.msg("error: invalid dev control address\n", .{});
            const remaining = timeout_ms - (Io.Clock.awake.now(io).toMilliseconds() - start);
            if (remaining <= 0) break;
            if (fetchBodyTimed(io, gpa, addr, @intCast(@min(remaining, 1000)))) |body| {
                defer gpa.free(body);
                if (try settledBuild(gpa, body)) |ok| {
                    writeStdout(io, body);
                    writeStdout(io, "\n");
                    std.process.exit(if (ok) 0 else 1);
                }
            } else |_| {} // Session may still be starting; bounded by timeout.
        }
        // Match logs --follow: avoid a fresh TCP connection every 50 ms.
        io.sleep(.fromMilliseconds(200), .awake) catch fatal.msg("error: dev wait interrupted\n", .{});
    }
    fatal.msg("error: timed out waiting for dev to settle\n", .{});
}

/// Contract 1. Bounds response reads, including in single-threaded builds.
fn fetchBodyTimed(io: Io, gpa: Allocator, address: Io.net.IpAddress, timeout_ms: u32) ![]u8 {
    return fetchBodyWithTimeout(io, gpa, address, "/_zigapagos/status", timeout_ms);
}

test "dev wait: never accepts pending or unknown status as settled" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?bool, true), try settledBuild(gpa, "{\"build\":{\"pending\":false,\"status\":\"ok\"}}"));
    try std.testing.expectEqual(@as(?bool, false), try settledBuild(gpa, "{\"build\":{\"pending\":false,\"status\":\"failed\"}}"));
    for ([_][]const u8{
        "{\"build\":{\"pending\":true,\"status\":\"ok\"}}",
        "{\"build\":{\"status\":\"ok\"}}",
        "{\"build\":{\"pending\":false,\"status\":\"building\"}}",
        "[]",
        "invalid",
    }) |body| try std.testing.expectEqual(@as(?bool, null), try settledBuild(gpa, body));
}

test "dev wait: a silent control peer times out without a worker thread" {
    const io = std.testing.io;
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    try std.testing.expectError(error.Timeout, fetchBodyTimed(io, std.testing.allocator, listener.socket.address, 25));
}

fn statusVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    var json = false;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            // Consumed by resolveDataDir below; validated here only.
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else fatal.usageError(
            "error: unexpected 'zigapagos dev status' argument '{s}'\n" ++
                "usage: zigapagos dev status [--json] [--data-dir=DIR]\n",
            .{arg},
        );
    }
    const data_dir_abs = resolveDataDir(io, gpa, args);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ONE snapshot read each — `status` never polls/blocks, unlike
    // `stopInstance`'s up-to-5s wait for the same race: a snapshot verb
    // reports what it sees right now, even if that's mid-startup.
    const live = dev_lockfile.isLive(io, gpa, data_dir_abs);
    const lf = dev_lockfile.read(arena, io, data_dir_abs);
    switch (classifySession(live, lf != null)) {
        .none => {
            // `classifySession` only reaches `.none` when `!live`, so a
            // non-null `lf` here is a lockfile a dead session left behind
            // (a kill -9), not the live-but-unpublished race — safe to
            // sweep.
            if (lf != null) dev_lockfile.remove(io, gpa, data_dir_abs); // stale
            // The human ANSWER to "is a session running?" — an agent's `dev
            // status --json | jq .` needs this on stdout even for the negative
            // case (F1: it used to go to stderr, so a caller piping stdout read
            // nothing at all). The exit code still carries "not running".
            if (json) {
                writeStdout(io, "{\"running\":false}\n");
            } else {
                writeStdout(io, "No dev server is running.\n");
            }
            std.process.exit(1);
        },
        .starting => {
            // The flock is held but `dev.json` hasn't appeared yet — see
            // `classifySession`'s doc comment. Exit 1 like `.none` (there is
            // no usable session to report on yet), but say so truthfully
            // instead of claiming nothing is running.
            if (json) {
                writeStdout(io, "{\"running\":false,\"starting\":true}\n");
            } else {
                writeStdout(
                    io,
                    "A dev session is starting (lock held, dev.json not yet published) — retry in a few seconds.\n",
                );
            }
            std.process.exit(1);
        },
        .running => {},
    }

    // Fetch the control endpoint (best-effort; a just-started session may not
    // answer yet — status still prints from the lockfile alone). `probeHost`
    // maps an unspecified `--host` bind to the loopback that actually
    // answers there (P2c) — a hardcoded 127.0.0.1 broke any session bound to
    // a non-default host.
    const body: ?[]u8 = blk: {
        const addr = Io.net.IpAddress.parse(probeHost(lf.?.host), lf.?.control_port) catch break :blk null;
        break :blk fetchBody(io, gpa, addr, "/_zigapagos/status") catch null;
    };
    defer if (body) |b| gpa.free(b);

    const out = if (json)
        try renderStatusJson(gpa, lf.?, body)
    else
        try renderStatusText(gpa, lf.?, body);
    defer gpa.free(out);
    // The primary answer, not a diagnostic — stdout (F1).
    writeStdout(io, out);
    std.process.exit(0);
}

/// Map an unspecified bind address to the loopback a control verb can
/// actually dial; pass anything else through verbatim. A session started
/// with `--host=0.0.0.0` (or an IPv6 equivalent) legitimately LISTENS on
/// every interface, but nothing can CONNECT "to" an unspecified address — the
/// OS also answers there on loopback, which is what every control-verb
/// connect site (the status fetch, `sweepOrphan`'s `/api/health` probe) and
/// every printed control URL actually needs to dial. PR #140 round 2 (P2c):
/// pre-fix, every one of those sites hardcoded `"127.0.0.1"` outright, so a
/// session on any OTHER `--host` (a LAN IP, say) was just as broken as the
/// unspecified case — this function (and threading `lf.host` through it) is
/// the fix for both. Contract 3 (caller-buffer): allocates nothing.
fn probeHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "::")) return "127.0.0.1";
    if (std.mem.eql(u8, host, "[::]")) return "127.0.0.1";
    return host;
}

/// Pure `--data-dir=` scan, split out of `resolveDataDir` so it is testable
/// without a real `Config.load` (which needs a site on disk). Stops at the
/// first `--` rebuild-command separator: a flag AFTER it belongs to the
/// user's own rebuild command, not to `dev` itself (PR #140 round 2: P2a —
/// pre-fix, `dev --background -- tool --data-dir=tmp` had this scan keep
/// going past `--` and pick up the rebuild command's `--data-dir=tmp`, so the
/// PARENT resolved `tmp/` while the CHILD — which re-scans this same raw
/// argv the identical way — correctly stopped at `--` and wrote
/// `.zigbase/dev.json`; the parent's 30s readiness poll then watched the
/// wrong directory forever and killed an otherwise-healthy child). Contract 3
/// (caller-buffer): allocates nothing, returns a literal or a slice into
/// `args`.
fn scanDataDirArg(args: []const []const u8) []const u8 {
    var data_dir: []const u8 = ".zigbase";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.startsWith(u8, arg, "--data-dir=")) data_dir = arg["--data-dir=".len..];
    }
    return data_dir;
}

/// Resolve the data dir against the site root (the dir holding
/// zigapagos.ziggy), exactly as dev() does. Fatals (via Config.load) when run
/// outside a site. Contract 1: result is gpa-owned, held to process exit.
///
/// `args` is scanned here (rather than threading the already-parsed value
/// through) so this stays a single, reusable "find the data dir" helper for
/// every control verb — `status` is the only caller today, `stop`/`logs`
/// (Tasks 6/7) parse the same `--data-dir=` flag the same way.
fn resolveDataDir(io: Io, gpa: Allocator, args: []const []const u8) []const u8 {
    const data_dir = scanDataDirArg(args);
    _, const base_dir_path = root.Config.load(io, gpa);
    return std.fs.path.resolve(gpa, &.{ base_dir_path, data_dir }) catch fatal.oom();
}

/// Safe field access into a parsed `std.json.Value`: each returns the typed
/// value only when the active union tag actually matches, `null` otherwise.
/// `std.json.Value` is a tagged union — indexing a field whose tag is not the
/// currently-active one (e.g. `.integer` on a value that is actually
/// `.string`) is a hard panic in Debug/ReleaseSafe, not a catchable error.
/// The status renderers below parse an HTTP response body from OUR OWN
/// control endpoint, but "valid JSON" and "the shape this endpoint always
/// sends" are different guarantees — a body that is syntactically fine but
/// unexpectedly shaped (an array at the root; `"build"` present but not an
/// object; `"generation"` as a string) used to panic the whole `dev status`
/// process instead of degrading (PR #140 round 2: P2d). Contract 3
/// (caller-buffer): allocates nothing.
fn jsonObject(v: std.json.Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}
fn jsonInt(v: std.json.Value) ?i64 {
    return if (v == .integer) v.integer else null;
}
fn jsonStr(v: std.json.Value) ?[]const u8 {
    return if (v == .string) v.string else null;
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
        // Every access below is tag-checked (jsonObject/jsonInt/jsonStr) —
        // any shape mismatch (root not an object, "build" not an object, a
        // field of the wrong type) falls through to the degraded path below
        // rather than panicking (P2d).
        const root_obj = jsonObject(parsed) orelse break :build_line;
        const build = jsonObject(root_obj.get("build") orelse break :build_line) orelse break :build_line;
        const generation = jsonInt(build.get("generation") orelse break :build_line) orelse break :build_line;
        const status = jsonStr(build.get("status") orelse break :build_line) orelse break :build_line;
        const duration = jsonInt(build.get("duration_ms") orelse break :build_line) orelse break :build_line;
        w.print("  build #{d} {s} ({d} ms)\n", .{ generation, status, duration }) catch
            return error.OutOfMemory;
        if (build.get("error")) |e| if (e == .string)
            w.print("  error: {s}\n", .{e.string}) catch return error.OutOfMemory;
        w.print("  control: http://{s}:{d}/_zigapagos/status\n  logs:    zigapagos dev logs\n", .{
            probeHost(lf.host), lf.control_port,
        }) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
    // Unreachable/unparseable/malshaped endpoint: degrade, never fail — the
    // session may be mid-startup, or answering something we don't recognize.
    w.print("  build: unknown (control server unreachable)\n", .{}) catch return error.OutOfMemory;
    w.print("  control: http://{s}:{d}/_zigapagos/status\n  logs:    zigapagos dev logs\n", .{
        probeHost(lf.host), lf.control_port,
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
        // Tag-checked (P2d): a root that isn't an object (e.g. the endpoint
        // somehow answered a bare JSON array) must degrade to `build: null`,
        // not panic on `.object` while the active tag is `.array`.
        const root_obj = jsonObject(parsed) orelse break :blk null;
        break :blk root_obj.get("build");
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    std.json.Stringify.value(.{
        .running = true,
        .pid = lf.pid,
        .zigbase_pid = lf.zigbase_pid,
        .url = lf.url,
        .port = lf.port,
        .control_port = lf.control_port,
        .background = lf.background,
        .started_at = lf.started_at,
        .build = build_value,
    }, .{}, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeAll("\n") catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// One bounded HTTP GET: connect, send, strip headers, return the body.
/// Modeled on e2e.zig's probeStatus, which stops at the status line — this
/// reads to EOF (we send `connection: close`). Contract 1.
/// Response reads have a 1 s budget and propagate read errors, including a reset
/// after body bytes arrived; partial data is not accepted as a successful fetch.
fn fetchBody(io: Io, gpa: Allocator, address: Io.net.IpAddress, path: []const u8) ![]u8 {
    return fetchBodyWithTimeout(io, gpa, address, path, 1000);
}

fn fetchBodyWithTimeout(io: Io, gpa: Allocator, address: Io.net.IpAddress, path: []const u8, timeout_ms: u32) ![]u8 {
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + timeout_ms;
    // The address is this machine's dev listener. Zig 0.16's threaded I/O
    // panics for a connect timeout; bound response reads explicitly below.
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
    // Zig 0.16's stream reader exposes no per-read deadline. Use poll/read on
    // its socket so a peer that never closes cannot hang even single-threaded
    // dev control. This escape hatch is POSIX-only (our current host targets);
    // revisit it when Windows support returns with the 0.17 I/O port. The
    // connect-timeout limitation above is separate from this read deadline.
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(gpa);
    while (all.items.len < 64 * 1024) {
        const remaining = deadline - Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) return error.Timeout;
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) == 0) return error.Timeout;
        const n = try std.posix.read(stream.socket.handle, &in_buf);
        if (n == 0) break;
        try all.appendSlice(gpa, in_buf[0..n]);
    }
    if (all.items.len >= 64 * 1024) return error.ResponseTooLarge;
    const raw = all.items;
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    return gpa.dupe(u8, raw[split + 4 ..]);
}

fn stopVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            // Consumed by resolveDataDir below; validated here only.
        } else fatal.usageError(
            "error: unexpected 'zigapagos dev stop' argument '{s}'\n" ++
                "usage: zigapagos dev stop [--data-dir=DIR]\n",
            .{arg},
        );
    }
    const data_dir_abs = resolveDataDir(io, gpa, args);
    switch (stopInstance(io, gpa, data_dir_abs)) {
        .stopped => {
            std.debug.print("Stopped.\n", .{});
            std.process.exit(0); // idempotent: nothing-to-stop is success
        },
        .none => {
            std.debug.print("No dev server is running.\n", .{});
            std.process.exit(0); // idempotent: nothing-to-stop is success
        },
        .starting => {
            // stopInstance already polled for up to 5s and never saw
            // dev.json — NOT "nothing to stop" (a session genuinely holds
            // the lock), so this is not the idempotent-success case above.
            std.debug.print("dev stop: " ++ stop_starting_detail, .{});
            std.process.exit(1);
        },
    }
}

/// Shared explanation for `stopInstance` returning `.starting`: the flock is
/// live but `dev.json` hasn't appeared, so the holder's pid is unknowable
/// (`flock` has no owner-query API) — this is a session between
/// `dev_lockfile.acquire` and its own `waitReady`, not "no session". Every
/// caller of `stopInstance` reports this same fact, worded for its own exit
/// contract: `stopVerb` prefixes it as a warning and exits 1 (not the
/// idempotent-success 0 the `.none`/`.stopped` cases use — a live session
/// really is still there, nothing was stopped); `background()`'s `--force`
/// path and dev.zig's own `--force` re-acquire path both `fatal.msg` it,
/// since either would otherwise go on to spawn/acquire a doomed duplicate
/// against a lock they cannot actually clear.
pub const stop_starting_detail =
    "a dev session holds the lock but has not finished starting (no dev.json " ++
    "yet) — retry in a few seconds, or find and kill the process manually\n";

/// The whole stop path: TERM the dev pid (its reaper cascades to zigbase),
/// poll the flock up to 5s, escalate to KILL, then sweep any zigbase orphan
/// and remove the lockfile. Also handles the dev-already-dead (kill -9) case:
/// the sweep runs regardless. Contract 1.
pub fn stopInstance(io: Io, gpa: Allocator, data_dir_abs: []const u8) enum { stopped, none, starting } {
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

    var pid: ?i64 = if (lf) |l| l.pid else null;
    if (pid == null) {
        // The flock is LIVE but `dev.json` hasn't been written yet: a
        // session between `dev_lockfile.acquire` and its own `waitReady` (a
        // cold zigbase boot is a multi-second window). `flock(2)` has no
        // owner-query API, so the holder's pid is genuinely unknowable until
        // dev.json appears — force-unwrapping `lf` here (as this function
        // used to) panics on exactly this race, reachable from a plain
        // `zigapagos dev stop` or a `--force` racing a session that is still
        // starting.
        //
        // Poll instead of assuming: the writer publishes dev.json right
        // after readiness, so ~5s at 200ms comfortably covers a session
        // that is merely starting, without turning a real hang into an
        // unbounded one. The loop also exits the moment the lock itself
        // drops (`live` goes false) — a session that dies before ever
        // publishing dev.json needs no further waiting.
        var waited_ms: u64 = 0;
        var still_live = true;
        while (pid == null and still_live and waited_ms < 5000) {
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            waited_ms += 200;
            var poll_state = std.heap.ArenaAllocator.init(gpa);
            defer poll_state.deinit();
            if (dev_lockfile.read(poll_state.allocator(), io, data_dir_abs)) |l| pid = l.pid;
            still_live = dev_lockfile.isLive(io, gpa, data_dir_abs);
        }
        if (pid == null) {
            // Either the lock dropped without ever publishing dev.json (the
            // starting session died) or the full 5s elapsed with the lock
            // still held and no dev.json in sight. The first has nothing to
            // report or clean up (no facts survive to sweep); the second is
            // a real, live, still-starting session — report it truthfully
            // rather than silently doing nothing.
            if (!still_live) return .none;
            return .starting;
        }
    }

    const target: std.posix.pid_t = @intCast(pid.?);
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

/// Classifies a signal-0 (existence-only, no signal sent) probe on `pid`.
/// `SIG` is a non-exhaustive enum with no named zero member (0 isn't a real
/// signal, just POSIX's kill(2) convention for "probe"), hence
/// `@enumFromInt(0)` rather than a tag literal like `.TERM` elsewhere in this
/// file. `ProcessNotFound` and `PermissionDenied` both come back as an
/// `error`, but they mean opposite things — the same distinction
/// `dev.zig`'s `reaper.terminate()` makes: NotFound is "gone", nothing to
/// clean up; PermissionDenied means a DIFFERENT process now holds that pid
/// (reuse) and must never be touched. `Unexpected` folds into `.gone`: a dev
/// tool doesn't need to chase every possible errno, and "nothing to clean
/// up" is the safe default for a failure mode we don't understand — it never
/// leads to killing something we're unsure about.
fn probeAlive(pid: std.posix.pid_t) enum { alive, gone, not_ours } {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => .gone,
        error.PermissionDenied => .not_ours,
        error.Unexpected => .gone,
    };
    return .alive;
}

/// PID-reuse guard hit: signal 0 came back EPERM, so `pid` exists but isn't
/// ours. Never kill it.
fn warnNotOurs(pid: i64) void {
    std.debug.print(
        "dev stop: pid {d} exists but is not ours (permission denied) — " ++
            "not killing it (PID may have been reused); if a zigbase is stuck, " ++
            "'pkill zigbase' remains the manual recovery\n",
        .{pid},
    );
}

/// `GET /api/health` on the recorded zigbase port (the endpoint the stock
/// binary has served since v0.12.0's pin), on the session's own bind host
/// (P2c: `zigbase serve` binds the same `--host` the dev session does, so a
/// hardcoded `127.0.0.1` missed a `--host`-bound session exactly like every
/// other control-verb connect site did). True iff it answers with a
/// `"status"` field.
fn probeHealth(io: Io, gpa: Allocator, host: []const u8, port: u16) bool {
    const addr = Io.net.IpAddress.parse(probeHost(host), port) catch return false;
    const body = fetchBody(io, gpa, addr, "/api/health") catch return false;
    defer gpa.free(body);
    return std.mem.indexOf(u8, body, "\"status\"") != null;
}

/// Kill an orphaned zigbase recorded in the lockfile — but only after
/// confirming the process on that port really is our zigbase, by hitting its
/// /api/health. No match → warn and leave it (PID reuse: killing an innocent
/// process is worse than leaving a squatter). Always removes the lockfile.
/// Contract 1.
pub fn sweepOrphan(io: Io, gpa: Allocator, data_dir_abs: []const u8) void {
    defer dev_lockfile.remove(io, gpa, data_dir_abs);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs) orelse return;
    if (lf.zigbase_pid <= 0) return;
    const zb: std.posix.pid_t = @intCast(lf.zigbase_pid);

    switch (probeAlive(zb)) {
        .gone => return,
        .not_ours => return warnNotOurs(lf.zigbase_pid),
        .alive => {},
    }

    if (!probeHealth(io, gpa, lf.host, lf.port)) {
        // A NORMAL stop TERMs the dev pid; its reaper fire-and-forgets a
        // cascading TERM to zigbase (dev.zig's `reaper.terminate()`) and
        // returns immediately WITHOUT waiting for zigbase to actually exit.
        // So landing here with a failed health probe is the COMMON case on a
        // healthy stop, not evidence of an orphan: zigbase is alive but
        // mid-shutdown, its listener already torn down. Grace-poll for it to
        // actually exit before concluding anything else — this path must
        // stay silent for a normal stop, not print a false "PID reuse?"
        // warning on every session teardown.
        var waited: u64 = 0;
        while (waited < 2000) : (waited += 100) {
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            switch (probeAlive(zb)) {
                .gone => return, // died during the cascade: normal stop, nothing to warn about
                .not_ours => return warnNotOurs(lf.zigbase_pid),
                .alive => {},
            }
        }
        // Still alive after the grace: one more health attempt — it may have
        // been slow to answer, though that's unlikely this long after a TERM
        // cascade — before concluding it's actually stuck/orphaned.
        if (!probeHealth(io, gpa, lf.host, lf.port)) {
            std.debug.print(
                "dev stop: pid {d} is alive but {d} does not answer /api/health — " ++
                    "not killing it (PID may have been reused); if a zigbase is stuck, " ++
                    "'pkill zigbase' remains the manual recovery\n",
                .{ lf.zigbase_pid, lf.port },
            );
            return;
        }
    }

    std.debug.print("dev stop: reaping orphaned zigbase (pid {d})\n", .{lf.zigbase_pid});
    std.posix.kill(zb, .TERM) catch return;
    // Brief grace, then KILL.
    var waited: u64 = 0;
    while (waited < 2000) : (waited += 100) {
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        switch (probeAlive(zb)) {
            .gone => return,
            .not_ours => return, // pid now belongs to someone else — stop touching it
            .alive => {},
        }
    }
    std.posix.kill(zb, .KILL) catch {};
}
/// Drop the flags that must not recurse into the background child: the child
/// runs the plain foreground path (guarded by background_child_env), and
/// --force was already consumed by the parent. Stops filtering at the first
/// `--` rebuild-command separator: everything after it belongs to the user's
/// OWN rebuild command (`zigapagos dev --background -- zigapagos release
/// --force`), not to this process's own flags, and must be re-exec'd to the
/// child byte-for-byte (PR #140 round 2: P1 — pre-fix, this function scanned
/// the whole argv unconditionally and silently ate a `--force`/`--background`
/// belonging to the rebuild command, not to `dev` itself). Contract 1: caller
/// frees the slice (the strings are borrowed from raw_args).
fn filterBackgroundArgs(gpa: Allocator, raw_args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var past_separator = false;
    for (raw_args) |arg| {
        if (!past_separator) {
            if (std.mem.eql(u8, arg, "--")) {
                past_separator = true;
                try out.append(gpa, arg);
                continue;
            }
            if (std.mem.eql(u8, arg, "--background")) continue;
            if (std.mem.eql(u8, arg, "--force")) continue;
        }
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

/// Checks `dev.json` for `child_pid`; on a match, prints the ready summary
/// and exits the process 0 (never returns in that case). Otherwise returns
/// plainly — a missing lockfile and one that names a different pid are the
/// same "not ready yet" fact to every caller. Contract 1 (self-freeing): the
/// read is arena-scoped, and the print happens INSIDE that scope, before the
/// arena — and the `LockFile`'s string fields, which point into it — is
/// freed. (An earlier draft of this returned the parsed `LockFile` up to the
/// caller after freeing its own arena, which would have handed back a
/// dangling `.url`; folding the print into this function's own scope is what
/// keeps it Contract 1 instead of Contract 4.)
fn checkBackgroundReady(
    io: Io,
    gpa: Allocator,
    data_dir_abs: []const u8,
    child_pid: std.posix.pid_t,
    log_path: []const u8,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs) orelse return;
    if (lf.pid != @as(i64, child_pid)) return;
    std.debug.print(
        "dev: running in the background at {s} (pid {d})\n" ++
            "dev: control:  http://{s}:{d}/_zigapagos/status\n" ++
            "dev: log file: {s}\n" ++
            "dev: manage:   zigapagos dev stop | status | wait | logs [--json] [--follow]\n",
        .{ lf.url, lf.pid, probeHost(lf.host), lf.control_port, log_path },
    );
    std.process.exit(0);
}

/// The background child died (or became unobservable) before publishing
/// `dev.json`: report it and exit 1. Never returns.
fn failBackgroundStartup(io: Io, gpa: Allocator, log_path: []const u8) noreturn {
    std.debug.print("error: dev: the background dev process exited before becoming ready\n", .{});
    printLogTail(io, gpa, log_path);
    std.process.exit(1);
}

/// The --background PARENT: spawn the child detached (own pgid, stdio to the
/// log file), wait for the lockfile to appear with the child's pid (that IS
/// the readiness handshake — dev.json is only written after waitReady), print
/// the summary, exit 0. Never returns. Contract 1.
///
/// `cmd` is `dev.Command`, passed `anytype` to avoid an import cycle
/// (dev.zig imports this file for the control-verb dispatch, so this file
/// cannot import dev.zig back); it reads only `.force`. The data dir comes
/// from `raw_args` (the ORIGINAL argv `dev()` received), not `cmd.data_dir`:
/// `resolveDataDir` below re-scans argv for `--data-dir=` itself — the same
/// helper `status`/`stop`/`logs` use — so it needs the raw slice of strings,
/// not the already-parsed single `[]const u8` value.
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
    const data_dir_abs = resolveDataDir(io, gpa, raw_args);
    Io.Dir.cwd().createDirPath(io, data_dir_abs) catch |err| fatal.msg(
        "error: dev: unable to create the data dir '{s}': {s}\n",
        .{ data_dir_abs, @errorName(err) },
    );

    // Fast-feedback idempotency: a live session means "already running", exit
    // 0 with its facts (--force stops it instead). The child re-checks under
    // its own flock, so a race here is caught authoritatively there.
    if (dev_lockfile.isLive(io, gpa, data_dir_abs)) {
        if (cmd.force) {
            switch (stopInstance(io, gpa, data_dir_abs)) {
                .stopped, .none => {},
                // Nothing was actually stopped — the flock is held by a
                // session still starting, whose pid stopInstance could not
                // even determine. Spawning a new child anyway would just
                // race that same flock: filterBackgroundArgs strips
                // `--force` before the re-exec, so the child would hit its
                // own plain `dev_lockfile.acquire`, lose, and fatal on
                // "already running" only after paying for a spawn and (most
                // of) the 30s readiness wait. Fail here instead, immediately
                // and truthfully.
                .starting => fatal.msg("error: dev: " ++ stop_starting_detail, .{}),
            }
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
    // `checkBackgroundReady` exits the process on a match and simply returns
    // otherwise (missing lockfile or a pid that isn't `child_pid` yet are the
    // same "not ready" outcome to this loop).
    var waited_ms: u64 = 0;
    while (waited_ms < 30_000) : (waited_ms += 200) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};

        checkBackgroundReady(io, gpa, data_dir_abs, child_pid, log_path);

        // Child death check: waitpid(WNOHANG) — kill(pid,0) is not enough, a
        // zombie still "exists" to it. `std.posix` has no `waitpid` in this
        // Zig (0.16.0; verified absent from lib/std/posix.zig) — Threaded.zig's
        // own `childWaitPosix` reaps through `posix.system.waitpid` (i.e.
        // `std.c.waitpid`) directly, so this mirrors the standard library's
        // own idiom rather than inventing a new one.
        //
        // Three outcomes, not two. `0` is WNOHANG's whole point — "still
        // running, nothing to report" — and needs no action here. A match on
        // `child_pid` means it just exited: fail. `-1` is an ERROR, not a
        // process state — almost certainly ECHILD because something else
        // already reaped the child out from under us (EINTR is not a
        // realistic outcome of a non-blocking WNOHANG call, since it never
        // blocks). An unreapable child is NOT the same fact as "still
        // running": treating it as 0 would spin for the rest of the 30s on a
        // child we can no longer observe at all. So it gets one more
        // dev.json check to settle the race this very check can create
        // (readiness can land between the check above and this waitpid call)
        // and otherwise fails the same way a confirmed exit does — one
        // spurious failure here beats a silent 30s stall.
        const wp = std.c.waitpid(child_pid, null, std.c.W.NOHANG);
        if (wp == child_pid) {
            failBackgroundStartup(io, gpa, log_path);
        } else if (wp == -1) {
            checkBackgroundReady(io, gpa, data_dir_abs, child_pid, log_path);
            failBackgroundStartup(io, gpa, log_path);
        }
    }

    // Timeout: kill the child's whole group (it leads its own), clean up.
    // `-child_pid`: negative-pid `kill(2)` targets the whole process group;
    // `child_pid`'s type (`std.posix.pid_t`) is already signed, so plain
    // negation needs no cast (unlike the brief's std.c.kill fallback, which
    // would only be needed if `std.posix.kill` rejected a negative operand by
    // type — it doesn't).
    std.debug.print("error: dev: the background dev process did not become ready within 30s\n", .{});
    std.posix.kill(-child_pid, .TERM) catch {};
    dev_lockfile.remove(io, gpa, data_dir_abs);
    printLogTail(io, gpa, log_path);
    std.process.exit(1);
}

fn logsVerb(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!noreturn {
    var follow = false;
    var json = false;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            // Consumed by resolveDataDir below; validated here only (matches
            // statusVerb/stopVerb — this file never stores a second, dead
            // copy of a flag resolveDataDir already re-scans args for).
        } else if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else fatal.usageError(
            "error: unexpected 'zigapagos dev logs' argument '{s}'\n" ++
                "usage: zigapagos dev logs [--json] [--follow] [--data-dir=DIR]\n",
            .{arg},
        );
    }
    const data_dir_abs = resolveDataDir(io, gpa, args);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lf = dev_lockfile.read(arena_state.allocator(), io, data_dir_abs);
    const live = dev_lockfile.isLive(io, gpa, data_dir_abs);
    if (!json and live and lf != null and !lf.?.background) fatal.msg(
        "error: dev logs: this session runs in the FOREGROUND — its output is " ++
            "in the terminal that started it (only --background sessions log to a file)\n",
        .{},
    );

    const log_path = std.fs.path.join(gpa, &.{ data_dir_abs, if (json) "dev.ndjson" else log_name }) catch fatal.oom();
    const contents = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.StreamTooLong) {
            fatal.msg(
                "error: dev logs: {s} exceeds the 16 MiB read cap — read it directly (tail -f {s})\n",
                .{ log_path, log_path },
            );
        } else {
            fatal.msg(
                "error: dev logs: no log file at {s} (was a background session ever started?)\n",
                .{log_path},
            );
        }
    };
    // The log content is the payload `zigapagos dev logs | grep` reads —
    // stdout (F1). The cap/stop notes below stay diagnostics on stderr.
    writeStdout(io, contents);
    var offset: usize = contents.len;
    gpa.free(contents);
    if (!follow) std.process.exit(0);

    // Poll-tail: stat-and-read-the-delta every 200ms; when the session dies,
    // flush whatever appeared and exit. Boring and portable — no fs-events
    // machinery for a dev-log tail.
    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        const now = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            if (err == error.StreamTooLong) {
                std.debug.print("dev logs: {s} exceeded the 16 MiB read cap — tail stopped\n", .{log_path});
            }
            break;
        };
        defer gpa.free(now);
        if (now.len > offset) {
            writeStdout(io, now[offset..]);
            offset = now.len;
        } else if (now.len < offset) {
            // Truncated (a --force restart): dump the fresh file from the top.
            writeStdout(io, now);
            offset = now.len;
        }
        if (!dev_lockfile.isLive(io, gpa, data_dir_abs)) {
            // One final delta read, then done.
            const last = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
                if (err == error.StreamTooLong) {
                    std.debug.print("dev logs: {s} exceeded the 16 MiB read cap — tail stopped\n", .{log_path});
                }
                break;
            };
            defer gpa.free(last);
            if (last.len > offset) writeStdout(io, last[offset..]);
            break;
        }
    }
    std.process.exit(0);
}
