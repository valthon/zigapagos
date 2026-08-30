//! Renders the human MIGRATION.md worklist. Pure: takes in-memory inventory
//! and route data and returns markdown, so it is testable without a
//! filesystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const inventory = @import("inventory.zig");
const integrations = @import("integrations.zig");
const blockers = @import("blockers.zig");
const routes = @import("routes.zig");
const classify = @import("classify.zig");
const findings = @import("findings.zig");

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
    /// Task 5's join: `classifications[i]` is `routes[i]`'s
    /// `classify.Verdict` (`rails.zig`'s `discover` calls `classifyRoutes`
    /// to build this, index-aligned with `routes`). Defaulted to empty
    /// alongside `routes` for the same reason `routes` defaults empty --
    /// but whenever `routes` is non-empty, the caller must supply exactly
    /// one classification per route; `build` asserts the lengths match
    /// rather than silently rendering an unclassified route or
    /// misaligning the pairing.
    classifications: []const classify.Verdict = &.{},
    /// #167 Stage 1: `findings.derive`'s result -- per-fragment questions
    /// for the operator, rendered in their own `## Findings` section after
    /// Blockers (see that section's own doc for why it is a SEPARATE
    /// section, not folded into Blockers). Defaulted to empty for the same
    /// reason `routes` defaults empty: every report test written before
    /// this field existed keeps compiling unchanged.
    findings: []const findings.Finding = &.{},
};

const unresolved_verdict: classify.Verdict = .{ .class = .unresolved, .reason = "test stub", .candidates = &.{} };
const content_verdict: classify.Verdict = .{ .class = .content, .reason = "test stub", .candidates = &.{} };

test "routes render with their origin, and uncertain ones are marked" {
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/", .controller = "home", .action = "index", .name = "root", .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/x", .controller = null, .action = null, .name = null, .certain = false, .origin = .static_ast },
    };
    const vs = [_]classify.Verdict{ content_verdict, unresolved_verdict };
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
        .classifications = &vs,
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
    // The certain route's line must end right after its class with nothing
    // else appended; the uncertain route's line must carry both the
    // uncertainty marker AND its class -- they are independent claims. This
    // also pins that the root route ("/") actually rendered, rather than
    // "GET /" merely being a substring of "GET /x".
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /` → `home#index` — content (test stub)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /x` — **uncertain** — unresolved (test stub)\n") != null);
}

test "a known controller with no action still renders, not silently dropped" {
    // `get "/x", controller: "a"` parses to controller="a", action=null (no
    // unresolved entry -- the earlier `action ||= seg` narrowing on this
    // branch deliberately stopped inventing actions from path strings).
    // Rendering nothing here would drop known information from the
    // worklist, which is the opposite of what this report is for.
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/x", .controller = "a", .action = null, .name = null, .certain = true, .origin = .static_ast },
    };
    const vs = [_]classify.Verdict{unresolved_verdict};
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(
        u8,
        md,
        "- `GET /x` → controller `a`, action unknown — unresolved (test stub)\n",
    ) != null);
}

test "a known action with no controller still renders, not silently dropped" {
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/x", .controller = null, .action = "show", .name = null, .certain = true, .origin = .static_ast },
    };
    const vs = [_]classify.Verdict{unresolved_verdict};
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(
        u8,
        md,
        "- `GET /x` → action `show`, controller unknown — unresolved (test stub)\n",
    ) != null);
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
            .{ .code = "RAILS_SIDECAR_MISSING", .path = "sidecar/rails/analyze.rb", .detail = "ZIGAPAGOS_RUNTIME_DIR is not set", .severity = .@"error", .line = null },
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
            .{ .code = "RAILS_ROUTE_ENGINE_MOUNT", .path = "config/routes.rb", .detail = "mount is not evaluated", .severity = .warn, .line = null },
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
            .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/x.html.haml", .detail = "Haml template is not converted", .severity = .warn, .line = null },
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
    // Index-aligned with `unsorted`, not with the sorted render order --
    // `build` is responsible for keeping each verdict paired with its own
    // route through the sort (see `RouteVerdict`).
    const vs = [_]classify.Verdict{
        .{ .class = .backend, .reason = "test stub", .candidates = &.{} },
        content_verdict,
        content_verdict,
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &unsorted,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md);

    const root_pos = std.mem.indexOf(u8, md, "`GET /`").?;
    const posts_get_pos = std.mem.indexOf(u8, md, "`GET /posts`").?;
    const posts_post_pos = std.mem.indexOf(u8, md, "`POST /posts`").?;
    // "/" < "/posts" lexically, and within "/posts", GET < POST.
    try std.testing.expect(root_pos < posts_get_pos);
    try std.testing.expect(posts_get_pos < posts_post_pos);
}

test "routes tying on (path, verb) still sort deterministically, by controller/action (B7)" {
    // Two rows identical in the OLD comparator's only two compared fields
    // (path, verb) -- exactly the shape fix round B / B7 closes: `std.mem.
    // sort` is not stable, so a comparator returning `lessThan(a,b) ==
    // lessThan(b,a) == false` for a tied pair leaves their relative render
    // order dependent on INPUT order, not on any property of the rows.
    // Feeding the SAME two rows in both orders and requiring the SAME
    // render order both times is what actually catches that: asserting the
    // order once would pass by accident on whichever order this build
    // happens to already produce for one fixed input.
    const zebra = routes.Route{ .verb = "GET", .path = "/x", .controller = "zebra", .action = "show", .name = null, .certain = true, .origin = .static_ast };
    const alpha = routes.Route{ .verb = "GET", .path = "/x", .controller = "alpha", .action = "show", .name = null, .certain = true, .origin = .static_ast };
    const vs = [_]classify.Verdict{ content_verdict, content_verdict };

    const forward = [_]routes.Route{ zebra, alpha };
    const md_forward = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &forward,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md_forward);

    const reverse = [_]routes.Route{ alpha, zebra };
    const md_reverse = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &reverse,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md_reverse);

    const alpha_pos_fwd = std.mem.indexOf(u8, md_forward, "alpha#show").?;
    const zebra_pos_fwd = std.mem.indexOf(u8, md_forward, "zebra#show").?;
    const alpha_pos_rev = std.mem.indexOf(u8, md_reverse, "alpha#show").?;
    const zebra_pos_rev = std.mem.indexOf(u8, md_reverse, "zebra#show").?;

    // "alpha" < "zebra" lexically: alpha must render first regardless of
    // which order the two rows were PASSED in.
    try std.testing.expect(alpha_pos_fwd < zebra_pos_fwd);
    try std.testing.expect(alpha_pos_rev < zebra_pos_rev);
}

test "each route renders with its classification, and an uncertain route still names its class" {
    // Task 5 brief's exact required line for the content route (verbatim).
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/mystery", .controller = null, .action = null, .name = null, .certain = true, .origin = .static_ast },
    };
    const vs = [_]classify.Verdict{ content_verdict, unresolved_verdict };
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /posts` → `posts#index` — content (test stub)\n") != null);
    // The brief's sketch for the second route only checked
    // `indexOf(md, "unresolved") != null` -- that passes even if the
    // classification summary table (added by this same task, a few lines
    // above the route list) is the only place "unresolved" appears, or if
    // a WRONG route were the one marked unresolved. Pinning the exact
    // rendered line for /mystery is what actually proves THIS route's join
    // produced `unresolved`, not merely that the word occurs somewhere in
    // the document.
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /mystery` — unresolved (test stub)\n") != null);
}

test "two routes unresolved for DIFFERENT rules render DIFFERENT reasons -- not a constant" {
    // Stage 5's final-fix round (finding 1): a test that only asserts the
    // rendered reason is non-empty would pass against a hardcoded constant
    // exactly as well as against the real per-rule text. This pins two
    // routes that reach `unresolved` through genuinely different rules
    // (classify.zig's real `classify`, not a test stub) and asserts their
    // rendered lines differ specifically in the parenthesized reason.
    const rs = [_]routes.Route{
        .{ .verb = "GET", .path = "/a", .controller = null, .action = null, .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/b", .controller = "b", .action = "show", .name = null, .certain = true, .origin = .static_ast },
    };
    // /a: no view, no action, controller evidence available -> classify.zig
    // rule 2's "no view template and no controller action were recovered"
    // branch returns `backend`, not `unresolved` -- so to pin two DISTINCT
    // `unresolved` reasons here we instead build the verdicts directly from
    // `classify.classify` for two inputs that both land on `unresolved`
    // through different rules: no view at all (rule 4's guard) vs. an
    // unsupported template engine (rule 4 proper).
    const v_no_view = classify.classify(.{
        .verb = "GET",
        .view = null,
        .action = .{ .controller = "a", .action = "index" },
    });
    const v_bad_engine = classify.classify(.{
        .verb = "GET",
        .view = .{ .path = "app/views/b/show.haml", .engine = .haml, .markers = .{} },
        .action = .{ .controller = "b", .action = "show" },
    });
    try std.testing.expectEqual(classify.Class.unresolved, v_no_view.class);
    try std.testing.expectEqual(classify.Class.unresolved, v_bad_engine.class);
    try std.testing.expect(!std.mem.eql(u8, v_no_view.reason, v_bad_engine.reason));

    const vs = [_]classify.Verdict{ v_no_view, v_bad_engine };
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /a` — unresolved (no view template to classify)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "- `GET /b` → `b#show` — unresolved (unsupported template engine, never converted)\n") != null);
}

test "a classification summary counts every class" {
    // Three routes: two backend, one content, zero of everything else. The
    // table must account for every route -- a class silently dropped from
    // the render loop (e.g. a `Class` tag added to the enum but not to
    // `build`'s summary loop) shows up here as a count mismatch, the same
    // property "report lists counts... " pins for the Inventory table.
    const rs = [_]routes.Route{
        .{ .verb = "POST", .path = "/posts", .controller = "posts", .action = "create", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "DELETE", .path = "/posts/:id", .controller = "posts", .action = "destroy", .name = null, .certain = true, .origin = .static_ast },
    };
    const backend_verdict: classify.Verdict = .{ .class = .backend, .reason = "test stub", .candidates = &.{} };
    const vs = [_]classify.Verdict{ backend_verdict, content_verdict, backend_verdict };
    const md = try build(std.testing.allocator, .{
        .app_path = "app",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .routes = &rs,
        .route_mode = "static_ast",
        .classifications = &vs,
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "| content | 1 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| island | 0 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| spa | 0 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| backend | 2 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| redirect | 0 |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| unresolved | 0 |\n") != null);
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
        .{ .name = "propshaft", .version = null, .evidence = "Gemfile:propshaft" },
    };
    // Constructed by hand rather than via
    // `inventory.appendUnsupportedEngineBlockers` -- that function has its
    // own test in inventory.zig; this file's tests are about rendering, not
    // construction, so they only need literal `Blocker` values to render.
    const rail_blockers = [_]blockers.Blocker{
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/posts/index.html.haml", .detail = "Haml template is not converted", .severity = .warn, .line = null },
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/posts/legacy.html.slim", .detail = "Slim template is not converted", .severity = .warn, .line = null },
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
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/z.html.haml", .detail = "Haml template is not converted", .severity = .warn, .line = null },
        .{ .code = "RAILS_INVENTORY_UNREADABLE", .path = "public", .detail = "AccessDenied", .integrity = true, .severity = .@"error", .line = null },
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/a.html.haml", .detail = "Haml template is not converted", .severity = .warn, .line = null },
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

test "blockers tying on (code, path) still sort deterministically, by detail (B7)" {
    // Same shape as the routes test above, for `blockerLessThan`: two rows
    // tied on the OLD comparator's only two compared fields (code, path),
    // fed in both input orders, must render in the SAME order both times.
    const zebra = Blocker{ .code = "RAILS_CONTROLLER_PARSE_ERROR", .path = "app/controllers/x_controller.rb", .detail = "zebra reason", .severity = .warn, .line = null };
    const alpha = Blocker{ .code = "RAILS_CONTROLLER_PARSE_ERROR", .path = "app/controllers/x_controller.rb", .detail = "alpha reason", .severity = .warn, .line = null };

    const forward = [_]Blocker{ zebra, alpha };
    const md_forward = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &forward,
    });
    defer std.testing.allocator.free(md_forward);

    const reverse = [_]Blocker{ alpha, zebra };
    const md_reverse = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &reverse,
    });
    defer std.testing.allocator.free(md_reverse);

    const alpha_pos_fwd = std.mem.indexOf(u8, md_forward, "alpha reason").?;
    const zebra_pos_fwd = std.mem.indexOf(u8, md_forward, "zebra reason").?;
    const alpha_pos_rev = std.mem.indexOf(u8, md_reverse, "alpha reason").?;
    const zebra_pos_rev = std.mem.indexOf(u8, md_reverse, "zebra reason").?;

    // "alpha reason" < "zebra reason" lexically: alpha must render first
    // regardless of which order the two rows were PASSED in.
    try std.testing.expect(alpha_pos_fwd < zebra_pos_fwd);
    try std.testing.expect(alpha_pos_rev < zebra_pos_rev);
}

test "blockerLessThan: two rows identical in (code, path, detail) tiebreak by route_id (fix round 2 / F8)" {
    // phase-1-review.md's own reproduction: `RAILS_TEMPLATE_RENDER_DEPTH_
    // EXCEEDED` is not deduped per file (unlike `RAILS_TEMPLATE_
    // UNREADABLE`), so two routes hitting the SAME over-nested partial
    // chain append two blockers identical in (code, path, detail) and
    // differing only in `route_id` -- exactly what the pre-fix 3-field
    // comparator treated as EQUAL (neither `lessThan(a,b)` nor
    // `lessThan(b,a)` true), leaving their relative order unspecified by
    // this comparator alone.
    const a = Blocker{
        .code = "RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED",
        .path = "app/views/posts/_p3.html.erb",
        .detail = "partial nesting exceeds the depth this scan follows; unify or flatten these partials",
        .severity = .warn,
        .route_id = "GET /posts/profile",
        .line = null,
    };
    const b = Blocker{
        .code = "RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED",
        .path = "app/views/posts/_p3.html.erb",
        .detail = "partial nesting exceeds the depth this scan follows; unify or flatten these partials",
        .severity = .warn,
        .route_id = "GET /posts/recent",
        .line = null,
    };
    // "GET /posts/profile" < "GET /posts/recent" lexically.
    try std.testing.expect(blockerLessThan({}, a, b));
    try std.testing.expect(!blockerLessThan({}, b, a));
    // A TOTAL order over this pair: exactly one direction is strictly less.
    try std.testing.expect(!(blockerLessThan({}, a, b) and blockerLessThan({}, b, a)));
}

test "blockerLessThan: two rows identical in (code, path, detail, route_id) tiebreak by severity (fix round 2 / F8)" {
    const a = Blocker{
        .code = "RAILS_ROUTE_CONDITIONAL",
        .path = "config/routes.rb",
        .detail = "conditional route",
        .severity = .@"error",
        .route_id = "GET /admin/health",
        .line = null,
    };
    const b = Blocker{
        .code = "RAILS_ROUTE_CONDITIONAL",
        .path = "config/routes.rb",
        .detail = "conditional route",
        .severity = .warn,
        .route_id = "GET /admin/health",
        .line = null,
    };
    // `.@"error"` (declared first in `blockers.Severity`) sorts before
    // `.warn`.
    try std.testing.expect(blockerLessThan({}, a, b));
    try std.testing.expect(!blockerLessThan({}, b, a));
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

const report_choices = [_][]const u8{ "retain", "blocked" };

test "build: a Findings section lists count-per-code and one exact line per finding" {
    const fs = [_]findings.Finding{
        .{ .id = "RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C9", .code = "RAILS_HELPER_UNKNOWN", .severity = .warn, .path = "app/views/posts/index.html.erb", .line = 1, .route_id = null, .message = "unknown helper `number_to_currency`", .choices = &report_choices, .requires_artifact = false },
        .{ .id = "RAILS_LAYOUT_DYNAMIC.app/controllers/posts_controller%2Erb.L2", .code = "RAILS_LAYOUT_DYNAMIC", .severity = .warn, .path = "app/controllers/posts_controller.rb", .line = 2, .route_id = null, .message = "controller declares a dynamic layout", .choices = &report_choices, .requires_artifact = false },
    };
    const md = try build(std.testing.allocator, .{ .app_path = "app", .entries = &.{}, .integrations = &.{}, .blockers = &.{}, .findings = &fs });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n## Findings\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- RAILS_HELPER_UNKNOWN: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- RAILS_LAYOUT_DYNAMIC: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n- `RAILS_HELPER_UNKNOWN` `app/views/posts/index.html.erb:1` — unknown helper `number_to_currency` (choices: retain, blocked)\n") != null);
}

test "build: zero findings still renders the section, saying so" {
    const md = try build(std.testing.allocator, .{ .app_path = "app", .entries = &.{}, .integrations = &.{}, .blockers = &.{} });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "\n## Findings\n\nNone.\n") != null);
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
    // `classifications` is index-aligned with `routes` -- see `Input`'s doc.
    // Every production caller (`rails.zig`'s `discover`) builds one via
    // `classifyRoutes`, one verdict per route; a mismatch here is a defect
    // in the caller, not a malformed input this function should degrade
    // around silently.
    std.debug.assert(in.classifications.len == in.routes.len);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    // The basename, never the path as given: an operator's absolute path is
    // machine-specific, and MIGRATION.md is committed beside the target.
    // `migrate.zig` resolves the source before it reaches here, so `.` has
    // a name by this point (#178).
    w.print("# Migrating {s} to Zigapagos\n\n", .{std.fs.path.basename(in.app_path)}) catch return error.OutOfMemory;
    w.writeAll(
        \\Rails source discovery. This worklist inventories the presentation
        \\layer and the recovered route graph. Discovery itself converts
        \\nothing: run `migrate --from rails --target DIR` to assemble a
        \\Zigapagos project from it, and see the Handoff section below (when
        \\present) for what each route became.
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

        // The classification summary: one row per `classify.Class` value,
        // counts summing to the route total -- the same "a kind silently
        // dropped shows up as a count mismatch" property the Inventory
        // table above has. Iterates `std.meta.tags` (declaration order), not
        // a hand-picked subset, so a future `Class` addition is covered
        // without a second edit here.
        w.writeAll("| Class | Count |\n| --- | --- |\n") catch return error.OutOfMemory;
        for (std.meta.tags(classify.Class)) |c| {
            w.print("| {s} | {d} |\n", .{ @tagName(c), classCount(in.classifications, c) }) catch return error.OutOfMemory;
        }
        w.writeAll("\n") catch return error.OutOfMemory;

        // Paired and sorted in a private copy for the same reason the
        // blockers section below sorts its own copy: determinism is
        // `build`'s responsibility, independent of whatever order the
        // caller's route discovery produced (`discoverRoutes` already
        // sorts, but this report must not depend on that -- an artifact
        // people diff has to be stable on its own terms). Paired (not two
        // parallel sorts) so each route's classification travels with it
        // through the reorder.
        const paired = try gpa.alloc(RouteVerdict, in.routes.len);
        defer gpa.free(paired);
        for (in.routes, in.classifications, 0..) |r, v, i| paired[i] = .{ .route = r, .verdict = v };
        std.mem.sort(RouteVerdict, paired, {}, routeVerdictLessThan);
        for (paired) |rv| {
            const r = rv.route;
            w.print("- `{s} {s}`", .{ r.verb, r.path }) catch return error.OutOfMemory;
            // Render whatever half of the destination is actually known --
            // dropping a known controller (or action) because the other
            // half is unknown throws away real information from a
            // migration worklist. `controller#action` is reserved for the
            // case both halves are known, so a reader can never mistake a
            // half-known destination for a complete one.
            if (r.controller) |c| {
                if (r.action) |a| {
                    w.print(" → `{s}#{s}`", .{ c, a }) catch return error.OutOfMemory;
                } else {
                    w.print(" → controller `{s}`, action unknown", .{c}) catch return error.OutOfMemory;
                }
            } else if (r.action) |a| {
                w.print(" → action `{s}`, controller unknown", .{a}) catch return error.OutOfMemory;
            }
            // `certain == false` must be visibly distinguished at a glance,
            // not just on close reading -- a route recovered from a
            // construct the parser could not evaluate is a materially
            // weaker claim than one read straight out of the DSL. This is
            // independent of the classification appended below: a route can
            // be uncertain AND classified -- those are separate claims.
            if (!r.certain) {
                w.writeAll(" — **uncertain**") catch return error.OutOfMemory;
            }
            // The reason travels on every line, not just `unresolved` ones:
            // Stage 5's final-fix round found `unresolved` routes with
            // neither a `reason` a reader could see nor a blocker naming
            // why -- `candidates[]` is empty by design for `unresolved`
            // (see `classify.zig`'s rule chain), so `reason` is the ONLY
            // evidence a human has for those routes specifically. Rendering
            // it uniformly (not "just for unresolved") keeps one code path
            // instead of a class-conditional branch, and lets every other
            // classification's reason be spot-checked the same way.
            w.print(" — {s} ({s})\n", .{ @tagName(rv.verdict.class), rv.verdict.reason }) catch return error.OutOfMemory;
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

    // #167 Stage 1: a SEPARATE section from Blockers, deliberately -- see
    // `Input.findings`'s doc and `findings.zig`'s module doc for why a
    // blocker (a fact discovery already settled) and a finding (a choice
    // left to the operator) must not be mixed into one list a reader could
    // mistake for a single kind of thing.
    w.writeAll("\n## Findings\n\n") catch return error.OutOfMemory;
    if (in.findings.len == 0) {
        w.writeAll("None.\n") catch return error.OutOfMemory;
    } else {
        // Sorted in a private copy, the same "determinism is this
        // function's own responsibility" stance the Blockers section above
        // already takes -- never trusting that `findings.derive` (or
        // whatever else built the caller's list) already sorted it.
        const sorted_findings = try gpa.dupe(findings.Finding, in.findings);
        defer gpa.free(sorted_findings);
        std.mem.sort(findings.Finding, sorted_findings, {}, findings.lessThan);

        // One count line per DISTINCT code. `sorted_findings` is already
        // ordered primarily by code (findings.lessThan), so equal codes are
        // already adjacent -- this single forward pass only needs to notice
        // where the code changes, not a second sort/dedup structure.
        var i: usize = 0;
        while (i < sorted_findings.len) {
            const code = sorted_findings[i].code;
            var count: usize = 0;
            while (i < sorted_findings.len and std.mem.eql(u8, sorted_findings[i].code, code)) : (i += 1) count += 1;
            w.print("- {s}: {d}\n", .{ code, count }) catch return error.OutOfMemory;
        }
        w.writeAll("\n") catch return error.OutOfMemory;

        for (sorted_findings) |f| {
            if (f.line) |l| {
                w.print("- `{s}` `{s}:{d}` — {s}", .{ f.code, f.path, l, f.message }) catch return error.OutOfMemory;
            } else {
                w.print("- `{s}` `{s}` — {s}", .{ f.code, f.path, f.message }) catch return error.OutOfMemory;
            }
            w.writeAll(" (choices: ") catch return error.OutOfMemory;
            for (f.choices, 0..) |c, ci| {
                if (ci > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(c) catch return error.OutOfMemory;
            }
            w.writeAll(")\n") catch return error.OutOfMemory;
        }
    }

    return aw.toOwnedSlice();
}

const Blocker = blockers.Blocker;

/// `std.mem.sort` (used by both sort call sites below) is NOT stable, so a
/// comparator that ever returns `false` for BOTH `lessThan(a, b)` and
/// `lessThan(b, a)` on two rows whose RENDERED text differs leaves that
/// pair's relative order unspecified -- a determinism violation the report's
/// own "byte-identical across runs" guarantee (and Stage 4's drift gate)
/// depend on not happening (fix round B / B7). `blockerLessThan` and
/// `routeLessThan` below are both extended with one more tiebreak field so
/// that any two rows differing in what actually gets PRINTED also differ
/// under the comparator; `std.mem.order`'s `.eq` case chaining into the next
/// field (rather than an early truthy return) is what makes each one a
/// total order over the fields the render loop reads, not three independent
/// partial checks.
/// Fix round 2 (phase-1-review.md F8 / phase-1-fixes.md finding 7):
/// `code`/`path`/`detail` alone is a total order over what THIS renderer
/// prints (see this function's own doc), but Task 1 widened `Blocker` past
/// what those three fields can discriminate -- two
/// `RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED` blockers from different routes
/// sharing one over-nested partial chain are identical in `(code, path,
/// detail)` and differ only in `severity`/`route_id`, which reached this
/// comparator un-ordered and rendered as duplicate lines (reproduced by the
/// reviewer against the fixture: two routes both hitting `_p3.html.erb`'s
/// depth cap print the SAME `RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED` line
/// twice). Widened below with `severity` then `route_id` as two more
/// tiebreaks, keeping the whole comparator a TOTAL order over `Blocker` --
/// not merely "does not crash" -- so it stays correct for any later reader
/// (Phase 2's manifest emitter, should it reuse this sort) that DOES render
/// those two fields, not just for this file's own three-field print line.
/// `pub` (Stage 4 Task 8): `manifest.zig` reuses this exact comparator to
/// sort the manifest's own `blockers[]` (spec, "The manifest" -- "blockers
/// ... by (code, file, line)"), rather than declaring a second copy that
/// could silently drift from this one's already-hard-won total order (fix
/// round 2, phase-1-review.md F8 -- see this function's own doc above). One
/// comparator means the human-readable report and the machine-readable
/// manifest always agree on blocker order.
pub fn blockerLessThan(_: void, a: Blocker, b: Blocker) bool {
    // Rendered as `- \`{code}\` {path}: {detail}\n` (see the Blockers
    // section below) -- `code`, `path`, `detail` is exactly the field order
    // that determines the printed line, so it is the tiebreak order here,
    // followed by `severity` then `route_id` (see this function's own doc
    // above for why those two are included despite not being printed here).
    return switch (std.mem.order(u8, a.code, b.code)) {
        .lt => true,
        .gt => false,
        .eq => switch (std.mem.order(u8, a.path, b.path)) {
            .lt => true,
            .gt => false,
            .eq => switch (std.mem.order(u8, a.detail, b.detail)) {
                .lt => true,
                .gt => false,
                .eq => switch (std.math.order(@intFromEnum(a.severity), @intFromEnum(b.severity))) {
                    .lt => true,
                    .gt => false,
                    .eq => orderOptionalString(a.route_id, b.route_id) == .lt,
                },
            },
        },
    };
}

const Route = routes.Route;

/// `?[]const u8` order, shared by `routeLessThan` (`Route.controller`/
/// `.action`) and, since fix round 2, `blockerLessThan` (`Blocker.route_id`)
/// above: `null` sorts before every string (an unresolved/absent half is
/// "less than" any known one), and two non-null values compare byte-wise.
/// Contract 3 (caller-buffer): no allocation.
pub fn orderOptionalString(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    const av = a orelse return if (b == null) .eq else .lt;
    const bv = b orelse return .gt;
    return std.mem.order(u8, av, bv);
}

/// Not imported from routes.zig: `routes.routeLessThan` is private (that
/// module sorts its own decoded result before returning it), and this file
/// must not depend on the caller having already sorted -- see the
/// "byte-identical across runs" test and this section's own comment.
///
/// `controller`/`action` are the third and fourth tiebreak keys (fix round
/// B / B7), after `path` and `verb`: two routes that tie on `(path, verb)`
/// but differ in `controller`/`action` render DIFFERENT text (see the
/// route-line loop below, which prints both), so the pre-B7 two-key
/// comparator left their relative order to `std.mem.sort`'s instability. Two
/// routes tying on all four are indistinguishable in what actually gets
/// printed on this line (verdict class/reason are rendered too, but those
/// are a pure function of verb/view/action -- identical verb+controller+
/// action routes cannot classify differently), so four keys are already a
/// total order over the rendered output, not merely "more tiebreaks".
///
/// `pub` (Stage 4 Task 8): `manifest.zig` reuses this comparator (via a
/// thin wrapper pairing each `Route` with its classification/template
/// graph, the same shape `RouteVerdict` below already models) to sort the
/// manifest's own `routes[]` (spec, "The manifest" -- "routes sorted by
/// (path, verb)"). Reusing rather than re-deriving is what keeps the
/// report and the manifest agreeing on route order, and keeps this
/// already-fixed total order (fix round B / B7) from being reinvented --
/// and possibly reintroducing its own partial-order bug -- a second time.
pub fn routeLessThan(_: void, a: Route, b: Route) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => switch (std.mem.order(u8, a.verb, b.verb)) {
            .lt => true,
            .gt => false,
            .eq => switch (orderOptionalString(a.controller, b.controller)) {
                .lt => true,
                .gt => false,
                .eq => orderOptionalString(a.action, b.action) == .lt,
            },
        },
    };
}

/// A route paired with its `classify.Verdict`, so the two travel together
/// through `build`'s private sort -- see `Input.classifications`'s doc for
/// the index-alignment this pairing exists to preserve once the caller's
/// order is discarded.
const RouteVerdict = struct { route: Route, verdict: classify.Verdict };

fn routeVerdictLessThan(_: void, a: RouteVerdict, b: RouteVerdict) bool {
    return routeLessThan({}, a.route, b.route);
}

/// Counts how many of `classifications` carry `class`. Linear scan, not a
/// precomputed histogram: `classifications` is at most a handful of routes
/// per run and this runs once per `classify.Class` tag (six calls), not
/// once per route.
fn classCount(classifications: []const classify.Verdict, class: classify.Class) usize {
    var n: usize = 0;
    for (classifications) |v| {
        if (v.class == class) n += 1;
    }
    return n;
}

/// The Handoff section's inputs: what `scaffold.zig` produced, reduced to the
/// numbers a human reader needs.
///
/// Deliberately a plain count struct rather than `handoff.Status` counts:
/// `handoff.zig` imports THIS file (for `routeLessThan`), so taking its types
/// here would close an import cycle for no gain -- the section renders six
/// numbers and a boolean, none of which need the wire types' semantics.
pub const HandoffSummary = struct {
    /// `handoff.isComplete`'s verdict, verbatim -- never recomputed here, so
    /// the report and the JSON artifact beside it cannot disagree.
    complete: bool,
    migrated: usize = 0,
    open: usize = 0,
    blocked: usize = 0,
    retained: usize = 0,
    backend: usize = 0,
    redirect: usize = 0,
};

/// The `## Handoff` section, rendered SEPARATELY from `build` and appended by
/// `migrate.zig` after the scaffold has run.
///
/// Why not a `build` input: `rails.discover` builds the report, and it does so
/// before `scaffold.write` exists to be summarised -- the conversion outcome is
/// not known until after `discover` has returned. Threading a
/// `?HandoffSummary` through `Input` would therefore add a branch no production
/// caller could ever take with a non-null value. The report is markdown, the
/// section is the last one (`build` ends with `## Findings`), and concatenation
/// is the whole join.
///
/// Contract 1 (self-freeing): all scratch is released; the returned markdown is
/// the single escaping allocation, owned by the caller. No timestamps, no
/// absolute paths -- identical input renders identical bytes.
pub fn handoffSection(gpa: Allocator, in: HandoffSummary) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    // Leading newline, matching every other section's own separator: `build`
    // leaves the document without a trailing blank line, so the caller can
    // concatenate this directly onto it.
    w.writeAll("\n## Handoff\n\n") catch return error.OutOfMemory;
    w.print("complete: {s}\n\n", .{if (in.complete) "true" else "false"}) catch return error.OutOfMemory;
    w.writeAll(
        \\`MIGRATION.handoff.json` records what each recovered route became.
        \\
        \\| Status | Routes |
        \\| --- | --- |
        \\
    ) catch return error.OutOfMemory;
    // Fixed order, not sorted by count: the six statuses are a vocabulary, and
    // a reader diffing two runs needs the rows to stay in the same places.
    w.print("| migrated | {d} |\n", .{in.migrated}) catch return error.OutOfMemory;
    w.print("| open | {d} |\n", .{in.open}) catch return error.OutOfMemory;
    w.print("| blocked | {d} |\n", .{in.blocked}) catch return error.OutOfMemory;
    w.print("| retained | {d} |\n", .{in.retained}) catch return error.OutOfMemory;
    w.print("| backend | {d} |\n", .{in.backend}) catch return error.OutOfMemory;
    w.print("| redirect | {d} |\n", .{in.redirect}) catch return error.OutOfMemory;

    if (in.complete) {
        // `bash`, not `sh`. `scaffold.emitBuildSh` writes
        // `#!/usr/bin/env bash` and `set -euo pipefail`, and `pipefail` is not
        // in POSIX `set` -- run under dash (which is `/bin/sh` on Debian and
        // Ubuntu) the script dies on line 2 with `Illegal option -o pipefail`
        // and exit 2, before it builds anything. The one instruction the
        // report gives an operator whose migration is FINISHED has to work.
        w.writeAll(
            \\
            \\Next: every user-facing route is accounted for. Build the target
            \\with `bash build.sh`, then check it with `zigapagos doctor`.
            \\
        ) catch return error.OutOfMemory;
    } else {
        // Names the file, the key, and the shape of one entry: an operator
        // reading only this paragraph has to be able to write the next line of
        // `MIGRATION.decisions.json` without opening the docs.
        w.writeAll(
            \\
            \\Next: each `open` route in `MIGRATION.handoff.json` lists the
            \\finding ids still unanswered. Answer each one in
            \\`MIGRATION.decisions.json` -- `{"id": "<finding id>", "choice":
            \\"<one of that finding's choices>", "rationale": "why"}` -- then
            \\delete everything in the target except that file and re-run the
            \\same command.
            \\
        ) catch return error.OutOfMemory;
    }

    return aw.toOwnedSlice();
}

test "handoffSection: an incomplete run renders the counts and the decide-and-re-run instruction" {
    const md = try handoffSection(std.testing.allocator, .{
        .complete = false,
        .migrated = 1,
        .open = 4,
        .backend = 5,
        .redirect = 1,
    });
    defer std.testing.allocator.free(md);
    // Golden: the whole section, byte for byte. A substring check would pass
    // an implementation that rendered the table twice or lost the separator
    // the caller concatenates against.
    try std.testing.expectEqualStrings(
        \\
        \\## Handoff
        \\
        \\complete: false
        \\
        \\`MIGRATION.handoff.json` records what each recovered route became.
        \\
        \\| Status | Routes |
        \\| --- | --- |
        \\| migrated | 1 |
        \\| open | 4 |
        \\| blocked | 0 |
        \\| retained | 0 |
        \\| backend | 5 |
        \\| redirect | 1 |
        \\
        \\Next: each `open` route in `MIGRATION.handoff.json` lists the
        \\finding ids still unanswered. Answer each one in
        \\`MIGRATION.decisions.json` -- `{"id": "<finding id>", "choice":
        \\"<one of that finding's choices>", "rationale": "why"}` -- then
        \\delete everything in the target except that file and re-run the
        \\same command.
        \\
    , md);
}

test "handoffSection: a complete run says so and points at the build, not at decisions" {
    const md = try handoffSection(std.testing.allocator, .{ .complete = true, .migrated = 3, .retained = 2 });
    defer std.testing.allocator.free(md);
    try std.testing.expectEqualStrings(
        \\
        \\## Handoff
        \\
        \\complete: true
        \\
        \\`MIGRATION.handoff.json` records what each recovered route became.
        \\
        \\| Status | Routes |
        \\| --- | --- |
        \\| migrated | 3 |
        \\| open | 0 |
        \\| blocked | 0 |
        \\| retained | 2 |
        \\| backend | 0 |
        \\| redirect | 0 |
        \\
        \\Next: every user-facing route is accounted for. Build the target
        \\with `bash build.sh`, then check it with `zigapagos doctor`.
        \\
    , md);
    // The discriminating half: a complete run must NOT tell the operator to
    // go on answering findings.
    try std.testing.expect(std.mem.indexOf(u8, md, "MIGRATION.decisions.json") == null);
}

test "handoffSection: the section appends onto build()'s output as the last section" {
    const gpa = std.testing.allocator;
    const body = try build(gpa, .{ .app_path = "app", .entries = &.{}, .integrations = &.{}, .blockers = &.{} });
    defer gpa.free(body);
    const tail = try handoffSection(gpa, .{ .complete = false, .open = 1 });
    defer gpa.free(tail);
    const joined = try std.mem.concat(gpa, u8, &.{ body, tail });
    defer gpa.free(joined);
    // `build` ends with the Findings section; the handoff must follow it, not
    // precede it (the operator reads the findings, then what to do about them).
    const findings_at = std.mem.indexOf(u8, joined, "\n## Findings\n").?;
    const handoff_at = std.mem.indexOf(u8, joined, "\n## Handoff\n").?;
    try std.testing.expect(findings_at < handoff_at);
}

test "report: the title is the app basename, never the path as given (#178)" {
    var entries = [_]inventory.Entry{};
    var ints = [_]integrations.Integration{};
    var rail_blockers = [_]blockers.Blocker{};
    const md = try build(std.testing.allocator, .{
        .app_path = "/home/someone/src/my-app/",
        .entries = &entries,
        .integrations = &ints,
        .blockers = &rail_blockers,
    });
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "# Migrating my-app to Zigapagos") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "/home/someone") == null);
}
