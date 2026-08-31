//! Turns the node streams `fragments.discoverTemplates` recovered (plus
//! `controllers.zig`'s layout facts) into `Finding`s: questions FOR THE
//! OPERATOR, each with a fixed, static set of answers (`choices`) rather
//! than a fact discovery itself already settled. That is the line that
//! separates this file from `blockers.zig`: a blocker is a statement about
//! what discovery could or couldn't establish (a Gemfile it couldn't read,
//! a route it couldn't resolve); a finding is a per-fragment decision this
//! run cannot make on the operator's behalf (keep this ERB helper as an
//! island, retire it, block the route). `RAILS_TEMPLATE_UNREADABLE` stays a
//! blocker (from the transitive scan) precisely because "the scan could not
//! read this file" has no choice to offer -- the route's true shape is
//! unknown until the read failure is fixed, so there is nothing to decide.
//!
//! **`fragments.Template.unreadable` is a different fact, and it IS a
//! finding** (R15). It means the TEMPLATES op refused a file the transitive
//! scan had already read successfully -- a symlink resolving outside the app
//! root, a permission the sidecar's own `File.read` hit, a non-string path.
//! No `RAILS_TEMPLATE_UNREADABLE` blocker exists for it (the scan follows
//! symlinks and was perfectly happy), and it contributes neither nodes nor a
//! parse error, so before `RAILS_TEMPLATE_UNSCANNED` such a view produced
//! literally nothing anywhere in the manifest -- a template silently exempt
//! from the presentation analysis, indistinguishable from a clean one. The
//! operator has a real choice here, which is what makes it a finding rather
//! than a blocker: retain the view as-is, or block the migration on it.
//!
//! **Ids, not array positions.** Task 11 (the manifest writer) needs to
//! reconcile a finding against a PREVIOUS run's recorded operator decision
//! even after the message text was reworded or nodes were re-ordered by a
//! template edit elsewhere in the file. `findingId` borrows rails2zb's own
//! reversible `%`/`.` escaping (`%` -> `%25`, then `.` -> `%2E`, in that
//! order so a literal `%25` in the input can never be mistaken for an
//! escaped `.`) so `<code>.<path>.<loc>` decodes unambiguously even though
//! `path` routinely contains `.` (`index.html.erb`) and, in principle,
//! `%`. `loc` folds line+col for a node (`"L3C5"`) or just line for a
//! parse error/layout (`"L4""`) into the same id shape, so every finding
//! kind still fits the one 3-part scheme.
//!
//! **The derivation table is the single source of truth.** `derive` is a
//! table-driven walk (`table.zig`-style would be a separate file; this one
//! is small enough to live as a `switch` per source -- nodes, then parse
//! errors, then layouts -- rather than a hand-duplicated `append` call per
//! `Kind`), so a code/severity/choices tuple is written once and read from
//! one place instead of drifting between a table comment and a switch body.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("assets.zig");
const backend = @import("backend.zig");
const blockers = @import("blockers.zig");
const classify = @import("classify.zig");
// Only for `opensBlock` (ruling S12's form-nesting scope). `convert.zig`
// imports this file in turn -- a cycle Zig resolves the same way it already
// resolves `manifest.zig` <-> `rails.zig`. Sharing the predicate is the whole
// point: see `convert.opensBlock`'s own doc.
const convert = @import("convert.zig");
const fragments = @import("fragments.zig");
const integrations = @import("integrations.zig");
const port = @import("port.zig");
const controllers = @import("controllers.zig");
const resolve = @import("resolve.zig");
const routes = @import("routes.zig");

pub const Severity = blockers.Severity;

/// A per-fragment (or per-layout, or per-template) decision this run
/// surfaces to the operator rather than settling itself. See the module
/// doc for how this differs from `blockers.Blocker`.
///
/// Contract 2 (owned-result): `id`, `path`, `message` and `choices` (both
/// levels) are fresh `gpa` allocations; `route_id` is a fresh allocation
/// when non-null. `code` alone is a static string literal, never freed.
/// Released by `free`.
pub const Finding = struct {
    /// `<code>.<path>.<loc>` with `%`/`.` escaped; see `findingId`. Stable
    /// across a reworded `message` or a template edit elsewhere in the
    /// file, so Task 11 can reconcile against a prior recorded decision.
    id: []const u8,
    /// Stable, machine-greppable code from the derivation table. Always a
    /// static string literal -- never freed by `free`.
    code: []const u8,
    severity: Severity,
    /// Root-relative source path the finding concerns.
    path: []const u8,
    /// 1-based source line, when the trigger has one. Every Stage 1 row
    /// does (a node, a parse error, a layout declaration all carry a
    /// line), but the field stays optional because `lessThan`'s tie-break
    /// order treats "no line" as sorting first (`orelse 0`) and a future
    /// finding kind may not have one.
    line: ?u64,
    /// Owned when non-null. `null` for every Stage 1 finding: these are
    /// all template- or controller-scoped rather than tied to one route.
    route_id: ?[]const u8,
    /// Human detail, e.g. the helper/route-helper name. NOT part of `id`
    /// -- see the module doc -- so rewording this never invalidates a
    /// recorded decision.
    message: []const u8,
    /// The set of answers an operator may record against this finding.
    ///
    /// #167 Stage 3: OWNED (both the slice and every string in it), where
    /// Stage 2 had it be a static literal slice. The reason is
    /// `RAILS_BACKEND_ENDPOINT`: its answers are the ZigBase operations
    /// `--backend` named, so the list is built per finding from a
    /// `backend.Document` and cannot be a comptime constant. And it is a
    /// DEEP copy rather than an owned slice over `backend.choicesFor`'s
    /// borrowed elements, because a `Finding` outlives nothing it can see:
    /// it is handed to `manifest.zig`, `report.zig` and `decisions.zig`
    /// with no handle on the document those strings live in, so borrowing
    /// would make every consumer's correctness depend on a lifetime none of
    /// them can check. `backend.choicesFor` keeps its own contract 1; this
    /// type is contract 2 and pays a handful of small dupes for it.
    ///
    /// A hand-built `Finding` in a test may still point this at a static
    /// literal, as long as that finding is never passed to `free`.
    choices: []const []const u8,
    /// Whether resolving this finding requires generating an artifact
    /// (e.g. an island component) rather than just recording a choice.
    /// `false` for every Stage 1 finding.
    requires_artifact: bool,
};

const choices_retain_blocked = [_][]const u8{ "retain", "blocked" };
const choices_island_retain_blocked = [_][]const u8{ "island", "retain", "blocked" };
const choices_island_spa_retain_blocked = [_][]const u8{ "island", "spa", "retain", "blocked" };
const choices_spa_retain_blocked = [_][]const u8{ "spa", "retain", "blocked" };
const choices_full = [_][]const u8{ "island", "spa", "backend", "retain", "blocked" };
const choices_stimulus = [_][]const u8{ "island", "drop", "retain", "blocked" };
const choices_drop_retain_blocked = [_][]const u8{ "drop", "retain", "blocked" };
const choices_inline_retain_blocked = [_][]const u8{ "inline", "retain", "blocked" };
const choices_drop_blocked = [_][]const u8{ "drop", "blocked" };
/// #167 Stage 3 assumption A7's new choice word: "ship the page; the ZigBase
/// rules protect the data". Only `RAILS_ROUTE_AUTH_GUARD` offers it.
const choices_public_retain_blocked = [_][]const u8{ "public", "retain", "blocked" };

/// Contract 2 (owned-result): a deep copy of `src`, released by
/// `freeChoices`. Every row's `choices` goes through here -- see
/// `Finding.choices` for why a `Finding` owns its answers outright.
pub fn dupeChoices(gpa: Allocator, src: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |c| gpa.free(c);
        gpa.free(out);
    }
    for (src, 0..) |c, i| {
        out[i] = try gpa.dupe(u8, c);
        filled = i + 1;
    }
    return out;
}

/// Contract 2's release half for `dupeChoices`.
pub fn freeChoices(gpa: Allocator, choices: []const []const u8) void {
    for (choices) |c| gpa.free(c);
    gpa.free(choices);
}

/// The three #167 Stage 2 ROUTE-scoped codes, and the file all of them point
/// at. Public because `scaffold.zig` has to recompute the very ids `derive`
/// produced in order to look an operator decision up against them -- see
/// `routeFindingId`.
///
/// **Ruling S22's grouping, and its one exception.** Every ROUTE-scoped row
/// emits ONE finding per `config/routes.rb` LINE, whose `message` names every
/// route on that line, because one declaration is one decision. #167 Stage 3
/// fix round 1 (ruling I-3), extended in fix round 2 (NEW-2), narrows exactly
/// one row to `(line, verb, resource)`: `RAILS_BACKEND_ENDPOINT`, whose
/// answer is a single ZigBase operation. One `resources :posts` line declares
/// both `POST /posts` and `DELETE /posts/:id`, and one
/// `resources :posts, :comments` line declares `POST /posts` and
/// `POST /comments`; no single operation serves either pair. The narrowed key
/// is exactly the pair `backend.choicesFor` is asked, so two routes share a
/// finding precisely when they would be offered the same answers. That row
/// alone uses `routeVerbFindingId`; every other row keeps `routeFindingId`.
pub const routes_file = "config/routes.rb";
pub const code_route_dynamic_segment = "RAILS_ROUTE_DYNAMIC_SEGMENT";
pub const code_redirect_host_config = "RAILS_REDIRECT_HOST_CONFIG";

/// #167 Stage 2 ruling S22, and the last of the "open note with no id" holes
/// rulings S12/S18/S21 closed elsewhere.
///
/// A route whose controller/action pair resolves no view template at all --
/// `def other; render :about; end` with no `app/views/pages/other.html.erb`,
/// an action whose template was deleted, a `render` this stage does not
/// follow -- reached `scaffold.contentRoute`, found nothing to convert, and
/// left the route `open` with a bare sentence. That sentence carries no id,
/// so no line in `MIGRATION.decisions.json` could name it and `complete` was
/// unreachable for the whole app by any answer the operator could give.
///
/// `retain`/`blocked` only: there is no template, so no choice this stage
/// could offer produces a page. Keyed on the `routes.rb` line like the other
/// two ROUTE-scoped rows, because the route declaration -- not a template
/// that does not exist -- is the thing an operator can point at.
///
/// It is a FINDING and not a change to discovery's classification: whether a
/// route is `content` is a statement about what the route is for, and it is
/// still that even with the template missing.
pub const code_no_template = "RAILS_NO_TEMPLATE";

/// #167 Stage 2 ruling S12: the six node kinds `convert.zig` always turns
/// into a placeholder but that had NO derivation row -- the plan's Global
/// Constraints parked their real handling on Stages 3 and 4, and the rows
/// were left out with them.
///
/// That was a hole, not a deferral. A route whose only blemish is a `form`
/// converted to `<!-- rails:unmapped form -->`, which carries no id; ruling
/// S6 correctly kept the route `open`, and the operator had nothing to
/// answer, so the route could never reach `complete` by any route at all --
/// not even `blocked`. The rows below exist so every region the converter
/// cannot finish is at least ACKNOWLEDGEABLE.
///
/// Their `choices` are `retain`/`blocked` only. Stage 3 widens the two form
/// codes with the backend operations from `--backend`, and Stage 4 widens the
/// Turbo/component ones with `island`; neither can be offered honestly today,
/// and offering a choice this stage cannot carry out is worse than offering
/// two it can. `RAILS_COMPONENT_ROOT` is new (additive to the spec's code
/// list); the other four were already reserved there.
/// #167 Stage 2 ruling S18, the same hole ruling S12 closed for the six
/// deferred node kinds, in the one place S12 could not reach: a template
/// whose ENGINE has no converter.
///
/// `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` was a blocker and nothing else
/// (`inventory.appendUnsupportedEngineBlockers`), which is the right verdict
/// about the FILE -- discovery established the engine, there is nothing to
/// decide about that. But a ROUTE rendering that file is a different
/// question: the scaffold cannot convert it, so the route stays `open`, and
/// with no finding on the view's path there was no id for a decision to name
/// -- `complete` was unreachable for any app with one Haml view, by any
/// answer the operator could give. The spec's own sentence ("Haml/Slim stay
/// `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` from #166; such a route can only reach
/// `blocked` or `retained`") requires an id to reach either.
///
/// The blocker STAYS: it is what the report explains the engine with, and it
/// is what `--strict` counts. This adds the operator's half of the same fact,
/// on the same path, so `scaffold.collectTemplateFindings` picks it up for
/// every route whose view it is. `retain`/`blocked` only -- an engine no
/// converter reads cannot become an island or a SPA by anyone deciding so.
pub const code_template_engine_unsupported = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED";

pub const code_backend_endpoint = "RAILS_BACKEND_ENDPOINT";

/// Ruling S12's row for anything the page can only know at request time: an
/// `errors` summary, a `current_user` helper, a `session[...]` read.
///
/// Named since #167 Stage 3 Task 5 because `scaffold.zig` now has to tell
/// this code apart from the others to decide whether an `island` answer is
/// the auth-status scaffold or Stage 4's component port; the derivation sites
/// below used the literal, and a second copy of it in another file is exactly
/// the drift the other `code_*` constants exist to prevent.
pub const code_request_time_state = "RAILS_REQUEST_TIME_STATE";

/// #167 Stage 3 assumption A5. The sign-in/sign-up/sign-out routes are ONE
/// decision, not one per route: they share a ZigBase auth collection, an
/// `AuthForm` and an `AuthStatus`, and answering three of them `island` with
/// three different collection names is not a migration anyone wants. At most
/// one of these exists per app, keyed (ruling S22) on the SMALLEST
/// `config/routes.rb` line the journey occupies.
///
/// The one row in the table with `requires_artifact: true`: the artifact is
/// the ZigBase auth collection name, which no amount of reading the Rails app
/// can recover -- it is a fact about the destination.
pub const code_auth_journey = "RAILS_AUTH_JOURNEY";

/// #167 Stage 3 assumption A7. A page whose Rails controller runs an
/// authentication `before_action` is not a page: it is a page PLUS an
/// enforcement the static tree cannot express. Emitting it silently is the
/// "silently marked complete" #167 exists to prevent, so the operator either
/// ships it deliberately (`public` -- the ZigBase rules still protect the
/// data behind it), retains the Rails route, or blocks on it.
pub const code_route_auth_guard = "RAILS_ROUTE_AUTH_GUARD";

/// #182, first half. Two route declarations reducing to one
/// `content/<url>/index.smd` (`/about` and `/about/`) used to be a bare
/// `addOpenNote` in `scaffold.zig` with no id behind it, so no decisions file
/// could name it and `complete` was unreachable for the app. `retain`/
/// `blocked` only: the loser has no page to write whatever anyone decides.
pub const code_content_path_collision = "RAILS_CONTENT_PATH_COLLISION";

/// #182, second half, and the case `routeHasNoView` deliberately leaves to
/// this row: a static GET route whose path carries syntax `resolve.
/// contentPath` refuses (`(.:format)`). Same id-less-note defect, same two
/// choices -- there is no file to write until the route parser learns the
/// syntax.
pub const code_route_path_unsupported = "RAILS_ROUTE_PATH_UNSUPPORTED";

pub const code_turbo_frame = "RAILS_TURBO_FRAME";
pub const code_turbo_stream = "RAILS_TURBO_STREAM";
pub const code_component_root = "RAILS_COMPONENT_ROOT";
pub const code_stimulus_controller = "RAILS_STIMULUS_CONTROLLER";
pub const code_component_props_dynamic = "RAILS_COMPONENT_PROPS_DYNAMIC";
pub const code_component_vue_unsupported = "RAILS_COMPONENT_VUE_UNSUPPORTED";
pub const code_js_entry = "RAILS_JS_ENTRY";

/// Filled with the follow-up issue number when the Stage 4 PR is opened.
/// Keeping the reference in one constant makes that PR-time edit mechanical.
pub const turbo_stream_issue: usize = 189;

/// Contract 1 (self-freeing): the only allocation is the returned buffer,
/// which escapes to the caller; nothing else is retained. Maps `%` to
/// `%25` and then `.` to `%2E` (in that order -- doing `.` first would let
/// the `%` an escaped-`.` introduces be mistaken for the start of a
/// SECOND escape sequence on a later pass), which is what makes the
/// mapping reversible: a decoder can undo `%2E` -> `.` and then
/// `%25` -> `%` and land exactly back on `part`.
pub fn escapePart(gpa: Allocator, part: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (part) |c| {
        switch (c) {
            '%' => try out.appendSlice(gpa, "%25"),
            '.' => try out.appendSlice(gpa, "%2E"),
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Contract 1 (self-freeing): every intermediate `escapePart` result is
/// freed before returning; only the joined buffer escapes.
pub fn findingId(gpa: Allocator, code: []const u8, path: []const u8, loc: []const u8) Allocator.Error![]u8 {
    const code_esc = try escapePart(gpa, code);
    defer gpa.free(code_esc);
    const path_esc = try escapePart(gpa, path);
    defer gpa.free(path_esc);
    const loc_esc = try escapePart(gpa, loc);
    defer gpa.free(loc_esc);
    return std.fmt.allocPrint(gpa, "{s}.{s}.{s}", .{ code_esc, path_esc, loc_esc });
}

/// The id of a ROUTE-scoped finding (#167 Stage 2): `<code>.config/routes.rb.
/// L<line>`, where `line` is the `routes.rb` line the route was DECLARED on.
///
/// Exported because two files have to agree on it byte for byte: `derive`
/// below produces the finding, and `scaffold.zig` recomputes the same id from
/// a `routes.Route` to look up the operator's decision. Recomputing rather
/// than searching `findings[]` by `route_id` is deliberate -- one declaration
/// can produce several routes (see `deriveRouteFindings`), so `route_id`
/// names only one of them and is not a key to join on.
///
/// Contract 1 (self-freeing): the `loc` scratch is released; only the id
/// escapes.
pub fn routeFindingId(gpa: Allocator, code: []const u8, line: u64) Allocator.Error![]u8 {
    const loc = try lineLoc(gpa, line);
    defer gpa.free(loc);
    return findingId(gpa, code, routes_file, loc);
}

/// The id of the one ROUTE-scoped row that is keyed on
/// `(line, verb, resource)` rather than on the line alone:
/// `RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L<line>.<VERB>.<resource>`.
///
/// #167 Stage 3 fix round 1 (ruling I-3), extended in fix round 2 (NEW-2).
/// S22 folds every route on one `routes.rb` line into one finding because
/// one declaration is one decision -- `spa` on a `resources :posts` line
/// means the whole declaration becomes a SPA. That reasoning does not
/// survive contact with this row, whose answer is a single ZigBase
/// OPERATION, and one `routes.rb` line can declare routes needing several:
///
/// - `resources :posts` declares `POST /posts`, `PATCH /posts/:id` and
///   `DELETE /posts/:id`. No operation is both a create and a delete.
/// - `resources :posts, :comments` declares `POST /posts` AND
///   `POST /comments` -- same verb, two collections, and `createPosts`
///   cannot serve a comment.
///
/// So this row, and only this row, narrows S22's grouping to
/// `(line, verb, resource)`, where `resource` is the route's controller --
/// exactly the pair `backend.choicesFor` is asked, so two routes share a
/// finding precisely when they would be offered the same answers.
///
/// The two extra keys ride in a FOURTH and FIFTH id component rather than
/// inside `loc`, so the three-part `<code>.<path>.<loc>` shape every other
/// finding has is still what a reader sees, with the extra keys appended and
/// separated by the same `.`. `escapePart` is applied to both like any other
/// component, so the id stays reversible even for a namespaced controller
/// key (`admin/users`).
///
/// **`resource` is always emitted**, so the id has a fixed component count
/// and a reader never has to guess whether a trailing token is a verb or a
/// controller. A route whose controller discovery never recovered
/// (`Route.controller == null`) contributes an EMPTY component
/// (`…L7.POST.`) -- distinct from every real controller key, which is
/// derived from a file path and is never empty.
///
/// Exported for the same reason `routeFindingId` is: `scaffold.zig` has to
/// recompute this byte for byte to look an operator decision up.
///
/// Contract 1 (self-freeing): all scratch is released; only the id escapes.
pub fn routeVerbFindingId(
    gpa: Allocator,
    code: []const u8,
    line: u64,
    verb: []const u8,
    resource: ?[]const u8,
) Allocator.Error![]u8 {
    const base = try routeFindingId(gpa, code, line);
    defer gpa.free(base);
    // Upper-cased HERE, not at the call sites: two callers have to produce
    // the same bytes, and `routes.Route.verb` being upper-case today is a
    // property of one producer, not a guarantee of the type.
    const upper = try upperAlloc(gpa, verb);
    defer gpa.free(upper);
    const verb_esc = try escapePart(gpa, upper);
    defer gpa.free(verb_esc);
    const resource_esc = try escapePart(gpa, resource orelse "");
    defer gpa.free(resource_esc);
    return std.fmt.allocPrint(gpa, "{s}.{s}.{s}", .{ base, verb_esc, resource_esc });
}

/// True when a route path has a `:param` or `*glob` segment -- i.e. when it
/// stands for a family of URLs rather than one.
///
/// A one-line forward to `resolve.isDynamicRoutePath`, kept as a name in this
/// file because `scaffold.zig` and this file's own rows read it under this
/// name. It used to be a SECOND copy of the loop, kept honest by the test
/// below; "dynamic" is defined as exactly "`resolve.contentPath` gives it no
/// single static page", so the definition belongs next to `contentPath` and
/// there is now no second implementation to drift.
///
/// Contract 3 (caller-buffer): allocates nothing.
pub fn isDynamicRoutePath(route_path: []const u8) bool {
    return resolve.isDynamicRoutePath(route_path);
}

/// Total order over `(code, path, line orelse 0, id)`. `id` is the key that
/// makes the tuple total, and it is unique because `loc` is:
///
/// - A node finding's `loc` is `L<line>C<col>`, where `col` is the fragment's
///   TRUE 1-based source column -- `templates.rb`'s `col_map` maps Prism's
///   generated-program column back through the compiled program (ruling
///   R17). Two distinct fragments cannot begin at the same byte of the same
///   line, so two node findings on one line always differ in `col`.
/// - A parse-error, layout or unscanned-template finding's `loc` is
///   `L<line>` or `"unscanned"`, and each of those sources yields at most
///   one finding per (code, path, line) by construction: one parse error per
///   template, one `layout` declaration per controller line, one
///   `fragments.Template` per path.
///
/// That is what this comparator needs, and why it needs no fifth key:
/// `std.mem.sort` is not guaranteed stable, so two distinct elements it
/// considers equal would order either way between runs. It is not a
/// hypothetical -- before R17 a tag holding several statements gave every
/// statement after the first `col: 0`, and
/// `<% number_to_currency(1); pluralize(2) %>` produced exactly that pair.
///
/// Contract 3 (caller-buffer): takes no allocator and allocates nothing.
pub fn lessThan(_: void, a: Finding, b: Finding) bool {
    const code_order = std.mem.order(u8, a.code, b.code);
    if (code_order != .eq) return code_order == .lt;
    const path_order = std.mem.order(u8, a.path, b.path);
    if (path_order != .eq) return path_order == .lt;
    const a_line = a.line orelse 0;
    const b_line = b.line orelse 0;
    if (a_line != b_line) return a_line < b_line;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Contract 2 counterpart to `derive`: releases `id`/`path`/`message`/
/// `choices` and (when non-null) `route_id` on every finding plus the slice
/// itself. Does not free `code`, which is always the static literal the
/// derivation table names.
pub fn free(gpa: Allocator, list: []Finding) void {
    for (list) |f| freeOne(gpa, f);
    gpa.free(list);
}

/// The per-element half of `free`, shared with `derive`'s `errdefer` so the
/// two cannot drift over which fields a `Finding` owns.
fn freeOne(gpa: Allocator, f: Finding) void {
    gpa.free(f.id);
    gpa.free(f.path);
    gpa.free(f.message);
    if (f.route_id) |rid| gpa.free(rid);
    freeChoices(gpa, f.choices);
}

pub const ControllerFile = struct { controller: []const u8, path: []const u8 };

pub const DeriveInput = struct {
    templates: []const fragments.Template,
    layouts: []const controllers.LayoutInfo,
    /// `{controller, path}` pairs from the inventory, consulted only for
    /// `RAILS_LAYOUT_DYNAMIC`'s `path` -- a `LayoutInfo` names its
    /// controller, not the file it came from.
    controller_files: []const ControllerFile,
    /// Names of `certain` routes (Stage 4's route classification), used to
    /// decide whether a `.route_helper`/`.link_to` node's `name` matches a
    /// route this run actually resolved.
    route_names: []const []const u8,
    /// The I18n locale `fragments.discoverTemplates` loaded (its `Result.
    /// locale`), threaded through only for `RAILS_I18N_UNRESOLVED`'s
    /// message. `null` when the sidecar could not determine one, in which
    /// case the parenthetical is simply omitted.
    locale: ?[]const u8,
    /// R16: the `config/locales/**` files that failed to load this run
    /// (`fragments.Result.i18n_errors`' paths). Non-empty means the
    /// translation table is empty or partial through no fault of any
    /// template, so every `RAILS_I18N_UNRESOLVED` message says so -- see
    /// `deriveNode`'s `.i18n` arm. Defaulted empty because that is the
    /// ordinary case AND the safe one: a caller that forgets it gets the
    /// pre-R16 message, never a wrong claim about a locale file.
    i18n_error_paths: []const []const u8 = &.{},
    /// Stage 2 (#167 plan ruling S1): the asset table `assets.scan`
    /// recovered, so an `asset` node's literal can be resolved the same way
    /// `convert.zig` resolves it (`resolve.assetFor`) and the two agree on
    /// which helper calls become a placeholder.
    ///
    /// Defaulted empty ONLY so the pre-Stage-2 `derive` call literals in this
    /// file's tests keep compiling -- unlike `i18n_error_paths`, an omitted
    /// value here is NOT the safe answer: with no table every literal
    /// resolves to nothing and every asset helper becomes a finding. The one
    /// production caller passes the real slice; see the test that pins it.
    assets: []const assets.Asset = &.{},
    /// Stage 2 (plan ruling S1): the recovered route table, for the two
    /// ROUTE-scoped rows (`RAILS_ROUTE_DYNAMIC_SEGMENT`,
    /// `RAILS_REDIRECT_HOST_CONFIG`). Every other row in this table is
    /// triggered by a template node, a parse error or a layout declaration;
    /// these two are triggered by a route, which is why they need their own
    /// input rather than another `fragments.Template` field.
    ///
    /// Defaulted empty ONLY so the pre-Stage-2 `derive` call literals in this
    /// file's own tests keep compiling. Like `assets` above and unlike
    /// `i18n_error_paths`, an omitted value is NOT the safe answer: with no
    /// route table neither row can fire at all, so every dynamic and every
    /// redirect route silently loses the finding an operator would have
    /// acknowledged it through. The one production caller passes the real
    /// slice.
    routes: []const routes.Route = &.{},
    /// Index-aligned with `routes` above (`rails.Discovery`'s own alignment
    /// promise). Read only to EXCLUDE `backend` routes from the dynamic-
    /// segment row and to SELECT `redirect` routes for the redirect row.
    ///
    /// A short or empty slice is not an error and is not treated as
    /// `backend`: an unclassified route is one this run has no verdict for,
    /// and suppressing its finding on that basis would hide a route rather
    /// than surface it. See the "no classifications" test.
    classifications: []const classify.Verdict = &.{},
    /// Stage 2 (ruling S22): index-aligned with `routes` above, the template
    /// paths discovery resolved for each route -- one
    /// `rails.RouteTemplates.templates` per entry. Read by the
    /// `RAILS_NO_TEMPLATE` row alone, which asks whether the route's
    /// `<controller>/<action>` view is among them.
    ///
    /// A slice of slices rather than `[]const rails.RouteTemplates` because
    /// `rails.zig` is this package's ROOT and imports this file; only the
    /// `templates` half is read, so restating the shape is cheaper than
    /// reasoning about the cycle (the same call `deriveRouteFindings` makes
    /// about `rails.formatRouteId`).
    ///
    /// A SHORT slice is not an error and does not mean "no templates": an
    /// entry that is not present is a route this input says nothing about,
    /// and firing `RAILS_NO_TEMPLATE` on that basis would invent a missing
    /// template for every route in every caller that omits the field.
    /// Defaulted empty for that reason, which makes an omitted value LOSE the
    /// row rather than fabricate it -- the safe direction, and the same
    /// stance `classifications` above takes. The one production caller passes
    /// the real slice; see the test that pins it.
    route_templates: []const []const []const u8 = &.{},
    /// Stage 2 (ruling S18): the templates whose engine has no converter,
    /// exactly the set `inventory.unsupportedEngineLabel` accepts, carrying
    /// that label. Passed in rather than re-derived here so the finding and
    /// the blocker cannot disagree about which files qualify (see that
    /// function), and so this file stays free of an `inventory.zig` import it
    /// otherwise has no use for.
    ///
    /// Defaulted empty for the same reason `i18n_error_paths` is, and with
    /// the same safety: an omitted value only ever LOSES a finding an app
    /// with no Haml/Slim would not have had anyway. The one production caller
    /// passes the real slice.
    unsupported_templates: []const UnsupportedTemplate = &.{},
    /// #167 Stage 3: the ZigBase OpenAPI document `--backend FILE` named, or
    /// `null` for a run without one. Read ONLY through `backend.choicesFor`,
    /// which answers `["retain", "blocked"]` for `null` -- so a run without a
    /// document produces exactly the Stage 2 choice list and nothing about
    /// the file reaches the manifest (plan, Global Constraints: identical
    /// input, identical bytes).
    ///
    /// Borrowed for the duration of the call. Nothing in the returned
    /// `Finding`s points into it: `Finding.choices` is a deep copy, for the
    /// reason that field's doc gives.
    backend: ?backend.Document = null,
    /// #167 Stage 3 (assumption A7): the controllers op's filter view --
    /// every `before_action` and `skip_before_action` it recovered, plus the
    /// `class Child < Parent` edges. Read by `RAILS_ROUTE_AUTH_GUARD` alone,
    /// through `controllers.guardsFor`.
    ///
    /// A `FilterSet` and not a bare `[]BeforeAction` (fix round 1, I-1): the
    /// overwhelmingly common Rails shape is `before_action :authenticate_user!`
    /// on `ApplicationController` with every other controller inheriting it,
    /// and matching a filter's own `controller` against the route's saw NONE
    /// of them -- the row fired only for an app that redeclares the filter in
    /// every controller. `guardsFor` walks the chain and honours
    /// `skip_before_action` placement; both are Task 2's work, and re-deriving
    /// either here would be a second implementation to keep in step.
    ///
    /// Defaulted empty, which LOSES the row rather than fabricating one --
    /// the safe direction and the stance every input below takes.
    filters: controllers.FilterSet = .{},
    /// #167 Stage 3: index-aligned with `routes` -- the VIEW each route
    /// resolved (`resolve.viewFor` over that route's template list), or
    /// `null` where it resolved none. Two rows read it: assumption A5's
    /// journey detection (a view holding a password form makes its route a
    /// journey route) and the `RAILS_BACKEND_ENDPOINT` form row (a form's
    /// backend `resource` is the controller of the route whose view it sits
    /// in).
    ///
    /// A SHORT slice is not an error: an entry that is not present is a route
    /// this input says nothing about.
    route_views: []const ?[]const u8 = &.{},
    /// #182: the routes that lose a content path to an earlier route, from
    /// `resolve.contentClaims`. Computed by the caller rather than here so
    /// this row and `scaffold.zig`'s own claim walk read ONE function and
    /// cannot disagree about which route is the loser -- see that function's
    /// doc for the single remaining difference.
    content_collisions: []const resolve.ContentCollision = &.{},
    /// #182: the routes whose path `resolve.contentPath` refuses, from the
    /// same `resolve.contentClaims` call as `content_collisions`.
    unsupported_route_paths: []const usize = &.{},
    /// #167 Stage 3 fix round 2 (NEW-1): the render graph Stage 1 already
    /// resolved -- one entry per template, naming the OTHER templates it
    /// renders. `rails.Discovery.templates[].renders` verbatim.
    ///
    /// Read by assumption A5's journey detection alone, which has to know
    /// that `sessions/new.html.erb` reaches `shared/_login_form.html.erb`:
    /// the sign-in form usually lives in the partial, and without the edge
    /// the journey and the partial each raised a finding for the same form.
    /// Passed in rather than re-derived from the `.render_partial` nodes in
    /// `templates` because resolving a partial's LOGICAL name
    /// (`shared/login_form`) to a file is `rails.resolvePartialTarget`'s job
    /// and needs the inventory; a second implementation here would be a
    /// second thing to keep in step.
    ///
    /// Defaulted empty, which loses only the transitive half of the rule: a
    /// form in a journey route's OWN view is still the journey's.
    render_graph: []const TemplateRenders = &.{},
    /// Stage 4 Task 3 inputs. All are borrowed from `rails.Discovery`'s
    /// owned graph and default empty so older synthetic derive fixtures lose
    /// a new row rather than fabricate one.
    js_sources: []const port.JsSource = &.{},
    js_entry: ?[]const u8 = null,
    npm_dependencies: []const integrations.NpmDep = &.{},
    route_params: []const RouteParam = &.{},
    stimulus_markers: []const TemplateStimulusMarkers = &.{},
};

pub const RouteParam = struct {
    name: []const u8,
    path: []const u8,
};

pub const TemplateStimulusMarkers = struct {
    path: []const u8,
    names: []const []const u8,
};

/// One node of the render graph: a template, and the templates it renders.
/// Mirrors the two fields of `rails.TemplateNode` this file reads; restated
/// rather than imported because `rails.zig` is this package's ROOT and
/// imports this file. Both levels borrowed for the duration of the call.
pub const TemplateRenders = struct {
    path: []const u8,
    renders: []const []const u8,
};

/// One `unsupported_templates` row: the app-relative template path and the
/// engine label (`"Haml"`, `"Slim"`) `inventory.unsupportedEngineLabel`
/// returned for it. Both borrowed for the duration of the `derive` call.
pub const UnsupportedTemplate = struct {
    path: []const u8,
    label: []const u8,
};

/// True when `name` is not present in `route_names` -- a linear scan, not a
/// set, because `route_names` is the size of one app's route table (tens
/// to low hundreds of entries), scanned once per route-helper/link_to node
/// in one discovery run. Building a hash set for that would trade a
/// negligible constant-time win for an allocation this function would then
/// have to own and free.
fn routeNameUnknown(route_names: []const []const u8, name: []const u8) bool {
    for (route_names) |rn| {
        if (std.mem.eql(u8, rn, name)) return false;
    }
    return true;
}

/// Builds one `Finding`: computes `id` via `findingId`, dupes `path` and
/// the already-formatted `message`, and appends. Every derivation-table row
/// funnels through this one function so `id` construction and the
/// owned/static split (`code`/`choices` are never dupe'd; `path`/`message`
/// always are) is written once.
///
/// Contract 2 (owned-result), inherited from `derive`: on `OutOfMemory`,
/// every allocation this call made is freed via `errdefer` before
/// propagating, so a failed `appendFinding` never leaves `list` holding a
/// half-built entry.
fn appendFinding(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    code: []const u8,
    severity: Severity,
    path: []const u8,
    line: ?u64,
    loc: []const u8,
    message: []const u8,
    choices: []const []const u8,
) Allocator.Error!void {
    const id = try findingId(gpa, code, path, loc);
    errdefer gpa.free(id);
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);
    const message_copy = try gpa.dupe(u8, message);
    errdefer gpa.free(message_copy);
    const choices_copy = try dupeChoices(gpa, choices);
    errdefer freeChoices(gpa, choices_copy);
    try list.append(gpa, .{
        .id = id,
        .code = code,
        .severity = severity,
        .path = path_copy,
        .line = line,
        .route_id = null,
        .message = message_copy,
        .choices = choices_copy,
        .requires_artifact = false,
    });
}

/// `appendFinding`'s ROUTE-scoped sibling: the same construction with a
/// non-null `route_id`. Kept as a second function rather than an optional
/// parameter on the first so the ten existing call sites -- every one of
/// which is template- or controller-scoped and must keep `route_id = null`
/// -- read unchanged.
///
/// Contract 2 (owned-result), inherited from `derive`: on `OutOfMemory`
/// every allocation this call made is freed via `errdefer` before
/// propagating.
fn appendRouteFinding(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    code: []const u8,
    severity: Severity,
    line: u64,
    message: []const u8,
    choices: []const []const u8,
    route_id: []const u8,
    /// #167 Stage 3: true for `RAILS_AUTH_JOURNEY` alone. A parameter rather
    /// than a post-append mutation so the field is set where every other
    /// field of the same finding is.
    requires_artifact: bool,
    /// #167 Stage 3 fix rounds 1 and 2 (I-3 / NEW-2): non-null for
    /// `RAILS_BACKEND_ENDPOINT` alone, whose findings are keyed on
    /// `(line, verb, resource)`. `resource` is the second half of that key
    /// and may itself be null (a route whose controller never resolved);
    /// it is read only when `verb_key` is set. See `routeVerbFindingId`.
    verb_key: ?[]const u8,
    resource_key: ?[]const u8,
) Allocator.Error!void {
    const id = if (verb_key) |v|
        try routeVerbFindingId(gpa, code, line, v, resource_key)
    else
        try routeFindingId(gpa, code, line);
    errdefer gpa.free(id);
    const path_copy = try gpa.dupe(u8, routes_file);
    errdefer gpa.free(path_copy);
    const message_copy = try gpa.dupe(u8, message);
    errdefer gpa.free(message_copy);
    const route_id_copy = try gpa.dupe(u8, route_id);
    errdefer gpa.free(route_id_copy);
    const choices_copy = try dupeChoices(gpa, choices);
    errdefer freeChoices(gpa, choices_copy);
    try list.append(gpa, .{
        .id = id,
        .code = code,
        .severity = severity,
        .path = path_copy,
        .line = line,
        .route_id = route_id_copy,
        .message = message_copy,
        .choices = choices_copy,
        .requires_artifact = requires_artifact,
    });
}

/// The Rails resource a submission from `path` targets: the controller of
/// the route that named this template as its view.
///
/// `null` for a partial, a layout, or any template no route resolved to --
/// there is no controller to name, and `backend.choicesFor` answers a null
/// resource with one flat verb-matched group, which is the honest ranking
/// when the resource is unknown.
///
/// Ties (two routes on one view -- `root "pages#about"` and `get "/about"`)
/// resolve to the SMALLEST route index rather than to the first match in
/// some other order: the route table is `rails.Discovery.routes`, whose
/// order is fixed before this file sees it, so the same input gives the same
/// answer. The two would in any case share a controller in every case that
/// matters -- a view lives under `app/views/<controller>/`.
///
/// Contract 3 (caller-buffer): allocates nothing; borrows from `in`.
fn templateResource(in: DeriveInput, path: []const u8) ?[]const u8 {
    for (in.route_views, 0..) |maybe_view, i| {
        const view = maybe_view orelse continue;
        if (!std.mem.eql(u8, view, path)) continue;
        if (i >= in.routes.len) continue;
        if (in.routes[i].controller) |c| return c;
    }
    return null;
}

// ---- #167 Stage 3 assumption A5: the auth journey ------------------------

/// The controller names Rails' own generators, and every guide since, give
/// the sign-in and sign-up halves of an authentication flow. Matching on the
/// controller rather than on the route path is what makes `/session/new`,
/// `/login` and `/users/sign_in` one rule.
const journey_controllers = [_][]const u8{ "sessions", "registrations" };

/// True when `tpl` holds a `form` containing a `password_field`.
///
/// The nesting matters: a bare `password_field` outside any form is not
/// evidence of an authentication flow (it is a field on something else), and
/// A5 says "a `form` containing a `form_field` named `password_field`". The
/// frame walk is `derive`'s own, restated -- both go through
/// `convert.opensBlock`, so the two cannot disagree about what a form
/// encloses.
///
/// Contract 1 (self-freeing): the frame stack is the only allocation and it
/// is released before returning.
fn templateHasPasswordForm(gpa: Allocator, tpl: fragments.Template) Allocator.Error!bool {
    // Every open block gets a frame, not just forms: a `<% if %>` inside a
    // form must not pop the form's own frame when its `end` arrives.
    var frames: std.ArrayListUnmanaged(bool) = .empty;
    defer frames.deinit(gpa);
    var forms: usize = 0;
    for (tpl.nodes) |node| {
        if (node.text != null) continue;
        if (node.kind == .form_field and forms > 0) {
            if (node.name) |name| {
                if (std.mem.eql(u8, name, "password_field")) return true;
            }
        }
        if (node.kind == .block_end) {
            // A stray `block_end` with no frame is dropped, the same defence
            // `derive` and `convert.matchingEnd` take against a malformed
            // stream.
            if (frames.pop()) |was_form| {
                if (was_form) forms -= 1;
            }
        } else if (convert.opensBlock(node)) {
            const is_form = node.kind == .form;
            try frames.append(gpa, is_form);
            if (is_form) forms += 1;
        }
    }
    return false;
}

/// Assumption A5's verdict, computed once per `derive` and read by three
/// rows (the form row's suppression, the route-level
/// `RAILS_BACKEND_ENDPOINT` exclusion, and `RAILS_AUTH_JOURNEY` itself).
///
/// Contract 2 (owned-result): `route` and `views` are the two allocations;
/// released by `deinit`. Every string held is borrowed from `in`.
const Journey = struct {
    /// Index-aligned with `in.routes`.
    route: []bool,
    /// Every template whose forms the journey speaks for: the view of each
    /// journey route, plus every template those views reach through the
    /// render graph. Borrowed from `in`; the backing slice is owned.
    views: []const []const u8,

    fn deinit(self: Journey, gpa: Allocator) void {
        gpa.free(self.route);
        gpa.free(self.views);
    }

    /// True when a template's forms are the auth journey's question rather
    /// than their own.
    ///
    /// Contract 3 (caller-buffer): a linear scan of a list the size of one
    /// app's journey (a handful of templates), computed once per `derive`.
    fn isJourneyView(self: Journey, path: []const u8) bool {
        for (self.views) |v| {
            if (std.mem.eql(u8, v, path)) return true;
        }
        return false;
    }
};

/// How far the journey-view walk follows `render` edges. Mirrors
/// `rails.max_partial_depth` (3), the cap Stage 1's own transitive scan
/// applies -- restated rather than imported because `rails.zig` is this
/// package's ROOT and imports this file.
///
/// **The cap is what guarantees termination** -- including on a cycle, which
/// `in.render_graph` cannot contain today (it is the output of Stage 1's own
/// capped walk) but which this function must not depend on. The visited set
/// in `appendUnseen` is a WORK bound, not a correctness one: it keeps a wide
/// or diamond-shaped graph linear in the graph rather than exponential in
/// the cap, and removing it changes no answer.
const max_journey_render_depth: usize = 3;

/// Contract 2 (owned-result), released by `Journey.deinit`.
fn detectJourney(gpa: Allocator, in: DeriveInput) Allocator.Error!Journey {
    // Which templates hold a password form. Scratch: read only to decide
    // `route[]` below -- fix round 1 (I-2) took away its power to suppress
    // anything on its own, because a password partial that no journey route
    // reaches has a real, answerable backend question of its own.
    var password_views: std.ArrayListUnmanaged([]const u8) = .empty;
    defer password_views.deinit(gpa);
    for (in.templates) |tpl| {
        if (try templateHasPasswordForm(gpa, tpl)) try password_views.append(gpa, tpl.path);
    }
    const route = try journeyFlags(gpa, in.routes, in.route_views, password_views.items);
    errdefer gpa.free(route);

    // Fix round 2 (NEW-1): the journey's views are not just the route views.
    // A sign-in page routinely renders `shared/_login_form`, and the form is
    // in the PARTIAL -- so keying suppression on "is this a route view"
    // raised BOTH `RAILS_AUTH_JOURNEY` and the partial's own
    // `RAILS_BACKEND_ENDPOINT` for one form, which is the double question A5
    // exists to prevent. The render graph is what closes it: a partial's form
    // belongs to the journey exactly when some journey route's view REACHES
    // that partial.
    //
    // A partial reached from a journey view AND from an ordinary one is
    // treated as the journey's. That is the deliberate choice, and the
    // asymmetry is the reason: a shared partial answered twice is two
    // conflicting bindings for one region, while the ordinary page it also
    // appears on is still covered -- the journey's `island` answer scaffolds
    // the `AuthForm` that region becomes wherever it is rendered. The other
    // direction would leave the sign-in form asked about twice.
    var views: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer views.deinit(gpa);
    for (route, 0..) |j, i| {
        if (!j) continue;
        if (i >= in.route_views.len) continue;
        const v = in.route_views[i] orelse continue;
        try appendUnseen(gpa, &views, v);
    }
    // Breadth-first over the already-seeded prefix: `frontier_end` is where
    // the current depth's nodes stop, and everything appended past it is the
    // next depth. `max_journey_render_depth` is what ends the loop -- see its
    // doc for why the visited set is a work bound rather than the
    // termination argument.
    var depth: usize = 0;
    var frontier_start: usize = 0;
    while (depth < max_journey_render_depth and frontier_start < views.items.len) : (depth += 1) {
        const frontier_end = views.items.len;
        var k = frontier_start;
        while (k < frontier_end) : (k += 1) {
            const from = views.items[k];
            for (in.render_graph) |node| {
                if (!std.mem.eql(u8, node.path, from)) continue;
                for (node.renders) |target| try appendUnseen(gpa, &views, target);
            }
        }
        frontier_start = frontier_end;
    }

    return .{ .route = route, .views = try views.toOwnedSlice(gpa) };
}

/// A5's ROUTE rule, split out of `detectJourney` so the one definition can
/// also answer `journeyRouteFlags` below. `detectJourney` goes on to widen
/// the answer into a set of TEMPLATES through the render graph; this half is
/// only about which routes the journey covers, which is all `scaffold.zig`
/// needs.
///
/// Contract 2 (owned-result): the returned slice is the only allocation.
fn journeyFlags(
    gpa: Allocator,
    route_list: []const routes.Route,
    route_views: []const ?[]const u8,
    password_views: []const []const u8,
) Allocator.Error![]bool {
    const route = try gpa.alloc(bool, route_list.len);
    errdefer gpa.free(route);
    for (route_list, 0..) |r, i| {
        var is_journey = false;
        if (r.controller) |c| {
            for (journey_controllers) |jc| {
                if (std.mem.eql(u8, c, jc)) is_journey = true;
            }
        }
        if (!is_journey and i < route_views.len) {
            if (route_views[i]) |v| {
                for (password_views) |pv| {
                    if (std.mem.eql(u8, pv, v)) is_journey = true;
                }
            }
        }
        route[i] = is_journey;
    }
    return route;
}

/// Assumption A5's per-route verdict, index-aligned with `route_list`.
///
/// Public because `scaffold.zig` has to push the `RAILS_AUTH_JOURNEY`
/// finding's id into every journey route's `open_finding_ids` (ruling S21's
/// mechanism): the finding is keyed on ONE `config/routes.rb` line -- the
/// smallest the journey occupies -- so no route except that one can find it
/// by recomputing an id from its own line, and without the push the
/// operator's answer settles nothing. Exported rather than re-derived there
/// so A5 has exactly one definition; a second copy would let the question
/// and the answer disagree about which routes the journey covers.
///
/// Only the ROUTE half is exported. The render-graph widening
/// (`Journey.views`) decides which TEMPLATES the journey speaks for, which
/// is a question about findings, not about route outcomes -- `scaffold.zig`
/// never asks it.
///
/// Contract 2 (owned-result): the returned slice is the only allocation and
/// is the caller's to free.
pub fn journeyRouteFlags(
    gpa: Allocator,
    route_list: []const routes.Route,
    route_views: []const ?[]const u8,
    templates: []const fragments.Template,
) Allocator.Error![]bool {
    var password_views: std.ArrayListUnmanaged([]const u8) = .empty;
    defer password_views.deinit(gpa);
    for (templates) |tpl| {
        if (try templateHasPasswordForm(gpa, tpl)) try password_views.append(gpa, tpl.path);
    }
    return journeyFlags(gpa, route_list, route_views, password_views.items);
}

/// Appends `path` unless it is already present. Linear, which is right at
/// this size: the list is one app's journey (a handful of templates), walked
/// once per `derive`, and a hash set would cost an allocation and a failure
/// path to save nothing measurable.
///
/// The dedupe changes no ANSWER -- `Journey.isJourneyView` is a membership
/// test, and a duplicate entry is still the same member. It bounds the work
/// the BFS above does on a diamond-shaped graph (two partials rendering one
/// shared partial is the everyday case). Stated here rather than left to be
/// mistaken for the termination argument, which is the depth cap's.
///
/// Contract 2 (owned-result), via the `list` out-parameter rather than the
/// return value: the only allocation is `list`'s backing store, which the
/// caller owns and releases -- `detectJourney` hands it to
/// `toOwnedSlice`, and `Journey.deinit` frees it from there. `path` is
/// stored BORROWED, never copied, so the elements outlive this call by
/// virtue of `DeriveInput`, not of anything allocated here. Nothing is
/// scratch, so there is nothing to free on the error path either.
fn appendUnseen(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
) Allocator.Error!void {
    for (list.items) |v| {
        if (std.mem.eql(u8, v, path)) return;
    }
    try list.append(gpa, path);
}

/// Which routes one ROUTE-scoped row fires on.
const RouteRow = enum {
    /// A GET/HEAD route with a `:param`/`*glob` segment that discovery did
    /// NOT call `backend`. A non-GET route has no page to migrate in the
    /// first place, and a `backend` one is already answered by its own
    /// classification -- neither has a dynamic-segment decision to make.
    dynamic_segment,
    /// A route discovery classified `redirect`, whatever its verb: the
    /// static tree cannot express a redirect, so the host config owns it and
    /// the operator acknowledges that (spec, "Conversion: what a route
    /// becomes").
    redirect,
    /// Ruling S22: a route that `scaffold.zig` sends down the content-page
    /// path and finds no view template for. See `routeHasNoView`.
    no_template,
    /// #167 Stage 3: a route that is API traffic -- `backend` by
    /// classification, or by verb -- and therefore needs a ZigBase operation
    /// rather than a page. Journey routes are excluded: `RAILS_AUTH_JOURNEY`
    /// is already their question (assumption A5).
    backend_endpoint,
    /// #167 Stage 3 assumption A7: a page route whose controller runs an
    /// authentication `before_action` over its action.
    auth_guard,
    /// #182: the second route to claim one `content/<url>/index.smd`.
    content_collision,
    /// #182: a static GET route whose path `resolve.contentPath` refuses.
    route_path_unsupported,
};

/// Ruling S22's predicate, and a deliberate mirror of `scaffold.zig`'s own
/// route dispatch (`routeOutcome`): a finding attached to no route is worse
/// than no finding at all, because it sits in `findings[]` as a question that
/// no `MIGRATION.handoff.json` row ever names and no answer can retire.
///
/// So each exclusion below is one of scaffold's own earlier branches. A
/// `redirect` or `backend` route, and any non-GET verb, never becomes a page.
/// A dynamic path is answered by `RAILS_ROUTE_DYNAMIC_SEGMENT` and returns
/// before the view is ever looked up. A path `resolve.contentPath` refuses
/// (`(.:format)`-style syntax) has no file to write, and ruling S22 leaves
/// that one an id-less open note on purpose, so it must not gain a row here.
///
/// The one branch this cannot mirror is scaffold's content-path COLLISION
/// check, which depends on route order: two declarations reducing to one
/// `content/<url>/index.smd` where the loser is ALSO viewless would leave
/// this row unattached. That needs a duplicate route declaration and a
/// missing template on the same route.
///
/// Contract 1 (self-freeing): the `contentPath` scratch is released here;
/// nothing escapes.
fn routeHasNoView(
    gpa: Allocator,
    in: DeriveInput,
    r: routes.Route,
    index: usize,
    class: ?classify.Class,
) Allocator.Error!bool {
    if (!std.mem.eql(u8, r.verb, "GET") and !std.mem.eql(u8, r.verb, "HEAD")) return false;
    if (class == classify.Class.backend or class == classify.Class.redirect) return false;
    if (isDynamicRoutePath(r.path)) return false;
    // A route this input carries no template list for is a route we know
    // nothing about; see `DeriveInput.route_templates`.
    if (index >= in.route_templates.len) return false;
    if (resolve.viewFor(in.route_templates[index], r.controller, r.action) != null) return false;
    const content_path = try resolve.contentPath(gpa, r.path);
    defer if (content_path) |c| gpa.free(c);
    return content_path != null;
}

/// One qualifying route, reduced to what the grouping below needs.
/// `id` and `detail` are owned by `deriveRouteFindings`'s own scratch list.
const RouteHit = struct {
    line: u64,
    id: []u8,
    /// #167 Stage 3: the row-specific half of the message, for the two rows
    /// whose prefix is not a constant -- `auth_guard`'s
    /// `<filter> on <controller>` and `content_collision`'s winning route.
    /// `null` for every row with a fixed prefix.
    detail: ?[]u8 = null,
    /// #167 Stage 3: what the `backend_endpoint` row asks
    /// `backend.choicesFor`. Borrowed from the route table.
    verb: []const u8 = "",
    resource: ?[]const u8 = null,
};

/// `(line, verb, resource, id)`.
///
/// The `verb` key is redundant as an ORDER -- a hit's `id` is
/// `"<verb> <path>"`, so ordering by `id` already orders by verb (no HTTP
/// verb is a prefix of another, and even if one were, the `' '` separator
/// sorts below every letter). `resource` is not redundant at all: two routes
/// of different controllers can interleave freely under one `(line, verb)`.
/// Both are here so `deriveRouteFindings`' `RAILS_BACKEND_ENDPOINT` grouping
/// (fix round 1, I-3; fix round 2, NEW-2) walks CONTIGUOUS runs of equal
/// `(line, verb, resource)` -- a split run would emit two findings with the
/// same id, the one property an id must never lose.
fn routeHitLessThan(_: void, a: RouteHit, b: RouteHit) bool {
    if (a.line != b.line) return a.line < b.line;
    const verb_order = std.mem.order(u8, a.verb, b.verb);
    if (verb_order != .eq) return verb_order == .lt;
    const resource_order = std.mem.order(u8, a.resource orelse "", b.resource orelse "");
    if (resource_order != .eq) return resource_order == .lt;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// Whether two hits belong to the same `RAILS_BACKEND_ENDPOINT` group: the
/// key `backend.choicesFor` is asked, so a shared group is exactly "these
/// routes would be offered the same answers".
fn sameBackendGroup(a: RouteHit, b: RouteHit) bool {
    return std.mem.eql(u8, a.verb, b.verb) and
        std.mem.eql(u8, a.resource orelse "", b.resource orelse "");
}

fn containsIndex(list: []const usize, i: usize) bool {
    for (list) |v| {
        if (v == i) return true;
    }
    return false;
}

/// The route that beat `i` to its content path, or null when `i` did not
/// lose one. Contract 3 (caller-buffer).
fn collisionWinner(list: []const resolve.ContentCollision, i: usize) ?usize {
    for (list) |c| {
        if (c.route == i) return c.with;
    }
    return null;
}

/// Assumption A7's join: the authentication `before_action` that applies to
/// this route's action, or null.
///
/// `controllers.authGuardFor` is THE picker, shared with `scaffold.zig`'s
/// `public` note rather than restated here: the finding and the note are two
/// rows about one decision, and while each had its own pick they could -- and
/// on a controller with two auth-looking filters did -- name different
/// filters. Its doc carries the reasoning behind the smallest-`(name, line)`
/// rule and behind walking the `class Child < Parent` chain (fix round 1,
/// I-1: comparing `f.controller` to the route's own controller reported
/// nothing at all for the shape almost every Rails app has).
const authGuardFor = controllers.authGuardFor;

/// Emits ONE finding per `routes.rb` DECLARATION, not per route.
///
/// A single `resources :posts` line yields `GET /posts/:id` AND
/// `GET /posts/:id/edit`, both carrying that line as their `source.line` --
/// so a finding id of `<code>.config/routes.rb.L<line>` (the shape ruled for
/// these rows) is shared by both. Emitting one finding per route would put
/// two entries with the SAME id in `findings[]`, which breaks the one
/// property the id exists for: being the key a recorded decision is
/// reconciled against. Folding them is also the honest reading of the
/// decision itself -- `spa` on a `resources` line means "this whole
/// declaration becomes a SPA", and every route under it shares the one
/// `spa/<segment>.spa.tsx` anyway.
///
/// `route_id` therefore names ONE of the affected routes (the first in the
/// total order below), exactly as `blockers.Blocker.route_id` already does
/// for a shared unreadable template -- see manifest.zig's module doc, point
/// 2. The `message` names them all, so nothing is lost, only relocated.
///
/// Contract 2 (owned-result), inherited from `derive`: every scratch
/// allocation is released here; only what `appendRouteFinding` puts on
/// `list` escapes.
fn deriveRouteFindings(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    in: DeriveInput,
    row: RouteRow,
    journey: Journey,
) Allocator.Error!void {
    var hits: std.ArrayListUnmanaged(RouteHit) = .empty;
    defer {
        for (hits.items) |h| {
            gpa.free(h.id);
            if (h.detail) |d| gpa.free(d);
        }
        hits.deinit(gpa);
    }

    for (in.routes, 0..) |r, i| {
        // A missing verdict is `null`, not `.backend`: see
        // `DeriveInput.classifications`.
        const class: ?classify.Class = if (i < in.classifications.len) in.classifications[i].class else null;
        const qualifies = switch (row) {
            // A `redirect` route is excluded for the same reason a `backend`
            // one is: it already has its own row below, and it never becomes
            // a page, so "what should this dynamic segment become" is a
            // question with no answer that could change anything.
            // `scaffold.zig` reaches the `redirect` arm before it ever asks
            // whether the path is dynamic, so an unsuppressed row here would
            // be an orphan finding -- listed in the manifest, attached to no
            // route outcome, and unanswerable.
            .dynamic_segment => (std.mem.eql(u8, r.verb, "GET") or std.mem.eql(u8, r.verb, "HEAD")) and
                class != classify.Class.backend and
                class != classify.Class.redirect and
                isDynamicRoutePath(r.path),
            .redirect => class == classify.Class.redirect,
            .no_template => try routeHasNoView(gpa, in, r, i, class),
            // #167 Stage 3. `backend` by classification OR by verb, exactly
            // the pair `scaffold.routeOutcome` folds into its `backend`
            // status -- so every route the handoff calls `backend` has an id
            // an operator can bind an operation to (S11's reopening).
            //
            // `redirect` is excluded (fix round 1, M-1) for the reason it is
            // excluded from every other row: `scaffold.routeOutcome` reaches
            // its `redirect` arm FIRST, whatever the verb, and returns with
            // status `redirect` -- so a `post "/legacy" => redirect("/new")`
            // would carry a backend question attached to no route outcome,
            // unanswerable and un-retirable. Its own
            // `RAILS_REDIRECT_HOST_CONFIG` is the question about it.
            .backend_endpoint => !journeyRoute(journey, i) and
                class != classify.Class.redirect and
                (class == classify.Class.backend or
                    !(std.mem.eql(u8, r.verb, "GET") or std.mem.eql(u8, r.verb, "HEAD"))),
            // A7. Same exclusions as a page: a non-GET route, a `backend` or
            // `redirect` one, and a dynamic path all reach scaffold's earlier
            // arms and never become a page, so "this page cannot enforce its
            // guard" is not a question about them.
            .auth_guard => (std.mem.eql(u8, r.verb, "GET") or std.mem.eql(u8, r.verb, "HEAD")) and
                class != classify.Class.backend and
                class != classify.Class.redirect and
                !isDynamicRoutePath(r.path) and
                authGuardFor(in.filters, r.controller, r.action) != null,
            .content_collision => collisionWinner(in.content_collisions, i) != null,
            .route_path_unsupported => containsIndex(in.unsupported_route_paths, i),
        };
        if (!qualifies) continue;
        // `<verb> <path>`, the same string `rails.formatRouteId` builds.
        // Formatted here rather than imported because `rails.zig` is this
        // package's ROOT and imports this file; the two-token format is
        // simpler to restate than that cycle is to reason about.
        const id = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.verb, r.path });
        errdefer gpa.free(id);
        const detail: ?[]u8 = switch (row) {
            .auth_guard => blk: {
                const f = authGuardFor(in.filters, r.controller, r.action).?;
                break :blk try std.fmt.allocPrint(gpa, "{s} on {s}", .{ f.name orelse "", f.controller });
            },
            .content_collision => blk: {
                const w = in.routes[collisionWinner(in.content_collisions, i).?];
                break :blk try std.fmt.allocPrint(gpa, "{s} {s}", .{ w.verb, w.path });
            },
            else => null,
        };
        errdefer if (detail) |d| gpa.free(d);
        try hits.append(gpa, .{
            .line = r.source.line,
            .id = id,
            .detail = detail,
            .verb = r.verb,
            .resource = r.controller,
        });
    }

    // Sorted by (line, verb, resource, id) so the grouping below is
    // contiguous and the representative route -- and the message's order --
    // is the same on every machine, whatever order the sidecar emitted the
    // route table in.
    std.mem.sort(RouteHit, hits.items, {}, routeHitLessThan);

    const code = switch (row) {
        .dynamic_segment => code_route_dynamic_segment,
        .redirect => code_redirect_host_config,
        .no_template => code_no_template,
        .backend_endpoint => code_backend_endpoint,
        .auth_guard => code_route_auth_guard,
        .content_collision => code_content_path_collision,
        .route_path_unsupported => code_route_path_unsupported,
    };
    // `null` for the one row whose answers are not a constant: see the
    // per-group `choicesFor` call below.
    const static_choices: ?[]const []const u8 = switch (row) {
        .dynamic_segment => &choices_spa_retain_blocked,
        .redirect => &choices_retain_blocked,
        .no_template => &choices_retain_blocked,
        .backend_endpoint => null,
        .auth_guard => &choices_public_retain_blocked,
        .content_collision => &choices_retain_blocked,
        .route_path_unsupported => &choices_retain_blocked,
    };

    // Ruling S22 groups by `routes.rb` LINE. Fix round 1 (I-3) and fix round
    // 2 (NEW-2) narrow THIS row -- and only this row -- to
    // `(line, verb, resource)`: its answer is a single ZigBase operation, and
    // one line routinely declares routes needing several. `resources :posts`
    // puts `POST /posts`, `PATCH /posts/:id` and `DELETE /posts/:id` on one
    // line; `resources :posts, :comments` puts `POST /posts` and
    // `POST /comments` on one line at one verb. Either way the grouped
    // finding offered the REPRESENTATIVE route's operations only, so the rest
    // had nothing they could be bound to. The narrowed key is exactly the
    // pair `backend.choicesFor` is asked below. See `routeVerbFindingId` for
    // the id shape that keeps the groups apart.
    const group_by_verb = row == .backend_endpoint;

    var i: usize = 0;
    while (i < hits.items.len) {
        var j = i + 1;
        while (j < hits.items.len and hits.items[j].line == hits.items[i].line and
            (!group_by_verb or sameBackendGroup(hits.items[j], hits.items[i]))) j += 1;
        const head = hits.items[i];

        var message: std.ArrayListUnmanaged(u8) = .empty;
        defer message.deinit(gpa);
        // A prefix that names a specific route -- the guard's controller, the
        // winner of a content-path collision -- can only speak for the
        // group's representative. That is the same compromise `route_id`
        // already makes, and the trailing list still names every route in the
        // group.
        switch (row) {
            .dynamic_segment => try message.appendSlice(gpa, "route path has a dynamic segment: "),
            .redirect => try message.appendSlice(gpa, "route redirects; the host config owns it, not the static tree: "),
            .no_template => try message.appendSlice(gpa, "no view template resolves for the route's controller and action: "),
            .backend_endpoint => try message.appendSlice(gpa, "route is API traffic and needs a backend operation: "),
            .auth_guard => {
                try message.appendSlice(gpa, "page is guarded by before_action :");
                try message.appendSlice(gpa, head.detail orelse "");
                try message.appendSlice(gpa, "; a static page cannot enforce it: ");
            },
            .content_collision => {
                try message.appendSlice(gpa, "content path collision with ");
                try message.appendSlice(gpa, head.detail orelse "");
                try message.appendSlice(gpa, ": ");
            },
            .route_path_unsupported => try message.appendSlice(gpa, "route path contains syntax this stage does not interpret: "),
        }
        for (hits.items[i..j], 0..) |h, k| {
            if (k != 0) try message.appendSlice(gpa, ", ");
            try message.appendSlice(gpa, h.id);
        }

        const verb_key: ?[]const u8 = if (group_by_verb) head.verb else null;
        const resource_key: ?[]const u8 = if (group_by_verb) head.resource else null;
        if (static_choices) |ch| {
            try appendRouteFinding(gpa, list, code, .warn, head.line, message.items, ch, head.id, false, verb_key, resource_key);
        } else {
            // Contract 1 over borrowed elements: free the slice alone. Every
            // route in this group shares `head.verb` now, so the offered
            // operations really are the ones that could serve all of them.
            const ch = try backend.choicesFor(gpa, in.backend, head.verb, head.resource);
            defer gpa.free(ch);
            try appendRouteFinding(gpa, list, code, .warn, head.line, message.items, ch, head.id, false, verb_key, resource_key);
        }
        i = j;
    }
}

/// `journey.route[i]`, defensively: `Journey.route` is allocated to
/// `in.routes.len`, but reading it through one accessor keeps its two call
/// sites -- the `backend_endpoint` row's exclusion and `deriveAuthJourney`'s
/// own membership test -- from each repeating the bound check.
fn journeyRoute(journey: Journey, i: usize) bool {
    return i < journey.route.len and journey.route[i];
}

/// #167 Stage 3 assumption A5's own row: ONE finding for the whole
/// sign-in/sign-up/sign-out flow.
///
/// Keyed (ruling S22) on the SMALLEST `routes.rb` line the journey occupies
/// rather than on one route's own line, because the journey spans several
/// declarations and the id has to be stable when one of them moves. The
/// message names every journey route in the same (line, route id) order the
/// grouped rows use, and says what the artifact is: the ZigBase auth
/// collection, which is a fact about the destination that no amount of
/// reading the Rails app recovers.
///
/// Contract 2 (owned-result), inherited from `derive`.
fn deriveAuthJourney(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    in: DeriveInput,
    journey: Journey,
) Allocator.Error!void {
    var hits: std.ArrayListUnmanaged(RouteHit) = .empty;
    defer {
        for (hits.items) |h| gpa.free(h.id);
        hits.deinit(gpa);
    }
    for (in.routes, 0..) |r, i| {
        if (!journeyRoute(journey, i)) continue;
        const id = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.verb, r.path });
        errdefer gpa.free(id);
        try hits.append(gpa, .{ .line = r.source.line, .id = id });
    }
    if (hits.items.len == 0) return;
    std.mem.sort(RouteHit, hits.items, {}, routeHitLessThan);

    var message: std.ArrayListUnmanaged(u8) = .empty;
    defer message.deinit(gpa);
    try message.appendSlice(gpa, "auth journey: ");
    for (hits.items, 0..) |h, k| {
        if (k != 0) try message.appendSlice(gpa, ", ");
        try message.appendSlice(gpa, h.id);
    }
    try message.appendSlice(gpa, "; island needs artifact = the ZigBase auth collection name ");
    // The parenthetical exists to NAME the candidates, so it keys on there
    // being candidates rather than on there being a document: a document
    // with no auth collection (the in-repo `contract/zigbase.openapi.json`
    // is one -- three consumer routes and no collections at all) leaves the
    // operator exactly as unable to check the name as no document does, and
    // `(in --backend: )` would be a list pretending to be one.
    const auth_collections: []const []const u8 = if (in.backend) |doc| doc.auth_collections else &.{};
    if (auth_collections.len > 0) {
        try message.appendSlice(gpa, "(in --backend: ");
        for (auth_collections, 0..) |c, k| {
            if (k != 0) try message.appendSlice(gpa, ", ");
            try message.appendSlice(gpa, c);
        }
        try message.append(gpa, ')');
    } else {
        try message.appendSlice(gpa, "(pass --backend to validate the name)");
    }

    try appendRouteFinding(
        gpa,
        list,
        code_auth_journey,
        .warn,
        hits.items[0].line,
        message.items,
        &choices_island_retain_blocked,
        hits.items[0].id,
        true,
        // Keyed on the line alone (ruling S22): the journey IS one decision
        // across several verbs and both its controllers, which is exactly
        // what makes the `RAILS_BACKEND_ENDPOINT` row's
        // `(line, verb, resource)` narrowing an exception rather than a new
        // rule.
        null,
        null,
    );
}

/// Formats `"L<line>C<col>"` for a node loc, or `"L<line>"` for a parse
/// error/layout loc.
///
/// Contract 1 (self-freeing): the only allocation is the returned buffer.
fn nodeLoc(gpa: Allocator, line: u64, col: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "L{d}C{d}", .{ line, col });
}

fn lineLoc(gpa: Allocator, line: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "L{d}", .{line});
}

/// The `loc` for a finding whose trigger has no source position at all: the
/// templates op never read the file, so there is no line and no column to
/// name. A word rather than an `L<n>` because every `L<n>` in an id is a
/// promise that someone can open the file at that line -- see the R15 row in
/// `derive`.
const unscanned_loc = "unscanned";

/// The `loc` for `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`, for the same reason
/// `unscanned_loc` exists: the file was never parsed -- no ERB scan is ever
/// attempted on a Haml/Slim template -- so there is no line to name and an
/// `L1` would be a lie. The word says WHY there is none, and one template
/// yields at most one of these, so `(code, path)` is still unique.
const unsupported_engine_loc = "engine";

/// The value of `key` among `attrs`, or null. Contract 3 (caller-buffer):
/// returns a sub-slice of the node's own strings.
fn attrValue(node: fragments.Node, key: []const u8) ?[]const u8 {
    for (node.attrs) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

/// ASCII upper-case. Contract 1 (self-freeing): the returned buffer is the
/// only allocation and it escapes.
fn upperAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

/// The HTTP verb a `form`/`form_field` node submits with: its literal
/// `method` attribute, upper-cased, else `POST`.
///
/// `POST` and not `GET` for the default because that is Rails': `form_with`
/// and `form_for` both post unless told otherwise, and a `form_tag` without
/// `method:` posts too. Guessing `GET` would offer the operator a list of
/// read operations to bind a submission to.
///
/// Contract 1 (self-freeing): one allocation, and it escapes.
fn formVerb(gpa: Allocator, node: fragments.Node) Allocator.Error![]u8 {
    const raw = attrValue(node, "method") orelse return gpa.dupe(u8, "POST");
    if (raw.len == 0) return gpa.dupe(u8, "POST");
    return upperAlloc(gpa, raw);
}

/// The verb a `link_to`/`button_to` node submits with, or `null` when it
/// does not submit at all.
///
/// `method:` wins over `data-turbo-method:` and `data-method:` (the Turbo
/// and rails-ujs spellings) because Rails' own UJS reads it first; a
/// `button_to` with none of them posts (that is what `button_to` IS -- a
/// one-button form); a plain `link_to` with neither is navigation and
/// answers `null`. An explicit `get` answers `null` whichever attribute
/// carried it, `button_to` included: `button_to "Search", path, method: :get`
/// renders a GET form, which fetches a page rather than mutating anything.
///
/// Contract 1 (self-freeing): the returned buffer, when non-null, is the
/// only allocation and it escapes.
fn mutationVerb(gpa: Allocator, node: fragments.Node) Allocator.Error!?[]u8 {
    const raw = attrValue(node, "method") orelse
        attrValue(node, "data-turbo-method") orelse
        // rails-ujs' own spelling, `data: { method: :delete }`, which the
        // sidecar flattens to `data-method` exactly as Rails renders it. A
        // site that serves no UJS would otherwise ship it as a GET link to a
        // DELETE route -- the same silent loss as the Turbo spelling, one
        // key over.
        attrValue(node, "data-method") orelse
        {
            // `code` is the fragment's own source text, which is the only
            // place the helper's NAME survives: `classify_link` folds
            // `link_to` and `button_to` into one `link_to` kind.
            if (std.mem.startsWith(u8, node.code, "button_to")) return try gpa.dupe(u8, "POST");
            return null;
        };
    if (raw.len == 0) return null;
    const verb = try upperAlloc(gpa, raw);
    errdefer gpa.free(verb);
    if (std.mem.eql(u8, verb, "GET")) {
        gpa.free(verb);
        return null;
    }
    return verb;
}

/// The verb a node that raised `RAILS_BACKEND_ENDPOINT` submits with, or
/// `null` when the node is not a mutation at all.
///
/// Public because `scaffold.zig` needs the SAME verb this file offered the
/// operator a choice list for: an answer of `custom:/api/contact` carries a
/// path and no verb (assumption A3), so the binding's verb has to be
/// re-derived, and re-deriving it there would be a second copy of two rules
/// that already exist here. `deriveNode` keeps calling the two halves
/// directly -- it knows which kind it is holding and does not need the
/// dispatch.
///
/// Contract 1 (self-freeing): the returned verb, when non-null, is the only
/// allocation and it escapes.
pub fn nodeVerb(gpa: Allocator, node: fragments.Node) Allocator.Error!?[]u8 {
    return switch (node.kind) {
        .form, .form_field => try formVerb(gpa, node),
        .link_to => try mutationVerb(gpa, node),
        else => null,
    };
}

/// The route a mutating `link_to`/`button_to` submits to, as an index into
/// `route_list`, or null when this run resolved none.
///
/// A link names its own target -- a route helper stem (`post_path` -> `post`,
/// matched against `Route.name`) or a literal path -- so this is a lookup and
/// not a convention, unlike the new/create pairing a form needs. `verb` is
/// the method the control submits with; a route with a different verb is a
/// different route, and `resources :posts` puts several on one path.
///
/// Public and shared with `scaffold.zig`'s `linkRoute`, which pairs the
/// binding onto the same route. The two answers have to agree: the choices
/// this file offers are ranked against the resource that route names, and
/// scaffold hands the endpoint to that same route.
///
/// Contract 3 (caller-buffer): allocates nothing.
pub fn linkTargetRoute(route_list: []const routes.Route, node: fragments.Node, verb: ?[]const u8) ?usize {
    const want = verb orelse return null;
    // `classify_link` puts the link TEXT first, so a literal target is
    // `args[1]`; a helper target is `name` instead and leaves `args[1..]` to
    // the route's own placeholders.
    const literal_target: ?[]const u8 = if (node.name == null and node.args.len > 1) node.args[1] else null;
    for (route_list, 0..) |other, i| {
        if (!std.mem.eql(u8, other.verb, want)) continue;
        if (node.name) |stem| {
            const rn = other.name orelse continue;
            if (std.mem.eql(u8, rn, stem)) return i;
        } else if (literal_target) |t| {
            if (std.mem.eql(u8, other.path, t)) return i;
        }
    }
    return null;
}

/// #167 Stage 3's `RAILS_BACKEND_ENDPOINT` link row. Returns true when it
/// emitted a finding, so `deriveNode`'s `.link_to` arm knows to stop.
///
/// Contract 2 (owned-result), inherited from `derive`.
fn deriveMutationLink(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    in: DeriveInput,
    path: []const u8,
    node: fragments.Node,
) Allocator.Error!bool {
    const verb = (try mutationVerb(gpa, node)) orelse return false;
    defer gpa.free(verb);

    // The resource is the TARGET ROUTE's controller: the same key the
    // route-level `RAILS_BACKEND_ENDPOINT` row is grouped by
    // (`routeVerbFindingId`), and therefore the same key `choicesFor` is
    // asked everywhere else.
    //
    // The helper STEM was the key before, and it is the wrong shape. Rails
    // singularises a member helper -- `post_path(1)` for `DELETE /posts/:id`
    // -- while a ZigBase collection is plural, so "the resource's own
    // operations first" never fired for the member links that are most of the
    // mutating links there are: an operator answering a delete on a post was
    // offered every DELETE in the document in operation-id order, with the
    // right one wherever the alphabet put it.
    //
    // `null` when this run resolved no target route -- a literal path nothing
    // matches, a helper for a route the walk never recovered. There is no
    // resource to rank against then, and inventing one from the stem is what
    // this change removes.
    const target = linkTargetRoute(in.routes, node, verb);
    const resource: ?[]const u8 = if (target) |i| in.routes[i].controller else null;
    const choices = try backend.choicesFor(gpa, in.backend, verb, resource);
    defer gpa.free(choices);

    const loc = try nodeLoc(gpa, node.line, node.col);
    defer gpa.free(loc);

    var summary: std.ArrayListUnmanaged(u8) = .empty;
    defer summary.deinit(gpa);
    try summary.appendSlice(gpa, "link performs a mutation: ");
    try summary.appendSlice(gpa, if (std.mem.startsWith(u8, node.code, "button_to")) "button_to" else "link_to");
    // `args[0]` is the link TEXT (`classify_link` puts it first), which is
    // what an operator will recognise the control by -- the helper stem is
    // already implied by the choices.
    try summary.appendSlice(gpa, " `");
    if (node.args.len > 0) try summary.appendSlice(gpa, node.args[0]);
    try summary.append(gpa, '`');
    for (node.attrs) |a| {
        try summary.append(gpa, ' ');
        try summary.appendSlice(gpa, a.key);
        try summary.append(gpa, '=');
        try summary.appendSlice(gpa, a.value);
    }
    try appendFinding(gpa, list, code_backend_endpoint, .warn, path, node.line, loc, summary.items, choices);
    return true;
}

fn isElementRegion(node: fragments.Node) bool {
    return !node.missing and switch (node.kind) {
        .stimulus, .vue_root => true,
        .turbo_frame, .component_root => !node.output,
        else => false,
    };
}

/// Task 4 makes `convert.opensBlock` understand element regions globally.
/// Until then this derivation-local walk must count the sidecar's element
/// `block_end`s too, or nested-controller gating would pop the surrounding
/// Ruby frame instead of closing the element it belongs to.
fn elementEnd(nodes: []const fragments.Node, open: usize) ?usize {
    if (!isElementRegion(nodes[open])) return null;
    var depth: usize = 1;
    var i = open + 1;
    while (i < nodes.len) : (i += 1) {
        const node = nodes[i];
        if (node.text != null) continue;
        if (node.kind == .block_end) {
            depth -= 1;
            if (depth == 0) return i;
        } else if (isElementRegion(node) or convert.opensBlock(node)) {
            depth += 1;
        }
    }
    return null;
}

fn nestedStimulus(nodes: []const fragments.Node, index: usize) ?fragments.Node {
    for (nodes[0..index], 0..) |node, i| {
        if (node.kind != .stimulus or node.missing) continue;
        const end = elementEnd(nodes, i) orelse continue;
        if (end > index) return node;
    }
    return null;
}

/// Contract 1 (self-freeing): only the reconstructed extent bytes escape.
fn extentBytes(gpa: Allocator, nodes: []const fragments.Node, start: usize, end: usize) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (nodes[start .. end + 1]) |node| {
        if (node.text) |text| try out.appendSlice(gpa, text) else try out.appendSlice(gpa, node.code);
    }
    return out.toOwnedSlice(gpa);
}

fn sourceByPath(sources: []const port.JsSource, path: []const u8) ?port.JsSource {
    for (sources) |source| if (std.mem.eql(u8, source.path, path)) return source;
    return null;
}

fn npmHas(deps: []const integrations.NpmDep, name: []const u8) bool {
    for (deps) |dep| if (std.mem.eql(u8, dep.name, name)) return true;
    return false;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Contract 2 (owned-result), inherited from the caller's output list:
/// formatting scratch is freed before return and only appended bytes remain.
fn appendFmt(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try out.appendSlice(gpa, text);
}

/// Contract 1 (self-freeing): all controller/action scans are released and
/// only the complete finding message escapes.
fn stimulusMessage(
    gpa: Allocator,
    in: DeriveInput,
    nodes: []const fragments.Node,
    index: usize,
) Allocator.Error!struct { message: []u8, portable: bool } {
    const node = nodes[index];
    var message: std.ArrayListUnmanaged(u8) = .empty;
    errdefer message.deinit(gpa);
    try appendFmt(gpa, &message, "stimulus `{s}` on <{s}>", .{ node.name orelse "", node.value orelse "element" });
    if (node.missing or elementEnd(nodes, index) == null) {
        try message.appendSlice(gpa, "; element is not closed at its own block depth");
        return .{ .message = try message.toOwnedSlice(gpa), .portable = false };
    }
    if (nestedStimulus(nodes, index)) |outer| {
        try appendFmt(gpa, &message, "; nested inside the stimulus element at L{d}C{d}", .{ outer.line, outer.col });
        return .{ .message = try message.toOwnedSlice(gpa), .portable = false };
    }
    const end = elementEnd(nodes, index).?;
    const extent = try extentBytes(gpa, nodes, index, end);
    defer gpa.free(extent);

    var identifiers = std.mem.tokenizeAny(u8, node.name orelse "", " \t\r\n");
    var source_path: ?[]const u8 = null;
    var action_labels: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (action_labels.items) |label| gpa.free(label);
        action_labels.deinit(gpa);
    }
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(gpa);
    while (identifiers.next()) |identifier| {
        const controller = (try port.stimulusSource(gpa, identifier, in.js_sources)) orelse {
            var stem_buf: [512]u8 = undefined;
            const stem = port.controllerStem(&stem_buf, identifier);
            try appendFmt(gpa, &message, "; source not found ({s}.{{js,ts,jsx,tsx}})", .{stem});
            return .{ .message = try message.toOwnedSlice(gpa), .portable = false };
        };
        defer port.freeController(gpa, controller);
        if (controller.unsupported) |why| {
            try appendFmt(gpa, &message, "; port cannot follow: {s}", .{why});
            return .{ .message = try message.toOwnedSlice(gpa), .portable = false };
        }
        if (source_path == null) source_path = controller.path;
        for (controller.targets) |target| {
            var duplicate = false;
            for (targets.items) |existing| {
                if (std.mem.eql(u8, existing, target)) duplicate = true;
            }
            if (!duplicate) try targets.append(gpa, target);
        }
        const actions = try port.actionDescriptors(gpa, extent, identifier);
        defer gpa.free(actions.list);
        if (actions.unsupported) |why| {
            try appendFmt(gpa, &message, "; port cannot follow: {s}", .{why});
            return .{ .message = try message.toOwnedSlice(gpa), .portable = false };
        }
        for (actions.list) |action| {
            const label = try std.fmt.allocPrint(gpa, "{s}->{s}#{s}", .{ action.event, action.identifier, action.method });
            errdefer gpa.free(label);
            try action_labels.append(gpa, label);
        }
    }
    std.mem.sort([]u8, action_labels.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    std.mem.sort([]const u8, targets.items, {}, stringLessThan);
    if (action_labels.items.len > 0) {
        try message.appendSlice(gpa, "; actions: ");
        for (action_labels.items, 0..) |label, i| {
            if (i != 0) try message.appendSlice(gpa, ", ");
            try message.appendSlice(gpa, label);
        }
    }
    if (targets.items.len > 0) {
        try message.appendSlice(gpa, "; targets: ");
        for (targets.items, 0..) |target, i| {
            if (i != 0) try message.appendSlice(gpa, ", ");
            try message.appendSlice(gpa, target);
        }
    }
    try appendFmt(gpa, &message, "; source {s}", .{source_path orelse ""});
    return .{ .message = try message.toOwnedSlice(gpa), .portable = true };
}

/// Contract 1 (self-freeing): returns the resolved URL as the sole
/// allocation. `route_params` contains only certain named routes.
fn frameUrl(gpa: Allocator, in: DeriveInput, node: fragments.Node) Allocator.Error!?[]u8 {
    if (attrValue(node, "src")) |src| {
        if (std.mem.startsWith(u8, src, "/")) return try gpa.dupe(u8, src);
    }
    const stem = node.value orelse return null;
    for (in.route_params) |route| {
        if (!std.mem.eql(u8, route.name, stem)) continue;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        var arg: usize = 0;
        var segments = std.mem.splitScalar(u8, route.path, '/');
        var first = true;
        while (segments.next()) |segment| {
            if (!first) try out.append(gpa, '/');
            first = false;
            if (segment.len > 1 and (segment[0] == ':' or segment[0] == '*')) {
                if (arg >= node.args.len) return null;
                try out.appendSlice(gpa, node.args[arg]);
                arg += 1;
            } else try out.appendSlice(gpa, segment);
        }
        if (arg != node.args.len) return null;
        return try out.toOwnedSlice(gpa);
    }
    return null;
}

fn frameIsApi(in: DeriveInput, node: fragments.Node, url: []const u8) bool {
    if (std.mem.endsWith(u8, url, ".json")) return true;
    for (in.routes, 0..) |route, i| {
        const same_route = if (attrValue(node, "src") != null)
            std.mem.eql(u8, route.path, url)
        else if (node.value) |name|
            route.name != null and std.mem.eql(u8, route.name.?, name)
        else
            std.mem.eql(u8, route.path, url);
        if (!same_route) continue;
        if (i < in.classifications.len and in.classifications[i].class == .backend) return true;
    }
    return false;
}

fn componentSource(in: DeriveInput, name: []const u8) ?port.JsSource {
    for ([_][]const u8{ ".jsx", ".tsx", ".js", ".ts" }) |ext| {
        for (in.js_sources) |source| {
            if (!std.mem.startsWith(u8, source.path, "app/javascript/components/")) continue;
            const base = source.path["app/javascript/components/".len..];
            if (base.len == name.len + ext.len and std.mem.startsWith(u8, base, name) and std.mem.eql(u8, base[name.len..], ext)) return source;
        }
    }
    return null;
}

/// Contract 1 (self-freeing): all normalized-path candidates are scratch;
/// the returned source is borrowed from `in.js_sources`.
fn relativeImportSource(gpa: Allocator, in: DeriveInput, importer: []const u8, spec: []const u8) Allocator.Error!?port.JsSource {
    if (!std.mem.startsWith(u8, spec, "./") and !std.mem.startsWith(u8, spec, "../")) return null;
    const dir = std.fs.path.dirname(importer) orelse return null;
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(gpa);
    var base_it = std.mem.splitScalar(u8, dir, '/');
    while (base_it.next()) |part| if (part.len > 0) try parts.append(gpa, part);
    var spec_it = std.mem.splitScalar(u8, spec, '/');
    while (spec_it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len <= 2) return null;
            _ = parts.pop();
        } else try parts.append(gpa, part);
    }
    if (parts.items.len < 2 or !std.mem.eql(u8, parts.items[0], "app") or !std.mem.eql(u8, parts.items[1], "javascript")) return null;
    const base = try std.mem.join(gpa, "/", parts.items);
    defer gpa.free(base);
    for ([_][]const u8{ "", ".jsx", ".tsx", ".js", ".ts", "/index.jsx", "/index.tsx", "/index.js", "/index.ts" }) |suffix| {
        if (suffix.len == 0) {
            if (!std.mem.endsWith(u8, base, ".jsx") and !std.mem.endsWith(u8, base, ".tsx") and !std.mem.endsWith(u8, base, ".js") and !std.mem.endsWith(u8, base, ".ts")) continue;
        }
        const candidate = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, suffix });
        defer gpa.free(candidate);
        if (sourceByPath(in.js_sources, candidate)) |source| return source;
    }
    return null;
}

/// Contract 1 (self-freeing): returns an owned refusal message, or null when
/// the root and every source in its copied closure are bundleable.
fn componentProblem(gpa: Allocator, in: DeriveInput, root: port.JsSource) Allocator.Error!?[]u8 {
    var queue: std.ArrayListUnmanaged(port.JsSource) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, root);
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const source = queue.items[i];
        const imports = try port.reactImports(gpa, source.bytes);
        defer gpa.free(imports.list);
        if (imports.unsupported) |why| return try std.fmt.allocPrint(gpa, "port cannot follow {s}: {s}", .{ std.fs.path.basename(source.path), why });
        for (imports.list) |imp| {
            if (!imp.relative) {
                if (port.isBridgeResolved(imp.spec) or npmHas(in.npm_dependencies, imp.spec)) continue;
                return try std.fmt.allocPrint(gpa, "import \"{s}\" from {s} has no version in package.json", .{ imp.spec, std.fs.path.basename(source.path) });
            }
            const child = (try relativeImportSource(gpa, in, source.path, imp.spec)) orelse return try std.fmt.allocPrint(gpa, "import \"{s}\" from {s} cannot be bundled", .{ imp.spec, std.fs.path.basename(source.path) });
            var seen = false;
            for (queue.items) |queued| {
                if (std.mem.eql(u8, queued.path, child.path)) seen = true;
            }
            if (!seen) try queue.append(gpa, child);
        }
    }
    return null;
}

fn blockParam(code: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, code, '|') orelse return null;
    const last_rel = std.mem.indexOfScalar(u8, code[first + 1 ..], '|') orelse return null;
    const value = std.mem.trim(u8, code[first + 1 .. first + 1 + last_rel], " \t\r\n");
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, ',') != null) return null;
    return value;
}

fn collectionMatches(stem: []const u8, collection: []const u8) bool {
    if (std.mem.eql(u8, stem, collection)) return true;
    return collection.len == stem.len + 1 and std.mem.startsWith(u8, collection, stem) and collection[stem.len] == 's';
}

/// Contract 2 (owned-result), inherited from `derive`: the body port is
/// released here and only bytes appended to the finding message survive.
fn deriveIvar(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    in: DeriveInput,
    path: []const u8,
    nodes: []const fragments.Node,
    index: usize,
) Allocator.Error!void {
    const node = nodes[index];
    const loc = try nodeLoc(gpa, node.line, node.col);
    defer gpa.free(loc);
    const name = node.name orelse "";
    var message: std.ArrayListUnmanaged(u8) = .empty;
    defer message.deinit(gpa);
    try appendFmt(gpa, &message, "request-time state `{s}`", .{name});

    var aliases_buf: [2]port.Alias = undefined;
    var aliases_len: usize = 1;
    aliases_buf[0] = .{ .ruby = name, .js = "rec" };
    var region = nodes[index .. index + 1];
    if (!node.output) {
        const end = convert.matchingEnd(nodes, index);
        if (end) |closing| {
            region = nodes[index + 1 .. closing];
            if (blockParam(node.code)) |param| {
                aliases_buf[1] = .{ .ruby = param, .js = "rec" };
                aliases_len = 2;
            }
        } else {
            try appendFinding(gpa, list, code_request_time_state, .warn, path, node.line, loc, message.items, &choices_spa_retain_blocked);
            return;
        }
    }
    const body = try port.recordBody(gpa, .{
        .routes = in.routes,
        .assets = in.assets,
        .fragments = in.templates,
        .findings = &.{},
        .layout_stem = null,
    }, path, region, aliases_buf[0..aliases_len]);
    defer port.freeBody(gpa, body);
    const portable = body.unportable == null;

    if (in.backend) |doc| {
        const stem = std.mem.trim(u8, name, "@");
        var collections: std.ArrayListUnmanaged([]const u8) = .empty;
        defer collections.deinit(gpa);
        for (doc.operations) |operation| {
            const collection = operation.collection orelse continue;
            var duplicate = false;
            for (collections.items) |existing| {
                if (std.mem.eql(u8, existing, collection)) duplicate = true;
            }
            if (!duplicate) try collections.append(gpa, collection);
        }
        std.mem.sort([]const u8, collections.items, {}, stringLessThan);
        var matched: ?[]const u8 = null;
        for (collections.items) |collection| {
            if (collectionMatches(stem, collection)) {
                matched = collection;
                break;
            }
        }
        if (matched) |collection| {
            try appendFmt(gpa, &message, "; collection {s} (in --backend)", .{collection});
        } else if (collections.items.len > 0) {
            try message.appendSlice(gpa, "; island/backend need artifact = a collection in --backend (");
            for (collections.items, 0..) |collection, i| {
                if (i != 0) try message.appendSlice(gpa, ", ");
                try message.appendSlice(gpa, collection);
            }
            try message.append(gpa, ')');
        }
    }
    try appendFinding(gpa, list, code_request_time_state, .warn, path, node.line, loc, message.items, if (portable) &choices_full else &choices_spa_retain_blocked);
}

/// Handles the node-triggered rows of the derivation table for one
/// template. Split out of `derive` because it is the one source with
/// several codes keyed off `Kind`, so this is where the table's node rows
/// live as a `switch` rather than duplicated across `derive`'s body.
///
/// Contract 2 (owned-result), inherited from `derive`.
fn deriveNode(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    in: DeriveInput,
    path: []const u8,
    node: fragments.Node,
    nodes: []const fragments.Node,
    node_index: usize,
    /// Ruling S12: this node sits inside a `form` block that already carries
    /// its own `RAILS_BACKEND_ENDPOINT`. Computed by `derive`'s walk, because
    /// only a walk over the whole stream can know it.
    in_form: bool,
    /// #167 Stage 3: the Rails resource a submission from THIS template goes
    /// to -- the controller of the route whose view this is -- so
    /// `backend.choicesFor` can rank that resource's own operations first.
    /// `null` for a partial, a layout, or any template no route named as its
    /// view: an unranked flat list is the honest answer, never a guessed one.
    resource: ?[]const u8,
    /// #167 Stage 3 assumption A5: this template is part of the auth journey,
    /// whose ONE `RAILS_AUTH_JOURNEY` finding is already the question its
    /// forms would otherwise each ask.
    journey_view: bool,
) Allocator.Error!void {
    const route_names = in.route_names;
    const locale = in.locale;
    const in_i18n_error_paths = in.i18n_error_paths;
    const asset_list = in.assets;
    // A text run (`node.text != null`) is never a finding candidate: per
    // `fragments.zig`'s `Node` doc, a text run's `kind` is always `.unknown`
    // as a side effect of the wire decode (there is no real `Kind` for
    // literal template output), not because the sidecar recognised and then
    // failed to classify a helper call. Dispatching on `kind` alone would
    // fire `RAILS_HELPER_UNKNOWN` for the plain HTML between ERB tags --
    // the majority of nodes in any real template.
    if (node.text != null) return;
    switch (node.kind) {
        .unknown => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "unknown helper `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_HELPER_UNKNOWN", .warn, path, node.line, loc, message, &choices_island_retain_blocked);
        },
        .request_state => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "request-time state `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, code_request_time_state, .warn, path, node.line, loc, message, &choices_full);
        },
        .ivar => try deriveIvar(gpa, list, in, path, nodes, node_index),
        .stimulus => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const result = try stimulusMessage(gpa, in, nodes, node_index);
            defer gpa.free(result.message);
            try appendFinding(gpa, list, code_stimulus_controller, .warn, path, node.line, loc, result.message, if (result.portable) &choices_stimulus else &choices_drop_retain_blocked);
        },
        .vue_root => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "Vue root `{s}`: the runtime bridge is React-only", .{node.name orelse ""});
            defer gpa.free(message);
            try appendFinding(gpa, list, code_component_vue_unsupported, .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .i18n => {
            if (!node.missing) return;
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const key = node.name orelse "";
            const base = if (locale) |l|
                try std.fmt.allocPrint(gpa, "missing translation `{s}` (locale {s})", .{ key, l })
            else
                try std.fmt.allocPrint(gpa, "missing translation `{s}`", .{key});
            defer gpa.free(base);
            // R16: with a locale file broken, `missing` says far less than it
            // normally does -- the table it was looked up in is empty or
            // partial. Still the same code and the same choices (the key
            // genuinely does not resolve, and the operator still has to
            // answer); what changes is that the message stops implying the
            // template is at fault. Only the FIRST path is named: this is one
            // sentence of context on a per-key finding, not the locale
            // report, and the blockers carry every file individually.
            const message = if (in_i18n_error_paths.len > 0)
                try std.fmt.allocPrint(gpa, "{s} — a locale file failed to load: {s}", .{ base, in_i18n_error_paths[0] })
            else
                try gpa.dupe(u8, base);
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_I18N_UNRESOLVED", .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .raw => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            try appendFinding(gpa, list, "RAILS_RAW_OUTPUT", .warn, path, node.line, loc, "unescaped output", &choices_island_retain_blocked);
        },
        .render_dynamic => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "dynamic render target `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_PARTIAL_DYNAMIC", .warn, path, node.line, loc, message, &choices_island_spa_retain_blocked);
        },
        .route_helper_dynamic => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "route helper `{s}` has non-literal arguments", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_ROUTE_HELPER_DYNAMIC", .warn, path, node.line, loc, message, &choices_island_spa_retain_blocked);
        },
        .route_helper, .link_to => {
            // #167 Stage 3: a `button_to`, or a `link_to ... method: :delete`,
            // is not navigation -- it submits. It needs a backend operation
            // for exactly the reason a form does, and nothing else in the
            // table reports it: a sign-out control is a `link_to`/`button_to`
            // with no form around it, so before this row it produced no
            // finding at all. (No fixture exercises it yet -- Task 7 adds the
            // `button_to "Sign out"` this row was written for; the unit tests
            // below are its only coverage until then.)
            //
            // Checked BEFORE the route-name lookup below, and returning
            // instead of falling through, for two reasons: a `link_to` with a
            // literal target has `name == null` and would otherwise return
            // unexamined, and a mutation whose helper stem names no recovered
            // route must ask ONE question, not two on the same node -- the
            // backend row is answerable (`custom:/<path>` covers a route the
            // document does not carry), `RAILS_ROUTE_HELPER_UNKNOWN` is the
            // narrower restatement of the same problem.
            if (node.kind == .link_to) {
                if (try deriveMutationLink(gpa, list, in, path, node)) return;
            }
            const name = node.name orelse return;
            if (!routeNameUnknown(route_names, name)) return;
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "route helper `{s}` matches no certain named route", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_ROUTE_HELPER_UNKNOWN", .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .control => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "control flow `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_TEMPLATE_CONTROL_FLOW", .warn, path, node.line, loc, message, &choices_island_spa_retain_blocked);
        },
        .asset => {
            // The JS-entry family has no target path to compute: `convert.zig`
            // DROPS these outright (`@z/runtime` and the island bundle replace
            // the Rails JS entry wholesale), so a finding here would be a
            // question with no placeholder in the converted page and no way
            // for the route ever to close.
            const helper = node.name orelse return;
            if (std.mem.eql(u8, helper, "javascript_include_tag") or
                std.mem.eql(u8, helper, "favicon_link_tag")) return;

            // The same walk `convert.zig` performs, argument for argument, so
            // the two agree on exactly which helper calls become a
            // placeholder. `stylesheet_link_tag "a", "b"` is ONE node and two
            // sheets, and the converter makes the whole node a placeholder
            // when ANY of them fails -- so reading only `args[0]` here left a
            // node whose first sheet resolved and whose second did not with a
            // placeholder and no id behind it. The empty fallback covers a
            // helper called with no literal argument at all, which `assetFor`
            // answers `null` for -- the honest result: there is no name to
            // resolve.
            const args: []const []const u8 = if (node.args.len > 0) node.args else &.{""};
            const message = blk: {
                for (args) |literal| {
                    // Ruling S23: an absolute URL names a resource on another
                    // host. `convert.zig` emits it verbatim (same predicate,
                    // so the two cannot drift), so there is no placeholder in
                    // the converted page for a finding to be answered
                    // against, and nothing is missing to report.
                    if (resolve.isAbsoluteAssetLiteral(literal)) continue;
                    const found = resolve.assetFor(asset_list, helper, literal) orelse
                        break :blk try std.fmt.allocPrint(
                            gpa,
                            "asset helper `{s}` names `{s}`, which matches no file under app/assets/ or public/",
                            .{ helper, literal },
                        );
                    // The file exists; what could not be derived is the URL it
                    // is served at (`assets.Asset.deterministic`), so the
                    // operator is told which file to port rather than sent
                    // hunting.
                    if (found.deterministic) continue;
                    break :blk try std.fmt.allocPrint(
                        gpa,
                        "asset `{s}` has no deterministic public URL; its target path cannot be derived without guessing",
                        .{found.source},
                    );
                }
                // Every argument is emittable, so the converted page holds
                // the author's own markup and there is nothing to ask about.
                return;
            };
            defer gpa.free(message);
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            try appendFinding(gpa, list, "RAILS_ASSET_TRANSFORM", .warn, path, node.line, loc, message, &choices_retain_blocked);
        },

        // ---- ruling S12 ------------------------------------------------
        .form, .form_field => {
            // Only the OUTERMOST form asks the question. A nested form, and
            // every field inside one, are the same decision -- which backend
            // operation this submission becomes -- and one form with twelve
            // fields must not put twelve identical questions in front of an
            // operator. A `form_field` with no enclosing form is NOT
            // suppressed: a stray `text_field` still submits somewhere, and
            // nothing else in the table would report it.
            if (in_form) return;
            // #167 Stage 3 assumption A5: a form in a sign-in/sign-up view
            // is not a separate backend question. The whole journey is ONE
            // decision (`RAILS_AUTH_JOURNEY`) because the answer is a single
            // ZigBase auth collection that an `AuthForm` and an `AuthStatus`
            // share; asking each form which operation it binds to would let
            // an operator answer the sign-in form and the sign-up form
            // inconsistently. A stray `form_field` in such a view is
            // suppressed with it, for the same reason it is suppressed
            // inside a form: the journey's finding is its question.
            if (journey_view) return;
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            var summary: std.ArrayListUnmanaged(u8) = .empty;
            defer summary.deinit(gpa);
            try summary.appendSlice(gpa, "form submits to a Rails action: ");
            // A `form` node's `name` is the MODEL's param key (`post` from
            // `@post`) and is null for a model-less `form_with(url: ...)`
            // (`templates.rb`'s `classify_form`, ruling R9); a `form_field`'s
            // is the field HELPER (`text_field`). Naming which of the two it
            // is beats printing a bare word an operator cannot place -- and
            // "no model" is a real fact about the form, not a missing value.
            if (node.kind == .form) {
                if (node.name) |m| {
                    try summary.appendSlice(gpa, "model `");
                    try summary.appendSlice(gpa, m);
                    try summary.append(gpa, '`');
                } else {
                    try summary.appendSlice(gpa, "no model");
                }
            } else {
                try summary.appendSlice(gpa, "field `");
                try summary.appendSlice(gpa, node.name orelse "");
                try summary.append(gpa, '`');
            }
            for (node.attrs) |a| {
                try summary.append(gpa, ' ');
                try summary.appendSlice(gpa, a.key);
                try summary.append(gpa, '=');
                try summary.appendSlice(gpa, a.value);
            }
            // #167 Stage 3: the row S12 reserved. The choices are no longer
            // two words but the ZigBase operations that could answer THIS
            // submission -- the form's own `method` (Rails defaults a
            // `form_with` to POST) against the resource its route names --
            // plus `retain`/`blocked`, plus (validator-side only, ruling A3)
            // a `custom:/<path>` the message spells out because a free-form
            // token cannot be enumerated in a fixed list.
            const verb = try formVerb(gpa, node);
            defer gpa.free(verb);
            const choices = try backend.choicesFor(gpa, in.backend, verb, resource);
            // `choicesFor` is contract 1 over BORROWED elements: free the
            // slice and nothing else. `appendFinding` deep-copies what it
            // keeps.
            defer gpa.free(choices);
            try summary.appendSlice(gpa, "; bind it to a backend operation, retain, or block. A route not in the document is answerable as custom:/<path>.");
            try appendFinding(gpa, list, code_backend_endpoint, .warn, path, node.line, loc, summary.items, choices);
        },
        .errors => {
            // A separate question from the form's: the form asks where the
            // submission goes, this asks how the request-time validation
            // state that comes back is presented. `RAILS_REQUEST_TIME_STATE`
            // rather than a new code because that is exactly what it is --
            // the same code an `@post.errors` read through `.ivar` gets.
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "validation errors of `{s}`", .{node.name orelse ""});
            defer gpa.free(message);
            // #167 Stage 3 widens this row with `island`: the converter can
            // now render `ZigbaseError.data` where the ERB rendered
            // `full_messages`, so "present the backend's validation errors
            // client-side" is finally a choice this stage can carry out.
            // The message is untouched -- the question did not change, only
            // the set of answers -- so a decision recorded against it in a
            // Stage 2 run still applies.
            try appendFinding(gpa, list, code_request_time_state, .warn, path, node.line, loc, message, &choices_island_retain_blocked);
        },
        .turbo_frame => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const url = try frameUrl(gpa, in, node);
            defer if (url) |u| gpa.free(u);
            const has_src = node.value != null or attrValue(node, "src") != null;
            const message = if (url) |u|
                if (frameIsApi(in, node, u))
                    try std.fmt.allocPrint(gpa, "turbo-frame `{s}` src={s} is API traffic", .{ name, u })
                else
                    try std.fmt.allocPrint(gpa, "turbo-frame `{s}` src={s}", .{ name, u })
            else if (!has_src and !node.missing)
                try std.fmt.allocPrint(gpa, "turbo-frame `{s}` (no src)", .{name})
            else
                try std.fmt.allocPrint(gpa, "turbo-frame `{s}` src is request-time state", .{name});
            defer gpa.free(message);
            const choices: []const []const u8 = if (url != null and !frameIsApi(in, node, url.?))
                &choices_island_retain_blocked
            else if (!has_src and !node.missing)
                &choices_inline_retain_blocked
            else
                &choices_retain_blocked;
            try appendFinding(gpa, list, code_turbo_frame, .warn, path, node.line, loc, message, choices);
        },
        .turbo_stream => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "turbo-stream `{s}`: a realtime subscription has no converter (see #{d})", .{ node.name orelse "", turbo_stream_issue });
            defer gpa.free(message);
            try appendFinding(gpa, list, code_turbo_stream, .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .component_root => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            if (node.dynamic) {
                const message = try std.fmt.allocPrint(gpa, "React root `{s}` with request-time props", .{name});
                defer gpa.free(message);
                try appendFinding(gpa, list, code_component_props_dynamic, .warn, path, node.line, loc, message, &choices_retain_blocked);
                return;
            }
            var message: std.ArrayListUnmanaged(u8) = .empty;
            defer message.deinit(gpa);
            try appendFmt(gpa, &message, "React root `{s}` props {{", .{name});
            var prop_names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer prop_names.deinit(gpa);
            for (node.attrs) |attr| try prop_names.append(gpa, attr.key);
            std.mem.sort([]const u8, prop_names.items, {}, stringLessThan);
            for (prop_names.items, 0..) |prop, i| {
                if (i != 0) try message.appendSlice(gpa, ", ");
                try message.appendSlice(gpa, prop);
            }
            try message.append(gpa, '}');
            const source = componentSource(in, name);
            const portable = if (source) |src| blk: {
                if (try componentProblem(gpa, in, src)) |problem| {
                    defer gpa.free(problem);
                    try appendFmt(gpa, &message, "; {s}", .{problem});
                    break :blk false;
                }
                try appendFmt(gpa, &message, "; source {s}", .{src.path});
                break :blk true;
            } else blk: {
                try message.appendSlice(gpa, "; source not found under app/javascript/components/");
                break :blk false;
            };
            try appendFinding(gpa, list, code_component_root, .warn, path, node.line, loc, message.items, if (portable) &choices_island_retain_blocked else &choices_retain_blocked);
        },
        else => {},
    }
}

/// Walks `in.templates` (node findings, then a parse-error finding per
/// broken template) and then `in.layouts` (`RAILS_LAYOUT_DYNAMIC`),
/// appending in that order; `std.mem.sort` with `lessThan` at the end is
/// what actually fixes the final order, so the walk order here only needs
/// to be complete, not sorted.
///
/// Contract 2 (owned-result): the returned slice and every finding's owned
/// fields are released by `free`. `OutOfMemory` propagates from any inner
/// `try` -- `list.deinit` on the way out is unnecessary because every
/// element already in `list` at that point was built by `appendFinding`,
/// which itself cleans up its own partial allocation via `errdefer` before
/// ever reaching `list.append`; the ArrayList's backing buffer is
/// `Allocator.Error`-safe to simply abandon (the GPA -- or the
/// `FailingAllocator` wrapping it in tests -- reclaims it, same as any
/// other still-live allocation an aborted function leaves behind).
pub fn derive(gpa: Allocator, in: DeriveInput) Allocator.Error![]Finding {
    var list: std.ArrayListUnmanaged(Finding) = .empty;
    errdefer {
        for (list.items) |f| freeOne(gpa, f);
        list.deinit(gpa);
    }

    // #167 Stage 3 assumption A5, computed before anything derives: which
    // routes and which views belong to the auth journey. Four rows read it,
    // and every one of them would ask a question the journey already answers
    // if it did not.
    const journey = try detectJourney(gpa, in);
    defer journey.deinit(gpa);

    // Ruling S12's form-nesting scope. `frames` records, for each block
    // currently open, whether it is a `form`; `form_depth` is how many of
    // those are. Tracked here rather than inside `deriveNode` because it is a
    // property of the WALK, not of a node.
    //
    // A `form` whose source text opens no Ruby block (a bare `form_tag "..."`
    // with no `do`) pushes no frame, so a following `form_field` is not
    // suppressed by it -- correct, since that field is not lexically inside
    // anything, and `convert.zig`'s own region nesting reads the stream the
    // same way (both go through `convert.opensBlock`).
    var frames: std.ArrayListUnmanaged(bool) = .empty;
    defer frames.deinit(gpa);

    for (in.templates) |tpl| {
        frames.clearRetainingCapacity();
        var form_depth: usize = 0;
        // #167 Stage 3: both are properties of the TEMPLATE, so they are
        // resolved once per file rather than once per node.
        const resource = templateResource(in, tpl.path);
        const journey_view = journey.isJourneyView(tpl.path);
        for (tpl.nodes, 0..) |node, node_index| {
            // Computed BEFORE this node's own frame is pushed, so an
            // outermost `form` sees `false` and asks its question, while
            // everything it contains sees `true`.
            try deriveNode(gpa, &list, in, tpl.path, node, tpl.nodes, node_index, form_depth > 0, resource, journey_view);
            if (node.text != null) continue;
            if (node.kind == .block_end) {
                // A stray `block_end` with no frame is dropped rather than
                // popping an empty stack -- the same defence `convert.zig`'s
                // `matchingEnd` takes against a malformed stream.
                if (frames.pop()) |was_form| {
                    if (was_form) form_depth -= 1;
                }
            } else if (convert.opensBlock(node)) {
                const is_form = node.kind == .form;
                try frames.append(gpa, is_form);
                if (is_form) form_depth += 1;
            }
        }
        for (in.stimulus_markers) |markers| {
            if (!std.mem.eql(u8, markers.path, tpl.path)) continue;
            for (markers.names) |marker_name| {
                var covered = false;
                for (tpl.nodes) |node| {
                    if (node.kind != .stimulus) continue;
                    var identifiers = std.mem.tokenizeAny(u8, node.name orelse "", " \t\r\n");
                    while (identifiers.next()) |identifier| {
                        if (std.mem.eql(u8, identifier, marker_name)) covered = true;
                    }
                }
                if (covered) continue;
                const loc = try std.fmt.allocPrint(gpa, "marker-{s}", .{marker_name});
                defer gpa.free(loc);
                const message = try std.fmt.allocPrint(gpa, "stimulus `{s}`; the opening element is split by ERB and has no portable extent", .{marker_name});
                defer gpa.free(message);
                try appendFinding(gpa, &list, code_stimulus_controller, .warn, tpl.path, null, loc, message, &choices_retain_blocked);
            }
            break;
        }
        if (tpl.error_message) |em| {
            const line = tpl.error_line orelse 0;
            const loc = try lineLoc(gpa, line);
            defer gpa.free(loc);
            const message = try std.fmt.allocPrint(gpa, "template does not parse: {s}", .{em});
            defer gpa.free(message);
            try appendFinding(gpa, &list, "RAILS_TEMPLATE_PARSE_ERROR", .@"error", tpl.path, tpl.error_line, loc, message, &choices_retain_blocked);
        }
        // R15: the templates op refused this file outright (see the module
        // doc). `line` is null and `loc` is a word rather than an `L<n>`
        // because nothing here HAS a line -- the file was never parsed, and a
        // stand-in `L1` would point someone at the first line of a file that
        // was never read. `unscanned` still keeps the id's three-part shape,
        // and one template yields at most one of these, so it is unique per
        // (code, path) the way every other `loc` is.
        if (tpl.unreadable) |why| {
            const message = try std.fmt.allocPrint(gpa, "template was not analysed: {s}", .{why});
            defer gpa.free(message);
            try appendFinding(gpa, &list, "RAILS_TEMPLATE_UNSCANNED", .warn, tpl.path, null, unscanned_loc, message, &choices_retain_blocked);
        }
    }

    if (in.js_entry) |entry| {
        var message: std.ArrayListUnmanaged(u8) = .empty;
        defer message.deinit(gpa);
        try appendFmt(gpa, &message, "JS entry {s} was not inspected; imports: ", .{entry});
        var specs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer specs.deinit(gpa);
        if (sourceByPath(in.js_sources, entry)) |source| {
            const imports = try port.reactImports(gpa, source.bytes);
            defer gpa.free(imports.list);
            for (imports.list) |imp| try specs.append(gpa, imp.spec);
        }
        std.mem.sort([]const u8, specs.items, {}, stringLessThan);
        if (specs.items.len == 0) {
            try message.appendSlice(gpa, "none");
        } else for (specs.items, 0..) |spec, i| {
            if (i != 0) try message.appendSlice(gpa, ", ");
            try message.appendSlice(gpa, spec);
        }
        try message.appendSlice(gpa, "; the islands replace it — drop after review, or block");
        try appendFinding(gpa, &list, code_js_entry, .warn, entry, null, "entry", message.items, &choices_drop_blocked);
    }

    for (in.layouts) |layout| {
        if (!layout.dynamic) continue;
        var path: []const u8 = layout.controller;
        for (in.controller_files) |cf| {
            if (std.mem.eql(u8, cf.controller, layout.controller)) {
                path = cf.path;
                break;
            }
        }
        const loc = try lineLoc(gpa, layout.line);
        defer gpa.free(loc);
        try appendFinding(gpa, &list, "RAILS_LAYOUT_DYNAMIC", .warn, path, layout.line, loc, "controller declares a dynamic layout", &choices_retain_blocked);
    }

    // #167 Stage 2 ruling S18: the operator's half of every
    // `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` blocker. `line` is null and `loc`
    // is a word for the reason `unsupported_engine_loc` documents.
    for (in.unsupported_templates) |t| {
        const message = try std.fmt.allocPrint(gpa, "{s} template is not converted: no converter reads this engine", .{t.label});
        defer gpa.free(message);
        try appendFinding(gpa, &list, code_template_engine_unsupported, .warn, t.path, null, unsupported_engine_loc, message, &choices_retain_blocked);
    }

    // #167 Stage 2: the three ROUTE-scoped rows. Appended last purely for
    // readability -- the sort below fixes the output order regardless.
    try deriveRouteFindings(gpa, &list, in, .dynamic_segment, journey);
    try deriveRouteFindings(gpa, &list, in, .redirect, journey);
    try deriveRouteFindings(gpa, &list, in, .no_template, journey);
    // #167 Stage 3 and #182: four more, same mechanism.
    try deriveRouteFindings(gpa, &list, in, .backend_endpoint, journey);
    try deriveRouteFindings(gpa, &list, in, .auth_guard, journey);
    try deriveRouteFindings(gpa, &list, in, .content_collision, journey);
    try deriveRouteFindings(gpa, &list, in, .route_path_unsupported, journey);
    try deriveAuthJourney(gpa, &list, in, journey);

    const out = try list.toOwnedSlice(gpa);
    std.mem.sort(Finding, out, {}, lessThan);
    return out;
}

test "findingId escapes the separator reversibly" {
    const gpa = std.testing.allocator;
    const id = try findingId(gpa, "RAILS_HELPER_UNKNOWN", "app/views/posts/index.html.erb", "L3C5");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L3C5", id);
    const pct = try escapePart(gpa, "a%b.c");
    defer gpa.free(pct);
    try std.testing.expectEqualStrings("a%25b%2Ec", pct);
}

test "derive: one finding per triggering node, with code/choices/loc from the table, sorted" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeText("<h1>", 1),
        nodeCode(.request_state, 2, 3, "current_user"),
        nodeCode(.unknown, 1, 9, "number_to_currency"),
        nodeCode(.route_helper, 4, 1, "root"),
        nodeCode(.route_helper, 5, 1, "ghost"),
        nodeCode(.link_to, 6, 1, "posts"),
        nodeCode(.raw, 7, 1, null),
    };
    var missing = nodeCode(.i18n, 8, 1, "posts.index.nope");
    missing.missing = true;
    const all = nodes ++ [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&all), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/posts/broken.html.erb", .nodes = &.{}, .error_message = "unexpected end", .error_line = 4, .unreadable = null },
    };
    const layouts = [_]controllers.LayoutInfo{
        .{ .controller = "posts", .value = null, .disabled = false, .dynamic = true, .line = 2 },
        .{ .controller = "pages", .value = "marketing", .disabled = false, .dynamic = false, .line = 2 },
    };
    const files = [_]ControllerFile{
        .{ .controller = "posts", .path = "app/controllers/posts_controller.rb" },
        .{ .controller = "pages", .path = "app/controllers/pages_controller.rb" },
    };
    const names = [_][]const u8{ "root", "posts" };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &layouts, .controller_files = &files, .route_names = &names, .locale = "en" });
    defer free(gpa, out);

    const expect_codes = [_][]const u8{
        "RAILS_HELPER_UNKNOWN",
        "RAILS_I18N_UNRESOLVED",
        "RAILS_LAYOUT_DYNAMIC",
        "RAILS_RAW_OUTPUT",
        code_request_time_state,
        "RAILS_ROUTE_HELPER_UNKNOWN",
        "RAILS_TEMPLATE_PARSE_ERROR",
    };
    try std.testing.expectEqual(expect_codes.len, out.len);
    for (expect_codes, out) |c, f| try std.testing.expectEqualStrings(c, f.code);

    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C9", out[0].id);
    try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", out[2].path);
    try std.testing.expectEqual(@as(?u64, 2), out[2].line);
    try std.testing.expectEqualStrings("ghost", out[5].message[std.mem.indexOf(u8, out[5].message, "ghost").?..][0..5]);
    try std.testing.expectEqual(blockers.Severity.@"error", out[6].severity);
    try std.testing.expectEqualStrings("retain", out[6].choices[0]);
    try std.testing.expect(out[0].route_id == null);
    try std.testing.expect(!out[0].requires_artifact);
}

test "derive: input order does not leak into output -- ids and order are identical either way" {
    const gpa = std.testing.allocator;
    const a_nodes = [_]fragments.Node{ nodeCode(.unknown, 3, 1, "foo"), nodeCode(.raw, 1, 1, null) };
    const b_nodes = [_]fragments.Node{ nodeCode(.raw, 1, 1, null), nodeCode(.unknown, 3, 1, "foo") };
    const tpl_a = [_]fragments.Template{
        .{ .path = "app/views/b.html.erb", .nodes = @constCast(&a_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/a.html.erb", .nodes = @constCast(&a_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const tpl_b = [_]fragments.Template{
        .{ .path = "app/views/a.html.erb", .nodes = @constCast(&b_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/b.html.erb", .nodes = @constCast(&b_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out_a = try derive(gpa, .{ .templates = &tpl_a, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out_a);
    const out_b = try derive(gpa, .{ .templates = &tpl_b, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out_b);
    try std.testing.expectEqual(@as(usize, 4), out_a.len);
    try std.testing.expectEqual(out_a.len, out_b.len);
    for (out_a, out_b) |x, y| try std.testing.expectEqualStrings(x.id, y.id);
    // (code, path, line, id): both HELPER_UNKNOWN rows sort before both RAW_OUTPUT rows, a.html before b.html within a code.
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/a%2Ehtml%2Eerb.L3C1", out_a[0].id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/b%2Ehtml%2Eerb.L3C1", out_a[1].id);
    try std.testing.expectEqualStrings("RAILS_RAW_OUTPUT.app/views/a%2Ehtml%2Eerb.L1C1", out_a[2].id);
}

// Self-review addition: covers the derivation-table rows the two briefed
// tests above never trigger -- `route_helper_dynamic`, `.control`, a
// template `error_message` with `error_line == null`, and a `link_to`
// with a name absent from `route_names` (the briefed test only exercises
// this branch via `.route_helper`).
test "derive: render_dynamic, route_helper_dynamic, control, link_to-unknown, and a null-line parse error" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeCode(.render_dynamic, 1, 1, "partial_name"),
        nodeCode(.route_helper_dynamic, 2, 1, "posts_path"),
        nodeCode(.control, 3, 1, "if"),
        nodeCode(.link_to, 4, 1, "ghost_path"),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/y.html.erb", .nodes = &.{}, .error_message = "premature end of input", .error_line = null, .unreadable = null },
    };
    const names = [_][]const u8{"root"};
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &names, .locale = null });
    defer free(gpa, out);

    const expect_codes = [_][]const u8{
        "RAILS_PARTIAL_DYNAMIC",
        "RAILS_ROUTE_HELPER_DYNAMIC",
        "RAILS_ROUTE_HELPER_UNKNOWN",
        "RAILS_TEMPLATE_CONTROL_FLOW",
        "RAILS_TEMPLATE_PARSE_ERROR",
    };
    try std.testing.expectEqual(expect_codes.len, out.len);
    for (expect_codes, out) |c, f| try std.testing.expectEqualStrings(c, f.code);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "partial_name") != null);

    // A null `error_line` still gets a finding, with `line = null` on the
    // `Finding` even though the id's loc folds it to "L0".
    const parse_err = out[4];
    try std.testing.expectEqual(@as(?u64, null), parse_err.line);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_PARSE_ERROR.app/views/y%2Ehtml%2Eerb.L0", parse_err.id);
    try std.testing.expect(std.mem.indexOf(u8, parse_err.message, "premature end of input") != null);
}

// Fix round 1 (Task 9 review, Critical): a real text run decodes with
// `kind = .unknown` (see `fragments.zig`'s `dupeNode`, `is_text` branch,
// and the `Node` doc's "must not be read" note) -- NOT a dedicated
// `.literal` tag the way the brief's own `nodeText` helper used to
// construct it. `deriveNode` dispatching on `node.kind` alone, with no
// `node.text` guard, therefore fired `RAILS_HELPER_UNKNOWN` for every
// plain-HTML text run in every template -- the majority of nodes in any
// real template. This pins the fix: a node shaped exactly like the real
// decode of `<h1>Posts</h1>` must yield zero findings.
test "derive: a real text run (kind .unknown, text set) yields no findings" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeText("<h1>Posts</h1>", 1),
        nodeText("", 2),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// Mirrors fragments.zig's dupeNode's ACTUAL decode of a wire text run
// (fragments.zig, is_text branch), not an idealised one: kind is
// .unknown there too -- there is no real Kind tag for literal text, so
// the decoder leaves it at the enum's fallback value and the Node doc
// says explicitly that kind "must not be read" when text != null.
// Fix round 1 (Task 9 review, Critical): this helper used to hand-pick
// .literal here, a Kind fragments.zig never actually produces for a
// text run, which is exactly why the RAILS_HELPER_UNKNOWN-on-every-text-
// node defect this helper should have caught went uncaught.
fn nodeText(text: []const u8, line: u64) fragments.Node {
    return .{ .text = text, .kind = .unknown, .line = line, .col = 0, .output = false, .code = "", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}
fn nodeCode(kind: fragments.Kind, line: u64, col: u64, name: ?[]const u8) fragments.Node {
    return .{ .text = null, .kind = kind, .line = line, .col = col, .output = true, .code = "", .name = name, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false };
}

// Every code the derivation table can produce, in one place, so a future
// row addition without a matching test here is at least visible in a
// diff of this list rather than silently uncovered.
test "lessThan orders ties by id when code/path/line all match" {
    var a = Finding{ .id = "A", .code = "C", .severity = .warn, .path = "p", .line = 1, .route_id = null, .message = "m", .choices = &choices_retain_blocked, .requires_artifact = false };
    var b = a;
    b.id = "B";
    try std.testing.expect(lessThan({}, a, b));
    try std.testing.expect(!lessThan({}, b, a));
    a.line = null;
    b.line = null;
    try std.testing.expect(lessThan({}, a, b));
}

// Ruling R16 (review finding 2): when a locale file failed to load, the
// translation table is empty (or partial) and EVERY `t()` key looks missing.
// The finding is still real -- the key does not resolve, and the operator
// still has to answer retain-or-blocked -- but its message must not read as
// "this key is absent from the translations" when the translations never
// loaded. Same code, same choices, honest reason.
test "derive: a failed locale file qualifies every RAILS_I18N_UNRESOLVED message" {
    const gpa = std.testing.allocator;
    var missing = nodeCode(.i18n, 1, 5, "posts.index.nope");
    missing.missing = true;
    const nodes = [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const broken = [_][]const u8{ "config/locales/en.yml", "config/locales/de.yml" };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = "en",
        .i18n_error_paths = &broken,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings(
        "missing translation `posts.index.nope` (locale en) — a locale file failed to load: config/locales/en.yml",
        out[0].message,
    );
    // The id is untouched: `message` is prose and deliberately not part of
    // it, so a decision recorded against this finding survives the locale
    // file being fixed.
    try std.testing.expectEqualStrings("RAILS_I18N_UNRESOLVED.app/views/posts/index%2Ehtml%2Eerb.L1C5", out[0].id);
}

// Ruling R15 (review finding 1): a view the templates op REFUSED --
// `unreadable` set, e.g. a symlink resolving outside the app root -- used to
// vanish. It contributes no nodes and no parse error, so `derive` produced
// nothing for it; the transitive scan had already read the same file
// successfully (it follows symlinks), so no `RAILS_TEMPLATE_UNREADABLE`
// blocker fired either. The manifest said nothing at all about a template
// nothing had analysed.
test "derive: a template the templates op refused becomes one RAILS_TEMPLATE_UNSCANNED finding" {
    const gpa = std.testing.allocator;
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/pages/linked.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = "outside root" },
        // A neighbour that scanned fine, so this pins that the row keys off
        // `unreadable` rather than off "this template produced no findings".
        .{ .path = "app/views/pages/ok.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNSCANNED", out[0].code);
    // `loc` is not a line: there is no line to point at, and a fabricated
    // `L1` would send someone to the top of a file that was never read.
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNSCANNED.app/views/pages/linked%2Ehtml%2Eerb.unscanned", out[0].id);
    try std.testing.expectEqual(Severity.warn, out[0].severity);
    try std.testing.expectEqual(@as(?u64, null), out[0].line);
    try std.testing.expectEqualStrings("app/views/pages/linked.html.erb", out[0].path);
    // The sidecar's own reason rides through verbatim -- it is the only
    // evidence there is about why nothing was analysed.
    try std.testing.expectEqualStrings("template was not analysed: outside root", out[0].message);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[1]);
    try std.testing.expect(out[0].route_id == null);
    try std.testing.expect(!out[0].requires_artifact);
}

test "derive: a template whose engine has no converter becomes an answerable finding (ruling S18)" {
    const gpa = std.testing.allocator;
    const unsupported = [_]UnsupportedTemplate{
        .{ .path = "app/views/posts/legacy.html.haml", .label = "Haml" },
        .{ .path = "app/views/posts/_row.html.slim", .label = "Slim" },
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .unsupported_templates = &unsupported,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // Sorted by id, so the `_row.html.slim` row comes first.
    try std.testing.expectEqualStrings(
        "RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/posts/_row%2Ehtml%2Eslim.engine",
        out[0].id,
    );
    try std.testing.expectEqualStrings("Slim template is not converted: no converter reads this engine", out[0].message);
    try std.testing.expectEqualStrings(
        "RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/posts/legacy%2Ehtml%2Ehaml.engine",
        out[1].id,
    );
    try std.testing.expectEqualStrings("app/views/posts/legacy.html.haml", out[1].path);
    try std.testing.expectEqualStrings("Haml template is not converted: no converter reads this engine", out[1].message);
    try std.testing.expectEqual(Severity.warn, out[1].severity);
    // No line: an ERB scan is never attempted on these files, so there is no
    // position to name.
    try std.testing.expectEqual(@as(?u64, null), out[1].line);
    // `retain`/`blocked` and nothing else: an engine no converter reads
    // cannot become an island or a SPA because someone chose so.
    try std.testing.expectEqual(@as(usize, 2), out[1].choices.len);
    try std.testing.expectEqualStrings("retain", out[1].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[1].choices[1]);
    try std.testing.expect(!out[1].requires_artifact);
}

test "derive: no unsupported templates, no engine findings" {
    const gpa = std.testing.allocator;
    // The companion to the row above: the input defaults empty, and an app
    // with no Haml/Slim must not acquire a question about one.
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/pages/ok.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// Ruling R17 (review finding 3): `lessThan`'s total order rests entirely on
// `id` being unique, and `id` is only as unique as `col`. `templates.rb` used
// to report `col: 0` for every statement in a tag after the first, so
// `<% number_to_currency(1); pluralize(2) %>` arrived here as two nodes at
// (1, 0) and (1, 0) and derived the SAME id -- two distinct elements
// `std.mem.sort` (not guaranteed stable) considers equal, i.e. a manifest
// whose finding order is a coin flip. This pins the property from the
// consumer side; the producer side is pinned in `templates_test.rb`.
test "derive: two nodes on one line with different columns get different ids" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeCode(.unknown, 1, 4, "number_to_currency"),
        nodeCode(.unknown, 1, 27, "pluralize"),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // The tie-break is lexicographic over the whole `id`, not numeric over
    // the column, so `L1C27` sorts before `L1C4`. Deterministic is all the
    // order has to be.
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/x%2Ehtml%2Eerb.L1C27", out[0].id);
    try std.testing.expectEqualStrings("RAILS_HELPER_UNKNOWN.app/views/x%2Ehtml%2Eerb.L1C4", out[1].id);
    // Exactly one of the two directions holds -- what a strict weak ordering
    // requires of two distinct elements, and what a duplicate id destroys.
    try std.testing.expect(lessThan({}, out[0], out[1]) != lessThan({}, out[1], out[0]));
}

test "derive under a FailingAllocator leaks nothing on any partial allocation" {
    const nodes = [_]fragments.Node{
        nodeCode(.unknown, 1, 1, "foo"),
        nodeCode(.raw, 2, 1, null),
    };
    var missing = nodeCode(.i18n, 3, 1, "greeting");
    missing.missing = true;
    const all = nodes ++ [_]fragments.Node{missing};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/x.html.erb", .nodes = @constCast(&all), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/broken.html.erb", .nodes = &.{}, .error_message = "bad", .error_line = 9, .unreadable = null },
        // R15's row allocates a formatted message like every other row, so
        // it belongs in the sweep too.
        .{ .path = "app/views/gone.html.erb", .nodes = &.{}, .error_message = null, .error_line = null, .unreadable = "outside root" },
    };
    const layouts = [_]controllers.LayoutInfo{
        .{ .controller = "posts", .value = null, .disabled = false, .dynamic = true, .line = 5 },
    };
    const files = [_]ControllerFile{
        .{ .controller = "posts", .path = "app/controllers/posts_controller.rb" },
    };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (derive(failing.allocator(), .{ .templates = &tpls, .layouts = &layouts, .controller_files = &files, .route_names = &.{}, .locale = "en" })) |out| {
            defer free(std.testing.allocator, out);
            try std.testing.expectEqual(@as(usize, 6), out.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

// `comptime`, so `&.{literal}` is a pointer to a comptime-promoted constant
// rather than to a stack temporary that dies with this call.
fn assetNode(comptime helper: []const u8, comptime literal: []const u8, line: u64, col: u64) fragments.Node {
    var n = nodeCode(.asset, line, col, helper);
    n.args = &.{literal};
    return n;
}

fn deriveAsset(source: []const u8, deterministic: bool) assets.Asset {
    return .{ .source = source, .public_url = null, .pipeline = null, .deterministic = deterministic };
}

// Stage 2 (#167, plan Task 3): `convert.zig` needs a finding id to point its
// `<!-- rails:finding -->` placeholder at whenever an asset helper cannot be
// turned into a `$site.asset(...).link()` expression. Both causes are one
// question for the operator -- retain this asset reference as-is, or block
// the route on it -- so both are one code.
test "derive: an asset helper with no deterministic target raises RAILS_ASSET_TRANSFORM" {
    const gpa = std.testing.allocator;
    const asset_list = [_]assets.Asset{
        deriveAsset("app/assets/images/logo.png", true),
        deriveAsset("app/assets/images/hero.png", false),
    };
    const nodes = [_]fragments.Node{
        assetNode("image_tag", "logo.png", 1, 1),
        assetNode("image_tag", "hero.png", 2, 1),
        assetNode("image_tag", "ghost.png", 3, 1),
        // Dropped by the converter, so it must NOT ask a question the
        // converted page has no placeholder for -- see `deriveNode`'s
        // `.asset` arm.
        assetNode("javascript_include_tag", "application", 4, 1),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_nav.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .assets = &asset_list,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_TRANSFORM.app/views/shared/_nav%2Ehtml%2Eerb.L2C1", out[0].id);
    try std.testing.expectEqualStrings("RAILS_ASSET_TRANSFORM.app/views/shared/_nav%2Ehtml%2Eerb.L3C1", out[1].id);
    try std.testing.expectEqual(Severity.warn, out[0].severity);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[1]);
    // The two causes read differently: one names the file that exists but
    // cannot be pinned, the other says nothing matched at all.
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "app/assets/images/hero.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[1].message, "ghost.png") != null);
}

// Ruling S23, the derivation half of `convert.zig`'s absolute-URL passthrough.
// A CDN reference is not an unresolved asset: nothing is missing, nothing has
// to be copied, and the converter emits the literal verbatim -- so a finding
// here would be a question about a page that has no placeholder to answer for.
// Both files read the same predicate (`resolve.isAbsoluteAssetLiteral`) so
// they cannot drift into asking about a region the other emitted cleanly.
test "derive: an absolute asset URL raises no RAILS_ASSET_TRANSFORM (ruling S23)" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        assetNode("image_tag", "https://cdn.example.com/x.png", 1, 1),
        assetNode("stylesheet_link_tag", "//cdn.example.com/s.css", 2, 1),
        assetNode("asset_path", "http://cdn.example.com/f.woff", 3, 1),
        // The control: a local literal that matches nothing still asks.
        assetNode("image_tag", "ghost.png", 4, 1),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_nav.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .assets = &.{},
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_TRANSFORM.app/views/shared/_nav%2Ehtml%2Eerb.L4C1", out[0].id);
}

// `stylesheet_link_tag "a", "b"` is ONE node and N sheets, and `convert.zig`
// makes the whole node a placeholder when ANY argument fails to resolve. This
// file therefore has to walk every argument too: reading only `args[0]` left
// a node whose first sheet resolved and whose second did not with no finding
// at all, which is exactly the id-less `rails:unmapped asset` region ruling
// S6 has to keep the route open on.
test "derive: a multi-argument asset helper asks about the first argument that does not resolve" {
    const gpa = std.testing.allocator;
    const asset_list = [_]assets.Asset{deriveAsset("app/assets/stylesheets/application.css", true)};
    var multi = nodeCode(.asset, 1, 1, "stylesheet_link_tag");
    multi.args = &.{ "application", "ghost" };
    var absolute_then_local = nodeCode(.asset, 2, 1, "stylesheet_link_tag");
    absolute_then_local.args = &.{ "//cdn.example.com/s.css", "application" };
    const nodes = [_]fragments.Node{ multi, absolute_then_local };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_nav.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .assets = &asset_list,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_TRANSFORM.app/views/shared/_nav%2Ehtml%2Eerb.L1C1", out[0].id);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "ghost") != null);
}

// `DeriveInput.assets` defaults to empty ONLY so the pre-Stage-2 call
// literals in this file's own tests keep compiling; it is not a mode. An
// omitted table means every asset literal resolves to nothing, which is what
// the code below asserts -- so the one production caller (`rails.zig`'s
// `discover`) must pass `asset_list`, and this test is what fails if someone
// deletes that argument.
test "derive: an omitted asset table resolves nothing, so every asset helper is a finding" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{assetNode("image_tag", "logo.png", 1, 1)};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_nav.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_ASSET_TRANSFORM", out[0].code);
}

// ---- #167 Stage 2: the two ROUTE-scoped rows -----------------------------

fn testRoute(verb: []const u8, path: []const u8, line: u64) routes.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = "posts",
        .action = "show",
        .name = null,
        .certain = true,
        .origin = .static_ast,
        .source = .{ .file = "config/routes.rb", .line = line },
    };
}

fn testVerdict(class: classify.Class) classify.Verdict {
    return .{ .class = class, .reason = "test", .candidates = &.{} };
}

test "derive: a dynamic GET route raises RAILS_ROUTE_DYNAMIC_SEGMENT, one per declaration" {
    const gpa = std.testing.allocator;
    // `resources :posts` puts BOTH dynamic routes on ONE routes.rb line --
    // the shared-declaration case the id scheme has to survive (see
    // `deriveRouteFindings`). `/posts` is static, the POST is not a GET, and
    // the last one is excluded by classification: two rows, folded into ONE
    // finding.
    const rs = [_]routes.Route{
        testRoute("GET", "/posts", 3),
        testRoute("GET", "/posts/:id", 3),
        testRoute("GET", "/posts/:id/edit", 3),
        testRoute("POST", "/posts/:id/publish", 3),
        testRoute("GET", "/admin/:id", 9),
    };
    const vs = [_]classify.Verdict{
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.backend),
        testVerdict(.backend),
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);

    // Three, not one, since #167 Stage 3: the POST on line 3 and the
    // `backend` GET on line 9 are API traffic, and each now carries its own
    // `RAILS_BACKEND_ENDPOINT` so an operator can bind an operation to it
    // (S11's reopening). They sort before the dynamic-segment row by code.
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L3.POST.posts", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L9.GET.posts", out[1].id);
    const dyn = out[2];
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT", dyn.code);
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L3", dyn.id);
    try std.testing.expectEqualStrings("config/routes.rb", dyn.path);
    try std.testing.expectEqual(@as(?u64, 3), dyn.line);
    try std.testing.expectEqual(Severity.warn, dyn.severity);
    try std.testing.expectEqualStrings("GET /posts/:id", dyn.route_id.?);
    try std.testing.expectEqual(@as(usize, 3), dyn.choices.len);
    try std.testing.expectEqualStrings("spa", dyn.choices[0]);
    try std.testing.expectEqualStrings("retain", dyn.choices[1]);
    try std.testing.expectEqualStrings("blocked", dyn.choices[2]);
    // Both routes of the shared declaration are named in the message, so the
    // one `route_id` naming only the first is not the only evidence left.
    try std.testing.expect(std.mem.indexOf(u8, dyn.message, "GET /posts/:id/edit") != null);
}

test "derive: a redirect route raises RAILS_REDIRECT_HOST_CONFIG, whatever its path shape" {
    const gpa = std.testing.allocator;
    const rs = [_]routes.Route{
        testRoute("GET", "/posts/old", 7),
        testRoute("GET", "/about", 8),
    };
    const vs = [_]classify.Verdict{ testVerdict(.redirect), testVerdict(.content) };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_REDIRECT_HOST_CONFIG.config/routes%2Erb.L7", out[0].id);
    try std.testing.expectEqualStrings("GET /posts/old", out[0].route_id.?);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
}

test "derive: routes with no classifications still derive; input order does not leak" {
    const gpa = std.testing.allocator;
    // Index-alignment is the caller's promise, not something `derive` can
    // check. A SHORT `classifications` slice must not silently drop rows (an
    // unclassified route is not a `backend` one), and the output order must
    // come from the sort, not from the input.
    const forward = [_]routes.Route{ testRoute("GET", "/a/:id", 2), testRoute("GET", "/b/*rest", 1) };
    const reverse = [_]routes.Route{ testRoute("GET", "/b/*rest", 1), testRoute("GET", "/a/:id", 2) };
    const a = try derive(gpa, .{ .templates = &.{}, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null, .routes = &forward });
    defer free(gpa, a);
    const b = try derive(gpa, .{ .templates = &.{}, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null, .routes = &reverse });
    defer free(gpa, b);
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqualStrings(x.id, y.id);
        try std.testing.expectEqualStrings(x.route_id.?, y.route_id.?);
    }
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L1", a[0].id);
}

// Ruling S22. `scaffold.zig` used to report this shape as a bare sentence
// ("no view template resolved for this route") with no id behind it, so no
// decisions file could name it and `complete` was unreachable for the whole
// app. Every exclusion below is one of scaffold's own earlier branches --
// see `routeHasNoView` for why a row nothing attaches to is worse than none.
test "derive: a GET route whose controller/action resolves no view raises RAILS_NO_TEMPLATE" {
    const gpa = std.testing.allocator;
    var other = testRoute("GET", "/other", 3);
    other.action = "other";
    var about = testRoute("GET", "/about", 4);
    about.action = "about";
    var posted = testRoute("POST", "/submit", 5);
    posted.action = "submit";
    var api = testRoute("GET", "/api/posts", 6);
    api.action = "index";
    const dynamic = testRoute("GET", "/posts/:id", 7);
    const rs = [_]routes.Route{ other, about, posted, api, dynamic };
    const vs = [_]classify.Verdict{
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.content),
        // A JSON endpoint needs no page, so "it has no view" is not a
        // question about it.
        testVerdict(.backend),
        testVerdict(.content),
    };
    const about_view = [_][]const u8{"app/views/posts/about.html.erb"};
    const show_view = [_][]const u8{"app/views/posts/show.html.erb"};
    const rts = [_][]const []const u8{
        // `def other; render :about; end` -- the action has no template of
        // its own, and the partial list it did resolve is not one.
        &[_][]const u8{"app/views/posts/_row.html.erb"},
        &about_view,
        &.{},
        &.{},
        &show_view,
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_templates = &rts,
    });
    defer free(gpa, out);

    // Two rows: this one, and the dynamic route's own
    // `RAILS_ROUTE_DYNAMIC_SEGMENT` -- which is the point of excluding a
    // dynamic path here. `scaffold.zig` answers it in `dynamicRoute` and
    // never reaches the view lookup, so a second row about its missing
    // template would be a question no route outcome names.
    // Four since #167 Stage 3: the POST on line 5 and the `backend` GET on
    // line 6 each carry a `RAILS_BACKEND_ENDPOINT`, which sorts first by
    // code. The two rows this test is about follow.
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L5.POST.posts", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L6.GET.posts", out[1].id);
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L7", out[3].id);
    const no_tpl = out[2];
    try std.testing.expectEqualStrings("RAILS_NO_TEMPLATE", no_tpl.code);
    try std.testing.expectEqualStrings("RAILS_NO_TEMPLATE.config/routes%2Erb.L3", no_tpl.id);
    try std.testing.expectEqualStrings("config/routes.rb", no_tpl.path);
    try std.testing.expectEqual(@as(?u64, 3), no_tpl.line);
    try std.testing.expectEqual(Severity.warn, no_tpl.severity);
    try std.testing.expectEqualStrings("GET /other", no_tpl.route_id.?);
    try std.testing.expectEqual(@as(usize, 2), no_tpl.choices.len);
    try std.testing.expectEqualStrings("retain", no_tpl.choices[0]);
    try std.testing.expectEqualStrings("blocked", no_tpl.choices[1]);
}

// `DeriveInput.route_templates` defaults empty so this file's pre-S22 call
// literals keep compiling, and an omitted value must LOSE the row rather than
// fabricate one for every route. This is what fails if the production caller
// (`rails.zig`'s `discover`) stops passing it -- and what would fail loudly,
// with a finding per route, had the default been read as "no templates".
test "derive: an omitted route_templates slice derives no RAILS_NO_TEMPLATE at all" {
    const gpa = std.testing.allocator;
    const rs = [_]routes.Route{testRoute("GET", "/about", 4)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "isDynamicRoutePath agrees with resolve.contentPath on what has no static page" {
    const gpa = std.testing.allocator;
    // The two predicates must not drift: a route this file calls dynamic is
    // exactly a route `scaffold.zig` cannot give a `content/<path>/index.smd`
    // to. (`contentPath` also refuses uninterpretable syntax, a SUPERSET --
    // hence a one-way implication rather than an equality.)
    const dynamic = [_][]const u8{ "/posts/:id", "/files/*path", "/a/:id/edit" };
    for (dynamic) |p| {
        try std.testing.expect(isDynamicRoutePath(p));
        const cp = try resolve.contentPath(gpa, p);
        if (cp) |c| {
            gpa.free(c);
            return error.TestUnexpectedResult;
        }
    }
    const static = [_][]const u8{ "/", "/about", "/admin/users", "/posts/legacy" };
    for (static) |p| {
        try std.testing.expect(!isDynamicRoutePath(p));
        const cp = (try resolve.contentPath(gpa, p)).?;
        gpa.free(cp);
    }
    // A bare `:` or `*` is a literal segment, not a placeholder.
    try std.testing.expect(!isDynamicRoutePath("/a/:/b"));
}

// ---- ruling S12: the six kinds that used to convert to nothing answerable --

fn endNodeAt(line: u64, col: u64) fragments.Node {
    var n = nodeCode(.block_end, line, col, null);
    n.output = false;
    n.code = "end";
    return n;
}

fn openFormNode(line: u64, col: u64, name: []const u8) fragments.Node {
    var n = nodeCode(.form, line, col, name);
    n.output = false;
    n.code = "form_with(model: @post) do |f|";
    return n;
}

test "derive: a form is one answerable RAILS_BACKEND_ENDPOINT, not one per field" {
    const gpa = std.testing.allocator;
    // Ruling S12. Before this row a `form` region converted to
    // `<!-- rails:unmapped form -->`, which carries no id -- so `scaffold.zig`
    // could see the route was unfinished (S6) but the operator had no finding
    // to answer, and the route could never reach `complete`. Only the
    // OUTERMOST form asks the question: a nested form and every field inside
    // one are the same decision.
    var field = nodeCode(.form_field, 2, 3, "text_field");
    field.attrs = &[_]fragments.Attr{.{ .key = "name", .value = "title" }};
    const nodes = [_]fragments.Node{
        openFormNode(1, 1, "post"),
        field,
        nodeCode(.errors, 3, 3, "post"),
        endNodeAt(4, 1),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/new.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);

    // The form (one, not two) plus the `errors` region, which is a separate
    // question: how request-time validation state is presented.
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT", out[0].code);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L1C1", out[0].id);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "form submits to a Rails action") != null);
    // The model's param key, which is what a form node's `name` carries.
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "model `post`") != null);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[1]);

    try std.testing.expectEqualStrings("RAILS_REQUEST_TIME_STATE", out[1].code);
    try std.testing.expect(std.mem.indexOf(u8, out[1].message, "validation errors of `post`") != null);
    // #167 Stage 3 widened this one with `island`: the bound form island now
    // renders `ZigbaseError.data` where the ERB rendered `full_messages`, so
    // "present it client-side" is a choice this stage can carry out. The
    // message and the id are untouched, so a Stage 2 decision still applies.
    try std.testing.expectEqual(@as(usize, 3), out[1].choices.len);
    try std.testing.expectEqualStrings("island", out[1].choices[0]);
    try std.testing.expectEqualStrings("retain", out[1].choices[1]);
    try std.testing.expectEqualStrings("blocked", out[1].choices[2]);
}

test "derive: a form_field outside any form asks its own question" {
    const gpa = std.testing.allocator;
    // The suppression above is scoped to an enclosing form, not to the kind:
    // a stray `text_field` still submits somewhere, and nothing else would
    // report it.
    var field = nodeCode(.form_field, 1, 1, "text_field");
    field.attrs = &[_]fragments.Attr{.{ .key = "name", .value = "q" }};
    const nodes = [_]fragments.Node{field};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/pages/search.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT", out[0].code);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "field `text_field` name=q") != null);
}

// ---- #167 Stage 3: the backend boundary ----------------------------------

fn backendOp(
    id: []const u8,
    verb: []const u8,
    path: []const u8,
    collection: ?[]const u8,
    kind: backend.Kind,
) backend.Operation {
    return .{
        .operation_id = id,
        .verb = verb,
        .path = path,
        .collection = collection,
        .kind = kind,
        .access = .unknown,
    };
}

/// File scope, not a local inside `testBackendDoc`: a `Document`'s slices
/// have to outlive the call that builds it, and `&local_array` is a pointer
/// to a stack temporary (the same trap `assetNode`'s comptime note records).
var test_backend_ops = [_]backend.Operation{
    backendOp("createPosts", "POST", "/api/collections/posts/records", "posts", .create),
    backendOp("createUsers", "POST", "/api/collections/users/records", "users", .create),
    backendOp("deleteUsers", "DELETE", "/api/collections/users/records/{id}", "users", .delete),
    backendOp("listPosts", "GET", "/api/collections/posts/records", "posts", .list),
};
var test_backend_auth = [_][]const u8{"users"};

/// A hand-built stand-in for what `backend.parse` returns, shaped like the
/// document Task 7's fixture carries: two collections, one of them an auth
/// collection. Static storage, so `backend.free` must never see it.
fn testBackendDoc() backend.Document {
    return .{
        .file = "openapi.json",
        .contract_version = "1.0.0",
        .consumer_routes = false,
        .operations = &test_backend_ops,
        .auth_collections = &test_backend_auth,
    };
}

fn ctrlRoute(verb: []const u8, path: []const u8, controller: []const u8, action: []const u8, line: u64) routes.Route {
    var r = testRoute(verb, path, line);
    r.controller = controller;
    r.action = action;
    return r;
}

test "derive: a form's choices are the backend document's own operations for its verb and resource" {
    const gpa = std.testing.allocator;
    // Ruling S12 widened by Stage 3: the row is the same row, the id is the
    // same id, and the answers are now the operations `--backend` named for
    // this form's method against this template's resource.
    var form = openFormNode(1, 1, "user");
    form.attrs = &[_]fragments.Attr{.{ .key = "method", .value = "post" }};
    const nodes = [_]fragments.Node{ form, endNodeAt(2, 1) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/users/new.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{ctrlRoute("GET", "/users/new", "users", "new", 3)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const views = [_]?[]const u8{"app/views/users/new.html.erb"};
    const doc = testBackendDoc();

    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
        .backend = doc,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.app/views/users/new%2Ehtml%2Eerb.L1C1", out[0].id);
    try std.testing.expectEqualStrings(
        "form submits to a Rails action: model `user` method=post; bind it to a backend operation, retain, or block. A route not in the document is answerable as custom:/<path>.",
        out[0].message,
    );
    // `users` is the route's controller, so its own POST operation ranks
    // first; the other POST follows; the two words that are always available
    // come last. A GET operation is never offered for a POST.
    try std.testing.expectEqual(@as(usize, 4), out[0].choices.len);
    try std.testing.expectEqualStrings("createUsers", out[0].choices[0]);
    try std.testing.expectEqualStrings("createPosts", out[0].choices[1]);
    try std.testing.expectEqualStrings("retain", out[0].choices[2]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[3]);
}

test "derive: a form's choices survive the document being freed" {
    const gpa = std.testing.allocator;
    // `backend.choicesFor` returns BORROWED elements (its contract 1), so a
    // `Finding` that kept them would read freed memory the moment
    // `migrate.zig` released the document. `Finding.choices` is a deep copy
    // precisely so the two lifetimes are independent; this is what fails if
    // someone "optimises" the dupe away.
    const bytes =
        \\{"openapi":"3.1.2","info":{"version":"1.0.0"},"paths":{
        \\ "/api/collections/posts/records":{"post":{"operationId":"createPosts"}}}}
    ;
    const doc = try backend.parse(gpa, bytes, "openapi.json");
    const form = openFormNode(1, 1, "post");
    const nodes = [_]fragments.Node{ form, endNodeAt(2, 1) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/new.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .backend = doc,
    });
    defer free(gpa, out);
    backend.free(gpa, doc);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("createPosts", out[0].choices[0]);
    try std.testing.expectEqualStrings("retain", out[0].choices[1]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[2]);
}

test "derive: a form in a journey view asks no backend question -- the journey does" {
    const gpa = std.testing.allocator;
    // Assumption A5. The sign-in view's form and the sign-up view's form are
    // one decision (which ZigBase auth collection), so neither raises its own
    // `RAILS_BACKEND_ENDPOINT`; the ordinary form two templates over still
    // does, which is what proves the suppression is scoped to the journey
    // and not to forms in general.
    var pw = nodeCode(.form_field, 1, 20, "password_field");
    const journey_nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    const plain_nodes = [_]fragments.Node{ openFormNode(1, 1, "post"), endNodeAt(1, 40) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/sessions/new.html.erb", .nodes = @constCast(&journey_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/posts/new.html.erb", .nodes = @constCast(&plain_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/session/new", "sessions", "new", 2),
        ctrlRoute("GET", "/posts/new", "posts", "new", 3),
    };
    const vs = [_]classify.Verdict{ testVerdict(.content), testVerdict(.content) };
    const views = [_]?[]const u8{ "app/views/sessions/new.html.erb", "app/views/posts/new.html.erb" };

    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
    });
    defer free(gpa, out);

    // The journey finding, and the ordinary form's -- not the journey form's.
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L2", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.app/views/posts/new%2Ehtml%2Eerb.L1C1", out[1].id);
    _ = &pw;
}

test "derive: a password form makes its route a journey route even under an ordinary controller" {
    const gpa = std.testing.allocator;
    // The second half of A5: the controller names are the common case, the
    // password field is the fact. A `users#new` view holding one is a sign-up
    // page whatever the controller is called.
    const pw = nodeCode(.form_field, 1, 20, "password_field");
    const nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/users/new.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{ctrlRoute("GET", "/users/new", "users", "new", 4)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const views = [_]?[]const u8{"app/views/users/new.html.erb"};
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L4", out[0].id);
}

test "derive: a bare password_field outside any form is not a journey" {
    const gpa = std.testing.allocator;
    // A5 says "a `form` containing a `form_field` named `password_field`".
    // A stray field is a field on something else, and promoting it would
    // suppress a real backend question on the same view.
    const pw = nodeCode(.form_field, 1, 1, "password_field");
    const nodes = [_]fragments.Node{pw};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/pages/search.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{ctrlRoute("GET", "/search", "pages", "search", 4)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const views = [_]?[]const u8{"app/views/pages/search.html.erb"};
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.app/views/pages/search%2Ehtml%2Eerb.L1C1", out[0].id);
}

/// `comptime text`, so `&.{text}` points at a comptime-promoted constant
/// rather than at a stack temporary that dies with this call -- the trap
/// `assetNode` above already documents.
fn linkNode(code: []const u8, stem: ?[]const u8, comptime text: []const u8, line: u64, col: u64) fragments.Node {
    var n = nodeCode(.link_to, line, col, stem);
    n.code = code;
    n.args = &.{text};
    return n;
}

test "derive: button_to and a link_to with a mutating method raise RAILS_BACKEND_ENDPOINT" {
    const gpa = std.testing.allocator;
    var sign_out = linkNode("button_to \"Sign out\", session_path, method: :delete", "session", "Sign out", 1, 5);
    sign_out.attrs = &[_]fragments.Attr{.{ .key = "method", .value = "delete" }};
    var turbo = linkNode("link_to \"Destroy\", post_path(1), \"data-turbo-method\" => \"delete\"", "post", "Destroy", 2, 5);
    turbo.attrs = &[_]fragments.Attr{.{ .key = "data-turbo-method", .value = "delete" }};
    const plain_button = linkNode("button_to \"Publish\", publish_path", "publish", "Publish", 3, 5);
    // The two that must stay silent: an ordinary navigation link, and one
    // whose `method` is an explicit GET.
    const nav = linkNode("link_to \"Home\", root_path", "root", "Home", 4, 5);
    var get_link = linkNode("link_to \"Search\", search_path, method: :get", "search", "Search", 5, 5);
    get_link.attrs = &[_]fragments.Attr{.{ .key = "method", .value = "get" }};
    // rails-ujs' spelling, flattened by the sidecar from `data: { method: }`.
    var ujs = linkNode("link_to \"Sign out\", session_path, data: { method: :delete }", "session", "Sign out", 6, 5);
    ujs.attrs = &[_]fragments.Attr{.{ .key = "data-method", .value = "delete" }};
    const nodes = [_]fragments.Node{ sign_out, turbo, plain_button, nav, get_link, ujs };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_nav.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    // Every stem is a known route name, so a silent node really is silent
    // rather than raising `RAILS_ROUTE_HELPER_UNKNOWN` instead.
    const names = [_][]const u8{ "session", "post", "publish", "root", "search" };
    const doc = testBackendDoc();

    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &names,
        .locale = null,
        .backend = doc,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.app/views/shared/_nav%2Ehtml%2Eerb.L1C5", out[0].id);
    try std.testing.expectEqualStrings("link performs a mutation: link_to `Sign out` data-method=delete", out[3].message);
    try std.testing.expectEqualStrings("deleteUsers", out[3].choices[0]);
    try std.testing.expectEqualStrings("link performs a mutation: button_to `Sign out` method=delete", out[0].message);
    // DELETE, from the attribute: no operation on `session`, so the flat
    // same-verb group is what is offered.
    try std.testing.expectEqual(@as(usize, 3), out[0].choices.len);
    try std.testing.expectEqualStrings("deleteUsers", out[0].choices[0]);
    try std.testing.expectEqualStrings("retain", out[0].choices[1]);

    try std.testing.expectEqualStrings("link performs a mutation: link_to `Destroy` data-turbo-method=delete", out[1].message);
    // `button_to` with no method at all is a POST -- that is what the helper
    // renders -- so its choices are the POST operations.
    try std.testing.expectEqualStrings("link performs a mutation: button_to `Publish`", out[2].message);
    try std.testing.expectEqualStrings("createPosts", out[2].choices[0]);
    try std.testing.expectEqualStrings("createUsers", out[2].choices[1]);
}

/// Two DELETE operations whose ids sort the OPPOSITE way round from the
/// collection the link targets, so "the resource's own operations first" and
/// "operation ids in order" cannot both be satisfied and the test really does
/// discriminate between them. Static storage: `backend.free` must never see
/// it.
var link_rank_ops = [_]backend.Operation{
    backendOp("deleteComments", "DELETE", "/api/collections/comments/records/{id}", "comments", .delete),
    backendOp("removePosts", "DELETE", "/api/collections/posts/records/{id}", "posts", .delete),
};

test "derive: a mutating link's choices are ranked by the route it targets, not by the helper stem" {
    const gpa = std.testing.allocator;
    // Rails' member helper is SINGULAR (`post_path(1)` for
    // `DELETE /posts/:id`) and a ZigBase collection is plural, so keying
    // `choicesFor` on the helper stem meant "own collection first" could
    // never fire for a member link -- which is most of the mutating links
    // there are. The operator was offered every DELETE in the document in
    // operation-id order and had to find theirs in the alphabet.
    //
    // The target route's controller is the key now: the same key the
    // route-level row is grouped by, and the same route `scaffold.linkRoute`
    // pairs the binding onto.
    var destroy = linkNode(
        "link_to \"Destroy\", post_path(1), \"data-turbo-method\" => \"delete\"",
        "post",
        "Destroy",
        1,
        5,
    );
    destroy.attrs = &[_]fragments.Attr{.{ .key = "data-turbo-method", .value = "delete" }};
    const nodes = [_]fragments.Node{destroy};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    var member = ctrlRoute("DELETE", "/posts/:id", "posts", "destroy", 2);
    member.name = "post";
    const rs = [_]routes.Route{member};
    const vs = [_]classify.Verdict{testVerdict(.backend)};
    const views = [_]?[]const u8{null};
    const names = [_][]const u8{"post"};
    const doc: backend.Document = .{
        .file = "openapi.json",
        .contract_version = "1.0.0",
        .consumer_routes = false,
        .operations = &link_rank_ops,
        .auth_collections = &.{},
    };

    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &names,
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
        .backend = doc,
    });
    defer free(gpa, out);

    var link: ?Finding = null;
    for (out) |f| {
        if (std.mem.eql(u8, f.code, code_backend_endpoint) and
            std.mem.eql(u8, f.path, "app/views/posts/index.html.erb")) link = f;
    }
    const f = link orelse return error.NoLinkFinding;
    // `posts` is the target route's controller, so its own DELETE comes
    // first even though `deleteComments` sorts ahead of it.
    try std.testing.expectEqualStrings("removePosts", f.choices[0]);
    try std.testing.expectEqualStrings("deleteComments", f.choices[1]);
}

test "derive: a mutating link whose target route this run never resolved ranks nothing first" {
    const gpa = std.testing.allocator;
    // The other half. With no target route there is no resource, and the flat
    // same-verb group in operation-id order is the honest offer -- inventing
    // a resource from the stem is exactly what the change above removes.
    var destroy = linkNode(
        "link_to \"Destroy\", post_path(1), \"data-turbo-method\" => \"delete\"",
        "post",
        "Destroy",
        1,
        5,
    );
    destroy.attrs = &[_]fragments.Attr{.{ .key = "data-turbo-method", .value = "delete" }};
    const nodes = [_]fragments.Node{destroy};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    // `post` is a known helper name (so the node is a link and not a
    // `RAILS_ROUTE_HELPER_UNKNOWN`), but no route table reached this call.
    const names = [_][]const u8{"post"};
    const doc: backend.Document = .{
        .file = "openapi.json",
        .contract_version = "1.0.0",
        .consumer_routes = false,
        .operations = &link_rank_ops,
        .auth_collections = &.{},
    };

    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &names,
        .locale = null,
        .backend = doc,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("deleteComments", out[0].choices[0]);
    try std.testing.expectEqualStrings("removePosts", out[0].choices[1]);
}

test "derive: every API route raises RAILS_BACKEND_ENDPOINT, one per routes.rb line" {
    const gpa = std.testing.allocator;
    // `backend` by classification OR by verb, the same pair
    // `scaffold.routeOutcome` folds into its `backend` status -- so no route
    // reaches the handoff as `backend` without an id to bind an operation to.
    const rs = [_]routes.Route{
        ctrlRoute("POST", "/posts", "posts", "create", 4),
        ctrlRoute("GET", "/api/posts", "posts", "index", 6),
        // A page route: not API traffic, and must not acquire the row.
        ctrlRoute("GET", "/about", "pages", "about", 7),
    };
    const vs = [_]classify.Verdict{ testVerdict(.content), testVerdict(.backend), testVerdict(.content) };
    const doc = testBackendDoc();
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .backend = doc,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L4.POST.posts", out[0].id);
    try std.testing.expectEqualStrings("config/routes.rb", out[0].path);
    try std.testing.expectEqualStrings("GET /api/posts", out[1].route_id.?);
    try std.testing.expectEqualStrings("route is API traffic and needs a backend operation: POST /posts", out[0].message);
    try std.testing.expectEqualStrings("createPosts", out[0].choices[0]);
    // The GET row is offered GET operations, never the POST ones.
    try std.testing.expectEqualStrings("route is API traffic and needs a backend operation: GET /api/posts", out[1].message);
    try std.testing.expectEqual(@as(usize, 3), out[1].choices.len);
    try std.testing.expectEqualStrings("listPosts", out[1].choices[0]);
}

fn journeyRoutes() [5]routes.Route {
    return .{
        ctrlRoute("GET", "/registration/new", "registrations", "new", 2),
        ctrlRoute("GET", "/session/new", "sessions", "new", 3),
        ctrlRoute("POST", "/registration", "registrations", "create", 4),
        ctrlRoute("POST", "/session", "sessions", "create", 5),
        ctrlRoute("DELETE", "/session", "sessions", "destroy", 6),
    };
}

test "derive: the whole auth journey is ONE finding, keyed on its smallest routes.rb line" {
    const gpa = std.testing.allocator;
    const rs = journeyRoutes();
    const vs = [_]classify.Verdict{
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.backend),
        testVerdict(.backend),
        testVerdict(.backend),
    };
    const doc = testBackendDoc();
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .backend = doc,
    });
    defer free(gpa, out);

    // ONE finding for five routes, and -- assumption A5 -- no
    // `RAILS_BACKEND_ENDPOINT` for the three journey routes that are API
    // traffic: the journey is their question.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY", out[0].code);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L2", out[0].id);
    try std.testing.expectEqualStrings("config/routes.rb", out[0].path);
    try std.testing.expectEqual(@as(?u64, 2), out[0].line);
    try std.testing.expectEqualStrings("GET /registration/new", out[0].route_id.?);
    try std.testing.expect(out[0].requires_artifact);
    try std.testing.expectEqual(@as(usize, 3), out[0].choices.len);
    try std.testing.expectEqualStrings("island", out[0].choices[0]);
    try std.testing.expectEqualStrings("retain", out[0].choices[1]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[2]);
    try std.testing.expectEqualStrings(
        "auth journey: GET /registration/new, GET /session/new, POST /registration, POST /session, DELETE /session; island needs artifact = the ZigBase auth collection name (in --backend: users)",
        out[0].message,
    );
}

test "derive: without an auth collection to name, the journey message says to pass --backend" {
    const gpa = std.testing.allocator;
    const rs = journeyRoutes();
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
    });
    defer free(gpa, out);
    // Five routes, no classifications: three are non-GET, so they are API
    // traffic by verb -- and still suppressed by the journey.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.endsWith(
        u8,
        out[0].message,
        "island needs artifact = the ZigBase auth collection name (pass --backend to validate the name)",
    ));
}

test "derive: the journey's key line and route list do not depend on the route table's order" {
    const gpa = std.testing.allocator;
    // The id is keyed on the SMALLEST line the journey occupies and the
    // message lists the routes in (line, route id) order -- neither is the
    // order the sidecar happened to emit the route table in, which nothing
    // promises is stable across machines.
    const forward = journeyRoutes();
    var reversed: [5]routes.Route = undefined;
    for (forward, 0..) |r, i| reversed[forward.len - 1 - i] = r;
    const base: DeriveInput = .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
    };
    var a_in = base;
    a_in.routes = &forward;
    var b_in = base;
    b_in.routes = &reversed;
    const a = try derive(gpa, a_in);
    defer free(gpa, a);
    const b = try derive(gpa, b_in);
    defer free(gpa, b);
    try std.testing.expectEqual(@as(usize, 1), a.len);
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqualStrings(a[0].id, b[0].id);
    try std.testing.expectEqualStrings(a[0].message, b[0].message);
    try std.testing.expectEqualStrings(a[0].route_id.?, b[0].route_id.?);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L2", b[0].id);
    try std.testing.expect(std.mem.startsWith(
        u8,
        b[0].message,
        "auth journey: GET /registration/new, GET /session/new, POST /registration, POST /session, DELETE /session;",
    ));
}

test "derive: a document with no auth collection reads like no document at all" {
    const gpa = std.testing.allocator;
    // Not a hypothetical: the in-repo `contract/zigbase.openapi.json` is
    // exactly this document -- three consumer routes and no collections. The
    // parenthetical exists to NAME the candidates, so with none to name it
    // must not degrade to `(in --backend: )`, a list pretending to be one.
    const rs = journeyRoutes();
    var empty_ops = [_]backend.Operation{
        backendOp("submitContact", "POST", "/api/contact", null, .custom),
    };
    var no_auth = [_][]const u8{};
    const doc: backend.Document = .{
        .file = "zigbase.openapi.json",
        .contract_version = "2026-06-27.1",
        .consumer_routes = true,
        .operations = &empty_ops,
        .auth_collections = &no_auth,
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .backend = doc,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.endsWith(
        u8,
        out[0].message,
        "island needs artifact = the ZigBase auth collection name (pass --backend to validate the name)",
    ));
}

test "derive: an app with no journey raises no RAILS_AUTH_JOURNEY" {
    const gpa = std.testing.allocator;
    const rs = [_]routes.Route{ctrlRoute("GET", "/about", "pages", "about", 2)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "derive: a guarded page route raises RAILS_ROUTE_AUTH_GUARD (assumption A7)" {
    const gpa = std.testing.allocator;
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/posts", "posts", "index", 3),
        // Same controller, an action the filter's `only:` excludes.
        ctrlRoute("GET", "/posts/archive", "posts", "archive", 4),
        // Guarded by a filter whose name is not an auth heuristic hit.
        ctrlRoute("GET", "/about", "pages", "about", 5),
        // Guarded, but API traffic: it never becomes a page, so "a static
        // page cannot enforce it" is not a question about it.
        ctrlRoute("POST", "/posts", "posts", "create", 6),
    };
    const vs = [_]classify.Verdict{
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.backend),
    };
    const filters = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "require_login", .only = &.{ "index", "create" }, .except = &.{}, .dynamic = false, .line = 2 },
        .{ .controller = "pages", .name = "set_locale", .only = &.{}, .except = &.{}, .dynamic = false, .line = 2 },
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .filters = .{ .before_actions = &filters },
    });
    defer free(gpa, out);

    // The guard row on `GET /posts`, and the POST's own backend row.
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L6.POST.posts", out[0].id);
    const guard = out[1];
    try std.testing.expectEqualStrings("RAILS_ROUTE_AUTH_GUARD", guard.code);
    try std.testing.expectEqualStrings("RAILS_ROUTE_AUTH_GUARD.config/routes%2Erb.L3", guard.id);
    try std.testing.expectEqualStrings("config/routes.rb", guard.path);
    try std.testing.expectEqualStrings("GET /posts", guard.route_id.?);
    try std.testing.expectEqual(Severity.warn, guard.severity);
    try std.testing.expect(!guard.requires_artifact);
    try std.testing.expectEqualStrings(
        "page is guarded by before_action :require_login on posts; a static page cannot enforce it: GET /posts",
        guard.message,
    );
    try std.testing.expectEqual(@as(usize, 3), guard.choices.len);
    try std.testing.expectEqualStrings("public", guard.choices[0]);
    try std.testing.expectEqualStrings("retain", guard.choices[1]);
    try std.testing.expectEqualStrings("blocked", guard.choices[2]);
}

test "derive: which authentication filter a guarded route names does not depend on input order" {
    const gpa = std.testing.allocator;
    // `before_actions` is flattened across a directory walk of
    // app/controllers/, so its order is not promised. The filter's name is in
    // the message, which makes an order-dependent pick an order-dependent
    // manifest.
    const rs = [_]routes.Route{ctrlRoute("GET", "/posts", "posts", "index", 3)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const forward = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .only = &.{}, .except = &.{}, .dynamic = false, .line = 2 },
        .{ .controller = "posts", .name = "require_login", .only = &.{}, .except = &.{}, .dynamic = false, .line = 3 },
    };
    const reverse = [_]controllers.BeforeAction{ forward[1], forward[0] };
    const base: DeriveInput = .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    };
    var a_in = base;
    a_in.filters = .{ .before_actions = &forward };
    var b_in = base;
    b_in.filters = .{ .before_actions = &reverse };
    const a = try derive(gpa, a_in);
    defer free(gpa, a);
    const b = try derive(gpa, b_in);
    defer free(gpa, b);
    try std.testing.expectEqualStrings(a[0].message, b[0].message);
    try std.testing.expect(std.mem.indexOf(u8, a[0].message, "authenticate_user!") != null);
}

test "derive: a dynamic before_action guards nothing -- there is no symbol to read" {
    const gpa = std.testing.allocator;
    const rs = [_]routes.Route{ctrlRoute("GET", "/posts", "posts", "index", 3)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const filters = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = null, .only = &.{}, .except = &.{}, .dynamic = true, .line = 2 },
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .filters = .{ .before_actions = &filters },
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "derive: a guard declared on ApplicationController reaches the controllers that inherit it" {
    const gpa = std.testing.allocator;
    // Fix round 1 (I-1). This is what almost every Rails app looks like:
    //
    //   class ApplicationController < ActionController::Base
    //     before_action :authenticate_user!
    //   end
    //   class PostsController < ApplicationController; end
    //
    // Matching a filter's own `controller` against the route's saw none of
    // it, so A7's row fired only for an app that redeclares the filter in
    // every controller -- i.e. essentially never. `controllers.guardsFor`
    // walks the chain, and the message names the DECLARING controller,
    // which is where an operator has to go to read the filter.
    const rs = [_]routes.Route{ctrlRoute("GET", "/posts", "posts", "index", 3)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const filters = [_]controllers.BeforeAction{
        .{ .controller = "application", .name = "authenticate_user!", .only = &.{}, .except = &.{}, .dynamic = false, .line = 2 },
    };
    const parents = [_]controllers.ParentEdge{
        .{ .controller = "posts", .parent = "application" },
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .filters = .{ .before_actions = &filters, .parents = &parents },
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_AUTH_GUARD.config/routes%2Erb.L3", out[0].id);
    try std.testing.expectEqualStrings(
        "page is guarded by before_action :authenticate_user! on application; a static page cannot enforce it: GET /posts",
        out[0].message,
    );

    // The negative control, and the reason this is a chain walk rather than
    // a wildcard: with no edge, `application`'s filter is invisible from
    // `posts` -- which is also what Rails does.
    const unlinked = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .filters = .{ .before_actions = &filters },
    });
    defer free(gpa, unlinked);
    try std.testing.expectEqual(@as(usize, 0), unlinked.len);
}

test "derive: a skip_before_action leaves the page unguarded, and raises no finding" {
    const gpa = std.testing.allocator;
    // The other half of reading the whole `FilterSet`: a filter the
    // controller explicitly skips does not guard the action, so claiming the
    // page cannot enforce a guard it does not have would be a question about
    // nothing. `controllers.guardsFor` applies the skip (including its
    // placement rule); this file must not second-guess it.
    const rs = [_]routes.Route{ctrlRoute("GET", "/posts", "posts", "index", 3)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const filters = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .only = &.{}, .except = &.{}, .dynamic = false, .line = 2 },
    };
    const skips = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "authenticate_user!", .only = &.{}, .except = &.{}, .dynamic = false, .line = 3 },
    };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .filters = .{ .before_actions = &filters, .skips = &skips },
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "derive: a password form in a partial keeps its own backend question" {
    const gpa = std.testing.allocator;
    // Fix round 1 (I-2). `shared/_login_form.html.erb` is no route's view, so
    // it makes no route a journey route and `RAILS_AUTH_JOURNEY` never fires
    // -- yet the partial's password form used to suppress its own
    // `RAILS_BACKEND_ENDPOINT` in favour of that non-existent finding, which
    // left the form with no question at all. Ruling S12: Stage 3 WIDENS these
    // rows, never removes them.
    const pw = nodeCode(.form_field, 1, 20, "password_field");
    const nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_login_form.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{ctrlRoute("GET", "/", "pages", "home", 2)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const views = [_]?[]const u8{"app/views/pages/home.html.erb"};
    // Fix round 2 (NEW-1): the edge IS present -- `pages/home` really does
    // render this partial -- and it still is not a journey view, because
    // `pages/home` is not a journey route. Reachability alone is not the
    // rule; reachability FROM THE JOURNEY is.
    const home_renders = [_][]const u8{"app/views/shared/_login_form.html.erb"};
    const graph = [_]TemplateRenders{
        .{ .path = "app/views/pages/home.html.erb", .renders = &home_renders },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
        .render_graph = &graph,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings(
        "RAILS_BACKEND_ENDPOINT.app/views/shared/_login_form%2Ehtml%2Eerb.L1C1",
        out[0].id,
    );
}

test "derive: a journey view's password partial is the journey's question, not a second one" {
    const gpa = std.testing.allocator;
    // Fix round 2 (NEW-1), and the regression fix round 1 introduced. The
    // sign-in form almost never lives in `sessions/new.html.erb` itself --
    // it lives in `shared/_login_form`, and the view renders it. Keying the
    // suppression on "is this a route view" therefore raised BOTH
    // `RAILS_AUTH_JOURNEY` (the route is a journey route by controller) and
    // the partial's own `RAILS_BACKEND_ENDPOINT` for ONE form: the double
    // question assumption A5 exists to prevent.
    const pw = nodeCode(.form_field, 1, 20, "password_field");
    const partial_nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    const view_nodes = [_]fragments.Node{nodeCode(.render_partial, 2, 1, "shared/login_form")};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_login_form.html.erb", .nodes = @constCast(&partial_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/sessions/new.html.erb", .nodes = @constCast(&view_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/session/new", "sessions", "new", 4),
        ctrlRoute("POST", "/session", "sessions", "create", 5),
    };
    const vs = [_]classify.Verdict{ testVerdict(.content), testVerdict(.backend) };
    const views = [_]?[]const u8{ "app/views/sessions/new.html.erb", null };
    const new_renders = [_][]const u8{"app/views/shared/_login_form.html.erb"};
    const graph = [_]TemplateRenders{
        .{ .path = "app/views/sessions/new.html.erb", .renders = &new_renders },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
        .render_graph = &graph,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L4", out[0].id);
}

test "derive: a partial reached from a journey view AND an ordinary one belongs to the journey" {
    const gpa = std.testing.allocator;
    // The deliberate choice, stated at `detectJourney`: a shared partial
    // answered twice is two conflicting bindings for one region, while the
    // ordinary page it also appears on is still covered -- the journey's
    // `island` answer scaffolds the `AuthForm` that region becomes wherever
    // it is rendered. The other direction would ask about the sign-in form
    // twice.
    //
    // The walk is transitive, so this also pins the depth-1 hop: the journey
    // view renders a wrapper, and the wrapper renders the form.
    const pw = nodeCode(.form_field, 1, 20, "password_field");
    const partial_nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_login_form.html.erb", .nodes = @constCast(&partial_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/session/new", "sessions", "new", 4),
        ctrlRoute("GET", "/", "pages", "home", 6),
    };
    const vs = [_]classify.Verdict{ testVerdict(.content), testVerdict(.content) };
    const views = [_]?[]const u8{ "app/views/sessions/new.html.erb", "app/views/pages/home.html.erb" };
    const wrapper_renders = [_][]const u8{"app/views/shared/_login_form.html.erb"};
    const new_renders = [_][]const u8{"app/views/shared/_auth_panel.html.erb"};
    const home_renders = [_][]const u8{"app/views/shared/_login_form.html.erb"};
    const graph = [_]TemplateRenders{
        .{ .path = "app/views/sessions/new.html.erb", .renders = &new_renders },
        .{ .path = "app/views/shared/_auth_panel.html.erb", .renders = &wrapper_renders },
        .{ .path = "app/views/pages/home.html.erb", .renders = &home_renders },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
        .render_graph = &graph,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L4", out[0].id);
}

test "derive: a render cycle in the journey walk terminates" {
    const gpa = std.testing.allocator;
    // The depth cap, not the visited set, is what guarantees termination:
    // the graph is built from an operator's source tree and `render`
    // recursion is not something this stage can rule out, so the walk stops
    // after `max_journey_render_depth` frontiers whatever the edges say. The
    // visited set only keeps the work linear -- delete it and this test still
    // passes. (A real cycle also cannot survive Stage 1's own walk, which is
    // why this is defence rather than a case anyone has seen.)
    const pw = nodeCode(.form_field, 1, 20, "password_field");
    const partial_nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/shared/_login_form.html.erb", .nodes = @constCast(&partial_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const rs = [_]routes.Route{ctrlRoute("GET", "/session/new", "sessions", "new", 4)};
    const vs = [_]classify.Verdict{testVerdict(.content)};
    const views = [_]?[]const u8{"app/views/sessions/new.html.erb"};
    const a_renders = [_][]const u8{"app/views/shared/_login_form.html.erb"};
    const b_renders = [_][]const u8{"app/views/sessions/new.html.erb"};
    const graph = [_]TemplateRenders{
        .{ .path = "app/views/sessions/new.html.erb", .renders = &a_renders },
        .{ .path = "app/views/shared/_login_form.html.erb", .renders = &b_renders },
    };
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .route_views = &views,
        .render_graph = &graph,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_AUTH_JOURNEY.config/routes%2Erb.L4", out[0].id);
}

/// A document shaped for the mixed-verb test below: one collection carrying
/// all three writing operations, so each verb has exactly one right answer.
/// File scope for the reason `test_backend_ops` is.
var test_crud_ops = [_]backend.Operation{
    backendOp("createPosts", "POST", "/api/collections/posts/records", "posts", .create),
    backendOp("deletePosts", "DELETE", "/api/collections/posts/records/{id}", "posts", .delete),
    backendOp("updatePosts", "PATCH", "/api/collections/posts/records/{id}", "posts", .update),
};
var test_crud_auth = [_][]const u8{};

fn testCrudDoc() backend.Document {
    return .{
        .file = "openapi.json",
        .contract_version = "1.0.0",
        .consumer_routes = false,
        .operations = &test_crud_ops,
        .auth_collections = &test_crud_auth,
    };
}

test "derive: one routes.rb line with three verbs is three answerable findings" {
    const gpa = std.testing.allocator;
    // Fix round 1 (ruling I-3). `resources :posts` declares `POST /posts`,
    // `PATCH /posts/:id` and `DELETE /posts/:id` on ONE line. Ruling S22
    // folds a line into one finding because one declaration is one decision
    // -- true for `spa`, false here: the answer is a single ZigBase
    // OPERATION, and no operation is both a create and a delete. The grouped
    // row offered only the representative verb's operations, so two of the
    // three routes had nothing they could be bound to.
    const rs = [_]routes.Route{
        ctrlRoute("POST", "/posts", "posts", "create", 7),
        ctrlRoute("PATCH", "/posts/:id", "posts", "update", 7),
        ctrlRoute("DELETE", "/posts/:id", "posts", "destroy", 7),
    };
    const vs = [_]classify.Verdict{ testVerdict(.backend), testVerdict(.backend), testVerdict(.backend) };
    const doc = testCrudDoc();
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .backend = doc,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    // The verb is a fourth id component, appended after the line, so the
    // three-part `<code>.<path>.<loc>` shape a reader knows is still there
    // with one key added. Sorted lexicographically by id within the line.
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.DELETE.posts", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.PATCH.posts", out[1].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.posts", out[2].id);
    // Each names only its own verb's routes...
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: DELETE /posts/:id",
        out[0].message,
    );
    try std.testing.expectEqualStrings("DELETE /posts/:id", out[0].route_id.?);
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /posts",
        out[2].message,
    );
    // ...and offers only the operations that could serve it.
    try std.testing.expectEqualStrings("deletePosts", out[0].choices[0]);
    try std.testing.expectEqualStrings("updatePosts", out[1].choices[0]);
    try std.testing.expectEqualStrings("createPosts", out[2].choices[0]);
    for (out) |f| try std.testing.expectEqual(@as(usize, 3), f.choices.len);
}

test "routeVerbFindingId: the exported builder upper-cases and always emits a resource component" {
    const gpa = std.testing.allocator;
    // `scaffold.zig` recomputes this id to look an operator decision up
    // (Task 4). `routes.Route.verb` being upper-case today is a property of
    // one producer, not of the type, so the case is fixed HERE rather than
    // at each call site.
    const upper = try routeVerbFindingId(gpa, code_backend_endpoint, 7, "POST", "posts");
    defer gpa.free(upper);
    const lower = try routeVerbFindingId(gpa, code_backend_endpoint, 7, "post", "posts");
    defer gpa.free(lower);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.posts", upper);
    try std.testing.expectEqualStrings(upper, lower);

    // A namespaced controller key survives the escaping like any other
    // component -- `/` is not special, and `.`/`%` would be escaped.
    const nested = try routeVerbFindingId(gpa, code_backend_endpoint, 7, "POST", "admin/users");
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.admin/users", nested);

    // The component is ALWAYS present, so the id has a fixed shape: a route
    // whose controller never resolved contributes an empty one, which no
    // real controller key (derived from a file path) can collide with.
    const anon = try routeVerbFindingId(gpa, code_backend_endpoint, 7, "POST", null);
    defer gpa.free(anon);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.", anon);

    // The line-only builder is unchanged and is what every other row uses.
    const plain = try routeFindingId(gpa, code_route_auth_guard, 7);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("RAILS_ROUTE_AUTH_GUARD.config/routes%2Erb.L7", plain);
}

/// `resources :posts, :comments` -- one line, one verb, two collections.
var test_two_resource_ops = [_]backend.Operation{
    backendOp("createComments", "POST", "/api/collections/comments/records", "comments", .create),
    backendOp("createPosts", "POST", "/api/collections/posts/records", "posts", .create),
};
var test_two_resource_auth = [_][]const u8{};

test "derive: one routes.rb line declaring two resources is two answerable findings" {
    const gpa = std.testing.allocator;
    // Fix round 2 (NEW-2). `resources :posts, :comments` is one line and one
    // verb, and `createPosts` cannot serve a comment -- so `(line, verb)`
    // still put two routes needing two different operations behind one id
    // and one answer. The key is now `(line, verb, resource)`, which is
    // exactly the pair `backend.choicesFor` is asked: two routes share a
    // finding precisely when they would be offered the same answers.
    const doc: backend.Document = .{
        .file = "openapi.json",
        .contract_version = "1.0.0",
        .consumer_routes = false,
        .operations = &test_two_resource_ops,
        .auth_collections = &test_two_resource_auth,
    };
    const rs = [_]routes.Route{
        ctrlRoute("POST", "/posts", "posts", "create", 7),
        ctrlRoute("POST", "/comments", "comments", "create", 7),
    };
    const vs = [_]classify.Verdict{ testVerdict(.backend), testVerdict(.backend) };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .backend = doc,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.comments", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.posts", out[1].id);
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /comments",
        out[0].message,
    );
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /posts",
        out[1].message,
    );
    // Each is offered its OWN resource's operation first. The other one is
    // still reachable (a Rails controller may write to any collection), but
    // the answer nine times in ten now ranks first for both.
    try std.testing.expectEqualStrings("createComments", out[0].choices[0]);
    try std.testing.expectEqualStrings("createPosts", out[1].choices[0]);
}

test "derive: resources interleaved by path on one line still group into one finding each" {
    const gpa = std.testing.allocator;
    // The grouping walks CONTIGUOUS runs, so the sort has to order by
    // `resource` and not merely happen to. A hit's id is `"<verb> <path>"`,
    // which orders by verb for free but says nothing about the controller:
    // here the paths interleave the two resources (`/a` posts, `/b`
    // comments, `/c` posts), so an id-only sort splits the `posts` run in
    // two and emits TWO findings carrying the SAME id -- the one property an
    // id must never lose. Two findings, and the `posts` one names both of
    // its routes, is what proves the run was not split.
    const rs = [_]routes.Route{
        ctrlRoute("POST", "/a", "posts", "create", 7),
        ctrlRoute("POST", "/b", "comments", "create", 7),
        ctrlRoute("POST", "/c", "posts", "publish", 7),
    };
    const vs = [_]classify.Verdict{ testVerdict(.backend), testVerdict(.backend), testVerdict(.backend) };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.comments", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.posts", out[1].id);
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /b",
        out[0].message,
    );
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /a, POST /c",
        out[1].message,
    );
}

test "derive: a route with no controller is its own group, not folded into a neighbour's" {
    const gpa = std.testing.allocator;
    // `Route.controller` is optional, and a route whose controller discovery
    // never recovered has no resource -- so it is NOT the same question as a
    // route on the same line and verb that does have one, and must not be
    // handed that resource's operations. The empty fifth id component is
    // what keeps the two apart; no real controller key (derived from a file
    // path) is empty, so it cannot collide.
    var anon = ctrlRoute("POST", "/b", "posts", "create", 7);
    anon.controller = null;
    anon.action = null;
    const rs = [_]routes.Route{ ctrlRoute("POST", "/a", "posts", "create", 7), anon };
    const vs = [_]classify.Verdict{ testVerdict(.backend), testVerdict(.backend) };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.", out[0].id);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.posts", out[1].id);
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /b",
        out[0].message,
    );
}

test "derive: two routes sharing a line AND a verb are still one finding" {
    const gpa = std.testing.allocator;
    // The narrowing is `(line, verb)`, not "one finding per route": two POSTs
    // from one declaration are one question with one answer, and splitting
    // them would put two identical decisions in front of an operator.
    const rs = [_]routes.Route{
        ctrlRoute("POST", "/posts", "posts", "create", 7),
        ctrlRoute("POST", "/posts/bulk", "posts", "bulk", 7),
    };
    const vs = [_]classify.Verdict{ testVerdict(.backend), testVerdict(.backend) };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L7.POST.posts", out[0].id);
    try std.testing.expectEqualStrings(
        "route is API traffic and needs a backend operation: POST /posts, POST /posts/bulk",
        out[0].message,
    );
}

test "derive: a non-GET redirect route raises no backend-endpoint question" {
    const gpa = std.testing.allocator;
    // Fix round 1 (M-1). `scaffold.routeOutcome` reaches its `redirect` arm
    // FIRST, whatever the verb, so a `post "/legacy" => redirect(...)` never
    // becomes API traffic this stage can bind. The backend row on it was an
    // orphan: in the manifest, attached to no route outcome, retirable by no
    // answer. `RAILS_REDIRECT_HOST_CONFIG` is the question about it, and it
    // fires whatever the verb.
    const rs = [_]routes.Route{ctrlRoute("POST", "/legacy", "pages", "legacy", 9)};
    const vs = [_]classify.Verdict{testVerdict(.redirect)};
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_REDIRECT_HOST_CONFIG.config/routes%2Erb.L9", out[0].id);
}

test "derive: #182's two route rows name the winning route and the uninterpretable path" {
    const gpa = std.testing.allocator;
    // Both used to be bare `addOpenNote` sentences in `scaffold.zig` with no
    // id behind them, so no decisions file could name them and `complete`
    // was unreachable for the app. The route indexes come from
    // `resolve.contentClaims`, which `scaffold.zig` reads too.
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/about", "pages", "about", 2),
        ctrlRoute("GET", "/about/", "pages", "about_alias", 3),
        ctrlRoute("GET", "/posts(.:format)", "posts", "index", 4),
    };
    const vs = [_]classify.Verdict{ testVerdict(.content), testVerdict(.content), testVerdict(.content) };
    const collisions = [_]resolve.ContentCollision{.{ .route = 1, .with = 0 }};
    const unsupported = [_]usize{2};
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
        .content_collisions = &collisions,
        .unsupported_route_paths = &unsupported,
    });
    defer free(gpa, out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_CONTENT_PATH_COLLISION.config/routes%2Erb.L3", out[0].id);
    try std.testing.expectEqualStrings("content path collision with GET /about: GET /about/", out[0].message);
    try std.testing.expectEqualStrings("GET /about/", out[0].route_id.?);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[1]);

    try std.testing.expectEqualStrings("RAILS_ROUTE_PATH_UNSUPPORTED.config/routes%2Erb.L4", out[1].id);
    try std.testing.expectEqualStrings(
        "route path contains syntax this stage does not interpret: GET /posts(.:format)",
        out[1].message,
    );
    try std.testing.expectEqual(@as(usize, 2), out[1].choices.len);
}

test "derive: an omitted content-claims input derives neither #182 row" {
    const gpa = std.testing.allocator;
    // Both fields default empty so this file's pre-Stage-3 call literals keep
    // compiling, and an omitted value must LOSE the row rather than fabricate
    // one. This is what fails if `rails.zig` stops calling
    // `resolve.contentClaims`.
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/about", "pages", "about", 2),
        ctrlRoute("GET", "/about/", "pages", "about_alias", 3),
    };
    const vs = [_]classify.Verdict{ testVerdict(.content), testVerdict(.content) };
    const out = try derive(gpa, .{
        .templates = &.{},
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .routes = &rs,
        .classifications = &vs,
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "derive: the Stage 3 rows leak nothing under a FailingAllocator" {
    // The Stage 1 sweep above never reaches the backend document, the
    // journey, or any of the four new route rows.
    const pw = nodeCode(.form_field, 1, 20, "password_field");
    const journey_nodes = [_]fragments.Node{ openFormNode(1, 1, "user"), pw, endNodeAt(1, 60) };
    var form = openFormNode(1, 1, "post");
    form.attrs = &[_]fragments.Attr{.{ .key = "method", .value = "patch" }};
    var link = linkNode("button_to \"Sign out\", session_path, method: :delete", "session", "Sign out", 2, 5);
    link.attrs = &[_]fragments.Attr{.{ .key = "method", .value = "delete" }};
    const plain_nodes = [_]fragments.Node{ form, endNodeAt(1, 40), link };
    // Fix round 2 (NEW-1): the journey form lives in a PARTIAL the sign-in
    // view renders, so the sweep walks the render graph too -- and the
    // expected count below would be 8, not 7, if that walk stopped working.
    const view_nodes = [_]fragments.Node{nodeCode(.render_partial, 2, 1, "shared/login_form")};
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/sessions/new.html.erb", .nodes = @constCast(&view_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/shared/_login_form.html.erb", .nodes = @constCast(&journey_nodes), .error_message = null, .error_line = null, .unreadable = null },
        .{ .path = "app/views/posts/edit.html.erb", .nodes = @constCast(&plain_nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const sweep_renders = [_][]const u8{"app/views/shared/_login_form.html.erb"};
    const graph = [_]TemplateRenders{
        .{ .path = "app/views/sessions/new.html.erb", .renders = &sweep_renders },
    };
    const rs = [_]routes.Route{
        ctrlRoute("GET", "/session/new", "sessions", "new", 2),
        ctrlRoute("POST", "/session", "sessions", "create", 3),
        ctrlRoute("GET", "/posts/edit", "posts", "edit", 4),
        ctrlRoute("POST", "/posts", "posts", "create", 5),
        ctrlRoute("GET", "/about", "pages", "about", 6),
        ctrlRoute("GET", "/about/", "pages", "about_alias", 7),
        ctrlRoute("GET", "/legacy(.:format)", "pages", "legacy", 8),
    };
    const vs = [_]classify.Verdict{
        testVerdict(.content),
        testVerdict(.backend),
        testVerdict(.content),
        testVerdict(.backend),
        testVerdict(.content),
        testVerdict(.content),
        testVerdict(.content),
    };
    const views = [_]?[]const u8{
        "app/views/sessions/new.html.erb",
        null,
        "app/views/posts/edit.html.erb",
        null,
        null,
        null,
        null,
    };
    const filters = [_]controllers.BeforeAction{
        .{ .controller = "posts", .name = "require_login", .only = &.{}, .except = &.{}, .dynamic = false, .line = 2 },
    };
    const collisions = [_]resolve.ContentCollision{.{ .route = 5, .with = 4 }};
    const unsupported = [_]usize{6};
    const doc = testBackendDoc();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (derive(failing.allocator(), .{
            .templates = &tpls,
            .layouts = &.{},
            .controller_files = &.{},
            .route_names = &.{},
            .locale = null,
            .routes = &rs,
            .classifications = &vs,
            .route_views = &views,
            .filters = .{ .before_actions = &filters },
            .content_collisions = &collisions,
            .unsupported_route_paths = &unsupported,
            .render_graph = &graph,
            .backend = doc,
        })) |out| {
            defer free(std.testing.allocator, out);
            // form, link, backend route x1 (the POST /posts; the journey POST
            // is suppressed), auth journey, auth guard, collision,
            // unsupported.
            try std.testing.expectEqual(@as(usize, 7), out.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "derive: Stage 4 interactivity rows expose only buildable choices" {
    const gpa = std.testing.allocator;
    const attrs = [_]fragments.Attr{
        .{ .key = "series", .value = "a", .kind = .string },
        .{ .key = "points", .value = "3", .kind = .number },
    };
    const nodes = [_]fragments.Node{
        .{ .text = null, .kind = .stimulus, .line = 1, .col = 1, .output = false, .code = "<div data-controller=\"reveal\">", .name = "reveal", .value = "div", .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        nodeText("<button data-action=\"click->reveal#toggle\" data-reveal-target=\"details\">Show</button>", 1),
        .{ .text = null, .kind = .block_end, .line = 1, .col = 90, .output = false, .code = "</div>", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .turbo_frame, .line = 2, .col = 1, .output = true, .code = "turbo_frame_tag", .name = "latest", .value = "posts", .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .turbo_frame, .line = 3, .col = 1, .output = true, .code = "turbo_frame_tag", .name = "static", .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        nodeCode(.turbo_stream, 4, 1, "messages"),
        .{ .text = null, .kind = .component_root, .line = 5, .col = 1, .output = true, .code = "react_component", .name = "Chart", .value = null, .args = &.{}, .attrs = &attrs, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .vue_root, .line = 6, .col = 1, .output = false, .code = "<div data-vue-component=\"Widget\">", .name = "Widget", .value = "div", .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const sources = [_]port.JsSource{
        .{ .path = "app/javascript/controllers/reveal_controller.js", .bytes = "export default class extends Controller { static targets = [\"details\"]; toggle() {} }" },
        .{ .path = "app/javascript/components/Chart.jsx", .bytes = "import React from \"react\"; export default function Chart() {}" },
    };
    const route_params = [_]RouteParam{.{ .name = "posts", .path = "/posts" }};
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .js_sources = &sources,
        .route_params = &route_params,
        .js_entry = "app/javascript/application.js",
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 7), out.len);
    try std.testing.expectEqualStrings(code_component_root, out[0].code);
    try std.testing.expectEqualStrings("React root `Chart` props {points, series}; source app/javascript/components/Chart.jsx", out[0].message);
    for ([_][]const u8{ "island", "retain", "blocked" }, out[0].choices) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings(code_component_vue_unsupported, out[1].code);
    try std.testing.expectEqualStrings("RAILS_JS_ENTRY", out[2].code);
    try std.testing.expectEqual(@as(?u64, null), out[2].line);
    try std.testing.expectEqualStrings(code_stimulus_controller, out[3].code);
    try std.testing.expect(std.mem.indexOf(u8, out[3].message, "actions: click->reveal#toggle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[3].message, "targets: details") != null);
    for ([_][]const u8{ "island", "drop", "retain", "blocked" }, out[3].choices) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings(code_turbo_frame, out[4].code);
    try std.testing.expectEqualStrings("turbo-frame `latest` src=/posts", out[4].message);
    for ([_][]const u8{ "island", "retain", "blocked" }, out[4].choices) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings("turbo-frame `static` (no src)", out[5].message);
    for ([_][]const u8{ "inline", "retain", "blocked" }, out[5].choices) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings(code_turbo_stream, out[6].code);
    try std.testing.expect(std.mem.indexOf(u8, out[6].message, "a realtime subscription has no converter") != null);
}

test "derive: ivar islands require a portable record body and name backend collections" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        .{ .text = null, .kind = .ivar, .line = 1, .col = 1, .output = true, .code = "@post.title", .name = "@post", .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .ivar, .line = 2, .col = 1, .output = true, .code = "@post.author.name", .name = "@post", .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
    };
    const tpls = [_]fragments.Template{.{ .path = "app/views/posts/show.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null }};
    const out = try derive(gpa, .{
        .templates = &tpls,
        .layouts = &.{},
        .controller_files = &.{},
        .route_names = &.{},
        .locale = null,
        .backend = testBackendDoc(),
    });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(usize, 5), out[0].choices.len);
    try std.testing.expectEqualStrings("island", out[0].choices[0]);
    try std.testing.expect(std.mem.endsWith(u8, out[0].message, "; collection posts (in --backend)"));
    try std.testing.expectEqual(@as(usize, 3), out[1].choices.len);
    try std.testing.expectEqualStrings("spa", out[1].choices[0]);
}

test "derive: ERB-split Stimulus markers are diffed by name, never count" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        .{ .text = null, .kind = .stimulus, .line = 2, .col = 1, .output = false, .code = "<div data-controller=\"reveal modal\">", .name = "reveal modal", .value = "div", .args = &.{}, .attrs = &.{}, .missing = true, .dynamic = false },
    };
    const names = [_][]const u8{ "reveal", "modal", "split" };
    const tpls = [_]fragments.Template{.{ .path = "app/views/pages/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null }};
    const markers = [_]TemplateStimulusMarkers{.{ .path = tpls[0].path, .names = &names }};
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null, .stimulus_markers = &markers });
    defer free(gpa, out);
    // One finding for the element (covering reveal+modal), one for only the
    // marker name no element node covered. A count comparison would invent
    // two leftovers here because the marker set and node list are not the
    // same cardinality domain.
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "stimulus `split`") != null);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
}

test "derive: interactivity refusal paths never offer an emitter they cannot run" {
    const gpa = std.testing.allocator;
    const api_attrs = [_]fragments.Attr{.{ .key = "src", .value = "/literal", .kind = .string }};
    const nodes = [_]fragments.Node{
        .{ .text = null, .kind = .stimulus, .line = 1, .col = 1, .output = false, .code = "<div data-controller=\"outer\">", .name = "outer", .value = "div", .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .stimulus, .line = 2, .col = 1, .output = false, .code = "<span data-controller=\"inner\">", .name = "inner", .value = "span", .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .block_end, .line = 2, .col = 30, .output = false, .code = "</span>", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .block_end, .line = 3, .col = 1, .output = false, .code = "</div>", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .stimulus, .line = 4, .col = 1, .output = false, .code = "<div data-controller=\"missing\">", .name = "missing", .value = "div", .args = &.{}, .attrs = &.{}, .missing = true, .dynamic = false },
        .{ .text = null, .kind = .component_root, .line = 5, .col = 1, .output = true, .code = "react_component", .name = "Chart", .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .component_root, .line = 6, .col = 1, .output = true, .code = "react_component", .name = "Dynamic", .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = true },
        .{ .text = null, .kind = .turbo_frame, .line = 7, .col = 1, .output = true, .code = "turbo_frame_tag", .name = "api", .value = "api", .args = &.{"7"}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .turbo_frame, .line = 8, .col = 1, .output = false, .code = "<turbo-frame>", .name = "literal", .value = "turbo-frame", .args = &.{}, .attrs = &api_attrs, .missing = false, .dynamic = false },
    };
    const tpls = [_]fragments.Template{.{ .path = "app/views/pages/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null }};
    const sources = [_]port.JsSource{
        .{ .path = "app/javascript/controllers/outer_controller.js", .bytes = "export default class extends Controller {}" },
        .{ .path = "app/javascript/controllers/inner_controller.js", .bytes = "export default class extends Controller {}" },
        .{ .path = "app/javascript/components/Chart.jsx", .bytes = "import d3 from \"d3\"; export default function Chart() {}" },
    };
    var api_route = ctrlRoute("GET", "/api/:id", "api", "index", 1);
    api_route.name = "api";
    const rs = [_]routes.Route{ api_route, ctrlRoute("GET", "/literal", "api", "literal", 20) };
    const vs = [_]classify.Verdict{ testVerdict(.backend), testVerdict(.backend) };
    const route_params = [_]RouteParam{.{ .name = "api", .path = "/api/:id" }};
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null, .js_sources = &sources, .routes = &rs, .classifications = &vs, .route_params = &route_params });
    defer free(gpa, out);
    for (out) |finding| {
        if (finding.line == 2) {
            try std.testing.expectEqualStrings("drop", finding.choices[0]);
            try std.testing.expect(std.mem.indexOf(u8, finding.message, "nested inside") != null);
        } else if (finding.line == 4) {
            try std.testing.expectEqualStrings("drop", finding.choices[0]);
            try std.testing.expect(std.mem.indexOf(u8, finding.message, "not closed") != null);
        } else if (finding.line == 5) {
            try std.testing.expectEqual(@as(usize, 2), finding.choices.len);
            try std.testing.expect(std.mem.indexOf(u8, finding.message, "d3") != null);
        } else if (finding.line == 6) {
            try std.testing.expectEqualStrings(code_component_props_dynamic, finding.code);
        } else if (finding.line == 7) {
            try std.testing.expectEqual(@as(usize, 2), finding.choices.len);
            try std.testing.expectEqualStrings("turbo-frame `api` src=/api/7 is API traffic", finding.message);
        } else if (finding.line == 8) {
            try std.testing.expectEqual(@as(usize, 2), finding.choices.len);
            try std.testing.expectEqualStrings("turbo-frame `literal` src=/literal is API traffic", finding.message);
        }
    }
}

test "derive: Stage 4 interactivity FailingAllocator sweep" {
    const nodes = [_]fragments.Node{
        .{ .text = null, .kind = .stimulus, .line = 1, .col = 1, .output = false, .code = "<div data-controller=\"reveal\">", .name = "reveal", .value = "div", .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        nodeText("<button data-action=\"reveal#toggle\">x</button>", 1),
        .{ .text = null, .kind = .block_end, .line = 1, .col = 60, .output = false, .code = "</div>", .name = null, .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
        .{ .text = null, .kind = .component_root, .line = 2, .col = 1, .output = true, .code = "react_component", .name = "Chart", .value = null, .args = &.{}, .attrs = &.{}, .missing = false, .dynamic = false },
    };
    const tpls = [_]fragments.Template{.{ .path = "app/views/x.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null }};
    const sources = [_]port.JsSource{
        .{ .path = "app/javascript/controllers/reveal_controller.js", .bytes = "export default class extends Controller { toggle() {} }" },
        .{ .path = "app/javascript/components/Chart.jsx", .bytes = "import React from \"react\"; export default function Chart() {}" },
        .{ .path = "app/javascript/application.js", .bytes = "import \"./controllers\";" },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 2000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (derive(failing.allocator(), .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null, .js_sources = &sources, .js_entry = "app/javascript/application.js" })) |out| {
            defer free(std.testing.allocator, out);
            try std.testing.expectEqual(@as(usize, 3), out.len);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
