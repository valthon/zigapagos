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
const blockers = @import("blockers.zig");
const classify = @import("classify.zig");
// Only for `opensBlock` (ruling S12's form-nesting scope). `convert.zig`
// imports this file in turn -- a cycle Zig resolves the same way it already
// resolves `manifest.zig` <-> `rails.zig`. Sharing the predicate is the whole
// point: see `convert.opensBlock`'s own doc.
const convert = @import("convert.zig");
const fragments = @import("fragments.zig");
const controllers = @import("controllers.zig");
const resolve = @import("resolve.zig");
const routes = @import("routes.zig");

pub const Severity = blockers.Severity;

/// A per-fragment (or per-layout, or per-template) decision this run
/// surfaces to the operator rather than settling itself. See the module
/// doc for how this differs from `blockers.Blocker`.
///
/// Contract 2 (owned-result): `id`, `path`, and `message` are fresh `gpa`
/// allocations; `route_id` is a fresh allocation when non-null. `code` and
/// every `choices` slice are static string literals, never freed. Released
/// by `free`.
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
    /// The fixed set of answers an operator may record against this
    /// finding. Always a static string literal slice, never freed.
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

/// The three #167 Stage 2 ROUTE-scoped codes, and the file all of them point
/// at. Public because `scaffold.zig` has to recompute the very ids `derive`
/// produced in order to look an operator decision up against them -- see
/// `routeFindingId`.
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
pub const code_turbo_frame = "RAILS_TURBO_FRAME";
pub const code_turbo_stream = "RAILS_TURBO_STREAM";
pub const code_component_root = "RAILS_COMPONENT_ROOT";

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

/// True when a route path has a `:param` or `*glob` segment -- i.e. when it
/// stands for a family of URLs rather than one.
///
/// Duplicates the predicate `resolve.zig` keeps private inside `contentPath`
/// (`isPlaceholder`). The two MUST agree, since "dynamic" is defined here as
/// exactly "no single static content path", so the agreement is pinned by a
/// test below rather than left to a comment. Widening `resolve`'s API for a
/// two-line predicate would have been the alternative; the pinned test is
/// cheaper and catches drift in the direction that matters.
///
/// Contract 3 (caller-buffer): allocates nothing.
pub fn isDynamicRoutePath(route_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, route_path, '/');
    while (it.next()) |seg| {
        if (seg.len > 1 and (seg[0] == ':' or seg[0] == '*')) return true;
    }
    return false;
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

/// Contract 2 counterpart to `derive`: releases `id`/`path`/`message` and
/// (when non-null) `route_id` on every finding plus the slice itself. Does
/// not free `code` or `choices` -- both point at static literals owned by
/// the derivation table, never duplicated.
pub fn free(gpa: Allocator, list: []Finding) void {
    for (list) |f| {
        gpa.free(f.id);
        gpa.free(f.path);
        gpa.free(f.message);
        if (f.route_id) |rid| gpa.free(rid);
    }
    gpa.free(list);
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
    try list.append(gpa, .{
        .id = id,
        .code = code,
        .severity = severity,
        .path = path_copy,
        .line = line,
        .route_id = null,
        .message = message_copy,
        .choices = choices,
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
) Allocator.Error!void {
    const id = try routeFindingId(gpa, code, line);
    errdefer gpa.free(id);
    const path_copy = try gpa.dupe(u8, routes_file);
    errdefer gpa.free(path_copy);
    const message_copy = try gpa.dupe(u8, message);
    errdefer gpa.free(message_copy);
    const route_id_copy = try gpa.dupe(u8, route_id);
    errdefer gpa.free(route_id_copy);
    try list.append(gpa, .{
        .id = id,
        .code = code,
        .severity = severity,
        .path = path_copy,
        .line = line,
        .route_id = route_id_copy,
        .message = message_copy,
        .choices = choices,
        .requires_artifact = false,
    });
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
/// `id` is owned by `deriveRouteFindings`'s own scratch list.
const RouteHit = struct { line: u64, id: []u8 };

fn routeHitLessThan(_: void, a: RouteHit, b: RouteHit) bool {
    if (a.line != b.line) return a.line < b.line;
    return std.mem.lessThan(u8, a.id, b.id);
}

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
) Allocator.Error!void {
    var hits: std.ArrayListUnmanaged(RouteHit) = .empty;
    defer {
        for (hits.items) |h| gpa.free(h.id);
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
        };
        if (!qualifies) continue;
        // `<verb> <path>`, the same string `rails.formatRouteId` builds.
        // Formatted here rather than imported because `rails.zig` is this
        // package's ROOT and imports this file; the two-token format is
        // simpler to restate than that cycle is to reason about.
        const id = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.verb, r.path });
        errdefer gpa.free(id);
        try hits.append(gpa, .{ .line = r.source.line, .id = id });
    }

    // Sorted by (line, route id) so the grouping below is contiguous and the
    // representative route -- and the message's order -- is the same on every
    // machine, whatever order the sidecar emitted the route table in.
    std.mem.sort(RouteHit, hits.items, {}, routeHitLessThan);

    const code = switch (row) {
        .dynamic_segment => code_route_dynamic_segment,
        .redirect => code_redirect_host_config,
        .no_template => code_no_template,
    };
    const choices: []const []const u8 = switch (row) {
        .dynamic_segment => &choices_spa_retain_blocked,
        .redirect => &choices_retain_blocked,
        .no_template => &choices_retain_blocked,
    };
    const prefix = switch (row) {
        .dynamic_segment => "route path has a dynamic segment: ",
        .redirect => "route redirects; the host config owns it, not the static tree: ",
        .no_template => "no view template resolves for the route's controller and action: ",
    };

    var i: usize = 0;
    while (i < hits.items.len) {
        var j = i + 1;
        while (j < hits.items.len and hits.items[j].line == hits.items[i].line) j += 1;

        var message: std.ArrayListUnmanaged(u8) = .empty;
        defer message.deinit(gpa);
        try message.appendSlice(gpa, prefix);
        for (hits.items[i..j], 0..) |h, k| {
            if (k != 0) try message.appendSlice(gpa, ", ");
            try message.appendSlice(gpa, h.id);
        }
        try appendRouteFinding(gpa, list, code, .warn, hits.items[i].line, message.items, choices, hits.items[i].id);
        i = j;
    }
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

/// Handles the node-triggered rows of the derivation table for one
/// template. Split out of `derive` because it is the one source with
/// several codes keyed off `Kind`, so this is where the table's node rows
/// live as a `switch` rather than duplicated across `derive`'s body.
///
/// Contract 2 (owned-result), inherited from `derive`.
fn deriveNode(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Finding),
    path: []const u8,
    node: fragments.Node,
    route_names: []const []const u8,
    locale: ?[]const u8,
    in_i18n_error_paths: []const []const u8,
    asset_list: []const assets.Asset,
    /// Ruling S12: this node sits inside a `form` block that already carries
    /// its own `RAILS_BACKEND_ENDPOINT`. Computed by `derive`'s walk, because
    /// only a walk over the whole stream can know it.
    in_form: bool,
) Allocator.Error!void {
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
        .request_state, .ivar => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const message = try std.fmt.allocPrint(gpa, "request-time state `{s}`", .{name});
            defer gpa.free(message);
            try appendFinding(gpa, list, "RAILS_REQUEST_TIME_STATE", .warn, path, node.line, loc, message, &choices_full);
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
            try appendFinding(gpa, list, code_backend_endpoint, .warn, path, node.line, loc, summary.items, &choices_retain_blocked);
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
            try appendFinding(gpa, list, "RAILS_REQUEST_TIME_STATE", .warn, path, node.line, loc, message, &choices_retain_blocked);
        },
        .turbo_frame, .turbo_stream, .component_root => {
            const loc = try nodeLoc(gpa, node.line, node.col);
            defer gpa.free(loc);
            const name = node.name orelse "";
            const code = switch (node.kind) {
                .turbo_frame => code_turbo_frame,
                .turbo_stream => code_turbo_stream,
                else => code_component_root,
            };
            const message = switch (node.kind) {
                .turbo_frame => try std.fmt.allocPrint(gpa, "turbo-frame `{s}`", .{name}),
                .turbo_stream => try std.fmt.allocPrint(gpa, "turbo-stream `{s}`", .{name}),
                else => try std.fmt.allocPrint(gpa, "React/Vue root `{s}`", .{name}),
            };
            defer gpa.free(message);
            try appendFinding(gpa, list, code, .warn, path, node.line, loc, message, &choices_retain_blocked);
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
        for (list.items) |f| {
            gpa.free(f.id);
            gpa.free(f.path);
            gpa.free(f.message);
            if (f.route_id) |rid| gpa.free(rid);
        }
        list.deinit(gpa);
    }

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
        for (tpl.nodes) |node| {
            // Computed BEFORE this node's own frame is pushed, so an
            // outermost `form` sees `false` and asks its question, while
            // everything it contains sees `true`.
            try deriveNode(gpa, &list, tpl.path, node, in.route_names, in.locale, in.i18n_error_paths, in.assets, form_depth > 0);
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
    try deriveRouteFindings(gpa, &list, in, .dynamic_segment);
    try deriveRouteFindings(gpa, &list, in, .redirect);
    try deriveRouteFindings(gpa, &list, in, .no_template);

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
        "RAILS_REQUEST_TIME_STATE",
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

    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT", out[0].code);
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L3", out[0].id);
    try std.testing.expectEqualStrings("config/routes.rb", out[0].path);
    try std.testing.expectEqual(@as(?u64, 3), out[0].line);
    try std.testing.expectEqual(Severity.warn, out[0].severity);
    try std.testing.expectEqualStrings("GET /posts/:id", out[0].route_id.?);
    try std.testing.expectEqual(@as(usize, 3), out[0].choices.len);
    try std.testing.expectEqualStrings("spa", out[0].choices[0]);
    try std.testing.expectEqualStrings("retain", out[0].choices[1]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[2]);
    // Both routes of the shared declaration are named in the message, so the
    // one `route_id` naming only the first is not the only evidence left.
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "GET /posts/:id/edit") != null);
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
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L7", out[1].id);
    try std.testing.expectEqualStrings("RAILS_NO_TEMPLATE", out[0].code);
    try std.testing.expectEqualStrings("RAILS_NO_TEMPLATE.config/routes%2Erb.L3", out[0].id);
    try std.testing.expectEqualStrings("config/routes.rb", out[0].path);
    try std.testing.expectEqual(@as(?u64, 3), out[0].line);
    try std.testing.expectEqual(Severity.warn, out[0].severity);
    try std.testing.expectEqualStrings("GET /other", out[0].route_id.?);
    try std.testing.expectEqual(@as(usize, 2), out[0].choices.len);
    try std.testing.expectEqualStrings("retain", out[0].choices[0]);
    try std.testing.expectEqualStrings("blocked", out[0].choices[1]);
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

test "derive: turbo and component roots each get their own code" {
    const gpa = std.testing.allocator;
    const nodes = [_]fragments.Node{
        nodeCode(.turbo_frame, 1, 1, "posts"),
        nodeCode(.turbo_stream, 2, 1, "messages"),
        nodeCode(.component_root, 3, 1, "PostList"),
    };
    const tpls = [_]fragments.Template{
        .{ .path = "app/views/posts/index.html.erb", .nodes = @constCast(&nodes), .error_message = null, .error_line = null, .unreadable = null },
    };
    const out = try derive(gpa, .{ .templates = &tpls, .layouts = &.{}, .controller_files = &.{}, .route_names = &.{}, .locale = null });
    defer free(gpa, out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    // Sorted by code: COMPONENT_ROOT, TURBO_FRAME, TURBO_STREAM.
    try std.testing.expectEqualStrings("RAILS_COMPONENT_ROOT", out[0].code);
    try std.testing.expect(std.mem.indexOf(u8, out[0].message, "React/Vue root `PostList`") != null);
    try std.testing.expectEqualStrings("RAILS_TURBO_FRAME", out[1].code);
    try std.testing.expectEqualStrings("RAILS_TURBO_STREAM", out[2].code);
    for (out) |f| {
        try std.testing.expectEqual(@as(usize, 2), f.choices.len);
        try std.testing.expectEqual(Severity.warn, f.severity);
    }
}
