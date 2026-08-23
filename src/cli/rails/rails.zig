//! Package root for the Rails migration adapter, and the `standalone` test
//! suite root for `zig build test-rails`.
//!
//! Everything below is std-only: no import escapes `src/cli/rails/`, so this
//! compiles as its own module. `fatal.*` handling belongs to migrate.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const blockers = @import("blockers.zig");
pub const detect = @import("detect.zig");
pub const inventory = @import("inventory.zig");
pub const integrations = @import("integrations.zig");
pub const report = @import("report.zig");
pub const routes = @import("routes.zig");
pub const controllers = @import("controllers.zig");
pub const sidecar_client = @import("sidecar_client.zig");
pub const template_scan = @import("template_scan.zig");

// Pulls the suites of every sibling file into this module so `test-rails`
// runs them all. Without this the standalone binary only sees this file.
test {
    std.testing.refAllDecls(@This());
    _ = blockers;
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
    defer {
        for (blocker_list.items) |b| {
            gpa.free(b.path);
            gpa.free(b.detail);
        }
        blocker_list.deinit(gpa);
    }

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
    });
    return .{
        .report = body,
        .integrity_blocker_count = integrity_blocker_count,
        .route_count = route_result.routes.len,
        .route_mode = route_result.mode,
        .route_blocker = route_blocker,
    };
}
