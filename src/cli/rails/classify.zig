//! Stage 3's classifier: turns the evidence the sibling files recovered
//! (`routes.Route`'s verb, `controllers.ActionInfo`'s action shape,
//! `template_scan.Markers`'s view markers) into one `Verdict` per route.
//! `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`'s
//! "Classification" section is the spec this implements: first match wins,
//! in the table's exact numbered order, and anything unmatched falls to
//! `unresolved` rather than a guess.
//!
//! **The order is load-bearing, not stylistic.** `content` is the only
//! verdict that asserts something POSITIVE -- "this page is safely static".
//! Every other outcome is a deferral (`unresolved`), a handoff (`backend`,
//! `redirect`), or a narrower claim (`island`). The error costs are
//! lopsided: a falsely-`unresolved` route costs a human one look; a
//! falsely-`content` route makes the migration build a static page for a
//! page that is not static, and the site breaks silently for a visitor.
//! `content` therefore sits LAST in the chain below, reachable only once
//! every earlier (negative) rule has failed to fire. Rule 5 (request-time
//! state) is checked before rule 6 (interactivity markers) for the same
//! reason at a smaller scale: a page that is both interactive AND reads
//! session state is not a static island we can build yet -- the state has
//! to be resolved first (that is issue #167's job, not this one's).
//!
//! **Rule 2 is the spec's conjunction on "no view template", not three
//! independent triggers.** The spec's row 2 reads "no view template; action
//! renders JSON or is absent" -> `backend`: BOTH halves require `view ==
//! null` before either sub-clause can fire. This branch shipped a narrower
//! reading once (only the `action == null` half was gated on `view ==
//! null`, with `renders_json` firing independent of `view`) and a
//! whole-branch review found the gap it opens: `controllers.rb`'s
//! `any_render_json?` walks the ENTIRE method body, so `renders_json`
//! does not mean "this action is an API endpoint" -- it means "this action
//! CAN also answer JSON", which is true of the single most common
//! dual-format idiom in Rails:
//!
//! ```ruby
//! def show
//!   respond_to { |f| f.html; f.json { render json: @post } }
//! end
//! ```
//!
//! Gating only the `action == null` half meant that idiom classified
//! `backend` even with a real, static `show.html.erb` present -- a
//! positive claim a human would act on, wrong. The fix (and the spec's
//! literal reading) is the full conjunction below: neither sub-clause may
//! fire while a view exists.
//!
//! `action == null` is also not a rare edge case even once gated on `view
//! == null`: it is the shape of the ENTIRE controller-analysis degradation
//! path (no Ruby, no sidecar, no `app/controllers/`: `discoverControllers`
//! returns zero actions with `integrity = false` and the run still exits
//! 0). Under that degradation, `view == null and action == null` would
//! still positively assert "backend" for every view-less route, when the
//! honest statement is "we could not read your controllers". So that
//! sub-clause carries a SECOND gate, `controller_evidence_available` (see
//! `Input`'s doc): when controller-shape discovery degraded wholesale, no
//! verdict may rest on an absent `action`, because absence is not evidence
//! under that condition -- it is the SAME non-signal for every route in the
//! app. `action.renders_json`'s sub-clause needs no such gate: a `renders_json
//! == true` action was actually recovered, so its presence is real evidence
//! regardless of why OTHER routes' actions are missing.
//!
//! "no view template" is deliberately NOT its own independent trigger
//! either: if it were, a `view == null` route would be swallowed by rule 2
//! before rule 3 (redirect) ever ran, misclassifying a pure-redirect
//! action as `backend` merely because a redirecting action has no view.
//!
//! A route with a view but no recovered action falls through rules 3-6 (all
//! either need an action they don't have, or reason about the view only)
//! to a gated rule 7: reaching `content` -- the one verdict that asserts
//! something positive -- also requires `action != null`, for the identical
//! reason rule 2's conjunction exists: no controller evidence means no
//! proof the action is safe, and only `unresolved` is honest about that.
//! Rule 6 (`island`) is deliberately left ungated -- a Stimulus controller
//! or component root in the template is positive evidence standing on its
//! own, and `island` is a narrower claim than `content`.
//!
//! **Rule 5 also reads the view's LAYOUT and any partials it (or the
//! layout) renders, not just the view file itself.** `rails.zig`'s
//! `classifyRoutes` does the transitive scan and merge (layout by Rails'
//! per-controller-else-application convention, partials resolved from
//! literal `render` targets, one union of markers) and hands `classify`
//! the result through `ViewRef.markers`/`request_state_source` -- this
//! file has no filesystem access and does none of that walking itself. Two
//! consequences classify.zig's tests below can't see directly but are
//! worth knowing: `csrf_meta_tags`/`form_authenticity_token` (added to the
//! marker table for exactly this) now actually fire, because they live in
//! the layout in essentially every real Rails app; and a `render` target
//! `rails.zig` cannot resolve statically (a dynamic expression, or a
//! literal matching no inventory entry) makes a route that would otherwise
//! reach rule 7 land on `unresolved` instead -- unscanned content is
//! evidence this file does not have, and `content` is the one verdict that
//! must not be asserted without it.
//!
//! **Rule 4, read broader than "Haml or Slim" literally.** The spec table's
//! prose names Haml and Slim because those are the HTML template languages
//! in scope, but this implementation unresolves on ANY engine other than
//! `erb`: `jbuilder`/`builder` render JSON/XML data, not HTML, and `none`
//! means the engine could not even be identified -- all three are things
//! this adapter must not claim to have converted, for the same reason Haml
//! and Slim aren't. Only `erb` is a proven-safe engine today.
//!
//! `spa` is deliberately unreachable: nothing in Stage 3's evidence proves
//! a component root OWNS ROUTING (that needs the component's module and its
//! imports resolved, which is out of scope here), so a route with a
//! component-root marker still resolves to `island` via rule 6. The enum
//! value stays declared -- the spec and the eventual manifest schema need
//! it -- but inventing a heuristic to assign it would be the exact false
//! confidence issue #166 warns against.
//!
//! Contract 3 (caller-buffer): `classify` allocates nothing. Every `reason`
//! and every `Candidate` field is a string literal baked into the binary's
//! rodata, never a `gpa`-owned copy, so a `Verdict` owns nothing and there
//! is nothing for a caller to free.
//!
//! std-only, like every file in `src/cli/rails/`: the three sibling imports
//! below (`controllers`, `template_scan`, `inventory`) stay inside this
//! directory, and no `@import` here escapes it (`fatal.*` handling is not
//! this file's job).

const std = @import("std");
const controllers = @import("controllers.zig");
const template_scan = @import("template_scan.zig");
const inventory = @import("inventory.zig");

/// The issue's six classification values, kept verbatim, plus `unresolved`
/// for "matched nothing". See this file's module doc for why `spa` is
/// declared but never assigned by `classify`.
pub const Class = enum { content, island, spa, backend, redirect, unresolved };

/// One viable zigapagos shape for a route, with the evidence for it.
/// `classify`'s bare `class` states the Rails-side fact; `candidates`
/// serves the migration-target decision that comes after this stage (see
/// the design doc's "candidates: a deliberate addition" section).
pub const Candidate = struct {
    target: []const u8,
    evidence: []const u8,
};

pub const Verdict = struct {
    class: Class,
    reason: []const u8,
    candidates: []const Candidate,
};

/// Which contributing file `ViewRef.markers.request_state` was found in,
/// once `rails.zig`'s transitive scan has merged the view's own markers
/// with its layout's and any rendered partials' (module doc, "Rule 5 also
/// reads..."). Read only by rule 5's reason text below -- it does not
/// change WHETHER the rule fires, only how specifically the reason names
/// where the evidence came from. Defaults to `.view` so every existing
/// caller/test that never sets it (single-file evidence, same as before
/// this field existed) keeps its prior reason text unchanged.
pub const MarkerSource = enum { view, layout, partial };

/// The one view template a route's evidence bundle can carry. `engine` and
/// `markers` are `inventory.walk`'s and `template_scan.scan`'s outputs for
/// that file, respectively -- except `markers` may be a MERGE across the
/// view, its layout, and any partials it renders (see module doc); `path`
/// is carried for a future caller that wants to name the file in a report,
/// not read by `classify` itself.
pub const ViewRef = struct {
    path: []const u8,
    engine: inventory.Engine,
    markers: template_scan.Markers,
    request_state_source: MarkerSource = .view,
};

/// One route's evidence bundle: the HTTP verb straight off `routes.Route`,
/// the view template (if any) resolved for it, and the controller-action
/// shape (if controller analysis recovered one) for its controller#action
/// pair. All optional except `verb` -- a route with neither a view nor an
/// action recovered is exactly as classifiable as one with both (see rule
/// 2 in the module doc), just less informatively so.
pub const Input = struct {
    verb: []const u8,
    view: ?ViewRef = null,
    action: ?controllers.ActionInfo = null,
    /// `false` only when controller-shape discovery degraded WHOLESALE for
    /// this run (`rails.zig`'s `discover` saw a `RAILS_CONTROLLERS_MISSING`
    /// or `RAILS_CONTROLLERS_UNAVAILABLE` blocker) -- as opposed to a
    /// successful run that simply never found THIS route's action. In the
    /// degraded case `action == null` carries no information about any
    /// particular route: it is exactly as true for a route with real
    /// backend behavior as for one with none, so rule 2's `action == null`
    /// sub-clause must not rest a `backend` verdict on it (see module doc).
    /// Defaults to `true` so every caller/test written before this field
    /// existed keeps classifying as it always did.
    controller_evidence_available: bool = true,
};

const no_candidates: []const Candidate = &.{};

/// Pure, contract 3 (caller-buffer): see the module doc. First match wins,
/// in the spec's exact numbered order -- do not reorder without reading
/// that doc's "order is load-bearing" section first.
pub fn classify(in: Input) Verdict {
    // Rule 1: verb not in {GET, HEAD} -> backend, unconditionally. Nothing
    // past this point matters if the request isn't idempotent-safe.
    if (!std.mem.eql(u8, in.verb, "GET") and !std.mem.eql(u8, in.verb, "HEAD")) {
        return .{
            .class = .backend,
            .reason = "non-GET verb is a backend responsibility",
            .candidates = no_candidates,
        };
    }

    // Rule 2: the spec's full conjunction on "no view template" -- see
    // module doc for why BOTH sub-clauses below require `in.view == null`
    // (a view present, even on a `renders_json` action, is real evidence
    // the route is not backend-only) and why the `action == null`
    // sub-clause carries a second gate on top of that.
    if (in.view == null) {
        if (in.action) |action| {
            // Second sub-clause: a recovered action that renders JSON. Real,
            // recovered evidence about THIS action's shape -- not a
            // degradation signal -- so it needs no `controller_evidence_
            // available` gate the way the sub-clause below does.
            if (action.renders_json) {
                return .{
                    .class = .backend,
                    .reason = "action renders JSON, not a view",
                    .candidates = no_candidates,
                };
            }
        } else {
            // First sub-clause: no view AND no action. Gated on
            // `controller_evidence_available` -- when controller-shape
            // discovery degraded wholesale, `action == null` is not evidence
            // about THIS route, it is the absence of evidence about EVERY
            // route, and no verdict may rest on that (see `Input`'s doc).
            if (in.controller_evidence_available) {
                return .{
                    .class = .backend,
                    .reason = "no view template and no controller action were recovered for this route",
                    .candidates = no_candidates,
                };
            }
            return .{
                .class = .unresolved,
                .reason = "no view template, and controller evidence was unavailable for this run",
                .candidates = no_candidates,
            };
        }
    }

    // Rule 3: an action whose body is only `redirect_to`. Guarded on
    // `in.action` being present -- a `view == null` route with no action
    // at all already returned above; a `view != null` route with no
    // action falls through this (no action to check) to rules 4-7's
    // view-only reasoning, gated at rule 7 (see module doc).
    if (in.action) |action| {
        if (action.only_redirect) {
            return .{
                .class = .redirect,
                .reason = "controller action only issues a redirect",
                .candidates = no_candidates,
            };
        }
    }

    // Rules 4-6 all reason about the view template, so they all need one to
    // exist first: a route with an action but no view returns immediately
    // right here (fix round B / B6: this is a guard ABOVE rule 4, not a
    // trailing catch-all -- rule 7 below is what returns `content`, and it
    // has its own, different gate/reason for the reverse case, a view with
    // no action).
    const view = in.view orelse return .{
        .class = .unresolved,
        .reason = "no view template to classify",
        .candidates = no_candidates,
    };

    // Rule 4: only `erb` is a proven-safe template engine (see module doc
    // for why this is broader than the spec prose's literal "Haml or
    // Slim" -- it also unresolves `jbuilder`, `builder`, and `none`).
    if (view.engine != .erb) {
        return .{
            .class = .unresolved,
            .reason = "unsupported template engine, never converted",
            .candidates = no_candidates,
        };
    }

    // Rule 5: the view (or, per `request_state_source`, its layout or a
    // rendered partial -- see module doc) reads request-time state. This
    // beats rule 6 on purpose -- see module doc.
    if (view.markers.request_state != null) {
        const reason: []const u8 = switch (view.request_state_source) {
            .view => "view reads request-time state",
            .layout => "the resolved layout reads request-time state",
            .partial => "a rendered partial reads request-time state",
        };
        return .{
            .class = .unresolved,
            .reason = reason,
            .candidates = no_candidates,
        };
    }

    // Rule 6: the view wires up a Stimulus controller or mounts a
    // React/Vue component root. Deliberately UNGATED on `in.action` --
    // unlike rule 7 below, this is positive evidence of interactivity that
    // stands on its own, and `island` is a narrower claim than `content`
    // (see module doc).
    if (view.markers.stimulus or view.markers.component_root != null) {
        // `content` rides along as a second candidate only when Stimulus
        // is the ONLY interactivity found: a Stimulus behavior may be
        // portable to plain static content, but a mounted JS component
        // root is not (per the design doc's `candidates[]` addition).
        const only_stimulus = view.markers.stimulus and view.markers.component_root == null;
        const island_candidates: []const Candidate = if (only_stimulus)
            &[_]Candidate{
                .{ .target = "island", .evidence = "stimulus controller marker" },
                .{ .target = "content", .evidence = "stimulus behavior may be portable to static content" },
            }
        else
            &[_]Candidate{
                .{ .target = "island", .evidence = "component root marker" },
            };
        return .{
            .class = .island,
            .reason = "view has an interactive Stimulus controller or component root",
            .candidates = island_candidates,
        };
    }

    // Rule 7: the last resort, and the only verdict that asserts something
    // POSITIVE ("this page is safely static") -- reachable only when every
    // rule above has failed to fire (see module doc for the ordering
    // rationale). Gated on `in.action != null`: a static-looking view with
    // no recovered action is not proof of anything, only an absence of
    // counter-evidence, and asserting `content` on that basis is exactly
    // the false confidence this whole rule chain exists to prevent.
    if (in.action == null) {
        return .{
            .class = .unresolved,
            .reason = "view looks static but no controller action was recovered to confirm it",
            .candidates = no_candidates,
        };
    }
    return .{
        .class = .content,
        .reason = "no request-time state or interactivity found",
        .candidates = &[_]Candidate{
            .{ .target = "content", .evidence = "no request-time state or interactivity found" },
        },
    };
}

fn erbView(markers: template_scan.Markers) ViewRef {
    return .{ .path = "app/views/widgets/show.html.erb", .engine = .erb, .markers = markers };
}

fn hamlView(markers: template_scan.Markers) ViewRef {
    return .{ .path = "app/views/widgets/show.html.haml", .engine = .haml, .markers = markers };
}

fn jbuilderView(markers: template_scan.Markers) ViewRef {
    return .{ .path = "app/views/widgets/index.json.jbuilder", .engine = .jbuilder, .markers = markers };
}

fn v(in: Input) Verdict {
    return classify(in);
}

test "rule 1: a non-GET verb is backend regardless of anything else" {
    const got = v(.{ .verb = "POST", .view = null, .action = null });
    try std.testing.expectEqual(Class.backend, got.class);
    try std.testing.expectEqualStrings("non-GET verb is a backend responsibility", got.reason);
}

test "rule 2: no view and no action is backend" {
    const got = v(.{ .verb = "GET", .view = null, .action = null });
    try std.testing.expectEqual(Class.backend, got.class);
}

test "rule 2 (A2 fix): renders_json is gated on view == null -- a dual-format action with a real static view is NOT backend" {
    // This test used to assert the opposite (`backend`) and its own
    // stated justification was that gating renders_json on `view == null`
    // "would have broken this pinned test" -- backwards reasoning on a
    // branch with seven defects traced to plan-authored test code. Inverted
    // per the whole-branch review's finding 2: `any_render_json?` walks the
    // ENTIRE method body, so `renders_json` means "this action CAN also
    // answer JSON", not "this is an API endpoint" -- not grounds for a
    // `backend` verdict when a real HTML view exists. The classic
    // `respond_to { |f| f.html; f.json { render json: @post } }` idiom
    // must classify on its (clean, static) view like any other action.
    const got = v(.{ .verb = "GET", .view = erbView(.{}), .action = .{ .renders_json = true } });
    try std.testing.expectEqual(Class.content, got.class);
    try std.testing.expectEqualStrings("no request-time state or interactivity found", got.reason);
}

test "rule 2: renders_json still fires backend on its own when there is no view" {
    // The other half of the same fix: gating renders_json on `view ==
    // null` must not silently stop it firing at all -- a genuine
    // JSON-only API action (no view file exists for it) is still real
    // evidence of backend responsibility.
    const got = v(.{ .verb = "GET", .view = null, .action = .{ .renders_json = true } });
    try std.testing.expectEqual(Class.backend, got.class);
    try std.testing.expectEqualStrings("action renders JSON, not a view", got.reason);
}

test "rule 3: a pure redirect is a redirect" {
    const got = v(.{ .verb = "GET", .view = null, .action = .{ .only_redirect = true } });
    try std.testing.expectEqual(Class.redirect, got.class);
    try std.testing.expectEqualStrings("controller action only issues a redirect", got.reason);
}

test "rule 4: an unsupported engine is unresolved, never converted" {
    const got = v(.{ .verb = "GET", .view = hamlView(.{}), .action = .{} });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings("unsupported template engine, never converted", got.reason);
}

test "rule 4: jbuilder (renders JSON, not HTML) is unresolved too, not just Haml/Slim" {
    // The reader's most likely assumption about the non-erb generalization
    // is that it's an oversight limited to Haml/Slim -- pin jbuilder
    // explicitly so that assumption is falsified by a test, not a comment.
    const got = v(.{ .verb = "GET", .view = jbuilderView(.{}), .action = .{} });
    try std.testing.expectEqual(Class.unresolved, got.class);
}

test "rule 2 beats rule 3: an action that is both a redirect and JSON-rendering is backend, not redirect" {
    // `{ only_redirect = true, renders_json = true }` cannot arise from a
    // real controller today -- `only_redirect` requires the action body be
    // exactly one `redirect_to` statement, which leaves no room for a
    // `render json:` alongside it, so `controllers.rb` never emits this
    // combination. But `classify` is a public pure function that takes
    // whatever `Input` it is handed, "rule 2 wins over rule 3" is a real
    // decision the spec's numbered order makes, and a rule order nothing
    // enforces is one a future edit can silently invert. Pin the
    // spec-ordered outcome (rule 2 fires first) so a 2<->3 swap reddens
    // this test even though it can never fire on real input.
    const got = v(.{
        .verb = "GET",
        .view = null,
        .action = .{ .only_redirect = true, .renders_json = true },
    });
    try std.testing.expectEqual(Class.backend, got.class);
    try std.testing.expectEqualStrings("action renders JSON, not a view", got.reason);
}

test "rule 4 beats rule 5: an unsupported engine wins over request-time state" {
    // Both orderings land on `unresolved` here (haml is unsupported AND the
    // view reads request-time state), so only the `reason` distinguishes
    // "rule 4 fired first" from "rule 5 fired first" -- which is exactly
    // why the reason must be asserted, not just the class.
    const got = v(.{
        .verb = "GET",
        .action = .{},
        .view = hamlView(.{ .request_state = "current_user" }),
    });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings("unsupported template engine, never converted", got.reason);
}

test "rule 5 beats rule 6: request state wins over an island marker" {
    // An interactive page that also reads session state is NOT an island we
    // can build -- the state has to be resolved first (that is #167's job).
    const got = v(.{
        .verb = "GET",
        .action = .{},
        .view = erbView(.{ .request_state = "session", .stimulus = true }),
    });
    try std.testing.expectEqual(Class.unresolved, got.class);
}

test "rule 6: a stimulus marker makes it an island" {
    const got = v(.{ .verb = "GET", .action = .{}, .view = erbView(.{ .stimulus = true }) });
    try std.testing.expectEqual(Class.island, got.class);
}

test "rule 7: a static-safe view is content, and content is the last resort" {
    const got = v(.{ .verb = "GET", .action = .{}, .view = erbView(.{}) });
    try std.testing.expectEqual(Class.content, got.class);
    try std.testing.expectEqualStrings("no request-time state or interactivity found", got.reason);
}

test "spa is never assigned without positive evidence" {
    // Nothing in Stage 3 proves a component owns routing, so an island root
    // stays `island`. Claiming `spa` would be exactly the false confidence
    // the issue warns against.
    const got = v(.{
        .verb = "GET",
        .action = .{},
        .view = erbView(.{ .component_root = "react_component" }),
    });
    try std.testing.expect(got.class != Class.spa);
    try std.testing.expectEqual(Class.island, got.class);
}

test "island candidates include content only when the sole interactivity is Stimulus" {
    const stimulus_only = v(.{ .verb = "GET", .action = .{}, .view = erbView(.{ .stimulus = true }) });
    try std.testing.expectEqual(@as(usize, 2), stimulus_only.candidates.len);
    try std.testing.expectEqualStrings("island", stimulus_only.candidates[0].target);
    try std.testing.expectEqualStrings("stimulus controller marker", stimulus_only.candidates[0].evidence);
    try std.testing.expectEqualStrings("content", stimulus_only.candidates[1].target);
    try std.testing.expectEqualStrings(
        "stimulus behavior may be portable to static content",
        stimulus_only.candidates[1].evidence,
    );

    const component = v(.{
        .verb = "GET",
        .action = .{},
        .view = erbView(.{ .component_root = "react_component" }),
    });
    try std.testing.expectEqual(@as(usize, 1), component.candidates.len);
    try std.testing.expectEqualStrings("island", component.candidates[0].target);
    try std.testing.expectEqualStrings("component root marker", component.candidates[0].evidence);
}

test "no view and a non-redirect action is unresolved, not content" {
    const got = v(.{ .verb = "GET", .view = null, .action = .{} });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings("no view template to classify", got.reason);
}

// The four degradation-path cases fix round 1 required: `action == null`
// with each of the view shapes that matter, proving the missing-controller
// path no longer paints the whole app `backend` (the defect fix round 1
// found), while still not handing out `content` -- the one positive
// verdict -- on view evidence alone.

test "degradation: view + static markers, action absent -> unresolved (not backend, not content)" {
    const got = v(.{ .verb = "GET", .view = erbView(.{}), .action = null });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings(
        "view looks static but no controller action was recovered to confirm it",
        got.reason,
    );
}

test "degradation: view + stimulus, action absent -> island (rule 6 stays ungated)" {
    const got = v(.{ .verb = "GET", .view = erbView(.{ .stimulus = true }), .action = null });
    try std.testing.expectEqual(Class.island, got.class);
    try std.testing.expectEqualStrings("view has an interactive Stimulus controller or component root", got.reason);
}

test "degradation: view + request state, action absent -> unresolved (rule 5)" {
    const got = v(.{ .verb = "GET", .view = erbView(.{ .request_state = "session" }), .action = null });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings("view reads request-time state", got.reason);
}

test "degradation: no view, action absent -> backend (rule 2, unchanged)" {
    const got = v(.{ .verb = "GET", .view = null, .action = null });
    try std.testing.expectEqual(Class.backend, got.class);
    try std.testing.expectEqualStrings(
        "no view template and no controller action were recovered for this route",
        got.reason,
    );
}

// A3: `controller_evidence_available` distinguishes "controller-shape
// discovery degraded wholesale" from "discovery succeeded but this
// particular route's action was never found in it" -- see `Input`'s doc
// and rule 2's module-doc section. Both cases below share the same `Input`
// shape (`view == null`, `action == null`); only the flag differs, and the
// flag alone must be what decides `unresolved` vs `backend`.

test "A3: successful discovery, this route's action simply absent -> backend (unchanged, default true)" {
    // `controller_evidence_available` defaults to `true` -- a caller that
    // never sets it (every test above, and every direct classify() caller
    // written before this field existed) keeps today's behavior: rule 2's
    // absence-of-action clause is real information when the run overall
    // succeeded.
    const got = v(.{ .verb = "GET", .view = null, .action = null, .controller_evidence_available = true });
    try std.testing.expectEqual(Class.backend, got.class);
    try std.testing.expectEqualStrings(
        "no view template and no controller action were recovered for this route",
        got.reason,
    );
}

test "A3: controller evidence unavailable wholesale -> unresolved, not backend" {
    // Same Input shape as the test above, only the flag flipped. Under a
    // `RAILS_CONTROLLERS_MISSING`/`RAILS_CONTROLLERS_UNAVAILABLE` run,
    // `action == null` is true for EVERY route regardless of its real
    // backend-ness, so no verdict may rest on it -- this must not reach
    // `backend`.
    const got = v(.{ .verb = "GET", .view = null, .action = null, .controller_evidence_available = false });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings(
        "no view template, and controller evidence was unavailable for this run",
        got.reason,
    );
}

test "A3: controller evidence unavailable, but a view resolved and an action was still found -> unaffected" {
    // `controller_evidence_available` only gates rule 2's `action == null`
    // sub-clause; a route that DOES carry a recovered action (this run's
    // controller discovery still answered SOME routes, or the caller
    // otherwise has one) classifies exactly as it would with the flag
    // true -- the flag is not a global "distrust every action" switch.
    const got = v(.{
        .verb = "GET",
        .view = erbView(.{}),
        .action = .{},
        .controller_evidence_available = false,
    });
    try std.testing.expectEqual(Class.content, got.class);
}

test "A3: controller evidence unavailable, view present but no action -> rule 7's existing gate, unchanged" {
    // Rule 7 was already gated on `action != null` regardless of WHY it is
    // null (Ruling 17) -- `controller_evidence_available` adds nothing
    // here and must not change this reason string.
    const got = v(.{
        .verb = "GET",
        .view = erbView(.{}),
        .action = null,
        .controller_evidence_available = false,
    });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings(
        "view looks static but no controller action was recovered to confirm it",
        got.reason,
    );
}

// A1: `request_state_source` names which contributing file (view, layout,
// or a rendered partial) supplied the request-state marker that fired
// rule 5 -- see the module doc's "Rule 5 also reads..." section. These
// pin the reason text for each source; the merge itself (union of markers
// across files) is `rails.zig`'s job and is tested there.

test "A1: request_state_source names the layout when the marker came from there" {
    const got = v(.{
        .verb = "GET",
        .action = .{},
        .view = .{
            .path = "app/views/widgets/show.html.erb",
            .engine = .erb,
            .markers = .{ .request_state = "csrf_meta_tags" },
            .request_state_source = .layout,
        },
    });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings("the resolved layout reads request-time state", got.reason);
}

test "A1: request_state_source names a partial when the marker came from there" {
    const got = v(.{
        .verb = "GET",
        .action = .{},
        .view = .{
            .path = "app/views/widgets/show.html.erb",
            .engine = .erb,
            .markers = .{ .request_state = "current_user" },
            .request_state_source = .partial,
        },
    });
    try std.testing.expectEqual(Class.unresolved, got.class);
    try std.testing.expectEqualStrings("a rendered partial reads request-time state", got.reason);
}

test "A1: request_state_source defaults to .view, matching the pre-A1 reason text" {
    // Backward-compatibility pin: every ViewRef literal in this file's
    // tests above that never sets `request_state_source` must still read
    // "view reads request-time state" -- see "rule 5 beats rule 6" and the
    // "degradation: view + request state" test earlier in this file, both
    // of which rely on this default.
    const got = v(.{ .verb = "GET", .action = .{}, .view = erbView(.{ .request_state = "session" }) });
    try std.testing.expectEqualStrings("view reads request-time state", got.reason);
}
