//! Renders the human MIGRATION.md worklist. Pure: takes in-memory inventory
//! and route data and returns markdown, so it is testable without a
//! filesystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const inventory = @import("inventory.zig");
const integrations = @import("integrations.zig");
const blockers = @import("blockers.zig");
const routes = @import("routes.zig");

pub const Input = struct {
    app_path: []const u8,
    entries: []const inventory.Entry,
    integrations: []const integrations.Integration,
    /// Every blocker to render, from every source (inventory read failures,
    /// unsupported template engines, unreadable/malformed Gemfile and
    /// package.json). `build` only renders this list -- it constructs none
    /// of it itself, so there is a single blocker-construction path (the
    /// callers of `build`) rather than the report special-casing template
    /// engines on top of a separately populated list.
    blockers: []const blockers.Blocker,
    /// Every route the sidecar recovered (Task 5's `routes.discoverRoutes`).
    /// Defaulted to empty so the existing report tests above, written before
    /// this field existed, keep compiling unchanged.
    routes: []const routes.Route = &.{},
    /// `routes.Result.mode` passed straight through: `"static_ast"` when the
    /// sidecar answered, `"none"` on every degradation path. Defaulted to
    /// `"none"` for the same reason as `routes`.
    route_mode: []const u8 = "none",
};

test "routes render with their origin, and uncertain ones are marked" {
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/", .controller = "home", .action = "index", .name = "root", .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/x", .controller = null, .action = null, .name = null, .certain = false, .origin = .static_ast },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "## Routes") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "static_ast") != null);
    // Pin the exact rendered LINE for each route, not just "the word
    // 'uncertain' appears somewhere in the document". The section's
    // unconditional intro sentence explains the marker using that same
    // word, so a substring check against the whole document passes even
    // with the per-route marker deleted entirely -- this caught a review
    // finding that the original version of this assertion was vacuous.
    // The certain route's line must end right after its controller#action
    // with nothing appended; the uncertain route's line must carry the
    // marker. This also pins that the root route ("/") actually rendered,
    // rather than "GET /" merely being a substring of "GET /x".
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /` → `home#index`\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /x` — **uncertain**\n") != null);
}

// Three genuinely different zero-route situations (finding: "See Blockers
// for why" must not point at a section that says nothing about routes).
// `route_mode == "none"` means discovery never ran at all, so a degradation
// blocker is guaranteed; `route_mode == "static_ast"` means the sidecar DID
// run, and then the only question is whether it hit something unresolvable
// (a route-related blocker exists) or `config/routes.rb` genuinely declares
// no routes (no such blocker). Each test pins the exact rendered line, not
// a document-level substring -- see the "uncertain" marker test above for
// why that matters on this branch specifically.

test "zero routes, mode none: discovery did not run, points at Blockers" {
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{
            .{ .code = "RAILS_SIDECAR_MISSING", .path = "sidecar/rails/analyze.rb", .detail = "ZIGAPAGOS_RUNTIME_DIR is not set" },
        },
        .routes = &.{},
        .route_mode = "none",
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(
        u8,
        md,
        "No routes were recovered (route_mode: `none`). See Blockers below for why.\n",
    ) != null);
}

test "zero routes, mode static_ast with a route blocker: points at Blockers" {
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{
            .{ .code = "RAILS_ROUTE_ENGINE_MOUNT", .path = "config/routes.rb", .detail = "mount is not evaluated" },
        },
        .routes = &.{},
        .route_mode = "static_ast",
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(
        u8,
        md,
        "No routes were recovered (route_mode: `static_ast`). See Blockers below for why.\n",
    ) != null);
}

test "zero routes, mode static_ast with no route blocker: says routes.rb declares none" {
    // No blockers at all -- discovery ran cleanly and config/routes.rb is
    // simply empty (`Rails.application.routes.draw do end`). Pointing this
    // at Blockers would misdirect: there is nothing there about routes.
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &.{},
        .route_mode = "static_ast",
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(
        u8,
        md,
        "`config/routes.rb` declares no routes.\n",
    ) != null);
    // Must NOT point at a Blockers section that says nothing about routes.
    try std.testing.expect(std.mem.indexOf(u8, md, "See Blockers below for why") == null);
}

test "zero routes, mode static_ast, an unrelated blocker present: still says routes.rb declares none" {
    // A non-route blocker (e.g. an unsupported template engine) must not be
    // mistaken for a route-related one -- the route section's conclusion
    // depends only on route-related blockers.
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{
            .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/x.html.haml", .detail = "Haml template is not converted" },
        },
        .routes = &.{},
        .route_mode = "static_ast",
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(
        u8,
        md,
        "`config/routes.rb` declares no routes.\n",
    ) != null);
}

test "routes render in (path, verb) order regardless of input order" {
    // Mirrors "blockers render in (code, path) order regardless of input
    // order" below: the analogous guardrail was missing for routes, so a
    // future change to the sort call site in `build` had no test pinning
    // it -- only out-of-band review verification did.
    const unsorted = [_]routes.Route{
        .{ .verb = "POST", .path = "/posts", .controller = "posts", .action = "create", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/", .controller = "home", .action = "index", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &unsorted,
        .route_mode = "static_ast",
    });
    defer std.testing.allocator.free(md);

    const root_pos = std.mem.indexOf(u8, md, "`GET /`").?;
    const posts_get_pos = std.mem.indexOf(u8, md, "`GET /posts`").?;
    const posts_post_pos = std.mem.indexOf(u8, md, "`POST /posts`").?;
    // "/" < "/posts" lexically, and within "/posts", GET < POST.
    try std.testing.expect(root_pos < posts_get_pos);
    try std.testing.expect(posts_get_pos < posts_post_pos);
}

test "report lists counts, integrations, and flags unsupported engines" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.haml", .kind = .view, .engine = .haml },
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
        // Joins engineFor's .slim classification (tested in inventory.zig)
        // with this module's "Slim" label mapping, so the two halves are
        // actually exercised together at least once.
        .{ .path = "app/views/posts/legacy.html.slim", .kind = .view, .engine = .slim },
    };
    const ints = [_]integrations.Integration{
        .{ .name = "propshaft", .evidence = "Gemfile:propshaft" },
    };
    // Constructed by hand rather than via
    // `inventory.appendUnsupportedEngineBlockers` -- that function has its
    // own test in inventory.zig; this file's tests are about rendering, not
    // construction, so they only need literal `Blocker` values to render.
    const rail_blockers = [_]blockers.Blocker{
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/posts/index.html.haml", .detail = "Haml template is not converted" },
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/posts/legacy.html.slim", .detail = "Slim template is not converted" },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "my-app",
        .entries = &entries,
        .integrations = &ints,
        .blockers = &rail_blockers,
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "# Migrating my-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Views | 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "propshaft") != null);
    // The Haml and Slim views must both be named as blockers, never silently
    // counted as done.
    try std.testing.expect(std.mem.indexOf(u8, md, "RAILS_TEMPLATE_ENGINE_UNSUPPORTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "app/views/posts/index.html.haml") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Slim") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "app/views/posts/legacy.html.slim") != null);
}

test "blockers render in (code, path) order regardless of input order" {
    const unsorted = [_]blockers.Blocker{
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/z.html.haml", .detail = "Haml template is not converted" },
        .{ .code = "RAILS_INVENTORY_UNREADABLE", .path = "public", .detail = "AccessDenied", .integrity = true },
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/a.html.haml", .detail = "Haml template is not converted" },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &unsorted,
    });
    defer std.testing.allocator.free(md);

    const inventory_pos = std.mem.indexOf(u8, md, "RAILS_INVENTORY_UNREADABLE").?;
    const first_haml_pos = std.mem.indexOf(u8, md, "app/views/a.html.haml").?;
    const second_haml_pos = std.mem.indexOf(u8, md, "app/views/z.html.haml").?;
    // "RAILS_INVENTORY_UNREADABLE" < "RAILS_TEMPLATE_ENGINE_UNSUPPORTED"
    // lexically, and within the latter code, a.html.haml < z.html.haml.
    try std.testing.expect(inventory_pos < first_haml_pos);
    try std.testing.expect(first_haml_pos < second_haml_pos);
}

test "report is byte-identical across runs" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
    };
    const a = try build(std.testing.allocator, .{ .app_path = "x", .entries = &entries, .integrations = &.{}, .blockers = &.{} });
    defer std.testing.allocator.free(a);
    const b = try build(std.testing.allocator, .{ .app_path = "x", .entries = &entries, .integrations = &.{}, .blockers = &.{} });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

/// True when `list` contains at least one route-discovery-related blocker
/// (see `blockers.isRouteRelated`). Linear scan over the caller's own list,
/// not a sorted/deduped structure -- `list` is at most a handful of entries
/// per run and this is called once per `build`.
fn hasRouteBlocker(list: []const Blocker) bool {
    for (list) |b| {
        if (blockers.isRouteRelated(b.code)) return true;
    }
    return false;
}

fn countOf(entries: []const inventory.Entry, kind: inventory.Kind) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.kind == kind) n += 1;
    }
    return n;
}

/// Contract 1 (self-freeing): all scratch is released; the returned markdown is
/// the single escaping allocation and is owned by the caller.
///
/// Contains no timestamp on purpose -- determinism is an acceptance criterion,
/// and a wall-clock stamp would make identical input produce differing output.
///
/// Deviation from the brief: the brief sketched `out.writer(gpa)` on an
/// `ArrayListUnmanaged(u8)`, but that method doesn't exist on 0.16.0's
/// `ArrayListUnmanaged` -- `migrate.zig`'s `buildOtherReport`/`buildReport`
/// (the real precedent for this exact job) instead use
/// `std.Io.Writer.Allocating`, whose `print`/`writeAll` return
/// `error{WriteFailed}`, not `Allocator.Error`. Since an `Allocating` writer's
/// only failure mode is the backing allocator running out of memory, each call
/// is `catch return error.OutOfMemory` to keep this function's declared
/// `Allocator.Error!` signature intact. `errdefer aw.deinit()` covers that
/// path; `migrate.zig` skips it because its caller (`fatal.oom()`) never
/// returns, but this module is std-only and must actually free on error.
pub fn build(gpa: Allocator, in: Input) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    w.print("# Migrating {s} to Zigapagos\n\n", .{in.app_path}) catch return error.OutOfMemory;
    w.writeAll(
        \\Rails source discovery. This worklist inventories the presentation
        \\layer and the recovered route graph; it converts nothing.
        \\
        \\## Inventory
        \\
        \\| Kind | Count |
        \\| --- | --- |
        \\
    ) catch return error.OutOfMemory;
    w.print("| Views | {d} |\n", .{countOf(in.entries, .view)}) catch return error.OutOfMemory;
    w.print("| Layouts | {d} |\n", .{countOf(in.entries, .layout)}) catch return error.OutOfMemory;
    w.print("| Partials | {d} |\n", .{countOf(in.entries, .partial)}) catch return error.OutOfMemory;
    w.print("| Mailer views | {d} |\n", .{countOf(in.entries, .mailer_view)}) catch return error.OutOfMemory;
    w.print("| Controllers | {d} |\n", .{countOf(in.entries, .controller)}) catch return error.OutOfMemory;
    w.print("| Helpers | {d} |\n", .{countOf(in.entries, .helper)}) catch return error.OutOfMemory;
    w.print("| Stimulus controllers | {d} |\n", .{countOf(in.entries, .stimulus_controller)}) catch return error.OutOfMemory;
    w.print("| JS entrypoints | {d} |\n", .{countOf(in.entries, .js_entry)}) catch return error.OutOfMemory;
    w.print("| JS modules | {d} |\n", .{countOf(in.entries, .js_module)}) catch return error.OutOfMemory;
    w.print("| Assets | {d} |\n", .{countOf(in.entries, .asset)}) catch return error.OutOfMemory;

    w.writeAll("\n## Routes\n\n") catch return error.OutOfMemory;
    if (in.routes.len == 0) {
        // An empty section here would read as "this app has no routes",
        // which is true in exactly one of three situations -- conflating
        // them was the bug (see the "zero routes, ..." tests above):
        //
        //   1. route_mode == "none": discovery never ran (no Ruby, no
        //      sidecar, no config/routes.rb) -- a degradation blocker is
        //      guaranteed to exist, so pointing at Blockers is correct.
        //   2. route_mode == "static_ast" and a route-related blocker
        //      exists: the sidecar ran but everything it found was
        //      unresolvable -- Blockers is still the right pointer.
        //   3. route_mode == "static_ast" and no route-related blocker:
        //      config/routes.rb genuinely declares no routes. Pointing at
        //      Blockers here would misdirect the reader to a section that
        //      says nothing about routes, so this says the plain thing
        //      instead of promising an explanation that isn't there.
        const discovery_ran = std.mem.eql(u8, in.route_mode, "static_ast");
        if (!discovery_ran or hasRouteBlocker(in.blockers)) {
            w.print(
                "No routes were recovered (route_mode: `{s}`). See Blockers below for why.\n",
                .{in.route_mode},
            ) catch return error.OutOfMemory;
        } else {
            w.writeAll("`config/routes.rb` declares no routes.\n") catch return error.OutOfMemory;
        }
    } else {
        w.print(
            "Recovered via `{s}`. Routes marked **uncertain** were found through a construct the parser could not fully evaluate -- treat them as leads, not settled facts.\n\n",
            .{in.route_mode},
        ) catch return error.OutOfMemory;

        // Sorted in a private copy for the same reason the blockers section
        // below sorts its own copy: determinism is `build`'s responsibility,
        // independent of whatever order the caller's route discovery
        // produced (`discoverRoutes` already sorts, but this report must not
        // depend on that -- an artifact people diff has to be stable on its
        // own terms).
        const sorted_routes = try gpa.dupe(Route, in.routes);
        defer gpa.free(sorted_routes);
        std.mem.sort(Route, sorted_routes, {}, routeLessThan);
        for (sorted_routes) |r| {
            w.print("- `{s} {s}`", .{ r.verb, r.path }) catch return error.OutOfMemory;
            if (r.controller) |c| {
                if (r.action) |a| {
                    w.print(" → `{s}#{s}`", .{ c, a }) catch return error.OutOfMemory;
                }
            }
            // `certain == false` must be visibly distinguished at a glance,
            // not just on close reading -- a route recovered from a
            // construct the parser could not evaluate is a materially
            // weaker claim than one read straight out of the DSL.
            if (!r.certain) {
                w.writeAll(" — **uncertain**") catch return error.OutOfMemory;
            }
            w.writeAll("\n") catch return error.OutOfMemory;
        }
    }

    w.writeAll("\n## Detected integrations\n\n") catch return error.OutOfMemory;
    if (in.integrations.len == 0) {
        w.writeAll("None detected.\n") catch return error.OutOfMemory;
    } else {
        for (in.integrations) |i| w.print("- `{s}` ({s})\n", .{ i.name, i.evidence }) catch return error.OutOfMemory;
    }

    w.writeAll("\n## Blockers\n\n") catch return error.OutOfMemory;
    if (in.blockers.len == 0) {
        w.writeAll("None.\n") catch return error.OutOfMemory;
    } else {
        // Sorted in a private copy so callers don't have to hand `build` a
        // pre-sorted list -- determinism (see the "byte-identical across
        // runs" test) is this function's responsibility, independent of
        // blocker *discovery* order (e.g. a truncated app/ walk happening
        // before a package.json read failure).
        const sorted = try gpa.dupe(Blocker, in.blockers);
        defer gpa.free(sorted);
        std.mem.sort(Blocker, sorted, {}, blockerLessThan);
        for (sorted) |b| {
            w.print("- `{s}` {s}: {s}\n", .{ b.code, b.path, b.detail }) catch return error.OutOfMemory;
        }
    }

    return aw.toOwnedSlice();
}

const Blocker = blockers.Blocker;

fn blockerLessThan(_: void, a: Blocker, b: Blocker) bool {
    return switch (std.mem.order(u8, a.code, b.code)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.path, b.path),
    };
}

const Route = routes.Route;

/// Not imported from routes.zig: `routes.routeLessThan` is private (that
/// module sorts its own decoded result before returning it), and this file
/// must not depend on the caller having already sorted -- see the
/// "byte-identical across runs" test and this section's own comment.
fn routeLessThan(_: void, a: Route, b: Route) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.verb, b.verb) == .lt,
    };
}
