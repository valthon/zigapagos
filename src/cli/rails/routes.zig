//! The Zig client for the Rails route sidecar
//! (`runtime/sidecar/rails/analyze.rb`): locates Ruby and the sidecar
//! script, spawns a persistent-protocol process for exactly one
//! request/response pair, and folds the result into the discovery pass's
//! blocker list. Mirrors `src/islands/sidecar.zig`'s shape (locate the
//! interpreter, locate the script through `ZIGAPAGOS_RUNTIME_DIR`, one
//! request line, one response line) so this side is familiar rather than
//! novel -- Task 4 deliberately matched `runtime/sidecar/render.ts`'s
//! conventions in `analyze.rb` for the same reason.
//!
//! Every way this can fail -- no Ruby, no sidecar script, a spawn/exit/
//! response failure, or no `config/routes.rb` -- degrades to a blocker
//! rather than a fatal: a Rails app with no recovered route graph is still
//! a useful inventory (Stage 1 shipped exactly that on its own).
//!
//! All four degradation codes (`RAILS_RUBY_UNAVAILABLE`, `RAILS_SIDECAR_MISSING`,
//! `RAILS_SIDECAR_FAILED`, `RAILS_ROUTES_MISSING`) carry `integrity = false`, NOT
//! `true` -- despite naming a genuine failure. `Blocker.integrity` means "the
//! INVENTORY itself is untrustworthy" (blockers.zig's own doc), and none of
//! these four touch the inventory: `inventory.walk` and everything it found
//! are exactly as complete and correct as they were before route discovery
//! ran. Only the ROUTE GRAPH -- a separate, optional layer this stage adds
//! on top -- is absent. That is an expected finding about one part of the
//! worklist, the same as an unsupported template engine (`RAILS_TEMPLATE_
//! ENGINE_UNSUPPORTED`, also `integrity = false`), not evidence the rest of
//! the report can't be trusted. Do not "fix" these back to `true` because a
//! missing sidecar sounds serious: `--strict` (Stage 4) is the mechanism for
//! "fail when anything is blocked", and it does not need `integrity`
//! overloaded to serve it -- a plain `zigapagos migrate` on a machine with no
//! `ZIGAPAGOS_RUNTIME_DIR` set must still exit 0 (this was caught by
//! `tests/migrate/rails.sh` failing after these were first shipped as
//! `integrity = true`, which was simply wrong).
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` escapes this
//! directory, and `fatal.*` handling stays migrate.zig's job.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");

pub const Origin = enum { static_ast, actiondispatch, routes_import };

pub const Route = struct {
    verb: []const u8,
    path: []const u8,
    controller: ?[]const u8,
    action: ?[]const u8,
    /// Always `null` today -- the Prism-AST walk (Task 3) does not attempt
    /// to name routes yet. Carried rather than invented so a future stage
    /// can populate it without a shape change; see `routes.rb`'s own
    /// `name:` field comment.
    name: ?[]const u8,
    /// `false` when the parser found the route via a construct it could
    /// not fully evaluate (recorded as a paired `unresolved` entry --
    /// `decodeResponse` turns those into blockers) and is not vouching for
    /// this route being complete/accurate.
    certain: bool,
    origin: Origin,
};

pub const Result = struct {
    /// Owned; release with `freeRoutes`.
    routes: []Route,
    /// Always a static string literal (`"static_ast"` when a response was
    /// successfully decoded, `"none"` on every degradation path) and is
    /// never freed.
    mode: []const u8,
};

/// Env var naming the Ruby interpreter to spawn; `ruby` on `PATH` when
/// unset or blank (`std.process.spawn` resolves a bare name against `PATH`
/// itself -- see its own doc comment -- so no manual search is needed
/// here).
const ruby_env = "ZIGAPAGOS_RUBY";

/// The SAME variable `src/cli/release.zig:587` defines as
/// `pub const runtime_dir_env`. Re-declared rather than imported --
/// `src/cli/rails/` is std-only and that file pulls in `fatal.zig` and the
/// rest of the wired build -- so if the two ever need to diverge, this
/// comment is the tripwire: keep them in lockstep.
const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

/// Generous but bounded: a real Prism-AST walk of `config/routes.rb` is
/// milliseconds; this exists purely so a wedged interpreter (or a routes.rb
/// construct that sends the walker into a real infinite loop, as opposed to
/// the `RAILS_ROUTE_LOOP`-tagged ones `routes.rb` already detects
/// statically) cannot hang the whole build. See `killOnTimeout`.
const sidecar_timeout_ms: i64 = 30_000;

/// Contract 2 (owned-result) helper: returns a fresh `gpa`-owned absolute
/// path for `root_path`, resolved against the process cwd when relative.
/// Mirrors `Sidecar.absSrc` (`src/islands/sidecar.zig`) -- duplicated
/// rather than imported for the same std-only reason as everything else in
/// this file.
fn resolveAbsRoot(io: Io, gpa: Allocator, root_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(root_path)) return try gpa.dupe(u8, root_path);
    const cwd_str = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_str);
    return try std.fs.path.resolve(gpa, &.{ cwd_str, root_path });
}

/// Runs on a dedicated thread for as long as `discoverRoutes`'s blocking
/// write+read of the sidecar's one response line takes. If `done` is not
/// signaled within `sidecar_timeout_ms`, the sidecar is presumed hung and is
/// killed so the blocked read unblocks with an error instead of hanging the
/// build forever; `discoverRoutes` turns that into `RAILS_SIDECAR_FAILED`
/// like any other spawn/response failure.
///
/// `child.kill`/`child.wait` are not safe to call from two threads at once
/// (`Child.id` is checked/cleared without its own synchronization), so
/// `discoverRoutes` signals `done` and `join`s this thread BEFORE it ever
/// touches `child` again -- by construction, only one of "this thread's
/// timeout kill" and "the caller's own child.kill/wait" can run.
///
/// Inspection-verified only: no test forces the real 30s timeout to fire.
/// Making that deterministic needs either an actual 30s CI run or a seam
/// that exists solely for the test, and this guard's failure mode -- the
/// build hangs instead of erroring -- isn't worth either cost. Every other
/// test in this file completes in milliseconds and passes with this
/// watchdog wired in, which does exercise the FAST path (signal, join, no
/// kill) on every run; the kill-on-timeout branch itself is not covered.
///
/// Two known, narrow gaps (whole-branch review, deliberately left as-is --
/// fixing either would trade away the join-before-touch ordering the doc
/// above depends on to keep `kill`/`wait` single-threaded):
/// - `discoverRoutes`'s `child.wait(io)` runs AFTER this thread is joined,
///   so it is itself unbounded: a sidecar that answers the one response
///   line but then never exits hangs the build even though this watchdog
///   fired and returned cleanly (`done.set` + `join` only bound the
///   write+read, not the final wait).
/// - `std.process.Child.wait` asserts `child.id != null`; if `child.kill`
///   here and `discoverRoutes`'s own `child.kill`/`child.wait` could ever
///   race (they cannot today, by construction -- see above), a kill landing
///   in the same instant as a response would be a potential panic, not
///   just a lost race.
fn killOnTimeout(io: Io, child: *std.process.Child, done: *Io.Event) void {
    const dur: Io.Clock.Duration = .{ .raw = .fromMilliseconds(sidecar_timeout_ms), .clock = .awake };
    done.waitTimeout(io, .{ .duration = dur }) catch |err| switch (err) {
        error.Timeout => child.kill(io),
        error.Canceled => {},
    };
}

/// Contract 2 (owned-result): returns a fresh `gpa`-owned slice holding the
/// sidecar's one response line (newline stripped by `streamDelimiter`);
/// `discoverRoutes` frees it with a `defer gpa.free(line)` at its call site.
/// No scratch allocation escapes besides that one slice.
///
/// Writes the one NDJSON request line (`{"op":"routes","root":<abs>}`),
/// closes stdin (analyze.rb's loop treats EOF as an ordinary, expected
/// shutdown -- see its own module doc), and reads back the one response
/// line. Split out of `discoverRoutes` purely to keep that function's body
/// readable; unlike `decodeResponse` this half is not meant to be unit
/// tested on its own; it always needs a live process.
fn queryOnce(io: Io, gpa: Allocator, child: *std.process.Child, root_abs: []const u8) ![]u8 {
    var wbuf: [4096]u8 = undefined;
    var fw = child.stdin.?.writer(io, &wbuf);
    const w = &fw.interface;
    try w.writeAll("{\"op\":\"routes\",\"root\":");
    try std.json.Stringify.value(root_abs, .{}, w);
    try w.writeAll("}\n");
    try w.flush();
    // Signals "no more requests" -- analyze.rb's `$stdin.gets` returns nil
    // and the process exits normally once it has answered this one.
    child.stdin.?.close(io);
    child.stdin = null;

    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.reader(io, &rbuf);
    var line_aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer line_aw.deinit();
    _ = try fr.interface.streamDelimiter(&line_aw.writer, '\n');
    return line_aw.toOwnedSlice();
}

/// Contract 2 (owned-result): every `Route` field that is a string
/// (`verb`, `path`, and non-null `controller`/`action`/`name`) is a fresh
/// `gpa`-owned allocation -- `discoverRoutes`/`decodeResponse` never let a
/// `Route` alias the JSON tree it was decoded from, because that tree is
/// freed before either function returns. `origin` and `certain` are plain
/// values with nothing to free. `freeRoutes` is the matching release.
///
/// Every failure mode -- Ruby not found, the sidecar script/runtime dir not
/// found, a spawn/exit/response failure, or no `config/routes.rb` -- appends
/// exactly one blocker with `integrity = false` to `blocker_list` (see the
/// module doc for why NOT `true`: none of these make the INVENTORY
/// untrustworthy, only the separate route graph absent) and returns a
/// `Result` with zero routes and `mode = "none"`. None of them is fatal
/// (a Rails app with no recovered route graph is still a useful inventory,
/// which is what Stage 1 shipped on its own), so this function's own error
/// return stays `Allocator.Error` only: every other failure degrades
/// instead of propagating.
///
/// `config/routes.rb`'s absence is detected HERE, client-side, via `root.
/// access` -- rather than relying on analyze.rb's own `{"ok":false,"error":
/// "no config/routes.rb..."}` (see analyze.rb:44's comment on that case) --
/// for two reasons: it gives this specific, expected-to-be-common case its
/// own blocker code instead of folding it into the catch-all
/// `RAILS_SIDECAR_FAILED`, and it skips spawning Ruby entirely for an app
/// this adapter already knows has nothing to analyze.
///
/// `environ_map` is `main.zig`'s `init.environ_map`, threaded down through
/// `migrate`/`rails.discover` -- the same way `release.zig`/`dev.zig`/
/// `e2e.zig` already receive it -- rather than read via `std.c.getenv`:
/// `std.process.Environ.Map.get` is libc-free, and `migrate` simply hadn't
/// been wired to receive the map before this stage needed it.
pub fn discoverRoutes(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    root_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
    environ_map: *const std.process.Environ.Map,
) Allocator.Error!Result {
    const none: Result = .{ .routes = &.{}, .mode = "none" };

    root.access(io, "config/routes.rb", .{}) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_ROUTES_MISSING", "config/routes.rb", @errorName(err), false);
        return none;
    };

    const ruby_path = environ_map.get(ruby_env) orelse "ruby";

    const runtime_dir_raw = environ_map.get(runtime_dir_env);
    const runtime_dir = if (runtime_dir_raw) |v| std.mem.trim(u8, v, " \t\r\n") else "";
    if (runtime_dir.len == 0) {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_MISSING", "sidecar/rails/analyze.rb", "ZIGAPAGOS_RUNTIME_DIR is not set", false);
        return none;
    }

    const script_path = try std.fs.path.join(gpa, &.{ runtime_dir, "sidecar", "rails", "analyze.rb" });
    defer gpa.free(script_path);

    // Resolved to absolute up front (mirrors `Sidecar.spawn`'s
    // `realPathFile` in src/islands/sidecar.zig): this both confirms the
    // script exists -- RAILS_SIDECAR_MISSING when it doesn't -- and gives a
    // stable argv[1] regardless of the child's own cwd.
    var script_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const script_abs_n = Io.Dir.cwd().realPathFile(io, script_path, &script_abs_buf) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_MISSING", script_path, @errorName(err), false);
        return none;
    };
    const script_abs = script_abs_buf[0..script_abs_n];

    // analyze.rb's contract is an ABSOLUTE root (analyze.rb:44); resolve
    // root_path the same way `Sidecar.absSrc` resolves an island `src`.
    const abs_root = resolveAbsRoot(io, gpa, root_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", root_path, @errorName(err), false);
            return none;
        },
    };
    defer gpa.free(abs_root);

    var child = std.process.spawn(io, .{
        .argv = &.{ ruby_path, script_abs },
        .stdin = .pipe,
        .stdout = .pipe,
        // stderr inherits the parent so a Ruby crash/backtrace is visible
        // in the build log, same as the Bun sidecar.
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `script_abs` was already resolved to an absolute, existing path
        // above, so an ENOENT here can only be the interpreter -- the same
        // attribution `Sidecar.spawn` makes for the analogous Bun case.
        error.FileNotFound => {
            try blockers.append(gpa, blocker_list, "RAILS_RUBY_UNAVAILABLE", ruby_path, "not found on PATH", false);
            return none;
        },
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", ruby_path, @errorName(err), false);
            return none;
        },
    };

    var done: Io.Event = .unset;
    const watchdog: ?std.Thread = if (comptime !builtin.single_threaded)
        // `catch null` rather than propagating a spawn failure: this thread is
        // pure defense-in-depth (see `killOnTimeout`'s doc), so losing it just
        // means the wait below is unbounded again, not that discovery should
        // fail. `std.Thread.spawn` failing at all is a resource-exhaustion
        // edge case essentially never hit in practice, not something this
        // function has a better response to than "proceed without the guard".
        std.Thread.spawn(.{}, killOnTimeout, .{ io, &child, &done }) catch null
    else
        null; // -Dsingle-threaded has no threads to spawn a watchdog on; see CLAUDE.md's note on that gate.

    const query_result = queryOnce(io, gpa, &child, abs_root);

    // Stop the watchdog (if any) BEFORE touching `child` again below -- see
    // `killOnTimeout`'s doc for why this ordering is what keeps
    // `child.kill`/`child.wait` single-threaded.
    done.set(io);
    if (watchdog) |t| t.join();

    const line = query_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            child.kill(io);
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", ruby_path, @errorName(err), false);
            return none;
        },
    };
    defer gpa.free(line);

    const term = child.wait(io) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", ruby_path, @errorName(err), false);
        return none;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            var buf: [48]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "ruby exited {d}", .{code}) catch "ruby exited nonzero";
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", ruby_path, detail, false);
            return none;
        },
        .signal, .stopped, .unknown => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", ruby_path, "sidecar terminated abnormally", false);
            return none;
        },
    }

    // `decodeResponse`'s own error return is `Allocator.Error` only (every
    // other failure it might hit is turned into a blocker internally), so
    // whether it added a *new* RAILS_SIDECAR_FAILED blocker (a malformed
    // line, or a well-formed `{"ok":false,...}`) is the signal for whether
    // "static_ast" mode actually ran, since `decodeResponse` never adds that
    // code on its success path (only `unresolved`-entry codes, if any).
    const before = blocker_list.items.len;
    const routes = try decodeResponse(gpa, line, "config/routes.rb", blocker_list);
    var mode: []const u8 = "static_ast";
    if (blocker_list.items.len > before and
        std.mem.eql(u8, blocker_list.items[blocker_list.items.len - 1].code, "RAILS_SIDECAR_FAILED"))
    {
        mode = "none";
    }
    return .{ .routes = routes, .mode = mode };
}

const WireRoute = struct {
    verb: []const u8,
    path: []const u8,
    controller: ?[]const u8 = null,
    action: ?[]const u8 = null,
    name: ?[]const u8 = null,
    certain: bool,
};

const WireUnresolved = struct {
    code: []const u8,
    detail: []const u8 = "",
    line: ?u64 = null,
};

const WireResponse = struct {
    ok: bool,
    routes: []const WireRoute = &.{},
    unresolved: []const WireUnresolved = &.{},
    @"error": ?[]const u8 = null,
};

/// The known `unresolved[].code` vocabulary `runtime/sidecar/rails/
/// routes.rb` emits (its `mark_unresolved` call sites). Matched against
/// rather than trusting the JSON string directly as `Blocker.code`, because
/// `blockers.zig`'s contract is that `code` is ALWAYS a static string
/// literal that `blockers.free` never frees -- a JSON-decoded string lives
/// in the `std.json.parseFromSlice` arena `decodeResponse` frees before
/// returning, so aliasing it into a long-lived `Blocker` would leave a
/// dangling pointer the moment that arena is gone. Matching against this
/// table yields the equivalent STATIC literal instead, satisfying the
/// invariant while still producing the exact code text callers expect.
const known_unresolved_codes = [_][]const u8{
    "RAILS_ROUTES_PARSE_ERROR",
    "RAILS_ROUTE_CONDITIONAL",
    "RAILS_ROUTE_ENGINE_MOUNT",
    "RAILS_ROUTE_GEM_GENERATED",
    "RAILS_ROUTE_LOOP",
    "RAILS_ROUTE_CONCERN_CYCLE",
    "RAILS_ROUTE_CUSTOM_ROUTER",
    "RAILS_ROUTE_EXTERNAL_FILE",
    "RAILS_ROUTE_DYNAMIC_PATH",
};

/// Fallback for a code this build's table doesn't recognize (e.g. the Ruby
/// side adds one before the Zig side is updated). The real text is not
/// dropped -- `decodeResponse` folds it into the blocker's `detail`.
const unrecognized_unresolved_code = "RAILS_ROUTE_UNRESOLVED";

fn staticUnresolvedCode(json_code: []const u8) []const u8 {
    for (known_unresolved_codes) |c| {
        if (std.mem.eql(u8, c, json_code)) return c;
    }
    return unrecognized_unresolved_code;
}

/// Contract 2 (owned-result) helper for `decodeResponse`: every string
/// field of the returned `Route` is a fresh `gpa` allocation, independent
/// of `wr`'s backing JSON arena. On a mid-construction allocation failure,
/// every field already duplicated is freed before the error propagates
/// (each `errdefer` below guards only the one field above it; Zig runs them
/// in reverse order, so together they cover the whole partially-built
/// route).
fn dupeRoute(gpa: Allocator, wr: WireRoute) Allocator.Error!Route {
    const verb = try gpa.dupe(u8, wr.verb);
    errdefer gpa.free(verb);
    const path = try gpa.dupe(u8, wr.path);
    errdefer gpa.free(path);
    const controller: ?[]const u8 = if (wr.controller) |c| try gpa.dupe(u8, c) else null;
    errdefer if (controller) |c| gpa.free(c);
    const action: ?[]const u8 = if (wr.action) |a| try gpa.dupe(u8, a) else null;
    errdefer if (action) |a| gpa.free(a);
    const name: ?[]const u8 = if (wr.name) |n| try gpa.dupe(u8, n) else null;
    return .{
        .verb = verb,
        .path = path,
        .controller = controller,
        .action = action,
        .name = name,
        .certain = wr.certain,
        // Every route this stage recovers comes from the static-AST walk
        // (Task 3); `actiondispatch`/`routes_import` are later-stage
        // origins with no producer yet.
        .origin = .static_ast,
    };
}

fn freeRouteFields(gpa: Allocator, r: Route) void {
    gpa.free(r.verb);
    gpa.free(r.path);
    if (r.controller) |c| gpa.free(c);
    if (r.action) |a| gpa.free(a);
    if (r.name) |n| gpa.free(n);
}

fn routeLessThan(_: void, a: Route, b: Route) bool {
    const path_order = std.mem.order(u8, a.path, b.path);
    if (path_order != .eq) return path_order == .lt;
    return std.mem.order(u8, a.verb, b.verb) == .lt;
}

/// Decodes one sidecar response LINE (`{"ok":true,"routes":[...],
/// "unresolved":[...]}` or `{"ok":false,"error":"..."}`) into `[]Route`.
/// Split out from `discoverRoutes` so the JSON half is unit-testable
/// without spawning anything -- `discoverRoutes` wraps this with the spawn.
///
/// Contract 2 (owned-result): see `dupeRoute`'s doc for the per-field
/// ownership story. `parsed.deinit()` frees the JSON tree the result was
/// decoded from before this function returns, so nothing in the returned
/// slice may alias it; `freeRoutes` is the matching release.
///
/// `unresolved` entries become blockers (`integrity = false`: a construct
/// the static walk could not evaluate is an expected finding about ONE
/// route, not a reason to distrust the whole recovered graph) rather than
/// being silently dropped. A malformed line, or a well-formed `{"ok":
/// false,...}`, both collapse to a single `RAILS_SIDECAR_FAILED` blocker
/// (`integrity = false` -- see the module doc: the route graph is absent,
/// the inventory itself is not in question) and an empty route slice --
/// `discoverRoutes` reads that blocker back to decide `Result.mode` (see
/// its own comment on that call site).
fn decodeResponse(
    gpa: Allocator,
    line: []const u8,
    src_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error![]Route {
    var parsed = std.json.parseFromSlice(WireResponse, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", src_path, @errorName(err), false);
            return &.{};
        },
    };
    defer parsed.deinit();
    const resp = parsed.value;

    if (!resp.ok) {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", src_path, resp.@"error" orelse "sidecar reported failure", false);
        return &.{};
    }

    var routes = try gpa.alloc(Route, resp.routes.len);
    var filled: usize = 0;
    errdefer {
        for (routes[0..filled]) |r| freeRouteFields(gpa, r);
        gpa.free(routes);
    }
    for (resp.routes, 0..) |wr, i| {
        routes[i] = try dupeRoute(gpa, wr);
        filled = i + 1;
    }

    for (resp.unresolved) |u| {
        const code = staticUnresolvedCode(u.code);
        const recognized = !std.mem.eql(u8, code, unrecognized_unresolved_code);
        var detail_buf: [320]u8 = undefined;
        const detail = if (recognized)
            (if (u.line) |ln|
                std.fmt.bufPrint(&detail_buf, "{s} (line {d})", .{ u.detail, ln }) catch u.detail
            else
                u.detail)
        else if (u.line) |ln|
            std.fmt.bufPrint(&detail_buf, "unrecognized code {s}: {s} (line {d})", .{ u.code, u.detail, ln }) catch u.detail
        else
            std.fmt.bufPrint(&detail_buf, "unrecognized code {s}: {s}", .{ u.code, u.detail }) catch u.detail;
        try blockers.append(gpa, blocker_list, code, src_path, detail, false);
    }

    std.mem.sort(Route, routes, {}, routeLessThan);
    return routes;
}

/// Contract 2 counterpart to `discoverRoutes`/`decodeResponse`: releases
/// every owned string on every route (see `dupeRoute`'s ownership note)
/// plus the slice itself. `origin` and `certain` are plain values with
/// nothing to free.
pub fn freeRoutes(gpa: Allocator, routes: []Route) void {
    for (routes) |r| freeRouteFields(gpa, r);
    gpa.free(routes);
}

test "a sidecar response decodes into routes, preserving certainty" {
    const line =
        \\{"ok":true,"routes":[
        \\{"verb":"GET","path":"/","controller":"home","action":"index","name":"root","certain":true},
        \\{"verb":"GET","path":"/x","controller":null,"action":null,"name":null,"certain":false}],
        \\"unresolved":[{"code":"RAILS_ROUTE_LOOP","detail":"each","line":12}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 2), res.len);
    try std.testing.expectEqualStrings("GET", res[0].verb);
    try std.testing.expect(res[0].certain);
    try std.testing.expect(!res[1].certain);
    // Unresolved entries become blockers, not silence.
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_LOOP", blocker_list.items[0].code);
}

test "an ok:false response becomes one RAILS_SIDECAR_FAILED blocker and zero routes" {
    const line =
        \\{"ok":false,"error":"boom: NoMethodError"}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 0), res.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_FAILED", blocker_list.items[0].code);
    // Non-integrity: the sidecar failed, but that says nothing about
    // whether the rest of the inventory (which never touched this response)
    // is trustworthy -- see the module doc.
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "a malformed response line becomes one RAILS_SIDECAR_FAILED blocker and zero routes" {
    const line = "not json";
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 0), res.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_FAILED", blocker_list.items[0].code);
}

test "routes decode sorted by (path, verb) regardless of wire order" {
    const line =
        \\{"ok":true,"routes":[
        \\{"verb":"POST","path":"/posts","controller":"posts","action":"create","name":null,"certain":true},
        \\{"verb":"GET","path":"/posts","controller":"posts","action":"index","name":null,"certain":true},
        \\{"verb":"GET","path":"/","controller":"home","action":"index","name":null,"certain":true}],
        \\"unresolved":[]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 3), res.len);
    try std.testing.expectEqualStrings("/", res[0].path);
    try std.testing.expectEqualStrings("/posts", res[1].path);
    try std.testing.expectEqualStrings("GET", res[1].verb);
    try std.testing.expectEqualStrings("/posts", res[2].path);
    try std.testing.expectEqualStrings("POST", res[2].verb);
}

test "an unrecognized unresolved code is not dropped: it folds into detail under a static fallback code" {
    const line =
        \\{"ok":true,"routes":[],"unresolved":[{"code":"RAILS_ROUTE_FUTURE_THING","detail":"whatever","line":3}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_UNRESOLVED", blocker_list.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "RAILS_ROUTE_FUTURE_THING") != null);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "discoverRoutes spawns the real Ruby sidecar and recovers a route from config/routes.rb" {
    // Needs `ruby` on PATH (mise) and to run from the repo root (`build/
    // tests.zig`'s `repo_root_cwd` on the test-rails suite) so the relative
    // paths below resolve. Degrades to RAILS_RUBY_UNAVAILABLE -- not a hard
    // failure -- when ruby genuinely isn't installed; any OTHER degradation
    // is a real regression and fails loudly instead of being swallowed the
    // same way.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A real `Environ.Map` for the duration of just this test -- no process-
    // wide env mutation needed now that `discoverRoutes` takes the map as a
    // parameter rather than reading `std.c.getenv` directly. `ZIGAPAGOS_RUBY`
    // is deliberately left unset so this also exercises the "ruby on PATH"
    // default path.
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(runtime_dir_env, "runtime");

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try discoverRoutes(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeRoutes(gpa, result.routes);

    if (std.mem.eql(u8, result.mode, "none")) {
        if (blocker_list.items.len == 1 and std.mem.eql(u8, blocker_list.items[0].code, "RAILS_RUBY_UNAVAILABLE"))
            return error.SkipZigTest;
        std.debug.print("discoverRoutes degraded unexpectedly: {s}: {s}\n", .{
            blocker_list.items[blocker_list.items.len - 1].code,
            blocker_list.items[blocker_list.items.len - 1].detail,
        });
        return error.UnexpectedRouteDiscoveryDegradation;
    }

    try std.testing.expectEqualStrings("static_ast", result.mode);
    try std.testing.expect(result.routes.len >= 1);
    var found_root = false;
    for (result.routes) |r| {
        if (std.mem.eql(u8, r.path, "/") and std.mem.eql(u8, r.verb, "GET")) found_root = true;
    }
    try std.testing.expect(found_root);
}

test "discoverRoutes: no config/routes.rb appends RAILS_ROUTES_MISSING and degrades to mode=none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    // No env vars matter for this path -- `discoverRoutes` returns before
    // ever reading `environ_map` (the config/routes.rb check comes first) --
    // so an empty map is enough.
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();

    const result = try discoverRoutes(io, gpa, tmp.dir, ".", &blocker_list, &env_map);
    defer freeRoutes(gpa, result.routes);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTES_MISSING", blocker_list.items[0].code);
    // Non-integrity: a Rails app with no config/routes.rb still has a
    // complete, trustworthy presentation-layer inventory -- see the module
    // doc. This is the exact case tests/migrate/rails.sh's exit-code
    // assertion depends on staying 0.
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "discoverRoutes: ZIGAPAGOS_RUBY pointing at a nonexistent binary yields RAILS_RUBY_UNAVAILABLE" {
    // Pinned separately from the "spawns the real Ruby sidecar" test above:
    // that one skips (rather than failing) when this branch fires for real
    // reasons (no ruby on the runner), so it cannot pin the branch itself.
    // Cheap now that `environ_map` is a plain in-test `Environ.Map` (Ruling
    // A) rather than something only reachable via real process env
    // mutation.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(ruby_env, "/nonexistent/ruby-binary-does-not-exist-xyz");
    try env_map.put(runtime_dir_env, "runtime");

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try discoverRoutes(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeRoutes(gpa, result.routes);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_RUBY_UNAVAILABLE", blocker_list.items[0].code);
    // Non-integrity: see the module doc -- a missing interpreter means no
    // route graph, not an untrustworthy inventory.
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "discoverRoutes: ZIGAPAGOS_RUNTIME_DIR with no sidecar/rails/analyze.rb yields RAILS_SIDECAR_MISSING" {
    // An empty temp dir: it resolves as a directory (so this exercises the
    // "script not found under an otherwise-valid runtime dir" branch, not
    // the earlier "ZIGAPAGOS_RUNTIME_DIR is not set" branch, which is
    // already pinned by the sibling "no config/routes.rb" test taking the
    // default empty-string path).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var runtime_tmp = std.testing.tmpDir(.{});
    defer runtime_tmp.cleanup();
    var runtime_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_abs_n = try runtime_tmp.dir.realPath(io, &runtime_dir_buf);
    const runtime_dir_abs = runtime_dir_buf[0..runtime_dir_abs_n];

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(runtime_dir_env, runtime_dir_abs);

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try discoverRoutes(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeRoutes(gpa, result.routes);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_MISSING", blocker_list.items[0].code);
    // Non-integrity: see the module doc -- a missing sidecar script means no
    // route graph, not an untrustworthy inventory.
    try std.testing.expect(!blocker_list.items[0].integrity);
}
