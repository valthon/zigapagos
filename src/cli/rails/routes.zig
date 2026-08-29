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
//! Those same four codes are `severity = .@"error"` (Stage 4 Task 1),
//! DESPITE the paragraph above likening them to `RAILS_TEMPLATE_ENGINE_
//! UNSUPPORTED`. That comparison is about `integrity`/`--strict`, not
//! `severity`, and the two axes point opposite ways here on purpose: an
//! unsupported template engine is one file among many, correctly identified
//! -- the rest of the route graph is untouched. `RAILS_RUBY_UNAVAILABLE`/
//! `RAILS_SIDECAR_MISSING`/`RAILS_SIDECAR_FAILED`/`RAILS_ROUTES_MISSING`
//! mean route discovery never produced ANY graph at all -- every route this
//! run would otherwise classify is unresolved for lack of evidence, not
//! flagged as a scoped, known exception. A manifest consumer reading
//! `severity` needs that told apart from the `unresolved[].code` family
//! below (`RAILS_ROUTES_PARSE_ERROR` and the `RAILS_ROUTE_*` codes,
//! `severity = .warn`), which name ONE route the static walk correctly
//! identified as unresolvable while the rest of the graph came back intact.
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` escapes this
//! directory, and `fatal.*` handling stays migrate.zig's job. The spawn/
//! resolve/watchdog/query plumbing (`resolveAbsRoot`, `killOnTimeout`,
//! `queryOnce`) lives in the sibling `sidecar_client.zig` (fix round 1,
//! task-2-fixes.md item 1, moved there once `controllers.zig` needed the
//! identical logic) -- a pure relocation that changed neither this file's
//! public signature nor its watchdog/stdin-close semantics.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const sidecar_client = @import("sidecar_client.zig");

pub const Origin = enum { static_ast, actiondispatch, routes_import };

/// Where a route was declared -- the manifest's `routes[].source`
/// (spec, "The manifest"). `file` is always `"config/routes.rb"` today: the
/// only source this discovery stage reads (a `draw(:file)` reference to an
/// external routes file stays an `unresolved` entry rather than being
/// followed -- see `routes.rb`'s `draw_call`).
pub const Source = struct {
    file: []const u8,
    /// 1-based line of the route's OWN DSL call (`get`/`post`/the action
    /// expanded from a `resources` block/...), not the enclosing `draw`
    /// block's line and not the file's first/last line -- `routes.rb`'s
    /// `emit` passes `line_of(node)` for the specific call node each route
    /// came from, so two routes declared on different lines report
    /// different numbers.
    line: u64,
};

pub const Route = struct {
    verb: []const u8,
    path: []const u8,
    controller: ?[]const u8,
    action: ?[]const u8,
    /// Filled by `routes.rb`'s Mapper-faithful naming since #167 Stage 1;
    /// `null` when Rails itself would not name the route or when the route
    /// is `certain: false`.
    name: ?[]const u8,
    /// `false` when the parser found the route via a construct it could
    /// not fully evaluate (recorded as a paired `unresolved` entry --
    /// `decodeResponse` turns those into blockers) and is not vouching for
    /// this route being complete/accurate.
    certain: bool,
    origin: Origin,
    /// Defaults to a placeholder (`config/routes.rb` line 0) so the many
    /// hand-built `Route` literals in `rails.zig`'s and `report.zig`'s own
    /// tests -- which predate this field, exercise classification/reporting
    /// behavior that has nothing to do with source location, and are never
    /// routed through `freeRoutes` -- keep compiling without unrelated
    /// churn. Verified (Stage 4's task-2-fixes.md item 2), not merely
    /// assumed: `dupeRoute` is the ONLY site in this file that produces a
    /// `Route` ever passed to `freeRoutes`, and it sets `source` from the
    /// wire unconditionally -- so today, the default reaches test literals
    /// only.
    ///
    /// That is NOT a guarantee the type system enforces going forward. A
    /// second real producer -- `origin = .actiondispatch` or `.
    /// routes_import` (both currently unimplemented placeholders in
    /// `Origin`) are the likely candidates -- could construct a `Route`
    /// literal, omit `.source`, and silently inherit `line = 0` with no
    /// compile error: the default exists for TESTS, and nothing distinguishes
    /// a test literal from a future producer's literal at the type level.
    /// `line = 0` would then flow straight into the manifest (spec: every
    /// route's `source` is documented as present, not optional) as a
    /// plausible-looking but fabricated line number -- worse than an
    /// obviously-missing field, because nothing about it looks wrong. Any
    /// new `Route` producer MUST set `.source` explicitly from real
    /// evidence; this default is not a value to rely on outside a test.
    source: Source = .{ .file = "config/routes.rb", .line = 0 },
};

/// `discovery.ruby`'s per-op half (spec, "The manifest" documents the
/// COMBINED field; `rails.zig`'s `combineRuby` builds that from this and
/// `controllers.zig`'s identical `Result.ruby`): whether Ruby was available
/// to answer the `routes` op specifically, and which version. `available =
/// false` (`version = null`) on every path where Ruby/the sidecar never got
/// to run -- `discoverRoutes`'s own degradation branches build this
/// directly, since there is no running interpreter to ask. `available =
/// true` comes from the sidecar's OWN response (`analyze.rb`'s `RUBY_INFO`,
/// threaded through `WireResponse.ruby`): asking the process that just did
/// the work, rather than shelling out to `version_check.rb` a second time,
/// which could disagree with the interpreter that actually ran and wastes a
/// spawn either way.
///
/// Re-exported from `sidecar_client` (Stage 4's task-2-fixes.md item 1)
/// rather than declared here: `controllers.zig` needs the IDENTICAL type
/// and decode logic for its own, separate sidecar process, and two copies
/// would drift the same way `resolveAbsRoot`/`killOnTimeout`/`queryOnce`
/// already did before that extraction (see `sidecar_client.zig`'s module
/// doc). Nothing outside this file is known to reference `routes.Ruby`
/// today, but the alias keeps the name stable regardless.
pub const Ruby = sidecar_client.Ruby;

pub const Result = struct {
    /// Owned; release with `freeRoutes`.
    routes: []Route,
    /// Always a static string literal (`"static_ast"` when a response was
    /// successfully decoded, `"none"` on every degradation path) and is
    /// never freed.
    mode: []const u8,
    /// This op's own half of `discovery.ruby` -- see `Ruby`'s doc. NOT the
    /// final manifest value on its own: `rails.zig`'s `combineRuby` ORs
    /// this together with `controllers.Result.ruby` before either reaches a
    /// consumer, because `config/routes.rb` being absent (this op
    /// degrading to `available: false`) says nothing about whether the
    /// SEPARATE `controllers` op's Ruby process ran.
    ruby: Ruby,
};

/// Contract 2 counterpart to `decodeRuby`; re-exported from
/// `sidecar_client` for the same reason `Ruby` is -- see that alias's doc.
pub const freeRuby = sidecar_client.freeRuby;

/// Convenience wrapper releasing every owned piece of a `Result`
/// (`routes` via `freeRoutes`, `ruby.version` via `freeRuby`) in one call.
pub fn freeResult(gpa: Allocator, result: Result) void {
    freeRoutes(gpa, result.routes);
    freeRuby(gpa, result.ruby);
}

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

// `resolveAbsRoot`, `killOnTimeout`, `queryOnce` moved to `sidecar_client.zig`
// (fix round 1, task-2-fixes.md item 1) -- see that file for their docs. This is
// a pure relocation: no behavior here changed.

/// Contract 2 (owned-result): every `Route` field that is a string
/// (`verb`, `path`, `source.file`, and non-null `controller`/`action`/
/// `name`) is a fresh `gpa`-owned allocation -- `discoverRoutes`/
/// `decodeResponse` never let a `Route` alias the JSON tree it was decoded
/// from, because that tree is freed before either function returns.
/// `origin`, `certain`, and `source.line` are plain values with nothing to
/// free. `freeRoutes` is the matching release. `Result.ruby.version` is a
/// separate `gpa`-owned allocation released by `freeRuby`
/// (`freeResult` frees both in one call).
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
    // Every one of `discoverRoutes`'s own degradation branches returns this
    // literally -- Ruby/the sidecar never ran, so there is no interpreter to
    // ask and `ruby.available` is unconditionally `false` here. The success
    // path (below) overrides `.ruby` with whatever the sidecar's own
    // response reported instead.
    const none: Result = .{ .routes = &.{}, .mode = "none", .ruby = .{ .available = false, .version = null } };

    root.access(io, "config/routes.rb", .{}) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_ROUTES_MISSING", "config/routes.rb", @errorName(err), false, .@"error", null, null);
        return none;
    };

    const ruby_path = environ_map.get(ruby_env) orelse "ruby";

    const runtime_dir_raw = environ_map.get(runtime_dir_env);
    const runtime_dir = if (runtime_dir_raw) |v| std.mem.trim(u8, v, " \t\r\n") else "";
    if (runtime_dir.len == 0) {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_MISSING", "sidecar/rails/analyze.rb", "ZIGAPAGOS_RUNTIME_DIR is not set", false, .@"error", null, null);
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
        // R12 (fix round 1, task-8 review): `Blocker.path` is documented
        // app-root-relative and feeds the discovery report, so two machines
        // analysing the same app must produce the same bytes for it.
        // `script_path` is `$ZIGAPAGOS_RUNTIME_DIR` joined -- absolute on any
        // real install -- so it cannot go here. The static literal does; the
        // path actually attempted moves into free-text `detail`, which
        // carries no determinism contract. Same split the spawn branch below
        // already made for `ruby_path` (F3); this site had simply been
        // missed. Changed in `controllers.zig` and `fragments.zig` at the
        // same time so the three clients stay mirrors.
        var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s}: {t}", .{ script_path, err }) catch @errorName(err);
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_MISSING", "sidecar/rails/analyze.rb", detail, false, .@"error", null, null);
        return none;
    };
    const script_abs = script_abs_buf[0..script_abs_n];

    // analyze.rb's contract is an ABSOLUTE root (analyze.rb:44); resolve
    // root_path the same way `Sidecar.absSrc` resolves an island `src`.
    const abs_root = sidecar_client.resolveAbsRoot(io, gpa, root_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // R12, same reasoning as the site above: `root_path` is the
            // caller's own cwd-relative (or absolute) handle on the app, not
            // a path relative to the app root. `"."` IS the app-root-relative
            // name of the thing that could not be resolved -- the app root
            // itself -- and is identical on every machine; `root_path` moves
            // into `detail`.
            var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "{s}: {t}", .{ root_path, err }) catch @errorName(err);
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", ".", detail, false, .@"error", null, null);
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
            // `path` names the sidecar script, not `ruby_path` -- see this
            // function's own doc, "the absolute-interpreter-path leak, now
            // owned". `ZIGAPAGOS_RUBY` set to an absolute path would
            // otherwise put a machine-specific path into a field documented
            // "relative to the app root", and two machines with different
            // Ruby locations would then emit different manifest bytes for
            // this same blocker. The interpreter itself is still worth
            // naming -- it belongs in free-text `detail`, which carries no
            // such contract, not in the structured `path`.
            var buf: [Io.Dir.max_path_bytes + 64]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "interpreter '{s}' not found on PATH", .{ruby_path}) catch "interpreter not found on PATH";
            try blockers.append(gpa, blocker_list, "RAILS_RUBY_UNAVAILABLE", "sidecar/rails/analyze.rb", detail, false, .@"error", null, null);
            return none;
        },
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", "sidecar/rails/analyze.rb", @errorName(err), false, .@"error", null, null);
            return none;
        },
    };

    var done: Io.Event = .unset;
    const watchdog: ?std.Thread = if (comptime !builtin.single_threaded)
        // `catch null` rather than propagating a spawn failure: this thread is
        // pure defense-in-depth (see `sidecar_client.killOnTimeout`'s doc), so
        // losing it just means the wait below is unbounded again, not that
        // discovery should fail. `std.Thread.spawn` failing at all is a
        // resource-exhaustion edge case essentially never hit in practice, not
        // something this function has a better response to than "proceed
        // without the guard".
        std.Thread.spawn(.{}, sidecar_client.killOnTimeout, .{ io, &child, &done }) catch null
    else
        null; // -Dsingle-threaded has no threads to spawn a watchdog on; see CLAUDE.md's note on that gate.

    const query_result = sidecar_client.queryOnce(io, gpa, &child, "routes", abs_root);

    // Stop the watchdog (if any) BEFORE touching `child` again below -- see
    // `sidecar_client.killOnTimeout`'s doc for why this ordering is what keeps
    // `child.kill`/`child.wait` single-threaded.
    done.set(io);
    if (watchdog) |t| t.join();

    const line = query_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            child.kill(io);
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", "sidecar/rails/analyze.rb", @errorName(err), false, .@"error", null, null);
            return none;
        },
    };
    defer gpa.free(line);

    const term = child.wait(io) catch |err| {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", "sidecar/rails/analyze.rb", @errorName(err), false, .@"error", null, null);
        return none;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            var buf: [48]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "ruby exited {d}", .{code}) catch "ruby exited nonzero";
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", "sidecar/rails/analyze.rb", detail, false, .@"error", null, null);
            return none;
        },
        .signal, .stopped, .unknown => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", "sidecar/rails/analyze.rb", "sidecar terminated abnormally", false, .@"error", null, null);
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
    const decoded = try decodeResponse(gpa, line, "config/routes.rb", blocker_list);
    var mode: []const u8 = "static_ast";
    if (blocker_list.items.len > before and
        std.mem.eql(u8, blocker_list.items[blocker_list.items.len - 1].code, "RAILS_SIDECAR_FAILED"))
    {
        mode = "none";
    }
    return .{ .routes = decoded.routes, .mode = mode, .ruby = decoded.ruby };
}

const WireRoute = struct {
    verb: []const u8,
    path: []const u8,
    controller: ?[]const u8 = null,
    action: ?[]const u8 = null,
    name: ?[]const u8 = null,
    certain: bool,
    // `routes.rb`'s `emit` always sets this, but defaulting to `null`
    // (rather than making it required) matches the defensive convention
    // `controllers.zig`'s `WireAction.line` already uses for the identical
    // wire shape: never let a malformed/older sidecar response fail the
    // WHOLE decode over one missing optional field. `dupeRoute` falls back
    // to `0` in that case -- a degenerate value, not a route this walk
    // actually vouches for the line of.
    line: ?u64 = null,
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
    // Optional (not required) so a response from a hypothetically older
    // sidecar build, or the deliberately hand-written `"ok":false`/
    // malformed-line test literals below that predate this field, still
    // decode -- `decodeRuby` treats an absent `ruby` the same as an
    // explicit `available: false`.
    ruby: ?sidecar_client.WireRuby = null,
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
///
/// `src_path` is `decodeResponse`'s own `"config/routes.rb"` literal, duped
/// per-route into `source.file` rather than shared -- every `Route` string
/// field is independently `gpa`-owned (contract 2) so `freeRouteFields` can
/// release each one without knowing which other routes might alias it.
fn dupeRoute(gpa: Allocator, wr: WireRoute, src_path: []const u8) Allocator.Error!Route {
    const verb = try gpa.dupe(u8, wr.verb);
    errdefer gpa.free(verb);
    const path = try gpa.dupe(u8, wr.path);
    errdefer gpa.free(path);
    const controller: ?[]const u8 = if (wr.controller) |c| try gpa.dupe(u8, c) else null;
    errdefer if (controller) |c| gpa.free(c);
    const action: ?[]const u8 = if (wr.action) |a| try gpa.dupe(u8, a) else null;
    errdefer if (action) |a| gpa.free(a);
    const name: ?[]const u8 = if (wr.name) |n| try gpa.dupe(u8, n) else null;
    errdefer if (name) |n| gpa.free(n);
    const source_file = try gpa.dupe(u8, src_path);
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
        .source = .{ .file = source_file, .line = wr.line orelse 0 },
    };
}

fn freeRouteFields(gpa: Allocator, r: Route) void {
    gpa.free(r.verb);
    gpa.free(r.path);
    if (r.controller) |c| gpa.free(c);
    if (r.action) |a| gpa.free(a);
    if (r.name) |n| gpa.free(n);
    gpa.free(r.source.file);
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
///
/// `ruby` is decoded independent of `ok`: even an `{"ok":false,...}`
/// response (e.g. no `config/routes.rb`) still comes from a Ruby process
/// that genuinely ran and answered, so `analyze.rb` stamps `RUBY_INFO` on
/// every response, success or not -- see the module doc on `Ruby`. Only a
/// response this function could not decode AT ALL (the malformed-line
/// branch above) has no `ruby` to read, and falls back to `available:
/// false`.
const DecodedRoutes = struct {
    routes: []Route,
    ruby: Ruby,
};

fn decodeResponse(
    gpa: Allocator,
    line: []const u8,
    src_path: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!DecodedRoutes {
    var parsed = std.json.parseFromSlice(WireResponse, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", src_path, @errorName(err), false, .@"error", null, null);
            return .{ .routes = &.{}, .ruby = .{ .available = false, .version = null } };
        },
    };
    defer parsed.deinit();
    const resp = parsed.value;

    const ruby = try sidecar_client.decodeRuby(gpa, resp.ruby);
    errdefer sidecar_client.freeRuby(gpa, ruby);

    if (!resp.ok) {
        try blockers.append(gpa, blocker_list, "RAILS_SIDECAR_FAILED", src_path, resp.@"error" orelse "sidecar reported failure", false, .@"error", null, null);
        return .{ .routes = &.{}, .ruby = ruby };
    }

    var routes = try gpa.alloc(Route, resp.routes.len);
    var filled: usize = 0;
    errdefer {
        for (routes[0..filled]) |r| freeRouteFields(gpa, r);
        gpa.free(routes);
    }
    for (resp.routes, 0..) |wr, i| {
        routes[i] = try dupeRoute(gpa, wr, src_path);
        filled = i + 1;
    }

    // `route_id` stays `null` here, deliberately (Stage 4 Task 5): each `u`
    // describes a CONSTRUCT the Ruby-side parser could not statically
    // evaluate into a route at all (a dynamic `match`, a custom router
    // mount, ...) -- there is no `Route` in `routes` above for it to be
    // "the route for", recovered or otherwise. That is a different shape
    // from `rails.zig`'s `RAILS_TEMPLATE_UNREADABLE`/
    // `RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED`, which fire from INSIDE a
    // per-route classification loop with a real, already-recovered `Route`
    // in hand.
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
        try blockers.append(gpa, blocker_list, code, src_path, detail, false, .warn, null, u.line);
    }

    std.mem.sort(Route, routes, {}, routeLessThan);
    return .{ .routes = routes, .ruby = ruby };
}

/// Contract 2 counterpart to `discoverRoutes`/`decodeResponse`: releases
/// every owned string on every route -- including `source.file` -- (see
/// `dupeRoute`'s ownership note) plus the slice itself. `origin`, `certain`,
/// and `source.line` are plain values with nothing to free.
pub fn freeRoutes(gpa: Allocator, routes: []Route) void {
    for (routes) |r| freeRouteFields(gpa, r);
    gpa.free(routes);
}

test "a sidecar response decodes into routes, preserving certainty" {
    const line =
        \\{"ok":true,"routes":[
        \\{"verb":"GET","path":"/","controller":"home","action":"index","name":"root","certain":true,"line":2},
        \\{"verb":"GET","path":"/x","controller":null,"action":null,"name":null,"certain":false,"line":9}],
        \\"unresolved":[{"code":"RAILS_ROUTE_LOOP","detail":"each","line":12}],
        \\"ruby":{"available":true,"version":"3.3.6"}}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 2), res.routes.len);
    try std.testing.expectEqualStrings("GET", res.routes[0].verb);
    try std.testing.expect(res.routes[0].certain);
    try std.testing.expect(!res.routes[1].certain);
    // The wire response for "/" carries a fresh, independently-owned copy
    // of "config/routes.rb", not the caller's `src_path`.
    try std.testing.expectEqualStrings("config/routes.rb", res.routes[0].source.file);
    // Unresolved entries become blockers, not silence.
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_LOOP", blocker_list.items[0].code);
    // One route the static walk correctly identified as unresolvable, not a
    // wholesale discovery failure -- see the module doc's severity/integrity
    // contrast.
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
    // Stage 4 Task 8b: `u.line` off the wire must reach `Blocker.line`, not
    // be dropped on the way in (the third instance of that bug shape on
    // this feature -- see the task brief).
    try std.testing.expectEqual(@as(?u64, 12), blocker_list.items[0].line);
    // The sidecar's own response, not a second `version_check.rb` spawn.
    try std.testing.expect(res.ruby.available);
    try std.testing.expectEqualStrings("3.3.6", res.ruby.version.?);
}

// Discriminates the BLOCKER's own line, not a constant: an implementation
// that hardcodes `.line = null` (Task 8's pre-8b state -- `u.line` was
// decoded off the wire and then never threaded into the `Blocker`) passes
// every other test in this file, since none of them assert an unresolved
// entry's blocker carries a REAL, non-null line that differs from another
// one. This is the one that would catch it; the third case (no `line` key
// at all) proves the honest-null path still works, in the same test.
test "unresolved entries at different wire lines decode to different blocker.line values, and a lineless one is null" {
    const line =
        \\{"ok":true,"routes":[],
        \\"unresolved":[
        \\{"code":"RAILS_ROUTE_CONDITIONAL","detail":"first","line":5},
        \\{"code":"RAILS_ROUTE_CONDITIONAL","detail":"second","line":41},
        \\{"code":"RAILS_ROUTE_DYNAMIC_PATH","detail":"no line at all"}
        \\]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 3), blocker_list.items.len);
    try std.testing.expectEqual(@as(?u64, 5), blocker_list.items[0].line);
    try std.testing.expectEqual(@as(?u64, 41), blocker_list.items[1].line);
    try std.testing.expect(blocker_list.items[0].line != blocker_list.items[1].line);
    // No `line` key on the wire at all -- honestly `null`, not a fabricated
    // `1` and not accidentally reusing a sibling entry's value.
    try std.testing.expectEqual(@as(?u64, null), blocker_list.items[2].line);
}

// Discriminates the ROUTE's own line, not a constant: a decoder that just
// hardcodes `.line = 1` (or reuses the FIRST route's line for every route)
// passes every other test in this file, since none of them assert two
// DIFFERENT routes carry two DIFFERENT line numbers. This is the one that
// would catch it.
test "two routes at different wire lines decode to two different source.line values" {
    const line =
        \\{"ok":true,"routes":[
        \\{"verb":"GET","path":"/a","controller":"a","action":"index","name":null,"certain":true,"line":5},
        \\{"verb":"GET","path":"/b","controller":"b","action":"index","name":null,"certain":true,"line":41}],
        \\"unresolved":[]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 2), res.routes.len);
    // Sorted by (path, verb): "/a" then "/b", so index order matches wire
    // order here -- pin BOTH values, and that they differ from each other.
    try std.testing.expectEqual(@as(u64, 5), res.routes[0].source.line);
    try std.testing.expectEqual(@as(u64, 41), res.routes[1].source.line);
    try std.testing.expect(res.routes[0].source.line != res.routes[1].source.line);
}

test "an ok:false response becomes one RAILS_SIDECAR_FAILED blocker, zero routes, and still carries ruby info" {
    const line =
        \\{"ok":false,"error":"boom: NoMethodError","ruby":{"available":true,"version":"3.4.1"}}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 0), res.routes.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_FAILED", blocker_list.items[0].code);
    // Non-integrity: the sidecar failed, but that says nothing about
    // whether the rest of the inventory (which never touched this response)
    // is trustworthy -- see the module doc.
    try std.testing.expect(!blocker_list.items[0].integrity);
    // But it IS severity=.error: the route graph this call was supposed to
    // decode never materialized at all -- see the module doc's contrast with
    // the per-route unresolved codes above.
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // Ruby genuinely ran (it answered this very response) even though route
    // discovery itself failed -- the two are independent facts.
    try std.testing.expect(res.ruby.available);
    try std.testing.expectEqualStrings("3.4.1", res.ruby.version.?);
}

test "an ok:false response with no ruby key at all degrades ruby.available to false" {
    const line =
        \\{"ok":false,"error":"routes: \"root\" must be a non-empty string"}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expect(!res.ruby.available);
    try std.testing.expectEqual(@as(?[]const u8, null), res.ruby.version);
}

test "a malformed response line becomes one RAILS_SIDECAR_FAILED blocker, zero routes, and ruby.available false" {
    const line = "not json";
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 0), res.routes.len);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_FAILED", blocker_list.items[0].code);
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // No response was ever decoded at all -- no interpreter to vouch for.
    try std.testing.expect(!res.ruby.available);
}

test "routes decode sorted by (path, verb) regardless of wire order" {
    const line =
        \\{"ok":true,"routes":[
        \\{"verb":"POST","path":"/posts","controller":"posts","action":"create","name":null,"certain":true,"line":4},
        \\{"verb":"GET","path":"/posts","controller":"posts","action":"index","name":null,"certain":true,"line":3},
        \\{"verb":"GET","path":"/","controller":"home","action":"index","name":null,"certain":true,"line":2}],
        \\"unresolved":[]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 3), res.routes.len);
    try std.testing.expectEqualStrings("/", res.routes[0].path);
    try std.testing.expectEqualStrings("/posts", res.routes[1].path);
    try std.testing.expectEqualStrings("GET", res.routes[1].verb);
    try std.testing.expectEqualStrings("/posts", res.routes[2].path);
    try std.testing.expectEqualStrings("POST", res.routes[2].verb);
}

test "an unrecognized unresolved code is not dropped: it folds into detail under a static fallback code" {
    const line =
        \\{"ok":true,"routes":[],"unresolved":[{"code":"RAILS_ROUTE_FUTURE_THING","detail":"whatever","line":3}]}
    ;
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const res = try decodeResponse(std.testing.allocator, line, "config/routes.rb", &blocker_list);
    defer freeRoutes(std.testing.allocator, res.routes);
    defer freeRuby(std.testing.allocator, res.ruby);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_UNRESOLVED", blocker_list.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "RAILS_ROUTE_FUTURE_THING") != null);
    try std.testing.expect(!blocker_list.items[0].integrity);
    // The fallback bucket is still a per-route finding, not a wholesale
    // failure -- warn, same as every other member of the unresolved family.
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
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
    defer freeResult(gpa, result);

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

    // The real Ruby process that answered this request knows its own
    // version -- captured from analyze.rb's response, not a second spawn of
    // version_check.rb (see the module doc on `Ruby`).
    try std.testing.expect(result.ruby.available);
    try std.testing.expect(result.ruby.version != null);
    try std.testing.expect(result.ruby.version.?.len > 0);

    // `tests/migrate/rails-sample/config/routes.rb` declares `root` on
    // line 2 and `get "/posts/old", ...` on line 10 -- two routes at two
    // KNOWN, DIFFERENT lines, from a real Prism parse (not a JSON literal
    // this test wrote by hand). Pinning both, and that they differ, is what
    // catches an implementation that reports the enclosing `draw` block's
    // line (1) or a constant for every route.
    var found_root = false;
    var found_old = false;
    for (result.routes) |r| {
        if (std.mem.eql(u8, r.path, "/") and std.mem.eql(u8, r.verb, "GET")) {
            found_root = true;
            try std.testing.expectEqualStrings("config/routes.rb", r.source.file);
            try std.testing.expectEqual(@as(u64, 2), r.source.line);
        }
        if (std.mem.eql(u8, r.path, "/posts/old") and std.mem.eql(u8, r.verb, "GET")) {
            found_old = true;
            try std.testing.expectEqual(@as(u64, 10), r.source.line);
        }
    }
    try std.testing.expect(found_root);
    try std.testing.expect(found_old);
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
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_ROUTES_MISSING", blocker_list.items[0].code);
    // Non-integrity: a Rails app with no config/routes.rb still has a
    // complete, trustworthy presentation-layer inventory -- see the module
    // doc. This is the exact case tests/migrate/rails.sh's exit-code
    // assertion depends on staying 0.
    try std.testing.expect(!blocker_list.items[0].integrity);
    // But severity=.error: discovery never produced ANY route graph here.
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // Ruby never even got spawned on this path -- `discovery.ruby` must
    // say so, not silently report `available: true` from some stale value.
    try std.testing.expect(!result.ruby.available);
    try std.testing.expectEqual(@as(?[]const u8, null), result.ruby.version);
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
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_RUBY_UNAVAILABLE", blocker_list.items[0].code);
    // F3 (phase-2-review.md): `path` must name the sidecar script, never
    // the machine-specific `ZIGAPAGOS_RUBY` value -- an absolute
    // interpreter path here would make two machines with different Ruby
    // locations emit different manifest bytes for the same blocker. The
    // interpreter is still named, but only in free-text `detail`.
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", blocker_list.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "/nonexistent/ruby-binary-does-not-exist-xyz") != null);
    // Non-integrity: see the module doc -- a missing interpreter means no
    // route graph, not an untrustworthy inventory.
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // The spawn itself failed (ENOENT) -- no interpreter ever ran to answer
    // with a version.
    try std.testing.expect(!result.ruby.available);
}

test "discoverRoutes: config/routes.rb present but ZIGAPAGOS_RUNTIME_DIR unset yields RAILS_SIDECAR_MISSING (the runtime_dir.len == 0 branch)" {
    // Fix round 1 (task-1-fixes.md item 1): the sibling test below claimed
    // this branch was "already pinned by" the "no config/routes.rb" test,
    // which is false -- that test returns at the EARLIER `root.access`
    // check on a missing `config/routes.rb`, with a different code
    // (RAILS_ROUTES_MISSING), and never reaches `runtime_dir.len == 0` at
    // all. This test is what actually reaches it: `config/routes.rb` exists
    // (so the earlier check passes), and `environ_map` has no
    // `ZIGAPAGOS_RUNTIME_DIR` entry at all (so `environ_map.get` returns
    // `null`, `runtime_dir` resolves to `""`, and `runtime_dir.len == 0`
    // fires) -- distinct from the sibling test below, which sets
    // `ZIGAPAGOS_RUNTIME_DIR` to a valid, non-empty directory that merely
    // lacks the sidecar script, reaching `realPathFile`'s failure instead.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config_dir = try tmp.dir.createDirPathOpen(io, "config", .{});
    config_dir.close(io);
    const routes_rb = try tmp.dir.createFile(io, "config/routes.rb", .{});
    routes_rb.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();

    const result = try discoverRoutes(io, gpa, tmp.dir, ".", &blocker_list, &env_map);
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_MISSING", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", blocker_list.items[0].path);
    try std.testing.expectEqualStrings("ZIGAPAGOS_RUNTIME_DIR is not set", blocker_list.items[0].detail);
    // Non-integrity: see the module doc -- a missing runtime dir means no
    // route graph, not an untrustworthy inventory.
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // Never got as far as locating the sidecar script, let alone spawning
    // Ruby.
    try std.testing.expect(!result.ruby.available);
}

test "discoverRoutes: ZIGAPAGOS_RUNTIME_DIR with no sidecar/rails/analyze.rb yields RAILS_SIDECAR_MISSING" {
    // An empty temp dir: it resolves as a directory (so this exercises the
    // "script not found under an otherwise-valid runtime dir" branch --
    // ZIGAPAGOS_RUNTIME_DIR set to a real, non-empty path whose
    // sidecar/rails/analyze.rb doesn't exist). The EARLIER "ZIGAPAGOS_
    // RUNTIME_DIR is not set" branch (`runtime_dir.len == 0`) is a
    // different code path through the SAME `if` and is pinned by the
    // sibling test just above this one, not by "no config/routes.rb" (fix
    // round 1: that claim was false -- see that test's own comment).
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
    defer freeResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 0), result.routes.len);
    try std.testing.expectEqualStrings("none", result.mode);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_SIDECAR_MISSING", blocker_list.items[0].code);
    // R12 (fix round 1, task-8 review): `path` is the machine-stable
    // literal, never the absolute `script_path` this run actually tried --
    // that string is machine-specific and would make the same app produce
    // different report bytes on two machines. It is not lost: it moves into
    // `detail`, which carries no determinism contract.
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", blocker_list.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, runtime_dir_abs) != null);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "FileNotFound") != null);
    // Non-integrity: see the module doc -- a missing sidecar script means no
    // route graph, not an untrustworthy inventory.
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.@"error", blocker_list.items[0].severity);
    // The sidecar script itself doesn't exist -- nothing was ever spawned.
    try std.testing.expect(!result.ruby.available);
}
