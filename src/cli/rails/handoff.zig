//! `MIGRATION.handoff.json` -- the machine-readable answer to "is this Rails
//! app fully migrated yet, and if not, what is still open?".
//!
//! Written next to the discovery manifest by `zigapagos migrate --from rails
//! --target DIR`, schema `zigapagos.rails-handoff/1` (spec: `docs/superpowers
//! /specs/2026-08-29-rails-presentation-migration-design.md`, "Findings,
//! decisions, handoff"). It is a SEPARATE, separately-versioned artifact from
//! `zigapagos.rails-presentation/1`: the manifest records what DISCOVERY
//! established about the Rails app and never changes when the converter
//! improves; this file records what the CONVERSION produced and is expected
//! to change on every run of the decide -> re-run loop.
//!
//! ## The types below ARE the schema
//!
//! Same arrangement as `manifest.zig` (read its module doc first -- every
//! rule there applies here verbatim): `contract/rails-handoff.v1.schema.json`
//! is GENERATED from the wire types in this file by `schema_gen.zig`'s
//! `generateHandoff`, and `zig build rails-check` fails the build when the
//! committed schema and these types disagree. So:
//!
//! - **Field declaration order is the wire contract.** `std.json.Stringify`
//!   emits keys in declaration order and the generated schema lists
//!   `properties`/`required` in the same order; reordering a field here
//!   silently rewrites a published document's key order.
//! - **Every declared field is emitted, `null` included** -- nothing is
//!   omitted when absent, which is why the generated schema puts every field
//!   in `required`.
//! - The INPUT types (`RouteRow`/`AssetRow`/`Redirect`/`BuildInput`) are
//!   deliberately NOT the wire types even where their fields coincide today.
//!   A shared type would make a wire-order edit (which is a contract change)
//!   indistinguishable from a producer-convenience edit (which is not) --
//!   the exact trap `manifest.zig`'s `TemplateEntry` doc describes. `build`
//!   copies field by field.
//!
//! ## Determinism
//!
//! The handoff is diffed (`rails-check`'s sibling gate for the manifest, and
//! Task 7's `cmp` of two consecutive runs), so identical facts must produce
//! identical bytes no matter what order the caller assembled them in. Every
//! emitted list is therefore sorted here, in a PRIVATE copy, under a TOTAL
//! order -- never merely "sorted enough that the common case looks stable",
//! which is the partial-order bug `report.zig`'s fix round B/B7 already paid
//! for once: `std.mem.sort` is unstable, so any pair the comparator calls
//! equal has its relative order decided by the sort's internals.
//!
//! Private copies also matter for a second reason: `build`'s inputs are
//! borrowed `const` slices whose owner (`migrate.zig`) still renders
//! `MIGRATION.md` from the same rows afterwards. Sorting through the borrow
//! would reorder the caller's data underneath it.
//!
//! The claim is order-INDEPENDENCE, not merely "deterministic for a given
//! input order", and the difference is where this got caught in review: every
//! tiebreak compares CONTENT, never a row's position in the caller's slice. A
//! positional fallback reproduces itself run after run and so looks stable
//! under a repeat-the-same-call test, while still moving bytes the moment the
//! caller assembles the same facts in a different order -- which is exactly
//! what the decide-then-re-run loop does.
//!
//! ## `status` versus the manifest's `classification`
//!
//! They are different questions and may disagree. `classification` is
//! discovery's verdict about the RAILS route and is never revised; `status`
//! is what the conversion actually managed to produce. Where the two
//! disagree the conversion wins (spec, "Conversion: what a route becomes").
//! A consumer that wants "did this route migrate" must read `status`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rails = @import("rails.zig");
const routes = @import("routes.zig");
const report = @import("report.zig");

/// Additive-only within `1`, exactly as `manifest.schema_id` is: a field may
/// be appended, an existing one may not change meaning or disappear.
pub const schema_id: []const u8 = "zigapagos.rails-handoff/1";
pub const schema_version_value: u32 = 1;

/// Field order is the wire contract -- `tool` then `version`. Declared here
/// rather than aliasing `manifest.Generator` on purpose: the two documents
/// are independently versioned, and a future change to one's generator block
/// must not silently rewrite the other's.
pub const Generator = struct {
    tool: []const u8 = "zigapagos",
    version: []const u8,
};

/// `backend`'s non-null shape (spec's example: `{"file": "openapi.json",
/// "contract_version": "2026-06-27.1"}`). Filled from the `--backend FILE`
/// document since #167 Stage 3; `file` is that path's BASENAME.
pub const Backend = struct {
    file: []const u8,
    contract_version: []const u8,
};

/// `routes[].endpoint`'s non-null shape. Filled since #167 Stage 3 -- see
/// `RouteEntry.endpoint`.
pub const Endpoint = struct {
    operation_id: []const u8,
    verb: []const u8,
    path: []const u8,
};

/// What the conversion produced for one route. Member order is the generated
/// schema's `enum` order, so it is as much a wire contract as a field order.
///
/// - `migrated` -- real target artifacts exist for this route.
/// - `open` -- nothing was produced and no operator decision covers it. The
///   default, and the one status that keeps `complete` false.
/// - `blocked` -- the converter cannot produce this route, and the operator
///   has acknowledged that in `MIGRATION.decisions.json`.
/// - `retained` -- the operator chose to keep the Rails behaviour as-is.
/// - `backend` -- the route is API/JSON traffic that becomes a ZigBase
///   endpoint, not a page. It accounts for the route only once it has been
///   ANSWERED -- bound to an operation, or acknowledged by a decision
///   (ruling A2, the Stage 3 reopening ruling S11 promised). See
///   `statusAccounted`.
/// - `redirect` -- the route is a pure redirect, emitted as host config.
pub const Status = enum { migrated, open, blocked, retained, backend, redirect };

/// The operator's answer that justifies a non-`migrated` status, echoed into
/// the handoff so a reader does not have to cross-reference
/// `MIGRATION.decisions.json` by hand. Field order is the wire contract.
/// `artifact` is deliberately absent: it is an INPUT to the conversion (it
/// names the file the operator wrote), and where it produced something the
/// result is already in `artifacts[]`.
pub const DecisionRef = struct {
    id: []const u8,
    choice: []const u8,
    rationale: []const u8,
};

/// Field order is the wire contract, matching the spec's own example object:
/// `route_id`, `status`, `artifacts`, `endpoint`, `decision`, `findings`,
/// `note`.
pub const RouteEntry = struct {
    /// `rails.formatRouteId` of the route this row named -- a LABEL, not a
    /// unique key (see that function's own "not a unique identifier" doc).
    route_id: []const u8,
    status: Status,
    /// Target-relative paths this route produced, sorted lexicographically.
    artifacts: []const []const u8,
    /// The ZigBase operation this route's traffic becomes, or `null` for a
    /// page route and for a `backend` route nobody has bound yet. Since
    /// #167 Stage 3 that second case is also what keeps `complete` false
    /// for a user-facing route (`statusAccounted`, ruling A2).
    endpoint: ?Endpoint,
    decision: ?DecisionRef,
    /// `findings[].id`s from the manifest that this route left OPEN, sorted
    /// lexicographically -- the join key an operator answers in
    /// `MIGRATION.decisions.json`.
    findings: []const []const u8,
    /// Free prose for a human reader (e.g. "deferred to Stage 3/4"). Not
    /// identity, not parsed by anything.
    note: ?[]const u8,
};

/// Field order is the wire contract -- `source`, `rails_url`, `target_url`.
pub const AssetEntry = struct {
    /// App-relative source path (e.g. `app/assets/images/logo.png`).
    source: []const u8,
    /// The URL Rails served this asset at, or `null` when the run could not
    /// establish one.
    rails_url: ?[]const u8,
    /// The URL the migrated site serves it at.
    target_url: []const u8,
};

/// Field order is the wire contract -- `from`, `to`.
pub const RedirectEntry = struct {
    from: []const u8,
    /// `null` when the redirect's target could not be resolved to a
    /// target-site URL -- a real answer (the operator has to supply host
    /// config), not a placeholder for a value this file failed to compute.
    to: ?[]const u8,
};

/// One form field the fixed parity runner submits. Values are strings on the
/// wire because Rails form controls submit strings even when the backend later
/// coerces them to another scalar type. `invalid_value` is `null` unless this
/// field is the deterministic validation target.
pub const RequestField = struct {
    name: []const u8,
    value: []const u8,
    invalid_value: ?[]const u8,
};

pub const NavigateExpect = struct {
    status: u16,
    title: ?[]const u8,
    h1: ?[]const u8,
    links: []const []const u8,
};

pub const AssetExpect = struct {
    status: u16,
    content_type: []const u8,
    rails_url: ?[]const u8,
};

pub const AuthExpect = struct { status: u16, collection: []const u8, page_url: []const u8 };

pub const SubmitAllowedExpect = struct {
    status_family: u8,
    operation_id: []const u8,
    method: []const u8,
    collection: ?[]const u8,
    page_url: []const u8,
    fields: []const RequestField,
};

pub const SubmitDeniedExpect = struct {
    statuses: []const u16,
    operation_id: []const u8,
    method: []const u8,
    collection: ?[]const u8,
    fields: []const RequestField,
};

pub const ValidationErrorExpect = struct {
    status: u16,
    operation_id: []const u8,
    method: []const u8,
    collection: ?[]const u8,
    page_url: []const u8,
    field: []const u8,
    fields: []const RequestField,
};

pub const NavigateParity = struct { id: []const u8, url: []const u8, expect: NavigateExpect };
pub const AssetParity = struct { id: []const u8, url: []const u8, expect: AssetExpect };
pub const SignupParity = struct { id: []const u8, url: []const u8, expect: AuthExpect };
pub const SigninParity = struct { id: []const u8, url: []const u8, expect: AuthExpect };
pub const SubmitAllowedParity = struct { id: []const u8, url: []const u8, expect: SubmitAllowedExpect };
pub const SubmitDeniedParity = struct { id: []const u8, url: []const u8, expect: SubmitDeniedExpect };
pub const ValidationErrorParity = struct { id: []const u8, url: []const u8, expect: ValidationErrorExpect };

pub const ParityKind = enum { navigate, asset, signup, signin, submit_allowed, submit_denied, validation_error };

/// The tag is serialized as `kind` and the payload is flattened to
/// `{id,kind,url,expect}`. A mismatched kind/expect pair is unrepresentable.
pub const ParityEntry = union(ParityKind) {
    navigate: NavigateParity,
    asset: AssetParity,
    signup: SignupParity,
    signin: SigninParity,
    submit_allowed: SubmitAllowedParity,
    submit_denied: SubmitDeniedParity,
    validation_error: ValidationErrorParity,

    /// Structural metadata consumed by schema_gen's generic tagged-union
    /// walker. It describes this custom wire serializer without naming this
    /// particular union in the generator.
    pub const json_schema_tag_field = "kind";

    pub fn id(self: ParityEntry) []const u8 {
        return switch (self) {
            inline else => |row| row.id,
        };
    }

    pub fn url(self: ParityEntry) []const u8 {
        return switch (self) {
            inline else => |row| row.url,
        };
    }

    pub fn jsonStringify(self: ParityEntry, jws: anytype) !void {
        try jws.beginObject();
        switch (self) {
            inline else => |row, tag| {
                try jws.objectField("id");
                try jws.write(row.id);
                try jws.objectField(json_schema_tag_field);
                try jws.write(@tagName(tag));
                try jws.objectField("url");
                try jws.write(row.url);
                try jws.objectField("expect");
                try jws.write(row.expect);
            },
        }
        try jws.endObject();
    }
};

/// Field order is the wire contract, top to bottom: `schema`,
/// `schema_version`, `generator`, `backend`, `complete`, `routes`, `assets`,
/// `redirects`, `parity`.
pub const Handoff = struct {
    schema: []const u8 = schema_id,
    schema_version: u32 = schema_version_value,
    generator: Generator,
    /// The ZigBase OpenAPI document `--backend FILE` named, or `null` when
    /// the run had none. Present on the wire either way rather than omitted,
    /// so a consumer reads one shape whether or not the operator passed the
    /// flag.
    backend: ?Backend,
    /// `isComplete`'s verdict, recomputed by `build` from `routes` -- never
    /// supplied by the caller, so it cannot drift from the rows beside it.
    complete: bool,
    routes: []const RouteEntry,
    assets: []const AssetEntry,
    redirects: []const RedirectEntry,
    /// Always empty in Stage 2 -- Stage 5 fills it.
    parity: []const ParityEntry,
};

/// One route's conversion outcome, as the scaffold reports it.
///
/// `route_index` indexes `BuildInput.discovery.routes` (and, by the
/// index-alignment `rails.Discovery` maintains, `classifications` /
/// `route_templates`) rather than carrying a route id string: an id is a
/// LABEL two identical `routes.rb` declarations share, so a row identified by
/// id could not name WHICH of them it converted. An out-of-range index is a
/// programming error in the caller, not a degradation this file papers over
/// -- it faults on the array access.
pub const RouteRow = struct {
    route_index: usize,
    status: Status,
    /// Emitted sorted; the caller's order is not preserved and not read.
    artifacts: []const []const u8,
    /// #167 Stage 3: the ZigBase operation this route's traffic becomes,
    /// copied straight onto `RouteEntry.endpoint`.
    ///
    /// Deliberately WITHOUT a default. Every other field here is mandatory,
    /// and this one carries the half of the `backend` status that ruling A2
    /// makes load-bearing (`statusAccounted`): a defaulted `null` would let a
    /// producer that forgot to wire its endpoints through compile clean and
    /// report a migration as incomplete for a reason nobody can see.
    endpoint: ?Endpoint,
    decision: ?DecisionRef,
    /// Emitted sorted; the caller's order is not preserved and not read.
    findings: []const []const u8,
    note: ?[]const u8,
};

/// See `AssetEntry` for what each field means. A separate type for the
/// reason the module doc gives: the wire order is a contract, this one is
/// not.
pub const AssetRow = struct {
    source: []const u8,
    rails_url: ?[]const u8,
    target_url: []const u8,
};

/// See `RedirectEntry`. Separate from the wire type for the same reason
/// `AssetRow` is.
pub const Redirect = struct {
    from: []const u8,
    to: ?[]const u8,
};

/// `discovery` supplies the route table `RouteRow.route_index` indexes;
/// `generator_version` is `main.zig`'s build-time version, threaded down the
/// same way `manifest.BuildInput` already threads it (this directory is
/// std-only and cannot reach `build_options` itself).
pub const BuildInput = struct {
    generator_version: []const u8,
    discovery: *const rails.Discovery,
    routes: []const RouteRow,
    assets: []const AssetRow,
    redirects: []const Redirect,
    /// #167 Stage 3: the `--backend` document this run read, or `null` when
    /// the operator passed no `--backend FILE`. Copied verbatim onto
    /// `Handoff.backend`.
    ///
    /// `file` is a BASENAME (`backend.Document.file` already reduces it):
    /// the handoff is a committed artifact and "no absolute paths in any
    /// artifact" is a determinism rule, so the operator's directory layout
    /// must not reach the wire. Defaulted, unlike `RouteRow.endpoint`,
    /// because "this run had no backend document" is the ordinary state of
    /// every caller that predates Stage 3 -- and a wrong `null` here is
    /// visible in one line of the report, not hidden in a status rule.
    backend: ?Backend = null,
    /// Borrowed and never reordered in place; `build` takes a private sorted
    /// copy before serialization.
    parity: []const ParityEntry = &.{},
};

/// The verbs a visitor can reach by following a link -- the ones `complete`
/// is computed over. A `POST`/`PATCH`/`DELETE` route is form/API traffic
/// that Stage 3 handles; leaving it unconverted does not make the site
/// broken to browse, so it never blocks the exit code.
fn isUserFacing(verb: []const u8) bool {
    return std.mem.eql(u8, verb, "GET") or std.mem.eql(u8, verb, "HEAD");
}

/// Whether ONE row counts its route as answered.
///
/// `retained` and `blocked` both require an operator decision -- the spec's
/// own words, "`retained` and `blocked` both require a decision with a
/// rationale". Only `blocked` used to be checked, on the reasoning that
/// `retained` is an outcome the tool sometimes reaches by itself. It is not:
/// `scaffold.applyAcknowledgement` sets `retained` from a `retain` CHOICE and
/// from nothing else. So the unchecked half was not permissive-by-design, it
/// was a rule stated in one place and enforced in the other half only -- and
/// what it would have waved through is the worst kind of gap, since ruling
/// S20 makes a `retained` route write no page at all. A `retained` row with
/// no decision behind it is a URL the migration silently stopped serving.
///
/// `redirect` needs no decision: it IS a conversion outcome the tool reaches
/// on its own (discovery classified the route), and the host config owns the
/// redirect either way.
///
/// `backend` marks a route that needs no PAGE -- a POST/PATCH/DELETE, or a
/// GET that renders JSON. Ruling S11 accounted it unconditionally and said
/// so with a promise: "the still-open half -- WHICH endpoint it maps to --
/// rides on its own `RAILS_BACKEND_ENDPOINT` finding in Stage 3". Stage 3
/// exists, that finding is derived, and ruling A2 is the promise being kept:
/// a `backend` row is accounted iff it was ANSWERED -- bound to an operation
/// (`endpoint`), or acknowledged by a decision (`retain`/`blocked`, or a
/// `public` guard answer) on one of its findings.
///
/// This does NOT restore the over-strictness `isUserFacing` exists to avoid.
/// A POST/PATCH/DELETE route never reaches this function's caller at all, so
/// the only route A2 can bite on is a GET that renders JSON -- exactly the
/// one case where "nobody said what this URL becomes" is a real gap and not
/// a category error. An app whose `/feed` silently vanished from the
/// migration used to report `complete: true`.
///
/// `open` is the only status that is never accounted: it is the literal
/// statement that nothing has answered for this route.
fn statusAccounted(row: RouteRow) bool {
    return switch (row.status) {
        .migrated, .redirect => true,
        .backend => row.endpoint != null or row.decision != null,
        .retained, .blocked => row.decision != null,
        .open => false,
    };
}

/// The spec's completion rule, separately testable so the exit code (`3` when
/// false) has a truth table of its own rather than only being observable
/// through the emitted bytes:
///
///   `complete` iff EVERY route in `discovery.routes` whose verb is GET or
///   HEAD has `status` in {migrated, redirect}, `backend` with a non-null
///   `endpoint` or `decision` (ruling A2), or `retained`/`blocked` with a
///   non-null `decision`.
///
/// A user-facing route with NO row in `rows` counts as `open` -- absence is
/// the unanswered case, not an exemption, which is what stops a scaffold that
/// silently skipped a route from reporting a complete migration.
///
/// Duplicate rows naming the same route must ALL be accounted, not just the
/// first found: a caller that emitted both an answered and an unanswered row
/// for one route has a bug, and letting whichever came first decide would
/// make the verdict depend on `rows` order.
///
/// Contract 3 (caller-buffer): allocates nothing, borrows both arguments.
pub fn isComplete(discovery: *const rails.Discovery, rows: []const RouteRow) bool {
    for (discovery.routes, 0..) |r, i| {
        if (!isUserFacing(r.verb)) continue;
        var answered = false;
        for (rows) |row| {
            if (row.route_index != i) continue;
            if (!statusAccounted(row)) return false;
            answered = true;
        }
        if (!answered) return false;
    }
    return true;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A sorted private copy of `in_slice`, allocated from `scratch`. The copy is
/// the point: the caller's slice is a borrow it still uses (module doc,
/// "Determinism").
fn sortedCopy(scratch: Allocator, in_slice: []const []const u8) Allocator.Error![]const []const u8 {
    const copy = try scratch.dupe([]const u8, in_slice);
    std.mem.sort([]const u8, copy, {}, stringLessThan);
    return copy;
}

/// `source`, then `target_url`, then `rails_url`. The two tiebreaks are not
/// decoration: `source` alone is a PARTIAL order (two asset rows may share a
/// source -- e.g. one entry per URL a fingerprinted asset is reachable at),
/// and an unstable sort would then decide the bytes.
fn assetLessThan(_: void, a: AssetEntry, b: AssetEntry) bool {
    return switch (std.mem.order(u8, a.source, b.source)) {
        .lt => true,
        .gt => false,
        .eq => switch (std.mem.order(u8, a.target_url, b.target_url)) {
            .lt => true,
            .gt => false,
            .eq => report.orderOptionalString(a.rails_url, b.rails_url) == .lt,
        },
    };
}

/// `from`, then `to` -- same total-order obligation `assetLessThan` explains.
/// `report.orderOptionalString` rather than a local null rule, so `null`
/// sorts before every string here exactly as it does everywhere else in this
/// directory.
fn redirectLessThan(_: void, a: RedirectEntry, b: RedirectEntry) bool {
    return switch (std.mem.order(u8, a.from, b.from)) {
        .lt => true,
        .gt => false,
        .eq => report.orderOptionalString(a.to, b.to) == .lt,
    };
}

/// A parity row plus its compact wire bytes. The bytes are the final
/// tiebreaker after `(id, kind, url)`, making the order total even if a buggy
/// caller supplies the same identity with two different expectations.
const ParityPair = struct {
    entry: ParityEntry,
    wire: []const u8,
};

fn requestFieldLessThan(_: void, a: RequestField, b: RequestField) bool {
    const name = std.mem.order(u8, a.name, b.name);
    if (name != .eq) return name == .lt;
    const value = std.mem.order(u8, a.value, b.value);
    if (value != .eq) return value == .lt;
    return report.orderOptionalString(a.invalid_value, b.invalid_value) == .lt;
}

fn sortedFields(scratch: Allocator, fields: []const RequestField) Allocator.Error![]const RequestField {
    const copy = try scratch.dupe(RequestField, fields);
    std.mem.sort(RequestField, copy, {}, requestFieldLessThan);
    return copy;
}

fn u16LessThan(_: void, a: u16, b: u16) bool {
    return a < b;
}

fn sortedStatuses(scratch: Allocator, statuses: []const u16) Allocator.Error![]const u16 {
    const copy = try scratch.dupe(u16, statuses);
    std.mem.sort(u16, copy, {}, u16LessThan);
    return copy;
}

/// Normalize every nested list without reaching through the caller's borrows.
/// This keeps parity bytes independent of both row order and per-row list
/// order; all strings remain borrowed because sorting only moves slice values.
fn normalizedParity(scratch: Allocator, entry: ParityEntry) Allocator.Error!ParityEntry {
    return switch (entry) {
        .navigate => |row| .{ .navigate = .{
            .id = row.id,
            .url = row.url,
            .expect = .{
                .status = row.expect.status,
                .title = row.expect.title,
                .h1 = row.expect.h1,
                .links = try sortedCopy(scratch, row.expect.links),
            },
        } },
        .asset => |row| .{ .asset = row },
        .signup => |row| .{ .signup = row },
        .signin => |row| .{ .signin = row },
        .submit_allowed => |row| .{ .submit_allowed = .{
            .id = row.id,
            .url = row.url,
            .expect = .{
                .status_family = row.expect.status_family,
                .operation_id = row.expect.operation_id,
                .method = row.expect.method,
                .collection = row.expect.collection,
                .page_url = row.expect.page_url,
                .fields = try sortedFields(scratch, row.expect.fields),
            },
        } },
        .submit_denied => |row| .{ .submit_denied = .{
            .id = row.id,
            .url = row.url,
            .expect = .{
                .statuses = try sortedStatuses(scratch, row.expect.statuses),
                .operation_id = row.expect.operation_id,
                .method = row.expect.method,
                .collection = row.expect.collection,
                .fields = try sortedFields(scratch, row.expect.fields),
            },
        } },
        .validation_error => |row| .{ .validation_error = .{
            .id = row.id,
            .url = row.url,
            .expect = .{
                .status = row.expect.status,
                .operation_id = row.expect.operation_id,
                .method = row.expect.method,
                .collection = row.expect.collection,
                .page_url = row.expect.page_url,
                .field = row.expect.field,
                .fields = try sortedFields(scratch, row.expect.fields),
            },
        } },
    };
}

fn parityLessThan(_: void, a: ParityPair, b: ParityPair) bool {
    const id = std.mem.order(u8, a.entry.id(), b.entry.id());
    if (id != .eq) return id == .lt;
    const kind = std.mem.order(u8, @tagName(std.meta.activeTag(a.entry)), @tagName(std.meta.activeTag(b.entry)));
    if (kind != .eq) return kind == .lt;
    const url = std.mem.order(u8, a.entry.url(), b.entry.url());
    if (url != .eq) return url == .lt;
    return std.mem.lessThan(u8, a.wire, b.wire);
}

/// Element-wise lexicographic order over two already-sorted string lists,
/// with the shorter list first on a common prefix -- the ordinary sequence
/// order, spelled out because `std.mem.order` only does it for scalars.
fn orderStringList(a: []const []const u8, b: []const []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const o = std.mem.order(u8, x, y);
        if (o != .eq) return o;
    }
    return std.math.order(a.len, b.len);
}

/// `null` before any value, then field by field in wire order. Mirrors
/// `report.orderOptionalString`'s null rule so every optional in this
/// directory sorts the same way.
fn orderDecision(a: ?DecisionRef, b: ?DecisionRef) std.math.Order {
    const av = a orelse return if (b == null) .eq else .lt;
    const bv = b orelse return .gt;
    const id = std.mem.order(u8, av.id, bv.id);
    if (id != .eq) return id;
    const choice = std.mem.order(u8, av.choice, bv.choice);
    if (choice != .eq) return choice;
    return std.mem.order(u8, av.rationale, bv.rationale);
}

/// Same shape as `orderDecision`, for `RouteEntry.endpoint`. Written in
/// Stage 2 against the day `endpoint` stopped being `null` -- because
/// `entryOrder` below claims to be a TOTAL order over an entry's content, and
/// an omission here would have turned that claim into a partial order, i.e.
/// into nondeterministic bytes, with nothing failing. #167 Stage 3 is that
/// day, and the foresight is now load-bearing: "build: two rows naming the
/// same route are ordered by their endpoint, not by input position" is the
/// test that discriminates it.
fn orderEndpoint(a: ?Endpoint, b: ?Endpoint) std.math.Order {
    const av = a orelse return if (b == null) .eq else .lt;
    const bv = b orelse return .gt;
    const op = std.mem.order(u8, av.operation_id, bv.operation_id);
    if (op != .eq) return op;
    const verb = std.mem.order(u8, av.verb, bv.verb);
    if (verb != .eq) return verb;
    return std.mem.order(u8, av.path, bv.path);
}

/// A total order over everything an entry PRINTS except `route_id`, which is
/// a pure function of the route the caller has already compared. Two entries
/// this returns `.eq` for serialize to identical bytes, so the sort's
/// instability cannot reach the output.
fn entryOrder(a: RouteEntry, b: RouteEntry) std.math.Order {
    // Declaration order of `Status`, which is itself the wire enum order.
    const status = std.math.order(@intFromEnum(a.status), @intFromEnum(b.status));
    if (status != .eq) return status;
    const artifacts = orderStringList(a.artifacts, b.artifacts);
    if (artifacts != .eq) return artifacts;
    const endpoint = orderEndpoint(a.endpoint, b.endpoint);
    if (endpoint != .eq) return endpoint;
    const decision = orderDecision(a.decision, b.decision);
    if (decision != .eq) return decision;
    const found = orderStringList(a.findings, b.findings);
    if (found != .eq) return found;
    return report.orderOptionalString(a.note, b.note);
}

/// One built entry paired with the route it came from, so the route table
/// lookup the comparator needs travels with it -- the same pairing
/// `manifest.zig`'s `RoutePair` uses for its own index-alignment problem.
const RoutePair = struct { route_index: usize, entry: RouteEntry };

/// Sort context for `routes[]`: the route table the pairs index into.
const RowOrder = struct {
    table: []const routes.Route,

    /// `report.routeLessThan` first -- REUSED, not re-derived, for the reason
    /// its own doc gives (that comparator's four-key total order was arrived
    /// at the hard way, and a second hand-rolled version here would be free
    /// to reintroduce the partial-order bug it fixed).
    ///
    /// Two further tiebreaks, because `routeLessThan` is total over what the
    /// MANIFEST renders, not over what this file does: two identical
    /// `routes.rb` declarations tie on all four keys (see `rails.
    /// formatRouteId`'s "not a unique identifier" doc), and two rows may name
    /// the SAME route (one conversion emitting a page and a redirect, say).
    /// `route_index` settles the first; `entryOrder` -- the row's own CONTENT
    /// -- settles the second.
    ///
    /// Content, specifically, and NOT the row's position in the caller's
    /// slice, which is what this comparator used to fall back on. A
    /// positional tiebreak is deterministic given one input order but not
    /// order-INDEPENDENT: permuting two same-route rows moved bytes, breaking
    /// the guarantee this module's own determinism section states. Caught by
    /// review; pinned by "build: two rows naming the SAME route are ordered
    /// by content, not by input position".
    fn lessThan(ctx: RowOrder, a: RoutePair, b: RoutePair) bool {
        const ra = ctx.table[a.route_index];
        const rb = ctx.table[b.route_index];
        if (report.routeLessThan({}, ra, rb)) return true;
        if (report.routeLessThan({}, rb, ra)) return false;
        if (a.route_index != b.route_index) return a.route_index < b.route_index;
        return entryOrder(a.entry, b.entry) == .lt;
    }
};

/// Contract 1 (self-freeing): every intermediate -- the row ordering, the
/// per-route id buffers, the sorted `artifacts`/`findings` copies and the
/// three wire-entry arrays -- is allocated from a private arena over `gpa`
/// that `defer` releases on every path, including the OOM ones; the ONE
/// allocation that escapes is the returned `[]u8`. Same shape as
/// `schema_gen.generate` one layer over. Every string inside those entries is
/// a borrow of the caller's own memory (or of an id buffer the arena owns
/// until this function returns, by which point `std.json.Stringify` has
/// copied it into the result), never a fresh `gpa` allocation needing its own
/// release path.
///
/// `complete` is computed here from `in.routes` rather than accepted as an
/// input -- see `Handoff.complete`.
pub fn build(gpa: Allocator, in: BuildInput) Allocator.Error![]u8 {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    // --- routes[] --------------------------------------------------------
    // Entries are BUILT first and sorted afterwards, rather than sorting the
    // caller's rows and rendering in that order: `RowOrder.lessThan`'s last
    // tiebreak compares the entry's own content (see its doc), which does not
    // exist until the sorted `artifacts`/`findings` copies have been made.
    //
    // One id buffer per row, all released together once `std.json.Stringify`
    // has consumed every `route_id` pointing into them -- a single reused
    // buffer would alias every id onto whatever the LAST route's format call
    // left there (`rails.formatRouteId` borrows `buf`, it does not allocate).
    // Same trap `manifest.build` documents. Indexed by INPUT position, so the
    // sort below moving entries around cannot make two of them share one.
    const id_bufs = try scratch.alloc([rails.route_id_buf_len]u8, in.routes.len);

    const pairs = try scratch.alloc(RoutePair, in.routes.len);
    for (in.routes, 0..) |row, i| {
        pairs[i] = .{
            .route_index = row.route_index,
            .entry = .{
                .route_id = rails.formatRouteId(&id_bufs[i], in.discovery.routes[row.route_index]),
                .status = row.status,
                .artifacts = try sortedCopy(scratch, row.artifacts),
                .endpoint = row.endpoint,
                .decision = row.decision,
                .findings = try sortedCopy(scratch, row.findings),
                .note = row.note,
            },
        };
    }
    std.mem.sort(RoutePair, pairs, RowOrder{ .table = in.discovery.routes }, RowOrder.lessThan);

    const route_entries = try scratch.alloc(RouteEntry, pairs.len);
    for (pairs, 0..) |p, i| route_entries[i] = p.entry;

    // --- assets[] --------------------------------------------------------
    const asset_entries = try scratch.alloc(AssetEntry, in.assets.len);
    for (in.assets, 0..) |a, i| {
        asset_entries[i] = .{ .source = a.source, .rails_url = a.rails_url, .target_url = a.target_url };
    }
    std.mem.sort(AssetEntry, asset_entries, {}, assetLessThan);

    // --- redirects[] -----------------------------------------------------
    const redirect_entries = try scratch.alloc(RedirectEntry, in.redirects.len);
    for (in.redirects, 0..) |r, i| {
        redirect_entries[i] = .{ .from = r.from, .to = r.to };
    }
    std.mem.sort(RedirectEntry, redirect_entries, {}, redirectLessThan);

    // --- parity[] --------------------------------------------------------
    // Serialize once into the private arena to obtain a total content
    // tiebreak without writing a second hand-maintained expectation
    // comparator. The final Handoff serialization still writes the typed
    // entries, so these bytes are scratch only.
    const parity_pairs = try scratch.alloc(ParityPair, in.parity.len);
    for (in.parity, 0..) |entry, i| {
        const normalized = try normalizedParity(scratch, entry);
        parity_pairs[i] = .{
            .entry = normalized,
            .wire = try std.json.Stringify.valueAlloc(scratch, normalized, .{}),
        };
    }
    std.mem.sort(ParityPair, parity_pairs, {}, parityLessThan);
    const parity_entries = try scratch.alloc(ParityEntry, parity_pairs.len);
    for (parity_pairs, 0..) |pair, i| parity_entries[i] = pair.entry;

    const value: Handoff = .{
        .generator = .{ .version = in.generator_version },
        .backend = in.backend,
        .complete = isComplete(in.discovery, in.routes),
        .routes = route_entries,
        .assets = asset_entries,
        .redirects = redirect_entries,
        .parity = parity_entries,
    };

    var out = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    errdefer gpa.free(out);
    // Trailing newline, matching `manifest.build` and every other committed
    // JSON artifact in this repo -- what keeps a plain `git diff` on the
    // written file free of a "no newline at end of file" marker.
    out = try gpa.realloc(out, out.len + 1);
    out[out.len - 1] = '\n';
    return out;
}

const testing = std.testing;

fn testRoute(verb: []const u8, path: []const u8, controller: ?[]const u8, action: ?[]const u8) routes.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = controller,
        .action = action,
        .name = null,
        .certain = true,
        .origin = .static_ast,
    };
}

fn emptyDiscovery() rails.Discovery {
    return .{
        .report = "",
        .integrity_blocker_count = 0,
        .route_count = 0,
        .route_mode = "none",
        .route_blocker = false,
        .severity_error_count = 0,
        .severity_warn_count = 0,
        .ruby = .{ .available = false },
        .route_templates = &.{},
        .templates = &.{},
        .assets = &.{},
        .version = .{},
        .routes = &.{},
        .classifications = &.{},
        .integrations = &.{},
        .blockers = &.{},
        .fragments = &.{},
        .findings = &.{},
        .i18n_locale = null,
        .decisions = .empty,
        // #167 Stage 3: inputs to the backend boundary, not to this emitter.
        .actions = &.{},
        .before_actions = &.{},
        .skip_before_actions = &.{},
        .parents = &.{},
    };
}

/// `rails.Discovery.routes` is `[]routes.Route` (owned+freed by `discover`),
/// so these read-only fixtures hand it a mutable slice of a local/container
/// `var` array -- the same shape `manifest.zig`'s own tests use.
fn discoveryWith(rs: []routes.Route) rails.Discovery {
    var d = emptyDiscovery();
    d.routes = rs;
    d.route_count = rs.len;
    return d;
}

const golden_two_route =
    \\{
    \\  "schema": "zigapagos.rails-handoff/1",
    \\  "schema_version": 1,
    \\  "generator": {
    \\    "tool": "zigapagos",
    \\    "version": "0.0.0-test"
    \\  },
    \\  "backend": null,
    \\  "complete": true,
    \\  "routes": [
    \\    {
    \\      "route_id": "GET /about",
    \\      "status": "migrated",
    \\      "artifacts": [
    \\        "content/about/index.smd",
    \\        "layouts/pages/about.shtml"
    \\      ],
    \\      "endpoint": null,
    \\      "decision": null,
    \\      "findings": [],
    \\      "note": null
    \\    },
    \\    {
    \\      "route_id": "GET /posts",
    \\      "status": "blocked",
    \\      "artifacts": [],
    \\      "endpoint": null,
    \\      "decision": {
    \\        "id": "F1",
    \\        "choice": "blocked",
    \\        "rationale": "needs a backend"
    \\      },
    \\      "findings": [
    \\        "Fa",
    \\        "Fb"
    \\      ],
    \\      "note": "deferred to Stage 3/4"
    \\    }
    \\  ],
    \\  "assets": [
    \\    {
    \\      "source": "app/assets/images/logo.png",
    \\      "rails_url": "/assets/logo-abc.png",
    \\      "target_url": "/images/logo.png"
    \\    },
    \\    {
    \\      "source": "public/robots.txt",
    \\      "rails_url": null,
    \\      "target_url": "/robots.txt"
    \\    }
    \\  ],
    \\  "redirects": [
    \\    {
    \\      "from": "/legacy",
    \\      "to": null
    \\    },
    \\    {
    \\      "from": "/old",
    \\      "to": "/about"
    \\    }
    \\  ],
    \\  "parity": []
    \\}
    \\
;

var golden_routes = [_]routes.Route{
    testRoute("GET", "/about", "pages", "about"),
    testRoute("GET", "/posts", "posts", "index"),
};

/// The two-route fixture the byte-level tests share. Deliberately supplied
/// in the WRONG order on every axis -- rows reversed, artifacts reversed,
/// findings reversed, assets reversed, redirects reversed -- so a `build`
/// that emitted its input verbatim could not produce the golden.
fn goldenInput(d: *const rails.Discovery) BuildInput {
    return .{
        .generator_version = "0.0.0-test",
        .discovery = d,
        .routes = &.{
            .{
                .route_index = 1,
                .status = .blocked,
                .artifacts = &.{},
                .endpoint = null,
                .decision = .{ .id = "F1", .choice = "blocked", .rationale = "needs a backend" },
                .findings = &.{ "Fb", "Fa" },
                .note = "deferred to Stage 3/4",
            },
            .{
                .route_index = 0,
                .status = .migrated,
                .artifacts = &.{ "layouts/pages/about.shtml", "content/about/index.smd" },
                .endpoint = null,
                .decision = null,
                .findings = &.{},
                .note = null,
            },
        },
        .assets = &.{
            .{ .source = "public/robots.txt", .rails_url = null, .target_url = "/robots.txt" },
            .{ .source = "app/assets/images/logo.png", .rails_url = "/assets/logo-abc.png", .target_url = "/images/logo.png" },
        },
        .redirects = &.{
            .{ .from = "/old", .to = "/about" },
            .{ .from = "/legacy", .to = null },
        },
    };
}

test "build: a two-route handoff is EXACTLY these bytes" {
    // Golden bytes, authored from the spec's wire shape (docs/superpowers/
    // specs/2026-08-29-rails-presentation-migration-design.md, "Findings,
    // decisions, handoff") rather than pasted from a run: field ORDER is
    // the contract here, and a golden copied out of the implementation
    // pins whatever the implementation happened to do.
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_routes);
    const out = try build(gpa, goldenInput(&d));
    defer gpa.free(out);
    try testing.expectEqualStrings(golden_two_route, out);
}

/// #167 Stage 3. The other half of `golden_two_route`: that one pins the
/// shape of a document with no `--backend` and no bound route (`"backend":
/// null`, `"endpoint": null`), this one pins the shape when both are present.
/// Authored from the spec's wire example, not pasted from a run.
const golden_backend_bound =
    \\{
    \\  "schema": "zigapagos.rails-handoff/1",
    \\  "schema_version": 1,
    \\  "generator": {
    \\    "tool": "zigapagos",
    \\    "version": "0.0.0-test"
    \\  },
    \\  "backend": {
    \\    "file": "openapi.json",
    \\    "contract_version": "2026-06-27.1"
    \\  },
    \\  "complete": true,
    \\  "routes": [
    \\    {
    \\      "route_id": "GET /feed",
    \\      "status": "backend",
    \\      "artifacts": [],
    \\      "endpoint": {
    \\        "operation_id": "listPosts",
    \\        "verb": "GET",
    \\        "path": "/api/collections/posts/records"
    \\      },
    \\      "decision": {
    \\        "id": "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L9.GET.posts",
    \\        "choice": "listPosts",
    \\        "rationale": "the feed is the posts list"
    \\      },
    \\      "findings": [],
    \\      "note": null
    \\    },
    \\    {
    \\      "route_id": "POST /registration",
    \\      "status": "backend",
    \\      "artifacts": [],
    \\      "endpoint": {
    \\        "operation_id": "createUsers",
    \\        "verb": "POST",
    \\        "path": "/api/collections/users/records"
    \\      },
    \\      "decision": null,
    \\      "findings": [],
    \\      "note": null
    \\    }
    \\  ],
    \\  "assets": [],
    \\  "redirects": [],
    \\  "parity": []
    \\}
    \\
;

var golden_backend_routes = [_]routes.Route{
    testRoute("GET", "/feed", "posts", "feed"),
    testRoute("POST", "/registration", "registrations", "create"),
};

test "build: a --backend document and a bound endpoint are EXACTLY these bytes" {
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_backend_routes);
    const out = try build(gpa, .{
        .generator_version = "0.0.0-test",
        .discovery = &d,
        // Reversed, like `goldenInput`: a `build` that emitted its input
        // verbatim could not produce the golden.
        .routes = &.{
            .{
                .route_index = 1,
                .status = .backend,
                .artifacts = &.{},
                .endpoint = .{ .operation_id = "createUsers", .verb = "POST", .path = "/api/collections/users/records" },
                .decision = null,
                .findings = &.{},
                .note = null,
            },
            .{
                .route_index = 0,
                .status = .backend,
                .artifacts = &.{},
                .endpoint = .{ .operation_id = "listPosts", .verb = "GET", .path = "/api/collections/posts/records" },
                .decision = .{
                    .id = "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L9.GET.posts",
                    .choice = "listPosts",
                    .rationale = "the feed is the posts list",
                },
                .findings = &.{},
                .note = null,
            },
        },
        .assets = &.{},
        .redirects = &.{},
        .backend = .{ .file = "openapi.json", .contract_version = "2026-06-27.1" },
    });
    defer gpa.free(out);
    try testing.expectEqualStrings(golden_backend_bound, out);
}

test "build: a GET backend route nobody bound leaves the run incomplete (A2)" {
    // The byte-level half of the truth table's A2 rows: the SAME fixture as
    // the golden above with both routes' endpoints and decisions removed.
    // Ruling S11 used to make this `complete: true`.
    //
    // Two runs differing in ONE field, because the interesting claim is not
    // "false" on its own -- it is that the false verdict is the GET route's
    // doing and NOT "any unbound `backend` row". Run 2 flips only the GET to
    // `migrated`, leaving the POST an unbound `backend` row exactly as it
    // was, and gets `complete: true`. An `isUserFacing` that had stopped
    // exempting non-GET verbs would fail run 2 while run 1 stayed green.
    //
    // (This pair replaces an assertion that read the TOP-LEVEL `backend`
    // field as null -- true, but a statement about this run having no
    // `--backend` document, not about the POST row's exemption it claimed to
    // prove. Review finding M-1.)
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_backend_routes);

    const unbound_get: RouteRow = .{
        .route_index = 0,
        .status = .backend,
        .artifacts = &.{},
        .endpoint = null,
        .decision = null,
        .findings = &.{"RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L9.GET.posts"},
        .note = null,
    };
    const unbound_post: RouteRow = .{
        .route_index = 1,
        .status = .backend,
        .artifacts = &.{},
        .endpoint = null,
        .decision = null,
        .findings = &.{},
        .note = null,
    };

    const both_unbound = [_]RouteRow{ unbound_get, unbound_post };
    try testing.expect(!try completeWithPostStillUnbound(gpa, &d, &both_unbound));

    var migrated_get = unbound_get;
    migrated_get.status = .migrated;
    migrated_get.findings = &.{};
    const get_answered = [_]RouteRow{ migrated_get, unbound_post };
    try testing.expect(try completeWithPostStillUnbound(gpa, &d, &get_answered));
}

/// Builds `rows` and returns the document's `complete`, having first checked
/// that `POST /registration` is STILL an unbound `backend` row. That check is
/// the control for the test above: without it, run 2's `true` could be
/// explained by the fixture having quietly changed underneath rather than by
/// the non-GET exemption doing its job.
fn completeWithPostStillUnbound(
    gpa: Allocator,
    d: *const rails.Discovery,
    rows: []const RouteRow,
) !bool {
    const out = try build(gpa, .{
        .generator_version = "0.0.0-test",
        .discovery = d,
        .routes = rows,
        .assets = &.{},
        .redirects = &.{},
    });
    defer gpa.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const post = for (parsed.value.object.get("routes").?.array.items) |r| {
        if (std.mem.eql(u8, r.object.get("route_id").?.string, "POST /registration")) break r;
    } else return error.PostRouteMissing;
    try testing.expectEqualStrings("backend", post.object.get("status").?.string);
    try testing.expect(post.object.get("endpoint").? == .null);
    try testing.expect(post.object.get("decision").? == .null);
    return parsed.value.object.get("complete").?.bool;
}

test "build: two rows naming the same route are ordered by their endpoint, not by input position" {
    // `entryOrder` calls `orderEndpoint`, which could not discriminate
    // anything while every entry's endpoint was null (see its own doc). Now
    // that Stage 3 fills it, this is the test that keeps that claim true:
    // two rows for ONE route differing in NOTHING but the endpoint must
    // serialize identically whichever order the caller assembled them in.
    const gpa = testing.allocator;
    var rs = [_]routes.Route{testRoute("POST", "/session", "sessions", "create")};
    const d = discoveryWith(&rs);
    const a: RouteRow = .{
        .route_index = 0,
        .status = .backend,
        .artifacts = &.{},
        .endpoint = .{ .operation_id = "authWithPassword", .verb = "POST", .path = "/api/collections/users/auth-with-password" },
        .decision = null,
        .findings = &.{},
        .note = null,
    };
    var b = a;
    b.endpoint = .{ .operation_id = "createUsers", .verb = "POST", .path = "/api/collections/users/records" };

    const forward = [_]RouteRow{ a, b };
    const backward = [_]RouteRow{ b, a };
    const one = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &forward, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(one);
    const two = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &backward, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(two);
    try testing.expectEqualStrings(one, two);
    // Sorted by `operation_id`, so `authWithPassword` comes first in both.
    const at = std.mem.indexOf(u8, one, "authWithPassword").?;
    const ct = std.mem.indexOf(u8, one, "createUsers").?;
    try testing.expect(at < ct);
}

test "build: output ends in exactly one newline" {
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_routes);
    const out = try build(gpa, goldenInput(&d));
    defer gpa.free(out);
    try testing.expect(out.len >= 2);
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
    try testing.expect(out[out.len - 2] != '\n');
}

test "build: identical content in a DIFFERENT input order produces identical bytes" {
    // Determinism is the property `MIGRATION.handoff.json` is diffed under
    // (Task 7's re-run loop `cmp`s two runs): the same facts fed in a
    // different order must not move a single byte. Rows, artifacts,
    // findings, assets and redirects are all permuted relative to
    // `goldenInput` -- so this fails for a `build` that sorts only some.
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_routes);

    const a = try build(gpa, goldenInput(&d));
    defer gpa.free(a);

    const permuted: BuildInput = .{
        .generator_version = "0.0.0-test",
        .discovery = &d,
        .routes = &.{
            .{
                .route_index = 0,
                .status = .migrated,
                .artifacts = &.{ "content/about/index.smd", "layouts/pages/about.shtml" },
                .endpoint = null,
                .decision = null,
                .findings = &.{},
                .note = null,
            },
            .{
                .route_index = 1,
                .status = .blocked,
                .artifacts = &.{},
                .endpoint = null,
                .decision = .{ .id = "F1", .choice = "blocked", .rationale = "needs a backend" },
                .findings = &.{ "Fa", "Fb" },
                .note = "deferred to Stage 3/4",
            },
        },
        .assets = &.{
            .{ .source = "app/assets/images/logo.png", .rails_url = "/assets/logo-abc.png", .target_url = "/images/logo.png" },
            .{ .source = "public/robots.txt", .rails_url = null, .target_url = "/robots.txt" },
        },
        .redirects = &.{
            .{ .from = "/legacy", .to = null },
            .{ .from = "/old", .to = "/about" },
        },
    };
    const b = try build(gpa, permuted);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "build: two builds of the same input are byte-identical" {
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_routes);
    const a = try build(gpa, goldenInput(&d));
    defer gpa.free(a);
    const b = try build(gpa, goldenInput(&d));
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "build: an empty run still emits a well-formed, complete handoff" {
    const gpa = testing.allocator;
    const d = emptyDiscovery();
    const out = try build(gpa, .{
        .generator_version = "0.0.0-test",
        .discovery = &d,
        .routes = &.{},
        .assets = &.{},
        .redirects = &.{},
    });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(schema_id, parsed.value.object.get("schema").?.string);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    // No user-facing route to leave unanswered: vacuously complete.
    try testing.expect(parsed.value.object.get("complete").?.bool);
    try testing.expect(parsed.value.object.get("backend").? == .null);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("parity").?.array.items.len);
}

test "build: complete is recomputed from the rows, never taken from the caller" {
    // The golden fixture with the blocked route's decision removed: the
    // only thing that changes is the verdict.
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_routes);
    var in = goldenInput(&d);
    var rows = [_]RouteRow{ in.routes[0], in.routes[1] };
    rows[0].decision = null;
    in.routes = &rows;
    const out = try build(gpa, in);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.get("complete").?.bool);
}

test "isComplete: the truth table" {
    // Every row of the spec's rule, one case each. The non-GET/HEAD cases
    // are the ones a naive "every route must be migrated" implementation
    // gets wrong.
    const Case = struct { name: []const u8, verb: []const u8, row: ?RouteRow, want: bool };
    const decided: DecisionRef = .{ .id = "F1", .choice = "blocked", .rationale = "why" };
    const base: RouteRow = .{ .route_index = 0, .status = .open, .artifacts = &.{}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };

    var cases = [_]Case{
        .{ .name = "GET migrated", .verb = "GET", .row = base, .want = true },
        .{ .name = "GET retained WITH a decision", .verb = "GET", .row = base, .want = true },
        // The spec's own parenthetical: "`retained` and `blocked` both
        // require a decision with a rationale". A `retained` row is the claim
        // that an OPERATOR chose to leave this URL on Rails, and the target
        // deliberately serves nothing for it (ruling S20) -- so a `retained`
        // row nobody answered is a route the migration dropped silently, not
        // one it accounted for.
        .{ .name = "GET retained WITHOUT a decision", .verb = "GET", .row = base, .want = false },
        .{ .name = "GET redirect", .verb = "GET", .row = base, .want = true },
        .{ .name = "GET blocked WITH a decision", .verb = "GET", .row = base, .want = true },
        .{ .name = "GET blocked WITHOUT a decision", .verb = "GET", .row = base, .want = false },
        .{ .name = "GET open", .verb = "GET", .row = base, .want = false },
        .{ .name = "GET backend WITH a decision", .verb = "GET", .row = base, .want = true },
        .{ .name = "GET backend with NEITHER an endpoint nor a decision", .verb = "GET", .row = base, .want = false },
        .{ .name = "GET with no row at all", .verb = "GET", .row = null, .want = false },
        .{ .name = "HEAD open (HEAD is user-facing too)", .verb = "HEAD", .row = base, .want = false },
        .{ .name = "POST open (never counts)", .verb = "POST", .row = base, .want = true },
        .{ .name = "POST with no row at all", .verb = "POST", .row = null, .want = true },
        .{ .name = "DELETE with no row at all", .verb = "DELETE", .row = null, .want = true },
        // #167 Stage 3, ruling A2 -- the two rows S11 deferred to this stage.
        .{ .name = "GET backend WITH an endpoint", .verb = "GET", .row = base, .want = true },
        .{ .name = "GET backend WITH both an endpoint and a decision", .verb = "GET", .row = base, .want = true },
    };
    cases[0].row.?.status = .migrated;
    cases[1].row.?.status = .retained;
    cases[1].row.?.decision = decided;
    cases[2].row.?.status = .retained;
    cases[3].row.?.status = .redirect;
    cases[4].row.?.status = .blocked;
    cases[4].row.?.decision = decided;
    cases[5].row.?.status = .blocked;
    cases[7].row.?.status = .backend;
    cases[7].row.?.decision = decided;
    // Ruling A2 (#167 Stage 3) amends ruling S11. S11 made `backend`
    // accounted unconditionally, with a note that Stage 3's endpoint mapping
    // would reopen it -- this is that reopening. A `backend` route is
    // accounted iff it was ANSWERED: bound to an operation (`endpoint`), or
    // acknowledged (`decision`, i.e. `retain`/`blocked`/`public` on one of
    // its findings). A GET that renders JSON and that nobody has bound is
    // now `open` again, which is the only case A2 can bite on -- a non-GET
    // route never reaches `isComplete`'s count at all (`isUserFacing`).
    cases[8].row.?.status = .backend;
    cases[14].row.?.status = .backend;
    cases[14].row.?.endpoint = .{ .operation_id = "listPosts", .verb = "GET", .path = "/api/collections/posts/records" };
    cases[15].row.?.status = .backend;
    cases[15].row.?.endpoint = .{ .operation_id = "listPosts", .verb = "GET", .path = "/api/collections/posts/records" };
    cases[15].row.?.decision = decided;

    for (cases) |c| {
        var rs = [_]routes.Route{testRoute(c.verb, "/x", "x", "show")};
        const d = discoveryWith(&rs);
        var one: [1]RouteRow = undefined;
        var rows: []const RouteRow = &.{};
        if (c.row) |r| {
            one[0] = r;
            rows = one[0..1];
        }
        const got = isComplete(&d, rows);
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("isComplete case '{s}': want {}, got {}\n", .{ c.name, c.want, got });
            return err;
        };
    }
}

test "isComplete: one unanswered GET among answered ones is enough to be incomplete" {
    var rs = [_]routes.Route{
        testRoute("GET", "/a", "p", "a"),
        testRoute("GET", "/b", "p", "b"),
        testRoute("GET", "/c", "p", "c"),
    };
    const d = discoveryWith(&rs);
    const ok: RouteRow = .{ .route_index = 0, .status = .migrated, .artifacts = &.{}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    var rows = [_]RouteRow{ ok, ok, ok };
    rows[1].route_index = 1;
    rows[2].route_index = 2;
    try testing.expect(isComplete(&d, &rows));

    // Drop the middle route's row: it is `open` by absence.
    const missing = [_]RouteRow{ rows[0], rows[2] };
    try testing.expect(!isComplete(&d, &missing));
}

test "isComplete: a duplicate row cannot launder an unanswered route" {
    // Two rows naming the SAME route, one answered and one not. Order must
    // not decide the verdict -- both orders are incomplete.
    var rs = [_]routes.Route{testRoute("GET", "/a", "p", "a")};
    const d = discoveryWith(&rs);
    const good: RouteRow = .{ .route_index = 0, .status = .migrated, .artifacts = &.{}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    const bad: RouteRow = .{ .route_index = 0, .status = .open, .artifacts = &.{}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    const forward = [_]RouteRow{ good, bad };
    const backward = [_]RouteRow{ bad, good };
    try testing.expect(!isComplete(&d, &forward));
    try testing.expect(!isComplete(&d, &backward));
}

test "build: two routes tying on (path, verb, controller, action) still sort deterministically" {
    // `report.routeLessThan`'s four keys tie for two IDENTICAL route
    // declarations -- an ordinary occurrence in routes.rb (see `rails.
    // formatRouteId`'s "not a unique identifier" doc). Without a further
    // tiebreak the comparator is a partial order and std.mem.sort's
    // instability decides the bytes.
    const gpa = testing.allocator;
    var rs = [_]routes.Route{
        testRoute("GET", "/dup", "p", "d"),
        testRoute("GET", "/dup", "p", "d"),
    };
    const d = discoveryWith(&rs);
    const first: RouteRow = .{ .route_index = 0, .status = .migrated, .artifacts = &.{"first"}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    const second: RouteRow = .{ .route_index = 1, .status = .migrated, .artifacts = &.{"second"}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    const forward = [_]RouteRow{ first, second };
    const backward = [_]RouteRow{ second, first };

    const a = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &forward, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(a);
    const b = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &backward, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
    // And the lower route_index wins, rather than input order.
    try testing.expect(std.mem.indexOf(u8, a, "first").? < std.mem.indexOf(u8, a, "second").?);
}

test "build: two rows naming the SAME route are ordered by content, not by input position" {
    // Reviewer's Minor + the defect it exposes: `report.routeLessThan` ties
    // for two rows sharing a `route_index` (the same route converted into
    // more than one outcome -- a scaffold that emits a page AND a redirect,
    // say), and a tiebreak on the row's POSITION in the caller's slice is
    // deterministic-given-an-order but not order-INDEPENDENT: permuting the
    // input would move bytes, which is exactly what this module's own
    // determinism claim forbids. Only a comparison over the rows' CONTENT
    // closes it.
    const gpa = testing.allocator;
    var rs = [_]routes.Route{testRoute("GET", "/dup", "p", "d")};
    const d = discoveryWith(&rs);
    const first: RouteRow = .{ .route_index = 0, .status = .migrated, .artifacts = &.{"content/dup/index.smd"}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    const second: RouteRow = .{ .route_index = 0, .status = .redirect, .artifacts = &.{"redirects.conf"}, .endpoint = null, .decision = null, .findings = &.{}, .note = "host config" };
    const forward = [_]RouteRow{ first, second };
    const backward = [_]RouteRow{ second, first };

    const a = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &forward, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(a);
    const b = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &backward, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);

    // Both rows survive -- the fix must not be "deduplicate them away".
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, a, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("routes").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("GET /dup", items[0].object.get("route_id").?.string);
    try testing.expectEqualStrings("GET /dup", items[1].object.get("route_id").?.string);
    // `migrated` sorts before `redirect` in `Status`'s declaration order, so
    // content order -- not input order -- decides which comes first.
    try testing.expectEqualStrings("migrated", items[0].object.get("status").?.string);
    try testing.expectEqualStrings("redirect", items[1].object.get("status").?.string);
}

test "build: assets tying on source, and redirects tying on from, still sort deterministically" {
    const gpa = testing.allocator;
    const d = emptyDiscovery();
    const a1: AssetRow = .{ .source = "s", .rails_url = null, .target_url = "/a" };
    const a2: AssetRow = .{ .source = "s", .rails_url = "/r", .target_url = "/b" };
    const r1: Redirect = .{ .from = "/f", .to = null };
    const r2: Redirect = .{ .from = "/f", .to = "/t" };
    const av = [_]AssetRow{ a1, a2 };
    const av_rev = [_]AssetRow{ a2, a1 };
    const rv = [_]Redirect{ r1, r2 };
    const rv_rev = [_]Redirect{ r2, r1 };

    const a = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &.{}, .assets = &av, .redirects = &rv });
    defer gpa.free(a);
    const b = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &.{}, .assets = &av_rev, .redirects = &rv_rev });
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "build: every route_id is its OWN route, not the last one formatted" {
    // The per-route id-buffer trap `manifest.build` documents: one reused
    // buffer aliases every id onto the last route formatted.
    const gpa = testing.allocator;
    var rs = [_]routes.Route{
        testRoute("GET", "/alpha", "p", "a"),
        testRoute("GET", "/beta", "p", "b"),
        testRoute("GET", "/gamma", "p", "c"),
    };
    const d = discoveryWith(&rs);
    const base: RouteRow = .{ .route_index = 0, .status = .migrated, .artifacts = &.{}, .endpoint = null, .decision = null, .findings = &.{}, .note = null };
    var rows = [_]RouteRow{ base, base, base };
    rows[1].route_index = 1;
    rows[2].route_index = 2;
    const out = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &rows, .assets = &.{}, .redirects = &.{} });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("routes").?.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("GET /alpha", items[0].object.get("route_id").?.string);
    try testing.expectEqualStrings("GET /beta", items[1].object.get("route_id").?.string);
    try testing.expectEqualStrings("GET /gamma", items[2].object.get("route_id").?.string);
}

test "build: the caller's own slices are never reordered in place" {
    // `build` sorts, and its inputs are borrowed const slices the caller
    // may still be using (Task 6 renders the report from the same rows). A
    // sort that reached through the borrow would corrupt them.
    const gpa = testing.allocator;
    const d = discoveryWith(&golden_routes);
    var artifacts = [_][]const u8{ "z", "a" };
    var rows = [_]RouteRow{.{
        .route_index = 0,
        .status = .migrated,
        .artifacts = &artifacts,
        .endpoint = null,
        .decision = null,
        .findings = &.{},
        .note = null,
    }};
    var assets_in = [_]AssetRow{
        .{ .source = "z", .rails_url = null, .target_url = "/z" },
        .{ .source = "a", .rails_url = null, .target_url = "/a" },
    };
    const out = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &rows, .assets = &assets_in, .redirects = &.{} });
    defer gpa.free(out);
    try testing.expectEqualStrings("z", artifacts[0]);
    try testing.expectEqualStrings("a", artifacts[1]);
    try testing.expectEqualStrings("z", assets_in[0].source);
    try testing.expectEqualStrings("a", assets_in[1].source);
}

test "build under a FailingAllocator leaks nothing on any partial allocation" {
    const d = discoveryWith(&golden_routes);
    const in = goldenInput(&d);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (build(gpa, in)) |out| {
            gpa.free(out);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "build: parity is typed, flattened, and sorted by stable wire identity" {
    const gpa = testing.allocator;
    const d = emptyDiscovery();
    var links = [_][]const u8{ "/posts", "/" };
    const rows = [_]ParityEntry{
        .{ .asset = .{ .id = "parity:z", .url = "/z.css", .expect = .{ .status = 200, .content_type = "text/css", .rails_url = "/assets/z.css" } } },
        .{ .navigate = .{ .id = "parity:a", .url = "/a", .expect = .{ .status = 200, .title = "A", .h1 = null, .links = &links } } },
    };
    const out = try build(gpa, .{
        .generator_version = "v",
        .discovery = &d,
        .routes = &.{},
        .assets = &.{},
        .redirects = &.{},
        .parity = &rows,
    });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const parity = parsed.value.object.get("parity").?.array.items;
    try testing.expectEqual(@as(usize, 2), parity.len);
    try testing.expectEqualStrings("parity:a", parity[0].object.get("id").?.string);
    try testing.expectEqualStrings("navigate", parity[0].object.get("kind").?.string);
    try testing.expectEqualStrings("/a", parity[0].object.get("url").?.string);
    try testing.expectEqual(@as(i64, 200), parity[0].object.get("expect").?.object.get("status").?.integer);
    try testing.expectEqualStrings("/", parity[0].object.get("expect").?.object.get("links").?.array.items[0].string);
    try testing.expectEqualStrings("/posts", links[0]);
    try testing.expect(parity[0].object.get("navigate") == null);
    try testing.expectEqualStrings("parity:z", parity[1].object.get("id").?.string);
}

test "build: parity expectation bytes break identity ties without mutating the caller" {
    const gpa = testing.allocator;
    const d = emptyDiscovery();
    const a: ParityEntry = .{ .navigate = .{ .id = "same", .url = "/", .expect = .{ .status = 200, .title = "A", .h1 = null, .links = &.{} } } };
    const b: ParityEntry = .{ .navigate = .{ .id = "same", .url = "/", .expect = .{ .status = 200, .title = "B", .h1 = null, .links = &.{} } } };
    var forward = [_]ParityEntry{ a, b };
    const backward = [_]ParityEntry{ b, a };
    const out_a = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &.{}, .assets = &.{}, .redirects = &.{}, .parity = &forward });
    defer gpa.free(out_a);
    const out_b = try build(gpa, .{ .generator_version = "v", .discovery = &d, .routes = &.{}, .assets = &.{}, .redirects = &.{}, .parity = &backward });
    defer gpa.free(out_b);
    try testing.expectEqualStrings(out_a, out_b);
    try testing.expectEqualStrings("A", switch (forward[0]) {
        .navigate => |row| row.expect.title.?,
        else => unreachable,
    });
    try testing.expectEqualStrings("B", switch (forward[1]) {
        .navigate => |row| row.expect.title.?,
        else => unreachable,
    });
}

test "build: populated parity path is leak-free under every allocation failure" {
    const d = emptyDiscovery();
    const parity = [_]ParityEntry{.{ .submit_denied = .{
        .id = "submit_denied:createPosts",
        .url = "/api/collections/posts/records",
        .expect = .{
            .statuses = &.{ 401, 403 },
            .operation_id = "createPosts",
            .method = "POST",
            .collection = "posts",
            .fields = &.{.{ .name = "title", .value = "zigapagos parity", .invalid_value = "" }},
        },
    } }};
    const in: BuildInput = .{ .generator_version = "v", .discovery = &d, .routes = &.{}, .assets = &.{}, .redirects = &.{}, .parity = &parity };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 1000) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        if (build(gpa, in)) |out| {
            gpa.free(out);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}
