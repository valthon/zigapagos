//! Package root for the Rails migration adapter, and the `standalone` test
//! suite root for `zig build test-rails`.
//!
//! Everything below is std-only: no import escapes `src/cli/rails/`, so this
//! compiles as its own module. `fatal.*` handling belongs to migrate.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const blockers = @import("blockers.zig");
pub const classify = @import("classify.zig");
pub const detect = @import("detect.zig");
pub const inventory = @import("inventory.zig");
pub const integrations = @import("integrations.zig");
pub const report = @import("report.zig");
pub const routes = @import("routes.zig");
pub const controllers = @import("controllers.zig");
pub const sidecar_client = @import("sidecar_client.zig");
pub const template_scan = @import("template_scan.zig");

// Pulls the suites of every sibling file into this module so `test-rails`
// runs them all. Without this the standalone binary never sees them --
// `_ = sidecar_client` is required here even though that file currently has
// no `test` blocks of its own: without the `_ =` reference this module's
// lazy analysis (Zig 0.16) never reaches `sidecar_client.zig`'s decls at
// all, so a test ADDED there later would silently not run either.
test {
    std.testing.refAllDecls(@This());
    _ = blockers;
    _ = classify;
    _ = detect;
    _ = inventory;
    _ = integrations;
    _ = report;
    _ = routes;
    _ = controllers;
    _ = sidecar_client;
    _ = template_scan;
}

/// Discovery's result: the rendered report plus how many of its blockers mean
/// the inventory itself can't be trusted (`Blocker.integrity`).
/// `src/cli/migrate.zig`'s Rails block turns a nonzero
/// `integrity_blocker_count` into a non-zero exit -- the report is still
/// written either way, per the "report, never omit silently" rule; only the
/// process exit status changes.
pub const Discovery = struct {
    report: []const u8,
    integrity_blocker_count: usize,
    /// Count of routes actually rendered into `report`
    /// (`route_result.routes.len`). `src/cli/migrate.zig`'s CLI summary line
    /// reads this to say accurately whether any routes were recovered,
    /// rather than re-parsing `report`'s markdown or hardcoding either
    /// story -- a run with no Ruby/sidecar/`config/routes.rb` recovers zero
    /// routes just as validly as one that ran the sidecar and found none.
    route_count: usize,
    /// `routes.Result.mode` passed straight through (`"static_ast"` when
    /// the sidecar answered, `"none"` on every degradation path).
    /// `migrate.zig`'s CLI summary needs this -- alongside `route_blocker`
    /// below -- to reach the SAME three-way zero-route conclusion
    /// `report.zig`'s Routes section reaches, so the report and the
    /// one-line CLI summary a user sees never disagree about why zero
    /// routes were recovered.
    route_mode: []const u8,
    /// True when `blocker_list` (freed before this struct is returned)
    /// contained at least one route-discovery-related blocker
    /// (`blockers.isRouteRelated`) -- i.e. discovery ran but hit a
    /// construct it could not resolve, as opposed to `config/routes.rb`
    /// genuinely declaring no routes. Computed here because `migrate.zig`
    /// only ever receives this `Discovery`, never the blocker list itself.
    route_blocker: bool,
};

/// Contract 1 (self-freeing): every intermediate (entries, blockers,
/// integrations, file reads) is released here; the returned markdown is the
/// single escaping allocation and belongs to the caller.
pub fn discover(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    app_path: []const u8,
    environ_map: *const std.process.Environ.Map,
) Allocator.Error!Discovery {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    // Canonical release (fix round B / B8): every `Blocker` here was
    // appended via `blockers.append`/`appendCopy`, so `path`/`detail` are
    // always fresh `gpa` allocations and `code` is always a static literal
    // -- exactly what `blockers.free` expects. This used to be the one
    // remaining hand-rolled release on this branch (a loop freeing
    // `path`/`detail` plus a bare `.deinit(gpa)`); functionally identical,
    // but every other site on this branch already uses the one-call form.
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const wr = try inventory.walk(io, gpa, root);
    defer inventory.freeWalkResult(gpa, wr);
    // `wr.blockers` is owned by `wr` and freed by `freeWalkResult` above, so
    // its contents are copied into the run's single blocker list rather than
    // the slice being adopted directly.
    for (wr.blockers) |b| try blockers.appendCopy(gpa, &blocker_list, b);
    try inventory.appendUnsupportedEngineBlockers(gpa, wr.entries, &blocker_list);

    const gemfile = try detect.readCapped(io, gpa, root, "Gemfile", "RAILS_GEMFILE_UNREADABLE", &blocker_list);
    defer if (gemfile) |g| gpa.free(g);
    const pkg = try detect.readCapped(io, gpa, root, "package.json", "RAILS_PACKAGE_JSON_UNREADABLE", &blocker_list);
    defer if (pkg) |p| gpa.free(p);

    const ints = try integrations.scan(gpa, gemfile, pkg, &blocker_list);
    defer integrations.freeIntegrations(gpa, ints);

    // Route discovery threads the SAME blocker_list: every degradation path
    // it can hit (missing Ruby, missing sidecar, a spawn/response failure,
    // no config/routes.rb) appends here rather than failing this function,
    // so `integrity_blocker_count` below already accounts for it.
    const route_result = try routes.discoverRoutes(io, gpa, root, app_path, &blocker_list, environ_map);
    defer routes.freeRoutes(gpa, route_result.routes);

    // Controller-action shape threads the SAME blocker_list too, for the
    // identical reason: every degradation path (no Ruby, no sidecar, no
    // app/controllers/, a spawn/response failure) appends a non-integrity
    // blocker instead of failing this function -- see controllers.zig's
    // module doc.
    //
    // `blockers_before_controllers` brackets the blockers THIS call adds,
    // so `controllerEvidenceAvailable` below can tell "controller-shape
    // discovery degraded wholesale" (a `RAILS_CONTROLLERS_MISSING`/
    // `RAILS_CONTROLLERS_UNAVAILABLE` blocker appended HERE) apart from an
    // unrelated blocker any other pass appended -- see classify.zig's
    // `Input.controller_evidence_available` doc for why that distinction
    // decides whether rule 2 may rest a verdict on `action == null`.
    const blockers_before_controllers = blocker_list.items.len;
    const actions = try controllers.discoverControllers(io, gpa, root, app_path, &blocker_list, environ_map);
    defer controllers.freeActions(gpa, actions);
    const controller_evidence_available = controllerEvidenceAvailable(blocker_list.items[blockers_before_controllers..]);

    // Stage 3's join: one classify.Verdict per route, index-aligned with
    // route_result.routes. See classifyRoutes's own doc for why template
    // bytes must stay alive across the classify.classify call that borrows
    // from them, not just across the read.
    const classifications = try classifyRoutes(
        io,
        gpa,
        root,
        wr.entries,
        route_result.routes,
        actions,
        controller_evidence_available,
        &blocker_list,
    );
    defer gpa.free(classifications);

    var integrity_blocker_count: usize = 0;
    var route_blocker = false;
    for (blocker_list.items) |b| {
        if (b.integrity) integrity_blocker_count += 1;
        if (blockers.isRouteRelated(b.code)) route_blocker = true;
    }

    const body = try report.build(gpa, .{
        .app_path = app_path,
        .entries = wr.entries,
        .integrations = ints,
        .blockers = blocker_list.items,
        .routes = route_result.routes,
        .route_mode = route_result.mode,
        .classifications = classifications,
    });
    return .{
        .report = body,
        .integrity_blocker_count = integrity_blocker_count,
        .route_count = route_result.routes.len,
        .route_mode = route_result.mode,
        .route_blocker = route_blocker,
    };
}

/// True unless `controller_blockers` -- the slice of blockers
/// `controllers.discoverControllers` appended for THIS run (see
/// `discover`'s `blockers_before_controllers` slicing) -- contains a
/// `RAILS_CONTROLLERS_MISSING` or `RAILS_CONTROLLERS_UNAVAILABLE` code: the
/// two codes `discoverControllers` emits ONLY on a wholesale degradation
/// (see that function's own doc -- every such path appends exactly one of
/// these and returns zero actions). Matched by exact code rather than the
/// `RAILS_CONTROLLERS_` prefix `blockers.isRouteRelated` uses for a
/// different purpose: a per-FILE finding within an otherwise-successful run
/// (`RAILS_CONTROLLER_PARSE_ERROR`, `RAILS_CONTROLLER_UNRESOLVED` --
/// singular "CONTROLLER", not plural) is not wholesale degradation and must
/// not flip this signal; see classify.zig's `Input.controller_evidence_
/// available` doc for why that distinction matters. Contract 3
/// (caller-buffer): allocates nothing.
fn controllerEvidenceAvailable(controller_blockers: []const blockers.Blocker) bool {
    for (controller_blockers) |b| {
        if (std.mem.eql(u8, b.code, "RAILS_CONTROLLERS_MISSING")) return false;
        if (std.mem.eql(u8, b.code, "RAILS_CONTROLLERS_UNAVAILABLE")) return false;
    }
    return true;
}

/// Matches `path` against `app/views/<controller>/<action>.*` without
/// allocating: `controller` may itself contain a `/` (a namespaced
/// controller's PATH key, e.g. `admin/users`, which is what
/// `discoverControllers` keys `ActionInfo.controller` on), so this is a
/// plain prefix/segment check, not a `std.fs.path.join` + compare. The
/// trailing `.` check on `after_action` guards against `action` being a
/// prefix of a longer sibling action's basename (e.g. action "show" must
/// not match a file named "shower.html.erb"). Contract 3 (caller-buffer):
/// allocates nothing.
fn matchesRouteView(path: []const u8, controller: []const u8, action: []const u8) bool {
    const views_prefix = "app/views/";
    if (!std.mem.startsWith(u8, path, views_prefix)) return false;
    const rest = path[views_prefix.len..];
    if (!std.mem.startsWith(u8, rest, controller)) return false;
    const after_controller = rest[controller.len..];
    if (after_controller.len == 0 or after_controller[0] != '/') return false;
    const after_slash = after_controller[1..];
    if (!std.mem.startsWith(u8, after_slash, action)) return false;
    const after_action = after_slash[action.len..];
    return after_action.len > 0 and after_action[0] == '.';
}

/// Resolves the ONE view template that answers `controller#action`, among
/// possibly several candidate extensions `inventory.walk` found under
/// `app/views/<controller>/<action>.*` (kind `.view` or `.mailer_view`).
///
/// An `.html.*` match wins whenever one exists (checked via the literal
/// substring `".html."`, matching the brief's "prefer an .html.* match").
/// When the only match is a `.json.jbuilder`/`.xml.builder` file, this
/// returns `null` rather than that entry: a jbuilder/builder template
/// renders JSON/XML, not HTML, so treating it as "the view" would hand
/// `classify` a `ViewRef` it can only read through rule 4 as "unsupported
/// template engine, never converted" -- exactly the wrong story for what is
/// actually an API response. Returning `null` here makes the route look
/// like it has no view at all, which IS the honest state for `classify`'s
/// purposes: with no recovered action either, rule 2's existing `view ==
/// null and action == null` clause already reaches `backend`; with an
/// action recovered, the route falls through to the `in.view orelse` guard
/// ABOVE rule 4 -- "no view template to classify" -> `unresolved` (fix
/// round B / B6: this is not rule 7's own gate, which returns a different
/// reason) -- rather than a misleading unsupported-engine verdict. See
/// classify.zig's module doc for why that distinction (missing evidence vs.
/// a real negative finding) matters.
///
/// Contract 3 (caller-buffer): allocates nothing, returns a shallow copy of
/// the matching `Entry` (whose `path` string aliases `entries`' own
/// storage, same as `controllers.find`'s return).
fn resolveViewEntry(entries: []const inventory.Entry, controller: []const u8, action: []const u8) ?inventory.Entry {
    var html_match: ?inventory.Entry = null;
    var other_match: ?inventory.Entry = null;
    for (entries) |e| {
        if (e.kind != .view and e.kind != .mailer_view) continue;
        if (!matchesRouteView(e.path, controller, action)) continue;
        if (e.engine == .jbuilder or e.engine == .builder) continue;
        if (std.mem.indexOf(u8, e.path, ".html.") != null) {
            if (html_match == null) html_match = e;
        } else if (other_match == null) {
            other_match = e;
        }
    }
    return html_match orelse other_match;
}

/// Directory portion of a template's own path, e.g.
/// "app/views/posts/index.html.erb" -> "app/views/posts" -- the base a
/// no-slash `render` target (e.g. `"post"`) resolves relative to. Contract
/// 3 (caller-buffer): returns a slice into `path`, allocates nothing.
fn templateDirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[0..slash];
}

/// True when `path` (a `.layout`-kind entry) is the layout named `name`
/// under `app/views/layouts/` -- e.g. `name == "posts"` matches
/// `app/views/layouts/posts.html.erb`, `name == "admin/users"` matches
/// `app/views/layouts/admin/users.html.erb`. Mirrors `matchesRouteView`'s
/// segment-check style (plain prefix + trailing-dot check, not a
/// `std.fs.path.join` + compare) for the identical reason: `name` may
/// itself contain '/' (a namespaced controller's path key). Contract 3
/// (caller-buffer): allocates nothing.
fn matchesLayoutName(path: []const u8, name: []const u8) bool {
    const prefix = "app/views/layouts/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const rest = path[prefix.len..];
    if (!std.mem.startsWith(u8, rest, name)) return false;
    const after = rest[name.len..];
    return after.len > 0 and after[0] == '.';
}

fn matchesLayoutFor(entries: []const inventory.Entry, name: []const u8) ?inventory.Entry {
    var html_match: ?inventory.Entry = null;
    var other_match: ?inventory.Entry = null;
    for (entries) |e| {
        if (e.kind != .layout) continue;
        if (!matchesLayoutName(e.path, name)) continue;
        if (std.mem.indexOf(u8, e.path, ".html.") != null) {
            if (html_match == null) html_match = e;
        } else if (other_match == null) {
            other_match = e;
        }
    }
    return html_match orelse other_match;
}

/// Resolves the layout Rails would apply to `controller`, by CONVENTION:
/// prefer a per-controller layout (`app/views/layouts/<controller>.html.*`),
/// else the app-wide default (`app/views/layouts/application.html.*`). This
/// is a convention, not a `layout` declaration read from the controller's
/// source -- reading that needs deeper controller analysis out of scope for
/// this stage (see A1's brief); convention is the honest approximation and
/// is right for the overwhelming majority of Rails apps. Returns `null`
/// when neither exists -- a route still classifies on its view's (and any
/// resolved partials') markers alone in that case, same as before this
/// function existed.
///
/// Contract 3 (caller-buffer): allocates nothing, returns a shallow copy of
/// the matching `Entry`, same as `resolveViewEntry`.
fn resolveLayoutEntry(entries: []const inventory.Entry, controller: []const u8) ?inventory.Entry {
    return matchesLayoutFor(entries, controller) orelse matchesLayoutFor(entries, "application");
}

fn matchesPartialBasename(rest: []const u8, name: []const u8) bool {
    if (rest.len == 0 or rest[0] != '_') return false;
    const after_underscore = rest[1..];
    if (!std.mem.startsWith(u8, after_underscore, name)) return false;
    const after_name = after_underscore[name.len..];
    return after_name.len > 0 and after_name[0] == '.';
}

/// True when `path` is the partial that a `render` call's literal `target`
/// (found in a template whose own directory is `containing_dir`, e.g.
/// "app/views/posts") resolves to, by Rails' partial-path convention: a
/// target containing '/' is relative to `app/views/` itself (`"shared/nav"`
/// -> `app/views/shared/_nav.*`); a target with no '/' is relative to the
/// CURRENT template's own directory (`"post"` in a template under
/// `app/views/posts/` -> `app/views/posts/_post.*`). Contract 3
/// (caller-buffer): allocates nothing -- a segment/boundary comparison
/// directly against `path`, mirroring `matchesRouteView`'s style, rather
/// than building the candidate path string to compare against.
fn matchesPartialTarget(path: []const u8, containing_dir: []const u8, target: []const u8) bool {
    const views_prefix = "app/views/";
    if (!std.mem.startsWith(u8, path, views_prefix)) return false;
    const rest = path[views_prefix.len..]; // e.g. "posts/_post.html.erb"

    var dir: []const u8 = undefined;
    var name: []const u8 = undefined;
    if (std.mem.lastIndexOfScalar(u8, target, '/')) |slash| {
        dir = target[0..slash];
        name = target[slash + 1 ..];
    } else {
        if (!std.mem.startsWith(u8, containing_dir, views_prefix)) return false;
        dir = containing_dir[views_prefix.len..];
        name = target;
    }

    if (dir.len == 0) return matchesPartialBasename(rest, name);
    if (!std.mem.startsWith(u8, rest, dir)) return false;
    const after_dir = rest[dir.len..];
    if (after_dir.len == 0 or after_dir[0] != '/') return false;
    return matchesPartialBasename(after_dir[1..], name);
}

/// Contract 3 (caller-buffer): linear scan, no allocation. Returns a
/// shallow copy of the matching `Entry`, same as `resolveViewEntry`.
fn resolvePartialTarget(entries: []const inventory.Entry, containing_dir: []const u8, target: []const u8) ?inventory.Entry {
    for (entries) |e| {
        if (e.kind != .partial) continue;
        if (matchesPartialTarget(e.path, containing_dir, target)) return e;
    }
    return null;
}

/// Depth cap for the `render partial:`/bare-string/`render @x` chain
/// `transitiveScan` follows: the resolved view and its resolved layout are
/// both depth 0 (siblings, not nested -- see `transitiveScan`'s doc); a
/// partial either of them renders is depth 1; a partial a depth-1 partial
/// renders is depth 2; a partial a depth-2 partial renders is depth 3.
/// Beyond that, `transitiveScan` stops resolving further renders from that
/// node and reports it rather than silently truncating (A1's brief: "emit
/// a blocker if it is ever hit rather than silently stopping"). Three hops
/// of PARTIAL nesting (not counting the view/layout depth-0 pair) covers
/// the realistic worst case in a hand-styled Rails app -- a page rendering
/// a shared partial that itself renders a narrower sub-partial -- deeper
/// nesting is rare enough that silently guessing past it would cost more
/// than naming the limit and asking a human to look.
const max_partial_depth: u8 = 3;

const QueueItem = struct { entry: inventory.Entry, depth: u8 };

fn containsPath(list: []const []const u8, path: []const u8) bool {
    for (list) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn markerSourceFor(path: []const u8, view_path: []const u8, layout_path: ?[]const u8) classify.MarkerSource {
    if (std.mem.eql(u8, path, view_path)) return .view;
    if (layout_path) |lp| {
        if (std.mem.eql(u8, path, lp)) return .layout;
    }
    return .partial;
}

/// Why a route carrying `TransitiveScan.unresolved_render` must not be
/// allowed to reach `content` -- see that field's doc and A1's brief item
/// 3: "a render target you cannot resolve is evidence you do not have".
const UnresolvedRenderKind = enum { dynamic, unmatched, depth_cap, unreadable_include };

fn unresolvedRenderReason(kind: UnresolvedRenderKind) []const u8 {
    return switch (kind) {
        .dynamic => "template renders a dynamic partial target that cannot be resolved statically",
        .unmatched => "template renders a partial target that does not match any known template",
        .depth_cap => "template's partial nesting exceeds the depth this scan follows",
        .unreadable_include => "a layout or partial this template renders could not be read",
    };
}

/// The result of scanning one route's view template, its resolved layout,
/// and every partial either of them (transitively, up to
/// `max_partial_depth`) renders, merged into one evidence bundle.
///
/// Contract 2 (owned-result): `buffers` holds one fresh `gpa`-owned
/// allocation per file this scan actually read; `.markers.request_state`/
/// `.component_root` BORROW from one of those buffers (`template_scan.
/// scan`'s own borrowing rule, extended across however many buffers this
/// scan visited), so `buffers` must stay alive for as long as `.markers` is
/// read. Release both together with `freeTransitiveScan`, and only AFTER
/// the caller is done reading `.markers` -- in `classifyRoutes`, that means
/// after the `classify.classify` call that consumes it, exactly the same
/// ordering `classifyRoutes`'s own doc already requires for the
/// single-buffer case this generalizes.
const TransitiveScan = struct {
    markers: template_scan.Markers = .{},
    request_state_source: classify.MarkerSource = .view,
    /// Set the FIRST time this scan hits a render target it cannot prove
    /// safe -- a dynamic expression, a literal matching no inventory entry,
    /// a depth-cap cutoff, or an unreadable include. `classifyRoutes` must
    /// not let a route with this set reach `content`: unscanned content is
    /// evidence not in hand, and `content` is the one verdict that must not
    /// be asserted without it (A1's brief). Left `null` (the common case) a
    /// route classifies purely on `.markers` as before this field existed.
    unresolved_render: ?UnresolvedRenderKind = null,
    /// Set when the VIEW ITSELF (not a layout or partial it renders) could
    /// not be read. `classifyRoutes` must fall back to `.view = null` in
    /// this case, exactly as it did before transitive scanning existed
    /// (see the "an unreadable template becomes a non-integrity blocker"
    /// test) -- `.markers` and `.unresolved_render` are meaningless without
    /// the view's own content, so they are not consulted when this is set.
    view_unreadable: bool = false,
    buffers: std.ArrayListUnmanaged([]u8) = .empty,
};

/// Contract 2 counterpart to `transitiveScan`: releases every buffer plus
/// the list itself. Call only after every read of `.markers`/
/// `.request_state_source` is done.
fn freeTransitiveScan(gpa: Allocator, r: *TransitiveScan) void {
    for (r.buffers.items) |b| gpa.free(b);
    r.buffers.deinit(gpa);
}

/// Scans `view_entry` and everything it (transitively, through its
/// resolved layout and any `render`ed partials) pulls in, merging markers
/// per classify.zig's module doc: `stimulus` ORs; `request_state`/
/// `component_root` take the first non-null in view-then-layout-then-
/// partial order (the BFS below visits the view first, the layout second
/// -- both enqueued at depth 0 before either is dequeued -- and partials
/// afterward, so insertion order already IS that priority order; ties
/// within "partial" don't need a tiebreak since classify.zig only cares
/// whether a marker is present, not which partial supplied it). A partial
/// already visited (a cycle, or two templates rendering the same shared
/// partial) is scanned once, not re-queued -- see `containsPath`.
///
/// `reported_unreadable_templates` is shared across every route
/// `classifyRoutes` scans in one run (fix round B / B4): two routes that
/// resolve to the SAME template (e.g. `resources :posts`' `index` action
/// reachable at both `/` and `/posts`, sharing one view) used to each run
/// their own `transitiveScan` call and each emit their own byte-identical
/// `RAILS_TEMPLATE_UNREADABLE` blocker for that one unreadable file --
/// duplicating the finding once per ROUTE instead of reporting it once per
/// FILE, unlike `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` (emitted once per
/// inventory entry). The read-failure classification outcome
/// (`result.view_unreadable`/`result.unresolved_render`) is still recorded
/// for EVERY route that hits the unreadable file -- only the blocker
/// EMISSION is deduped, since a route's own verdict must not depend on
/// whether some earlier route already hit the same file.
///
/// See `TransitiveScan`'s doc for the ownership contract this returns
/// under.
fn transitiveScan(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    entries: []const inventory.Entry,
    view_entry: inventory.Entry,
    controller: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
    reported_unreadable_templates: *std.ArrayListUnmanaged([]const u8),
) Allocator.Error!TransitiveScan {
    var result: TransitiveScan = .{};
    errdefer freeTransitiveScan(gpa, &result);

    var queue: std.ArrayListUnmanaged(QueueItem) = .empty;
    defer queue.deinit(gpa);
    var visited: std.ArrayListUnmanaged([]const u8) = .empty;
    defer visited.deinit(gpa);

    try queue.append(gpa, .{ .entry = view_entry, .depth = 0 });
    try visited.append(gpa, view_entry.path);

    const layout_entry = resolveLayoutEntry(entries, controller);
    if (layout_entry) |le| {
        if (!containsPath(visited.items, le.path)) {
            try queue.append(gpa, .{ .entry = le, .depth = 0 });
            try visited.append(gpa, le.path);
        }
    }
    const layout_path: ?[]const u8 = if (layout_entry) |le| le.path else null;

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const item = queue.items[qi];
        const src = root.readFileAlloc(io, item.entry.path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Emit the blocker once per FILE across the whole
                // `classifyRoutes` run, not once per ROUTE that happens to
                // reach it (fix round B / B4) -- see this function's doc.
                if (!containsPath(reported_unreadable_templates.items, item.entry.path)) {
                    try blockers.append(gpa, blocker_list, "RAILS_TEMPLATE_UNREADABLE", item.entry.path, @errorName(err), false);
                    try reported_unreadable_templates.append(gpa, item.entry.path);
                }
                if (std.mem.eql(u8, item.entry.path, view_entry.path)) {
                    result.view_unreadable = true;
                } else if (result.unresolved_render == null) {
                    result.unresolved_render = .unreadable_include;
                }
                continue;
            },
        };
        // Scoped to this inner block on purpose: `src` is owned by nothing
        // until `buffers.append` succeeds, so an OOM from THIS call must
        // free it directly. Once the block exits normally, ownership has
        // moved to `result.buffers` and the outer `errdefer
        // freeTransitiveScan(...)` above is what covers it for every error
        // the REST of this loop iteration can still raise -- an unscoped
        // `errdefer gpa.free(src)` here would stay armed past that point
        // and double-free `src` on a later failure in the same iteration.
        {
            errdefer gpa.free(src);
            try result.buffers.append(gpa, src);
        }

        const m = template_scan.scan(src);
        if (m.request_state != null and result.markers.request_state == null) {
            result.markers.request_state = m.request_state;
            result.request_state_source = markerSourceFor(item.entry.path, view_entry.path, layout_path);
        }
        if (m.component_root != null and result.markers.component_root == null) {
            result.markers.component_root = m.component_root;
        }
        result.markers.stimulus = result.markers.stimulus or m.stimulus;

        const targets = try template_scan.scanRenders(gpa, src);
        defer gpa.free(targets);
        if (targets.len == 0) continue;

        if (item.depth >= max_partial_depth) {
            if (result.unresolved_render == null) result.unresolved_render = .depth_cap;
            try blockers.append(
                gpa,
                blocker_list,
                "RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED",
                item.entry.path,
                "partial nesting exceeds the depth this scan follows; unify or flatten these partials",
                false,
            );
            continue;
        }

        const containing_dir = templateDirOf(item.entry.path);
        for (targets) |t| {
            if (!t.resolved) {
                if (result.unresolved_render == null) result.unresolved_render = .dynamic;
                continue;
            }
            if (resolvePartialTarget(entries, containing_dir, t.text)) |partial_entry| {
                if (containsPath(visited.items, partial_entry.path)) continue;
                try visited.append(gpa, partial_entry.path);
                try queue.append(gpa, .{ .entry = partial_entry, .depth = item.depth + 1 });
            } else if (result.unresolved_render == null) {
                result.unresolved_render = .unmatched;
            }
        }
    }

    return result;
}

/// Contract 3 (caller-buffer): no allocation. A route missing either half of
/// `controller#action` has nothing to look up (`controllers.find` is keyed
/// on the pair); the returned `ActionInfo`, when non-null, is a copy whose
/// string fields alias `actions`' own storage, same as `controllers.find`'s
/// own doc describes.
fn actionFor(actions: []const controllers.ActionInfo, r: routes.Route) ?controllers.ActionInfo {
    const c = r.controller orelse return null;
    const a = r.action orelse return null;
    return controllers.find(actions, c, a);
}

/// Joins each route's verb, resolved view (if any), and resolved controller
/// action (if any) into one `classify.Verdict`, index-aligned with
/// `route_list` -- `report.build`'s `Input.classifications` depends on that
/// alignment to pair each rendered route with its verdict.
///
/// Contract 1 (self-freeing): the only allocation that escapes is the
/// returned `[]classify.Verdict` slice itself. Every `Verdict` value it
/// holds owns nothing (see classify.zig's module doc: `reason` and every
/// `Candidate` field are static string literals), so nothing in the
/// RETURNED slice depends on any allocation this function frees.
///
/// A matched view's bytes -- and its resolved layout's, and any partial
/// either of them renders -- are read via `transitiveScan`, whose
/// `TransitiveScan.buffers` those markers BORROW from (see that struct's
/// doc). `classify.classify` is called -- and its result stored into
/// `out[i]` -- WHILE `scan_result` (and therefore every buffer) is still in
/// scope, before the `defer freeTransitiveScan(...)` on that same block
/// fires. This generalizes the single-buffer lifetime rule the pre-A1
/// version of this function pinned (see git history / classify.zig's
/// module doc) to however many files one route's transitive scan visits:
/// building `view` and calling `classify` only after `scan_result` were
/// freed would leave `view.markers` pointing at freed memory, the exact
/// use-after-free this ordering exists to avoid.
///
/// A template that cannot be read is non-fatal: it becomes a
/// `RAILS_TEMPLATE_UNREADABLE` blocker (`integrity = false` -- an unreadable
/// file is a finding about one file, not a reason to distrust the whole
/// inventory). When the UNREADABLE file is the route's own view, the route
/// classifies as if it had no view at all (`null` handed to `classify`,
/// never a synthesized default) -- the same "missing evidence stays missing
/// evidence" rule `controllers.discoverControllers`'s degradation paths
/// already follow. When it is a layout or a rendered partial instead, or
/// when any `render` target this route's templates use could not be
/// resolved (a dynamic expression, a literal matching no inventory entry,
/// or the transitive scan's depth cap), the route may still reach every
/// verdict EXCEPT `content` -- unscanned content is evidence not in hand,
/// and `content` is the one verdict that must not be asserted without it
/// (see `TransitiveScan.unresolved_render`'s doc and A1's brief).
fn classifyRoutes(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    entries: []const inventory.Entry,
    route_list: []const routes.Route,
    actions: []const controllers.ActionInfo,
    controller_evidence_available: bool,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error![]classify.Verdict {
    const out = try gpa.alloc(classify.Verdict, route_list.len);
    errdefer gpa.free(out);

    // Shared across every route this call scans (fix round B / B4): dedupes
    // `RAILS_TEMPLATE_UNREADABLE` emission by FILE across the whole run --
    // see `transitiveScan`'s doc. Holds borrowed `entries` paths (never
    // freed independently; `entries` outlives this function), so this list
    // owns only its own backing array.
    var reported_unreadable_templates: std.ArrayListUnmanaged([]const u8) = .empty;
    defer reported_unreadable_templates.deinit(gpa);

    for (route_list, 0..) |r, i| {
        const action = actionFor(actions, r);

        if (r.controller) |c| {
            if (r.action) |a| {
                if (resolveViewEntry(entries, c, a)) |entry| {
                    var scan_result = try transitiveScan(io, gpa, root, entries, entry, c, blocker_list, &reported_unreadable_templates);
                    defer freeTransitiveScan(gpa, &scan_result);

                    if (scan_result.view_unreadable) {
                        out[i] = classify.classify(.{
                            .verb = r.verb,
                            .view = null,
                            .action = action,
                            .controller_evidence_available = controller_evidence_available,
                        });
                        continue;
                    }

                    var verdict = classify.classify(.{
                        .verb = r.verb,
                        .view = .{
                            .path = entry.path,
                            .engine = entry.engine,
                            .markers = scan_result.markers,
                            .request_state_source = scan_result.request_state_source,
                        },
                        .action = action,
                        .controller_evidence_available = controller_evidence_available,
                    });
                    if (scan_result.unresolved_render) |kind| {
                        if (verdict.class == .content) {
                            verdict = .{
                                .class = .unresolved,
                                .reason = unresolvedRenderReason(kind),
                                .candidates = &.{},
                            };
                        }
                    }
                    out[i] = verdict;
                    continue;
                }
            }
        }

        out[i] = classify.classify(.{
            .verb = r.verb,
            .view = null,
            .action = action,
            .controller_evidence_available = controller_evidence_available,
        });
    }

    return out;
}

test "matchesRouteView requires the exact controller/action pair, not a prefix" {
    try std.testing.expect(matchesRouteView("app/views/posts/show.html.erb", "posts", "show"));
    try std.testing.expect(matchesRouteView("app/views/admin/users/index.html.erb", "admin/users", "index"));
    // Action "show" must not match a sibling action whose name it prefixes.
    try std.testing.expect(!matchesRouteView("app/views/posts/shower.html.erb", "posts", "show"));
    // Controller "posts" must not match a sibling controller it prefixes.
    try std.testing.expect(!matchesRouteView("app/views/posts2/show.html.erb", "posts", "show"));
    try std.testing.expect(!matchesRouteView("app/views/comments/show.html.erb", "posts", "show"));
}

test "resolveViewEntry prefers an .html. match over a json.jbuilder sibling" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.json.jbuilder", .kind = .view, .engine = .jbuilder },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const got = resolveViewEntry(&entries, "posts", "index").?;
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", got.path);
}

test "resolveViewEntry: a jbuilder-only match returns null, not the jbuilder entry" {
    // See resolveViewEntry's doc: presenting a jbuilder file as "the view"
    // would misreport an API response through rule 4's unsupported-engine
    // path. Returning null here is what lets rule 2's existing "no view"
    // clause carry the correct story instead.
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.json.jbuilder", .kind = .view, .engine = .jbuilder },
    };
    try std.testing.expect(resolveViewEntry(&entries, "posts", "index") == null);
}

test "resolveViewEntry: a builder-only match also returns null" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.xml.builder", .kind = .view, .engine = .builder },
    };
    try std.testing.expect(resolveViewEntry(&entries, "posts", "index") == null);
}

test "resolveViewEntry matches mailer_view kind too" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/user_mailer/welcome.html.erb", .kind = .mailer_view, .engine = .erb },
    };
    const got = resolveViewEntry(&entries, "user_mailer", "welcome").?;
    try std.testing.expectEqualStrings("app/views/user_mailer/welcome.html.erb", got.path);
}

test "resolveViewEntry ignores non-view/mailer_view kinds and unrelated paths" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/controllers/posts_controller.rb", .kind = .controller, .engine = .none },
    };
    try std.testing.expect(resolveViewEntry(&entries, "posts", "index") == null);
}

test "classifyRoutes reads the matched template and classifies from real markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var views_dir = try tmp.dir.createDirPathOpen(io, "app/views/posts", .{});
    views_dir.close(io);
    {
        const f = try tmp.dir.createFile(io, "app/views/posts/index.html.erb", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<%= current_user.name %>\n");
    }

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{
        .{ .controller = "posts", .action = "index" },
    };

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(@as(usize, 1), verdicts.len);
    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("view reads request-time state", verdicts[0].reason);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "classifyRoutes: an unreadable template becomes a non-integrity blocker, route still classifies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // No file actually exists at the entry's path -- a deterministic read
    // failure without depending on platform-specific permission bits.

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{
        .{ .controller = "posts", .action = "index" },
    };

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(@as(usize, 1), verdicts.len);
    // No markers (the template could not be read), no view handed to
    // classify -> the `in.view orelse` guard above rule 4 returns "no view
    // template to classify" (fix round B / B6: not rule 7's own gate, which
    // returns a different reason), never a synthesized default.
    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("no view template to classify", verdicts[0].reason);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expect(!blocker_list.items[0].integrity);
}

test "classifyRoutes: two routes sharing one unreadable template emit ONE RAILS_TEMPLATE_UNREADABLE blocker, not two" {
    // Regression for B4 (final-fixes-B.md): `resources :posts` shape --
    // both `GET /` and `GET /posts` resolve to `posts#index`, sharing the
    // same view. Before the fix, each route ran its own `transitiveScan`
    // and each emitted its own byte-identical blocker for the same file --
    // the report listed the same line twice. Both routes must still
    // classify correctly (the dedup is blocker-emission only, not a skip of
    // the read-failure outcome itself).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // No file exists at the entry's path -- deterministic read failure.

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/", .controller = "posts", .action = "index", .name = "root", .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{
        .{ .controller = "posts", .action = "index" },
    };

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(@as(usize, 2), verdicts.len);
    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqual(classify.Class.unresolved, verdicts[1].class);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", blocker_list.items[0].path);
}

test "classifyRoutes: a jbuilder-only view resolves to no view, not a false unsupported-engine verdict" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.json.jbuilder", .kind = .view, .engine = .jbuilder },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{
        .{ .controller = "posts", .action = "index" },
    };
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("no view template to classify", verdicts[0].reason);
    // No read was even attempted -- the jbuilder file was excluded during
    // resolution, not read-and-rejected.
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "classifyRoutes degradation: no controllers recovered, view present -> unresolved (not content, not backend)" {
    // Mirrors classify.zig's own "degradation: view + static markers, action
    // absent" test, but exercised through the real join -- proves
    // classifyRoutes hands `null`, not a synthesized ActionInfo, when the
    // sidecar recovered zero actions.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var views_dir = try tmp.dir.createDirPathOpen(io, "app/views/posts", .{});
    views_dir.close(io);
    {
        const f = try tmp.dir.createFile(io, "app/views/posts/index.html.erb", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<h1>Posts</h1>\n");
    }

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts: []const controllers.ActionInfo = &.{}; // controller analysis unavailable

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings(
        "view looks static but no controller action was recovered to confirm it",
        verdicts[0].reason,
    );
}

// --- A1: transitive template scanning (layout + partials) ------------------

fn writeTemplate(tmp: std.testing.TmpDir, io: Io, sub_path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(sub_path) orelse ".";
    var d = try tmp.dir.createDirPathOpen(io, dir_path, .{});
    d.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

test "resolveLayoutEntry prefers a per-controller layout over application" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/layouts/posts.html.erb", .kind = .layout, .engine = .erb },
    };
    const got = resolveLayoutEntry(&entries, "posts").?;
    try std.testing.expectEqualStrings("app/views/layouts/posts.html.erb", got.path);
}

test "resolveLayoutEntry falls back to application when no per-controller layout exists" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
    };
    const got = resolveLayoutEntry(&entries, "posts").?;
    try std.testing.expectEqualStrings("app/views/layouts/application.html.erb", got.path);
}

test "resolveLayoutEntry returns null when neither exists" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    try std.testing.expect(resolveLayoutEntry(&entries, "posts") == null);
}

test "matchesPartialTarget resolves a no-slash target relative to the containing template's own directory" {
    try std.testing.expect(matchesPartialTarget("app/views/posts/_post.html.erb", "app/views/posts", "post"));
    // Must not match a partial of the same NAME in a different directory.
    try std.testing.expect(!matchesPartialTarget("app/views/shared/_post.html.erb", "app/views/posts", "post"));
    // Must not match a partial whose name the target merely prefixes.
    try std.testing.expect(!matchesPartialTarget("app/views/posts/_posting.html.erb", "app/views/posts", "post"));
}

test "matchesPartialTarget resolves a slash-bearing target relative to app/views/, regardless of the containing template's directory" {
    try std.testing.expect(matchesPartialTarget("app/views/shared/_nav.html.erb", "app/views/posts", "shared/nav"));
    try std.testing.expect(!matchesPartialTarget("app/views/shared/_footer.html.erb", "app/views/posts", "shared/nav"));
}

test "transitive scan: a clean layout and a clean partial still reach content (multi-buffer lifetime holds)" {
    // Three files (view, layout, partial) are read into three SEPARATE
    // buffers and all three markers are consulted -- if the lifetime
    // ordering `classifyRoutes`'s doc requires were wrong, this would be a
    // use-after-free the leak/ASan-less testing allocator may or may not
    // catch, but the WRONG-DATA failure mode (a freed buffer's bytes
    // reused for something else before `classify` reads them) is a
    // regression this test's exact class/reason assertions catch either
    // way -- not just "it didn't crash".
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render partial: \"post\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_post.html.erb", "<article><%= post.title %></article>\n");
    try writeTemplate(tmp, io, "app/views/layouts/application.html.erb", "<html><body><%= yield %></body></html>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.content, verdicts[0].class);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "transitive scan: a marker in the LAYOUT (not the view) forces unresolved, naming the layout" {
    // This is finding A1's exact repro shape: the view alone looks static.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n");
    try writeTemplate(tmp, io, "app/views/layouts/application.html.erb", "<%= csrf_meta_tags %><%= yield %>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("the resolved layout reads request-time state", verdicts[0].reason);
}

test "transitive scan: a marker in a RENDERED PARTIAL (view and layout clean) forces unresolved, naming the partial" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render partial: \"meta\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_meta.html.erb", "<%= current_user.email %>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/_meta.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("a rendered partial reads request-time state", verdicts[0].reason);
}

test "transitive scan: the view's own marker wins priority over the layout's (view-then-layout-then-partial order)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<%= current_user %>\n");
    try writeTemplate(tmp, io, "app/views/layouts/application.html.erb", "<%= session[:x] %><%= yield %>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    // If layout won, this would still be "unresolved" but with the WRONG
    // reason -- asserting the reason (not just the class) is what actually
    // proves view beats layout, not merely "a marker fired somewhere".
    try std.testing.expectEqualStrings("view reads request-time state", verdicts[0].reason);
}

test "transitive scan: stimulus in a partial still reaches island (stimulus ORs across files)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render partial: \"widget\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_widget.html.erb", "<div data-controller=\"reveal\"></div>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/_widget.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.island, verdicts[0].class);
}

test "transitive scan: a dynamic render target (render @post) forces unresolved, never content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render @post %>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("template renders a dynamic partial target that cannot be resolved statically", verdicts[0].reason);
}

test "transitive scan: a literal render target matching no inventory entry forces unresolved, never content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // "missing" is never declared as a partial entry below -- the literal
    // target is well-formed but unresolvable against this inventory.
    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render partial: \"missing\" %>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("template renders a partial target that does not match any known template", verdicts[0].reason);
}

test "transitive scan: an unresolvable render does NOT downgrade a verdict that was already non-content" {
    // The override only applies when the verdict WOULD have been `content`
    // -- a route that classifies `unresolved` for an unrelated reason (here,
    // rule 5's OWN request-state marker) keeps that reason, not the
    // render-target one, since the class doesn't change.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<%= current_user %><%= render @post %>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("view reads request-time state", verdicts[0].reason);
}

test "transitive scan: partial nesting past the depth cap emits a blocker and forces unresolved" {
    // view -> _p1 -> _p2 -> _p3 (view=depth0, _p1=depth1, _p2=depth2,
    // _p3=depth3) -- _p3 itself renders _p4, which is one hop past
    // `max_partial_depth`, so `transitiveScan` must not silently stop: it
    // names the cutoff with a blocker and the route may not reach content.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<%= render partial: \"p1\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_p1.html.erb", "<%= render partial: \"p2\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_p2.html.erb", "<%= render partial: \"p3\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_p3.html.erb", "<%= render partial: \"p4\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_p4.html.erb", "<p>leaf</p>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/_p1.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/_p2.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/_p3.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/_p4.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("template's partial nesting exceeds the depth this scan follows", verdicts[0].reason);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/views/posts/_p3.html.erb", blocker_list.items[0].path);
}

test "transitive scan: a shared partial rendered from two places (a cycle-safe graph) is scanned once, not infinitely" {
    // _a and _b both render _shared -- and, to prove cycles are handled and
    // not just diamonds, _shared also (harmlessly) re-renders "shared" by
    // its OTHER name is not attempted here; instead this pins that a
    // partial already visited is not re-queued (see `containsPath`), which
    // is what actually prevents an infinite loop on a true cycle.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<%= render partial: \"a\" %><%= render partial: \"b\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_a.html.erb", "<%= render partial: \"shared\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_b.html.erb", "<%= render partial: \"shared\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_shared.html.erb", "<p>shared</p>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/_a.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/_b.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/_shared.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.content, verdicts[0].class);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "transitive scan: an unreadable PARTIAL (not the view itself) forces unresolved, never content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<%= render partial: \"post\" %>\n");
    // No file actually exists at _post.html.erb's path -- the same
    // deterministic-unreadable trick the top-level unreadable-view test
    // above uses.

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("a layout or partial this template renders could not be read", verdicts[0].reason);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNREADABLE", blocker_list.items[0].code);
}

// --- A3: controller-evidence-availability gate, exercised through the real join ---

test "classifyRoutes A3: controller evidence unavailable wholesale -> a view-less route is unresolved, not backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]inventory.Entry{};
    // No view exists for this route, and no action was recovered either --
    // exactly rule 2's first sub-clause shape, but under a wholesale
    // controller-evidence-unavailable run.
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/admin/health", .controller = "admin", .action = "health", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts: []const controllers.ActionInfo = &.{};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const verdicts = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, acts, false, &blocker_list);
    defer gpa.free(verdicts);

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings(
        "no view template, and controller evidence was unavailable for this run",
        verdicts[0].reason,
    );
}

test "transitive scan: an OOM at any point in a multi-file scan leaks nothing" {
    // Mirrors controllers.zig's decodeResponse OOM-sweep test: this is the
    // strongest available proof for `transitiveScan`'s contract 2 doc claim
    // that `result.buffers` is released correctly on every error path --
    // not just the ones this file's author thought to check by hand. Three
    // files (view, layout, partial) means at least one swept `fail_index`
    // lands squarely between "a buffer was read" and "it was appended", the
    // exact seam the nested-errdefer block above exists for.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render partial: \"post\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_post.html.erb", "<article><%= post.title %></article>\n");
    try writeTemplate(tmp, io, "app/views/layouts/application.html.erb", "<html><body><%= yield %></body></html>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();

        var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
        defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

        if (classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list)) |verdicts| {
            defer std.testing.allocator.free(verdicts);
            try std.testing.expectEqual(@as(usize, 1), verdicts.len);
            try std.testing.expectEqual(classify.Class.content, verdicts[0].class);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
