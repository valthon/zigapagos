//! The Zig client for the Rails controller-shape sidecar op
//! (`runtime/sidecar/rails/analyze.rb`'s `"controllers"` op, backed by Task
//! 1's `runtime/sidecar/rails/controllers.rb`): locates Ruby and the
//! sidecar script, spawns a persistent-protocol process for exactly one
//! request/response pair, and folds the result into the discovery pass's
//! blocker list. Mirrors `routes.zig`'s shape closely -- same spawn helper
//! idiom, same `Environ.Map` parameter, same absolute-`root` contract, same
//! bounded wait -- because this file exists to answer the same kind of
//! question (what did the static AST find) over the same kind of transport.
//!
//! **Separate sidecar process, not a shared one.** The brief's efficiency
//! note asks for the `controllers` request to ride the SAME process
//! `discoverRoutes` already spawned for `routes`, saving one Ruby
//! interpreter start (~100ms). That is not done here: `discoverRoutes`
//! fully owns its child (spawn, one query, kill/wait) as a private,
//! self-contained sequence and never exposes the live `child` past its own
//! return -- there is no seam to hang a second request off of without
//! either changing its public signature (spawn separately of routes, hand
//! back a `*Child` for a caller to drive) or touching how it feeds/closes
//! stdin (`queryOnce` closes `child.stdin` immediately after writing the
//! one request, which is what lets analyze.rb's loop treat that close as
//! ordinary shutdown -- delaying it to allow a second request changes that
//! path). The ruling for this task is explicit that touching either of
//! those is out of bounds for this task, and that spawning a second sidecar
//! is a sanctioned outcome when sharing would require it. This file spawns
//! its own process instead of threading a live `child` through a modified
//! `discoverRoutes`.
//!
//! Every way this can fail -- no Ruby, no sidecar script, a spawn/exit/
//! response failure, or no `app/controllers/` -- degrades to a blocker
//! rather than a fatal, for the same reason `routes.zig`'s module doc gives:
//! a Rails app with no recovered action shape is still a useful inventory.
//! Unlike `routes.zig`'s four-way split, this file's degradation table (see
//! the brief) collapses every sidecar-side failure -- no Ruby, no script, a
//! spawn/exit/response failure, a malformed or `ok:false` response -- into
//! ONE code, `RAILS_CONTROLLERS_UNAVAILABLE`; only "the directory itself is
//! absent" gets its own code, `RAILS_CONTROLLERS_MISSING`, because that is
//! the one case where "the sidecar is fine but there is nothing to look at"
//! is a meaningfully different story from "the sidecar could not be asked".
//!
//! Both codes carry `integrity = false`: see `routes.zig`'s module doc for
//! why -- `discoverControllers` finding nothing changes only whether the
//! LATER classification rules that depend on action shape can fire (Stage
//! 3's rules 2/3), never whether `inventory.walk`'s presentation-layer
//! findings are trustworthy.
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` escapes this
//! directory, and `fatal.*` handling stays migrate.zig's job. The spawn/
//! resolve/watchdog/query plumbing (`resolveAbsRoot`, `killOnTimeout`,
//! `queryOnce`) lives in the sibling `sidecar_client.zig` and is imported
//! from there, NOT duplicated -- fix round 1 (task-2-fixes.md item 1)
//! extracted it after review found the two copies byte-identical apart from
//! `queryOnce`'s wire op string, which is now a parameter. That extraction
//! is a pure relocation of three already-private, self-contained helpers:
//! it changes neither `discoverRoutes`'s public signature nor its watchdog/
//! stdin-close semantics, so the ruling above (no touching `routes.zig` to
//! force PROCESS SHARING) still stands -- this file still spawns its OWN
//! sidecar process, it just no longer carries a second hand-copied
//! implementation of how to talk to one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const sidecar_client = @import("sidecar_client.zig");

// Every field defaults so a classifier test can write `.action = .{
// .renders_json = true }` and name only the field its case is about,
// instead of restating three irrelevant ones. Every PRODUCTION construction
// site (`dupeAction` below) still sets all four fields explicitly -- the
// defaults exist for tests only. The empty-string default is also the safe
// direction: an `ActionInfo` that ever ended up with an empty `controller`
// simply never matches in `find()` below, so the route falls through to
// `unresolved` rather than being silently misclassified.
pub const ActionInfo = struct {
    controller: []const u8 = "",
    action: []const u8 = "",
    only_redirect: bool = false,
    renders_json: bool = false,
};

/// Env var naming the Ruby interpreter to spawn; `ruby` on `PATH` when
/// unset or blank. See `routes.zig`'s identical constant for the full
/// rationale (`std.process.spawn` resolves a bare name against `PATH`
/// itself).
const ruby_env = "ZIGAPAGOS_RUBY";

/// The same variable `routes.zig` re-declares from `src/cli/release.zig`;
/// see that file's comment for why this is a re-declaration, not an import.
const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

// `resolveAbsRoot`, `killOnTimeout`, `queryOnce` moved to `sidecar_client.zig`
// (fix round 1, task-2-fixes.md item 1) -- see that file for their docs, and
// this file's module doc for why a SEPARATE process (not a shared one) is
// still spawned here. This is a pure relocation: no behavior changed.

const WireAction = struct {
    controller: []const u8,
    action: []const u8,
    only_redirect: bool,
    renders_json: bool,
    // `line` rides the wire (analyze.rb always sends it) but `ActionInfo`
    // has no field for it -- Stage 3's classification rules (the brief this
    // task serves) never need a line number, only the three structural
    // facts. `ignore_unknown_fields` on the decode below is what lets this
    // struct simply omit it rather than declaring and discarding it.
};

const WireUnresolved = struct {
    code: []const u8,
    /// The file this finding is about, relative to the app root (fix round
    /// B / B1) -- e.g. `"app/controllers/posts_controller.rb"`. Empty when
    /// absent (an older sidecar build, or a future code this build doesn't
    /// send a path for): `decodeResponse` falls back to `src_path` (the
    /// directory every controller finding used to share) in that case, same
    /// as before this field existed.
    path: []const u8 = "",
    detail: []const u8 = "",
    line: ?u64 = null,
};

const WireResponse = struct {
    ok: bool,
    actions: []const WireAction = &.{},
    unresolved: []const WireUnresolved = &.{},
    @"error": ?[]const u8 = null,
};

/// The known `unresolved[].code` vocabulary `runtime/sidecar/rails/
/// controllers.rb` and `analyze.rb`'s `handle_controllers` emit:
/// `RailsControllers.parse`'s own code for a file it read and rejected, and
/// `handle_controllers`'s own code (distinct since fix round B / B2) for a
/// file it never managed to read at all -- see that handler's own comment
/// for why those are not the same finding. Matched against rather than
/// trusting the JSON string directly, for the identical `Blocker.code`-
/// must-be-a-static-literal reason `routes.zig`'s `known_unresolved_codes`
/// documents.
const known_unresolved_codes = [_][]const u8{
    "RAILS_CONTROLLER_PARSE_ERROR",
    "RAILS_CONTROLLER_UNREADABLE",
};

/// Fallback for a code this build's table doesn't recognize. The real text
/// is not dropped -- `decodeResponse` folds it into the blocker's `detail`.
const unrecognized_unresolved_code = "RAILS_CONTROLLER_UNRESOLVED";

fn staticUnresolvedCode(json_code: []const u8) []const u8 {
    for (known_unresolved_codes) |c| {
        if (std.mem.eql(u8, c, json_code)) return c;
    }
    return unrecognized_unresolved_code;
}

/// Contract 2 (owned-result) helper for `decodeResponse`: every string
/// field of the returned `ActionInfo` is a fresh `gpa` allocation,
/// independent of `wa`'s backing JSON arena. On a mid-construction
/// allocation failure, `controller` is freed via `errdefer` before the
/// error propagates.
fn dupeAction(gpa: Allocator, wa: WireAction) Allocator.Error!ActionInfo {
    const controller = try gpa.dupe(u8, wa.controller);
    errdefer gpa.free(controller);
    const action = try gpa.dupe(u8, wa.action);
    return .{
        .controller = controller,
        .action = action,
        .only_redirect = wa.only_redirect,
        .renders_json = wa.renders_json,
    };
}

fn freeActionFields(gpa: Allocator, a: ActionInfo) void {
    gpa.free(a.controller);
    gpa.free(a.action);
}

/// Decodes one sidecar response LINE (`{"ok":true,"actions":[...],
/// "unresolved":[...]}` or `{"ok":false,"error":"..."}`) into `[]ActionInfo`.
/// Split out from `discoverControllers` so the JSON half is unit-testable
/// without spawning anything, mirroring `routes.zig`'s `decodeResponse`.
///
/// Contract 2 (owned-result): see `dupeAction`'s doc for the per-field
/// ownership story. `parsed.deinit()` frees the JSON tree the result was
/// decoded from before this function returns, so nothing in the returned
/// slice may alias it; `freeActions` is the matching release.
///
/// `unresolved` entries become blockers (`integrity = false` -- an action
/// shape the walk could not read is an expected finding about one file, not
/// a reason to distrust the whole recovered set) rather than being silently
/// dropped. A malformed line, or a well-formed `{"ok":false,...}`, both
/// collapse to a single `RAILS_CONTROLLERS_UNAVAILABLE` blocker (per the
/// brief's degradation table, every sidecar-side failure -- including a bad
/// response -- shares this one code) and an empty action slice.
///
/// Each `unresolved` entry's blocker gets its OWN `path` -- the file it is
/// about (`u.path`, relative to the app root) -- rather than the shared
/// `src_path` directory every controller finding used to collapse onto
/// (fix round B / B1: `path` should name the file the blocker is about,
/// same as `RAILS_TEMPLATE_UNREADABLE` already does). `src_path` remains
/// the fallback for an entry with no `path` (an older sidecar build, or the
/// `RAILS_CONTROLLERS_UNAVAILABLE` cases above that have no single file to
/// name).
fn decodeResponse(
    gpa: Allocator,
    line: []const u8,
    src_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error![]ActionInfo {
    var parsed = std.json.parseFromSlice(WireResponse, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", src_path, @errorName(err), false);
            return &.{};
        },
    };
    defer parsed.deinit();
    const resp = parsed.value;

    if (!resp.ok) {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", src_path, resp.@"error" orelse "sidecar reported failure", false);
        return &.{};
    }

    var actions = try gpa.alloc(ActionInfo, resp.actions.len);
    var filled: usize = 0;
    errdefer {
        for (actions[0..filled]) |a| freeActionFields(gpa, a);
        gpa.free(actions);
    }
    for (resp.actions, 0..) |wa, i| {
        actions[i] = try dupeAction(gpa, wa);
        filled = i + 1;
    }

    for (resp.unresolved) |u| {
        const code = staticUnresolvedCode(u.code);
        const recognized = !std.mem.eql(u8, code, unrecognized_unresolved_code);
        const blocker_path = if (u.path.len > 0) u.path else src_path;
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
        try blockers.append(gpa, blocker_list, code, blocker_path, detail, false);
    }

    return actions;
}

/// Contract 2 counterpart to `discoverControllers`/`decodeResponse`:
/// releases every owned string on every action (see `dupeAction`'s
/// ownership note) plus the slice itself. `only_redirect`/`renders_json`
/// are plain values with nothing to free. Matches `routes.zig`'s
/// `freeRoutes` ownership idiom, NOT `blockers.free` + a separate
/// `deinit()` -- this is the one release call for the whole slice.
pub fn freeActions(gpa: Allocator, actions: []ActionInfo) void {
    for (actions) |a| freeActionFields(gpa, a);
    gpa.free(actions);
}

/// Plain linear lookup, no allocation -- not one of NO_SLOP.md's §2.2a
/// allocator contracts because it takes no `Allocator` at all. `actions` is
/// typically small (one Rails app's worth of controller actions), so a
/// linear scan is not worth a hash map for Stage 3's per-route lookups.
/// Returns a copy of the matching `ActionInfo` (a plain-value struct whose
/// string fields alias `actions`' own storage, not new allocations) so the
/// caller cannot free through it independently of `actions`.
pub fn find(actions: []const ActionInfo, controller: []const u8, action: []const u8) ?ActionInfo {
    for (actions) |a| {
        if (std.mem.eql(u8, a.controller, controller) and std.mem.eql(u8, a.action, action)) return a;
    }
    return null;
}

/// Contract 2 (owned-result): every `ActionInfo.controller`/`.action` string
/// is a fresh `gpa`-owned allocation (see `dupeAction`'s doc); `freeActions`
/// is the matching release. `only_redirect`/`renders_json` are plain values.
///
/// Every failure mode -- Ruby not found, the sidecar script/runtime dir not
/// found, a spawn/exit/response failure, or no `app/controllers/` -- appends
/// exactly one blocker with `integrity = false` (see the module doc) and
/// returns an empty slice. This function's own error return stays
/// `Allocator.Error` only: every other failure degrades instead of
/// propagating, matching `routes.zig`'s `discoverRoutes`.
///
/// `app/controllers/`'s absence -- and, since fix round B / B3, its being
/// PRESENT but unreadable -- is detected HERE, client-side, via `openDir`
/// (not the bare `root.access` this used to be: `access`'s existence check
/// succeeds even when the directory's contents cannot be listed, since
/// resolving the path only needs search permission on its PARENT, not read
/// permission on the target itself -- so a `chmod 000 app/controllers` used
/// to sail through this check and on into the sidecar, whose own
/// `Dir.glob` swallows the resulting permission error and answers
/// `{"actions":[],"unresolved":[]}` -- indistinguishable from a genuinely
/// empty `app/controllers/`. `openDir` actually attempts to read the
/// directory, so it fails the same way `inventory.walk`'s own `openDir`
/// probe of `app/` does.) The same reasoning `routes.zig` gives for
/// checking `config/routes.rb` client-side rather than relying on
/// analyze.rb's own answer applies to both outcomes: each gets its own
/// blocker code (`RAILS_CONTROLLERS_MISSING` for `error.FileNotFound`,
/// `RAILS_CONTROLLERS_UNAVAILABLE` -- the same code every OTHER sidecar-side
/// degradation shares -- for anything else, chiefly `error.AccessDenied`)
/// and skips spawning Ruby entirely for an app this adapter already knows
/// has nothing usable to analyze. (analyze.rb's `handle_controllers` still
/// answers the ABSENT case correctly and structurally on its own --
/// `Dir.glob` against a nonexistent directory returns `[]` -- which is what
/// its own Ruby test pins; this client-side check is purely the "skip the
/// spawn" optimization for that one outcome, not a correctness requirement
/// analyze.rb relies on. The UNREADABLE case has no such fallback: without
/// this probe, that run silently reports zero actions with zero blockers,
/// which is exactly the "looks like a complete, controller-less app"
/// failure mode B3 exists to close.)
///
/// `environ_map` is threaded down the same way `routes.zig`'s
/// `discoverRoutes` receives it -- see that function's doc.
pub fn discoverControllers(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    root_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
    environ_map: *const std.process.Environ.Map,
) Allocator.Error![]ActionInfo {
    const none: []ActionInfo = &.{};

    var controllers_dir = root.openDir(io, "app/controllers", .{ .iterate = true }) catch |err| {
        const code = if (err == error.FileNotFound) "RAILS_CONTROLLERS_MISSING" else "RAILS_CONTROLLERS_UNAVAILABLE";
        try blockers.append(gpa, blocker_list, code, "app/controllers", @errorName(err), false);
        return none;
    };
    // Only a readability probe -- the actual walk happens Ruby-side via
    // `Dir.glob`, same division of labor as before this openDir replaced a
    // bare `access` call.
    controllers_dir.close(io);

    const ruby_path = environ_map.get(ruby_env) orelse "ruby";

    const runtime_dir_raw = environ_map.get(runtime_dir_env);
    const runtime_dir = if (runtime_dir_raw) |v| std.mem.trim(u8, v, " \t\r\n") else "";
    if (runtime_dir.len == 0) {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", "sidecar/rails/analyze.rb", "ZIGAPAGOS_RUNTIME_DIR is not set", false);
        return none;
    }

    const script_path = try std.fs.path.join(gpa, &.{ runtime_dir, "sidecar", "rails", "analyze.rb" });
    defer gpa.free(script_path);

    var script_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const script_abs_n = Io.Dir.cwd().realPathFile(io, script_path, &script_abs_buf) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", script_path, @errorName(err), false);
        return none;
    };
    const script_abs = script_abs_buf[0..script_abs_n];

    const abs_root = sidecar_client.resolveAbsRoot(io, gpa, root_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", root_path, @errorName(err), false);
            return none;
        },
    };
    defer gpa.free(abs_root);

    var child = std.process.spawn(io, .{
        .argv = &.{ ruby_path, script_abs },
        .stdin = .pipe,
        .stdout = .pipe,
        // stderr inherits the parent so a Ruby crash/backtrace is visible
        // in the build log, same as `routes.zig`.
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", ruby_path, @errorName(err), false);
            return none;
        },
    };

    var done: Io.Event = .unset;
    const watchdog: ?std.Thread = if (comptime !builtin.single_threaded)
        std.Thread.spawn(.{}, sidecar_client.killOnTimeout, .{ io, &child, &done }) catch null
    else
        null; // -Dsingle-threaded has no threads to spawn a watchdog on; see routes.zig's identical note.

    const query_result = sidecar_client.queryOnce(io, gpa, &child, "controllers", abs_root);

    // Stop the watchdog (if any) BEFORE touching `child` again below -- see
    // `sidecar_client.killOnTimeout`'s doc for why this ordering keeps
    // `child.kill`/`child.wait` single-threaded.
    done.set(io);
    if (watchdog) |t| t.join();

    const line = query_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            child.kill(io);
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", ruby_path, @errorName(err), false);
            return none;
        },
    };
    defer gpa.free(line);

    const term = child.wait(io) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", ruby_path, @errorName(err), false);
        return none;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            var buf: [48]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "ruby exited {d}", .{code}) catch "ruby exited nonzero";
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", ruby_path, detail, false);
            return none;
        },
        .signal, .stopped, .unknown => {
            try blockers.append(gpa, blocker_list, "RAILS_CONTROLLERS_UNAVAILABLE", ruby_path, "sidecar terminated abnormally", false);
            return none;
        },
    }

    return try decodeResponse(gpa, line, "app/controllers", blocker_list);
}

test "a sidecar response decodes into actions, preserving redirect/json flags" {
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2},
        \\{"controller":"admin/users","action":"create","only_redirect":true,"renders_json":false,"line":3}],
        \\"unresolved":[]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 2), res.len);
    try std.testing.expectEqualStrings("posts", res[0].controller);
    try std.testing.expectEqualStrings("index", res[0].action);
    try std.testing.expect(!res[0].only_redirect);
    try std.testing.expect(!res[0].renders_json);
    try std.testing.expectEqualStrings("admin/users", res[1].controller);
    try std.testing.expect(res[1].only_redirect);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "decodeResponse: an OOM at any point in a multi-row decode leaves no leak" {
    // Fix round 1, item 3 (task-2-fixes.md): review deleted decodeResponse's
    // partial-fill `errdefer` block outright and all 68 tests still passed
    // -- that guard was dead by this branch's standard. This test sweeps
    // EVERY allocation-failure point rather than hardcoding one `fail_index`:
    // the exact number of allocations `std.json.parseFromSlice` spends on
    // its internal arena before this function's own `gpa.alloc`/`dupeAction`
    // calls begin is a std.json implementation detail, not something this
    // test should hardcode and have silently stop meaning anything the next
    // time that shifts. Sweeping guarantees at least one iteration lands
    // squarely between two `dupeAction` calls -- i.e. genuinely "partway
    // through decoding a multi-row response", with one row's `ActionInfo`
    // already filled when the next allocation fails -- without this test
    // needing to know in advance which iteration that is.
    //
    // `std.testing.allocator`'s own leak detector is what actually proves
    // "no leak": every iteration runs allocations through it (via
    // `FailingAllocator`'s `internal_allocator`), and a missing `errdefer`
    // fails the WHOLE TEST through that detector -- not through an explicit
    // assertion this test has to write itself. See the mutation note in
    // task-2-fix-report.md for the observed red/green.
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2},
        \\{"controller":"admin/users","action":"create","only_redirect":true,"renders_json":false,"line":3},
        \\{"controller":"comments","action":"destroy","only_redirect":false,"renders_json":true,"line":9}],
        \\"unresolved":[]}
    ;

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        // Safety valve: a real decode of this line needs on the rough order
        // of 10-20 allocations (JSON-parse arena chunks plus one `gpa.alloc`
        // and two `dupeAction` dupes per row). 1000 is generous headroom
        // against that drifting with a future std.json change, while still
        // catching an infinite-sweep regression (e.g. `decodeResponse`
        // somehow never reaching a real success) as a test failure rather
        // than a hang.
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
        defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

        if (decodeResponse(failing.allocator(), line, "app/controllers", &blocker_list)) |actions| {
            defer freeActions(std.testing.allocator, actions);
            // `fail_index` finally exceeded every allocation this decode
            // needs: confirm it decoded correctly one last time, then the
            // sweep is done -- every earlier index already ran under the
            // leak detector above.
            try std.testing.expectEqual(@as(usize, 3), actions.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "an ok:false response becomes one RAILS_CONTROLLERS_UNAVAILABLE blocker and zero actions" {
    const line =
        \\{"ok":false,"error":"boom: NoMethodError"}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 0), res.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "a malformed response line becomes one RAILS_CONTROLLERS_UNAVAILABLE blocker and zero actions" {
    const line = "not json";
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 0), res.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
}

test "an unrecognized unresolved code is not dropped: it folds into detail under a static fallback code" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[{"code":"RAILS_CONTROLLER_FUTURE_THING","detail":"whatever","line":3}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLER_UNRESOLVED", blocker_list.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "RAILS_CONTROLLER_FUTURE_THING") != null);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "a recognized unresolved code (RAILS_CONTROLLER_PARSE_ERROR) becomes a blocker with that exact code" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[{"code":"RAILS_CONTROLLER_PARSE_ERROR","detail":"bad.rb: syntax error","line":7}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLER_PARSE_ERROR", blocker_list.items[0].code);
}

test "B1: an unresolved entry's own `path` becomes the blocker's `path`, not the shared directory `src_path`" {
    // Regression for final-fixes-B.md's B1: the controller blockers used to
    // put the DIRECTORY (`src_path`, e.g. "app/controllers") in `path` for
    // every finding, with the actual FILE buried inside `detail`'s text.
    // Exact-string equality on `.path` -- not merely `indexOf` on `.detail`
    // -- is what a reversion back to that shape would actually fail: an
    // `indexOf` check would still pass if the file happened to reappear
    // somewhere else in the string.
    const line =
        \\{"ok":true,"actions":[],"unresolved":[
        \\{"code":"RAILS_CONTROLLER_PARSE_ERROR","path":"app/controllers/posts_controller.rb","detail":"unexpected 'end'","line":3}
        \\]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", blocker_list.items[0].path);
    try std.testing.expectEqualStrings("unexpected 'end' (line 3)", blocker_list.items[0].detail);
}

test "an unresolved entry with no `path` (older sidecar shape) falls back to the shared src_path" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[{"code":"RAILS_CONTROLLER_PARSE_ERROR","detail":"bad.rb: syntax error","line":7}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqualStrings("app/controllers", blocker_list.items[0].path);
}

test "B2: RAILS_CONTROLLER_UNREADABLE is a recognized code, distinct from RAILS_CONTROLLER_PARSE_ERROR" {
    const line =
        \\{"ok":true,"actions":[],"unresolved":[
        \\{"code":"RAILS_CONTROLLER_UNREADABLE","path":"app/controllers/broken_controller.rb","detail":"Errno::EACCES: Permission denied","line":1}
        \\]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    // Exact code, not the `RAILS_CONTROLLER_UNRESOLVED` fallback -- proves
    // this code is in `known_unresolved_codes`, not merely tolerated.
    try std.testing.expectEqualStrings("RAILS_CONTROLLER_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/controllers/broken_controller.rb", blocker_list.items[0].path);
}

test "find matches on (controller, action) pair, not either alone" {
    const line =
        \\{"ok":true,"actions":[
        \\{"controller":"posts","action":"index","only_redirect":false,"renders_json":false,"line":2},
        \\{"controller":"posts","action":"show","only_redirect":true,"renders_json":false,"line":6},
        \\{"controller":"comments","action":"index","only_redirect":false,"renders_json":true,"line":9}],
        \\"unresolved":[]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "app/controllers", &blocker_list);
    defer freeActions(std.testing.allocator, res);

    const show = find(res, "posts", "show");
    try std.testing.expect(show != null);
    try std.testing.expect(show.?.only_redirect);

    const comments_index = find(res, "comments", "index");
    try std.testing.expect(comments_index != null);
    try std.testing.expect(comments_index.?.renders_json);

    // Same action name under a different controller must NOT match --
    // pins that the lookup keys on the PAIR, not `action` alone.
    try std.testing.expect(find(res, "comments", "show") == null);
    // Same controller, nonexistent action.
    try std.testing.expect(find(res, "posts", "destroy") == null);
}

test "discoverControllers spawns the real Ruby sidecar and recovers PostsController#index" {
    // Needs `ruby` on PATH (mise) and to run from the repo root, same
    // requirement `routes.zig`'s equivalent live-spawn test documents.
    // Degrades to a RAILS_CONTROLLERS_UNAVAILABLE blocker whose detail is
    // the bare `@errorName` `FileNotFound` (this file does not special-case
    // that error the way `routes.zig` attributes it to "not found on PATH"
    // -- see the module doc: every spawn-side failure collapses to one
    // code/detail-from-errorName here) -- not a hard failure -- when ruby
    // genuinely isn't installed; any OTHER degradation is a real
    // regression.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put(runtime_dir_env, "runtime");

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const actions = try discoverControllers(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeActions(gpa, actions);

    if (actions.len == 0 and blocker_list.items.len > 0) {
        if (blocker_list.items.len == 1 and
            std.mem.eql(u8, blocker_list.items[0].code, "RAILS_CONTROLLERS_UNAVAILABLE") and
            std.mem.eql(u8, blocker_list.items[0].detail, "FileNotFound"))
            return error.SkipZigTest;
        std.debug.print("discoverControllers degraded unexpectedly: {s}: {s}\n", .{
            blocker_list.items[blocker_list.items.len - 1].code,
            blocker_list.items[blocker_list.items.len - 1].detail,
        });
        return error.UnexpectedControllerDiscoveryDegradation;
    }

    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
    const posts_index = find(actions, "posts", "index");
    try std.testing.expect(posts_index != null);
    try std.testing.expect(!posts_index.?.only_redirect);
    try std.testing.expect(!posts_index.?.renders_json);
}

test "discoverControllers: no app/controllers/ appends RAILS_CONTROLLERS_MISSING and finds zero actions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    // No env vars matter for this path -- `discoverControllers` returns
    // before ever reading `environ_map` (the app/controllers check comes
    // first) -- so an empty map is enough.
    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();

    const actions = try discoverControllers(io, gpa, tmp.dir, ".", &blocker_list, &env_map);
    defer freeActions(gpa, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_MISSING", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "discoverControllers: app/controllers/ present but unreadable yields RAILS_CONTROLLERS_UNAVAILABLE, not silence" {
    // Regression for B3 (final-fixes-B.md): the whole-branch review's
    // degradation matrix found that a `chmod 000 app/controllers` used to
    // sail past the old `root.access` check (existence alone, not
    // readability) and on into the sidecar, whose own `Dir.glob` swallows
    // the permission error -- the run then reported ZERO actions and ZERO
    // controller-related blockers, indistinguishable from a genuinely
    // controller-less app. `openDir` (not `access`) is what actually
    // attempts to read the directory and surfaces the failure here.
    //
    // Same reliability caveat as inventory.zig's identical chmod tests:
    // skipped at comptime where `Permissions` isn't POSIX mode bits, and at
    // runtime if stripping permissions doesn't actually block the open
    // (root, or a sandboxed filesystem that ignores mode bits).
    if (!Io.Dir.Permissions.has_executable_bit) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var controllers_dir = try tmp.dir.createDirPathOpen(io, "app/controllers", .{ .open_options = .{ .iterate = true } });
    try controllers_dir.setPermissions(io, .fromMode(0));
    defer {
        controllers_dir.setPermissions(io, .fromMode(0o755)) catch {};
        controllers_dir.close(io);
    }

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();

    const actions = try discoverControllers(io, gpa, tmp.dir, ".", &blocker_list, &env_map);
    defer freeActions(gpa, actions);

    if (blocker_list.items.len == 0) {
        // Permission enforcement didn't actually block the open in this
        // environment -- nothing to assert.
        return error.SkipZigTest;
    }

    try std.testing.expectEqual(@as(usize, 0), actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/controllers", blocker_list.items[0].path);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "discoverControllers: ZIGAPAGOS_RUBY pointing at a nonexistent binary yields RAILS_CONTROLLERS_UNAVAILABLE" {
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

    const actions = try discoverControllers(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeActions(gpa, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "discoverControllers: ZIGAPAGOS_RUNTIME_DIR with no sidecar/rails/analyze.rb yields RAILS_CONTROLLERS_UNAVAILABLE" {
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

    const actions = try discoverControllers(io, gpa, app_dir, "tests/migrate/rails-sample", &blocker_list, &env_map);
    defer freeActions(gpa, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_CONTROLLERS_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
}
