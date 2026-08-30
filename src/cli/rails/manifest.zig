//! Stage 4 Task 8: the manifest emitter. Turns a `rails.Discovery` into the
//! bytes of `zigapagos.rails-presentation/1` JSON, per
//! `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`'s
//! "The manifest" section, which is the binding shape.
//!
//! **The types below ARE the schema**, not a description of it. Task 9's
//! schema generator reads these structs (field names, field TYPES, and
//! field DECLARATION ORDER) rather than a hand-maintained parallel document,
//! so a struct edit here is a schema edit -- there is no second place that
//! needs to agree.
//!
//! ## Key ordering is the wire contract, not a readability choice
//!
//! `write` below serializes every struct through `std.json.Stringify`,
//! which (per its own doc) renders "JSON object with each field in
//! declaration order" -- so the ONLY thing that determines a JSON object's
//! key order in the emitted manifest is the order fields are WRITTEN in
//! this file. That is deliberate, not incidental: reordering a struct's
//! fields for cosmetic reasons changes the manifest's committed bytes, and
//! Task 9's drift gate (`git diff --exit-code` over a regenerated fixture
//! manifest) will report that reorder as drift -- correctly, since it IS a
//! wire-format change, not a no-op refactor. Every struct below is
//! commented "field order is the wire contract" at the point a future
//! editor is most likely to reorder it (never sort/reformat these fields
//! automatically). `manifestGoldenBytes` (this file's tests) additionally
//! pins one full manifest's exact bytes -- not just field presence -- as a
//! belt-and-suspenders canary: a silent reorder fails that test even before
//! it ever reaches the drift gate.
//!
//! ## Four things this format does NOT claim (read before consuming)
//!
//! 1. **`routes[].id` is not a unique key.** It is `verb`+' '+`path`
//!    (`rails.formatRouteId`, reused here rather than reimplemented -- see
//!    that function's own doc for why two construction sites would drift).
//!    Two identical route DECLARATIONS in `config/routes.rb` (an ordinary,
//!    if unusual, occurrence the parser does not reject) produce the same
//!    `id`. Do not join on it expecting uniqueness.
//! 2. **A blocker's `route_id` names ONE affected route, not every affected
//!    route.** `RAILS_TEMPLATE_UNREADABLE` is deduped per FILE (see
//!    `rails.zig`'s `transitiveScan` doc): a layout shared by twenty routes
//!    yields one blocker, carrying whichever route's scan happened to hit
//!    the unreadable file first. A consumer must not treat that field as
//!    exhaustive and "fix" only the named route while the other nineteen
//!    stay broken.
//! 3. **`templates[].renders == []` ordinarily means "this template renders
//!    nothing" -- that IS the common case (9 of the checked-in fixture's 12
//!    templates are empty this way, none of them at the depth cap; a
//!    review round that flatly reversed the emphasis on this point, reading
//!    the rare case as the default one, is why this bullet leads with the
//!    ordinary meaning now).** The one other cause collapses to the exact
//!    same empty value: at `rails.zig`'s `max_partial_depth` cutoff, the
//!    walk stops and that node's own `renders` is empty because its targets
//!    were genuinely never resolved -- see `rails.GraphNode`'s doc. The two
//!    causes are NOT distinguishable from `renders` alone; the
//!    disambiguator is `blockers[]`: only when a `RAILS_TEMPLATE_RENDER_
//!    DEPTH_EXCEEDED` blocker names this same template's `path` was the
//!    walk cut short. No such blocker means `renders == []` is exactly what
//!    it says. An unreadable template (`RAILS_TEMPLATE_UNREADABLE`) never
//!    becomes a `templates[]` entry at all (its render targets are
//!    unknown, not "none"), so every entry present here was itself
//!    successfully read.
//! 4. **`severity` and `integrity` are different axes.** `integrity`
//!    (`BlockerEntry`'s own field) is what the exit code is computed from
//!    (`--strict`, Task 11, and today's plain `integrity_blocker_count`
//!    exit); `severity` is descriptive metadata about the finding. A
//!    consumer that filters `severity == "error"` will see errors on a
//!    perfectly healthy run that merely lacks Ruby (`RAILS_RUBY_
//!    UNAVAILABLE` etc. are `severity = .error` but `integrity = false` --
//!    a wholesale, but non-integrity, degradation; see `routes.zig`'s
//!    module doc). Do not derive one axis from the other.
//!
//! ## Two reachability gaps closed here, not invented around
//!
//! `Discovery` (as Phase 1 left it) had no path out for `routes[].
//! classification`/`.candidates` (needs `classify.Verdict`, computed and
//! then freed inside `discover`), the top-level `integrations[]` (computed
//! and freed the same way), or the top-level `blockers[]` (only aggregate
//! counts escaped). All three are the SAME shape of gap `route_templates`/
//! `templates`/`assets`/`version`/`routes` already closed in earlier fix
//! rounds -- see `Discovery.classifications`/`.integrations`/`.blockers`'
//! own docs in `rails.zig` for what changed there. This file assumes those
//! three fields exist; it does not recompute anything `discover` already
//! produced.
//!
//! ## Two fields Task 8 left unpopulated, closed by Task 8b
//!
//! Task 8 shipped with two spec-documented fields it could not populate
//! from what Phase 1 produced, and correctly reported that in-type rather
//! than inventing a value. Both turned out to be genuinely obtainable:
//!
//! - **`integrations[].version`** -- `integrations.Integration` now carries
//!   a `version` alongside `name`/`evidence` (Stage 4 Task 8b): the
//!   `Gemfile.lock`-resolved version for a gem-sourced integration (`detect.
//!   lockedVersion`, reused rather than re-parsed), the `package.json`
//!   dependency value for an npm-sourced one, or `null` when neither source
//!   names a version -- see that field's own doc.
//! - **`blockers[].source.line`** -- `blockers.Blocker` now carries `line:
//!   ?u64` (Stage 4 Task 8b), threaded from `WireUnresolved.line` at both
//!   `routes.zig`'s and `controllers.zig`'s `decodeResponse` fold sites,
//!   where it was already being decoded off the wire and then dropped on
//!   the way into a `Blocker`. `null` remains correct and expected for a
//!   blocker with no single source line at all (an unreadable Gemfile, a
//!   missing sidecar) -- never a fabricated `1`; see that field's own doc.
//!
//! std-only, like every file in `src/cli/rails/`: no `@import` here escapes
//! this directory. This file imports `rails.zig` for `Discovery`/
//! `RouteTemplates`/`TemplateNode`/`RubyInfo`/`formatRouteId`, and `rails.
//! zig` imports this file back (`pub const manifest = @import("manifest.
//! zig");`) purely to pull this file's `test` block into `test-rails` (see
//! that file's own module doc) -- Zig permits the resulting cycle (neither
//! file's types reference the other's at comptime struct-size level), but
//! it is worth a reader's pause: this file's PRODUCTION code depends on
//! `rails.zig`'s types; `rails.zig`'s dependency back is test-wiring only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rails = @import("rails.zig");
const routes = @import("routes.zig");
const assets = @import("assets.zig");
const integrations = @import("integrations.zig");
const blockers = @import("blockers.zig");
const classify = @import("classify.zig");
const detect = @import("detect.zig");
const inventory = @import("inventory.zig");
const report = @import("report.zig");
const findings = @import("findings.zig");

/// The manifest's `schema` field. Additive-only within `1`: a new field may
/// be appended, an existing one may not change meaning or disappear -- see
/// the design doc's "Blocker codes" section for the identical rule applied
/// to the blocker vocabulary.
pub const schema_id: []const u8 = "zigapagos.rails-presentation/1";
pub const schema_version_value: u32 = 1;

/// Field order is the wire contract (module doc) -- `tool` then `version`.
pub const Generator = struct {
    tool: []const u8 = "zigapagos",
    version: []const u8,
};

/// `source.version`'s non-null shape. `detect.Version`'s two fields are
/// independently `?[]u8`, but `detect.detectVersion` only ever returns them
/// TOGETHER (both set on the success path, both `null` on every degradation
/// path -- see that function's own doc) -- `build` below relies on that
/// invariant to collapse the pair into one `?VersionEntry` rather than
/// carrying the "value present, evidence absent" case this type has no way
/// to express (and `detectVersion` never produces).
pub const VersionEntry = struct {
    value: []const u8,
    evidence: []const u8,
};

/// Field order is the wire contract -- `framework`, `version`,
/// `root_evidence`.
pub const SourceInfo = struct {
    framework: []const u8 = "rails",
    version: ?VersionEntry,
    /// Not derivable from `rails.Discovery` -- `detect.collect`/`verdict`
    /// (the evidence that ANSWERED "is this a Rails app") run once, before
    /// `discover` is ever called (`migrate.zig`'s `--from rails` check),
    /// and `Discovery` was never widened to carry that `Evidence` forward.
    /// Supplied by the caller instead of re-probing the filesystem a
    /// second time from inside this emitter, which would risk a second
    /// answer disagreeing with the first. See `BuildInput.root_evidence`.
    root_evidence: []const []const u8,
};

/// Field order is the wire contract -- `available`, `version`. Mirrors
/// `rails.RubyInfo`, whose `version` is a method (`?[]const u8`) over a
/// fixed buffer, not a field `std.json.Stringify` could read directly.
pub const RubyStatus = struct {
    available: bool,
    version: ?[]const u8,
};

/// Field order is the wire contract -- `route_mode`, `ruby`.
pub const DiscoveryInfo = struct {
    route_mode: []const u8,
    ruby: RubyStatus,
};

/// `routes[].confidence`'s wire values. `routes.Route.certain` is a plain
/// `bool`; this is the only field in the whole manifest whose Zig type
/// (`bool`) and wire shape (a two-valued STRING, "certain"/"uncertain")
/// deliberately differ -- the spike's own finding was that a route's
/// confidence needs to read as a first-class fact, not an incidental `true`/
/// `false` a consumer could mistake for some other flag.
pub const Confidence = enum { certain, uncertain };

fn confidenceOf(certain: bool) Confidence {
    return if (certain) .certain else .uncertain;
}

/// Same shape as `routes.Source` (`file`, `line`) -- aliased rather than
/// redeclared since the field order already matches the wire contract.
pub const RouteSource = routes.Source;

/// Same shape as `classify.Candidate` (`target`, `evidence`) -- aliased for
/// the identical reason `RouteSource` is. See the design doc's "candidates:
/// a deliberate addition" section for why this field exists at all: the
/// issue's six `classification` values are kept verbatim as the Rails-side
/// fact, and `candidates` carries the SEPARATE, still-undecided question of
/// which zigapagos shape a route should become.
pub const CandidateEntry = classify.Candidate;

/// Field order is the wire contract, and matches the spec's own example
/// object plus one additive field: `id`, `verb`, `path`, `controller`,
/// `action`, `name`, `source`, `origin`, `confidence`, `classification`,
/// `reason`, `candidates`, `templates`, `layout`.
///
/// **`reason` was added by the Stage 5 final-fix round, REVERSING this
/// type's earlier stance.** Task 8 deliberately omitted it, arguing that
/// free-text explanation was `report.zig`'s (the human-readable
/// `MIGRATION.md`) job, and that a machine consumer already had
/// `classification` plus `candidates[].evidence` for the same information
/// in structured form. That argument fails for exactly the class that needs
/// it most: for `unresolved`, `candidates[]` is empty BY DESIGN (see
/// `classify.zig`'s rule chain -- every `unresolved` return sets
/// `candidates = no_candidates`), so an unresolved route carried a
/// classification and no evidence whatsoever -- neither a manifest consumer
/// nor a `MIGRATION.md` reader could tell WHY a given route landed there,
/// which is close to the silent omission this whole feature exists to
/// prevent. It also voided a justification in the design spec (`docs/
/// superpowers/specs/2026-08-22-rails-source-discovery-design.md`'s
/// "Declared, not yet emitted" section), which declines to emit
/// `RAILS_REQUEST_TIME_STATE`/`RAILS_NO_TEMPLATE` as blockers on the
/// grounds that "the route's verdict and its `reason` already carry that
/// finding" -- true only once `reason` actually reaches a consumer, which
/// it now does. `reason` is a static string literal on every `classify.
/// Verdict` (see that type's own doc), so emitting it costs no allocation.
pub const RouteEntry = struct {
    /// See the module doc's point 1: a LABEL (`rails.formatRouteId`'s
    /// output), not a unique key.
    id: []const u8,
    verb: []const u8,
    path: []const u8,
    controller: ?[]const u8,
    action: ?[]const u8,
    name: ?[]const u8,
    source: RouteSource,
    origin: routes.Origin,
    confidence: Confidence,
    classification: classify.Class,
    /// Why THIS route reached `classification` -- the exact string
    /// `classify.zig`'s rule chain returned (e.g. "view reads request-time
    /// state", "controller action only issues a redirect"). Two routes
    /// `unresolved` for different rules report different `reason` text;
    /// see `classify.Verdict.reason`'s own doc for the full string set.
    reason: []const u8,
    candidates: []const CandidateEntry,
    /// The view plus every partial (direct or nested) this route's scan
    /// resolved AND READ -- see `rails.RouteTemplates`'s own doc for why an
    /// unresolved/unreadable view defaults this to `&.{}` rather than
    /// omitting the route. `[]` here means "nothing resolved for this
    /// route", a DIFFERENT statement from a `TemplateEntry.renders == []`
    /// depth-cap stop (module doc point 3) -- this field is never truncated
    /// by a depth cap itself, only by there being no view to start from.
    templates: []const []const u8,
    layout: ?[]const u8,
};

/// Field order is the wire contract, and matches the spec's own example
/// object exactly: `path`, `engine`, `kind`, `renders`,
/// `stimulus_controllers`, `component_roots`. NOT an alias of `rails.
/// TemplateNode`, whose field order is `path`, `kind`, `engine`, ... --
/// deliberately different field order for an internal producer type versus
/// this file's wire contract is exactly the trap the module doc's "key
/// ordering" section warns about, so this type is declared independently
/// with the ORDER the spec actually shows, and `build` below copies field
/// by field rather than reusing `rails.TemplateNode`'s layout.
pub const TemplateEntry = struct {
    path: []const u8,
    engine: inventory.Engine,
    kind: inventory.Kind,
    /// See the module doc's point 3: `[]` at `rails.max_partial_depth`
    /// means "the scan stopped looking here", not "renders nothing". An
    /// unreadable template never reaches `templates[]` at all (see
    /// `rails.TransitiveScan`'s doc), so every entry that DOES appear here
    /// was successfully read; only ITS OWN render targets may be
    /// unresolved.
    renders: []const []const u8,
    stimulus_controllers: []const []const u8,
    component_roots: []const []const u8,
};

/// Field order matches `assets.Asset` exactly (`source`, `public_url`,
/// `pipeline`, `deterministic`), which is also the spec's own example order
/// -- aliased rather than redeclared.
pub const AssetEntry = assets.Asset;

/// Field order is the wire contract -- `name`, `version`, `evidence`,
/// matching the spec's own example object. NOT an alias of `integrations.
/// Integration` (Stage 4 Task 8b added `version` there too, but this type
/// stays independently declared for the same "internal producer order vs.
/// wire order" reason `TemplateEntry`'s doc gives): `version` is the gem's
/// `Gemfile.lock`-resolved version for a gem-sourced integration, or the
/// `package.json` dependency value for an npm-sourced one, or `null` when
/// neither source yields one -- never a guess. See `integrations.
/// Integration.version`'s own doc for exactly which source wins.
pub const IntegrationEntry = struct {
    name: []const u8,
    version: ?[]const u8,
    evidence: []const u8,
};

/// Matches `RouteSource`/`routes.Source`'s shape: `file` then `line`.
/// Stage 4 Task 8b added `line` here too -- see `blockers.Blocker.line`'s
/// own doc for the wire it comes from and why it is `null`, not a
/// fabricated value, when a blocker genuinely has no single source line.
pub const BlockerSource = struct {
    file: []const u8,
    line: ?u64,
};

/// Field order is the wire contract: `code`, `severity`, `integrity`,
/// `source`, `message`, `route_id`. `severity`/`integrity` are placed
/// adjacent on purpose -- see the module doc's point 4, which this field
/// pair exists to make legible rather than merely documented in prose:
/// `integrity` is the one spec's own example blocker omits, added here
/// (the design doc's own "candidates: a deliberate addition" precedent for
/// a principled, documented type extension beyond the literal example)
/// because a consumer cannot tell "drives the exit code" apart from
/// "describes the finding" if only `severity` is on the wire at all.
pub const BlockerEntry = struct {
    code: []const u8,
    severity: blockers.Severity,
    integrity: bool,
    source: BlockerSource,
    message: []const u8,
    route_id: ?[]const u8,
};

/// Same shape as `BlockerSource`/`RouteSource` (`file` then `line`),
/// declared independently for the same "internal producer order vs. wire
/// order" reason `TemplateEntry`'s doc gives -- `findings.Finding` carries
/// `path`/`line` as two separate top-level fields; this folds them into one
/// `source` object to match `BlockerEntry`'s shape.
pub const FindingSource = struct { file: []const u8, line: ?u64 };

/// Field order is the wire contract: `id`, `code`, `severity`, `source`,
/// `route_id`, `message`, `choices`, `requires_artifact`. NOT an alias of
/// `findings.Finding` -- see `FindingSource`'s doc for the one shape
/// difference; `build` below copies field by field, the same pattern
/// `BlockerEntry`/`TemplateEntry` already use for an internal producer type
/// with a different field order than its wire form.
///
/// `id` is the join key a Stage 2 decision file references against a
/// PREVIOUS run's recorded operator choice -- see `findings.zig`'s module
/// doc ("Ids, not array positions") for why it survives a reworded
/// `message` or a template edit elsewhere in the file. `message` is prose
/// and deliberately NOT part of that identity.
pub const FindingEntry = struct {
    id: []const u8,
    code: []const u8,
    severity: blockers.Severity,
    source: FindingSource,
    route_id: ?[]const u8,
    message: []const u8,
    choices: []const []const u8,
    requires_artifact: bool,
};

/// Field order is the wire contract and matches the spec's own example
/// object top to bottom: `schema`, `schema_version`, `generator`, `source`,
/// `discovery`, `routes`, `templates`, `assets`, `integrations`,
/// `blockers`, `findings`. `findings` is LAST and deliberately a SEPARATE
/// array from `blockers`, not folded into it: a blocker is a fact about
/// what discovery could or couldn't establish (drives the exit code via
/// `integrity`); a finding is a per-fragment choice this run cannot make on
/// the operator's behalf, meant to be answered by id in a Stage 2 decision
/// file -- see `findings.zig`'s module doc. A consumer filtering `blockers[]`
/// for integrity facts must never see operator questions mixed in.
pub const Manifest = struct {
    schema: []const u8 = schema_id,
    schema_version: u32 = schema_version_value,
    generator: Generator,
    source: SourceInfo,
    discovery: DiscoveryInfo,
    routes: []const RouteEntry,
    templates: []const TemplateEntry,
    assets: []const AssetEntry,
    integrations: []const IntegrationEntry,
    blockers: []const BlockerEntry,
    findings: []const FindingEntry,
};

/// Everything `build` needs beyond a `rails.Discovery`: the two pieces
/// discovery genuinely has no seam to produce on its own (see `SourceInfo.
/// root_evidence`'s doc for why `root_evidence` is caller-supplied rather
/// than re-derived here) and the generator's own version string (`main.
/// zig`'s build-time version, threaded down the same way `app_path` already
/// is -- this file stays std-only and has no access to `build_options`
/// itself).
pub const BuildInput = struct {
    generator_version: []const u8,
    root_evidence: []const []const u8,
    discovery: *const rails.Discovery,
};

/// A route paired with everything else `build` needs to render it, so the
/// three index-aligned slices `rails.Discovery` carries (`routes`,
/// `classifications`, `route_templates`) travel together through the sort
/// below -- the same pairing `report.zig`'s own `RouteVerdict` uses for the
/// identical two-way alignment problem (there it pairs `Route`+`Verdict`
/// only, since it does not also render the template graph).
const RoutePair = struct {
    route: routes.Route,
    verdict: classify.Verdict,
    tpl: rails.RouteTemplates,
};

/// Delegates to `report.routeLessThan` over the pair's own `.route` --
/// deliberately NOT a fresh comparator. See `report.zig`'s own doc on why
/// this reuse matters: `Discovery.routes` already carries a route each of
/// whose (path, verb) pairs may legitimately repeat (module doc point 1),
/// so any comparator here has the same total-order obligation `report.
/// zig`'s fix round B/B7 found the hard way (a partial-order comparator
/// leaves tied rows' relative order to `std.mem.sort`'s instability, which
/// is exactly the determinism violation this stage's drift gate exists to
/// catch). Reusing the already-fixed comparator is what guarantees this
/// file never reintroduces that bug independently.
fn routePairLessThan(_: void, a: RoutePair, b: RoutePair) bool {
    return report.routeLessThan({}, a.route, b.route);
}

/// Contract 1 (self-freeing): every allocation this function makes --
/// the paired/sorted route, blocker, and finding scratch arrays, the
/// per-route id buffers, the constructed `RouteEntry`/`TemplateEntry`/
/// `BlockerEntry`/`FindingEntry` arrays, and `std.json.Stringify`'s own
/// internal buffer -- is freed before returning; the ONE allocation that
/// escapes is the returned `[]u8`. Every `RouteEntry`/`TemplateEntry`/
/// `AssetEntry`/`IntegrationEntry`/`BlockerEntry`/`FindingEntry` string this
/// function builds is either a borrow of `in.discovery`'s own
/// already-owned memory (which outlives this call) or a borrow of a
/// per-route id buffer freed at the end of this function -- never a NEW
/// `gpa` allocation that would need its own release path, which is what
/// keeps this contract 1 instead of contract 2 despite building a fair
/// amount of intermediate structure.
///
/// Determinism (module doc; design doc's "Determinism" section): `routes[]`,
/// `blockers[]`, and `findings[]` are sorted in private copies here
/// (`templates[]`/`assets[]` arrive from `Discovery` already sorted by path
/// -- see `rails.zig`'s `classifyRoutes`/`assets.scan` docs -- so they are
/// copied verbatim, not re-sorted); this function never depends on the
/// order discovery happened to produce any of them in --
/// `findings.derive` already sorts its own returned slice by `findings.
/// lessThan` before `Discovery.findings` is ever set, but this function
/// re-sorts a private copy anyway rather than trusting that upstream
/// invariant, the same "determinism is this function's own responsibility"
/// stance it already takes for `blockers[]`. `root_evidence`/`integrations[]`
/// are emitted in the order the caller/`Discovery` supplies them, which is
/// itself deterministic given a fixed evidence-probe order and a fixed
/// gem/package lookup table respectively -- see those types' own docs.
pub fn build(gpa: Allocator, in: BuildInput) Allocator.Error![]u8 {
    const d = in.discovery;

    // --- routes[] --------------------------------------------------------
    const pairs = try gpa.alloc(RoutePair, d.routes.len);
    defer gpa.free(pairs);
    for (d.routes, d.classifications, d.route_templates, 0..) |r, v, rt, i| {
        pairs[i] = .{ .route = r, .verdict = v, .tpl = rt };
    }
    std.mem.sort(RoutePair, pairs, {}, routePairLessThan);

    // One id buffer per route, all released together after
    // `std.json.Stringify` has consumed every `RouteEntry.id` it points
    // into -- a single buffer reused across iterations would alias every
    // `RouteEntry.id` onto whatever the LAST route's format call left in
    // it (see `rails.formatRouteId`'s own contract: it borrows `buf`, it
    // does not allocate).
    const id_bufs = try gpa.alloc([rails.route_id_buf_len]u8, pairs.len);
    defer gpa.free(id_bufs);

    const route_entries = try gpa.alloc(RouteEntry, pairs.len);
    defer gpa.free(route_entries);
    for (pairs, 0..) |p, i| {
        route_entries[i] = .{
            .id = rails.formatRouteId(&id_bufs[i], p.route),
            .verb = p.route.verb,
            .path = p.route.path,
            .controller = p.route.controller,
            .action = p.route.action,
            .name = p.route.name,
            .source = p.route.source,
            .origin = p.route.origin,
            .confidence = confidenceOf(p.route.certain),
            .classification = p.verdict.class,
            .reason = p.verdict.reason,
            .candidates = p.verdict.candidates,
            .templates = p.tpl.templates,
            .layout = p.tpl.layout,
        };
    }

    // --- templates[] -------------------------------------------------------
    // Already sorted by path (rails.zig's classifyRoutes) -- copied field
    // by field into this file's own wire-order type (TemplateEntry's own
    // doc: NOT an alias of rails.TemplateNode, whose field order differs).
    const template_entries = try gpa.alloc(TemplateEntry, d.templates.len);
    defer gpa.free(template_entries);
    for (d.templates, 0..) |t, i| {
        template_entries[i] = .{
            .path = t.path,
            .engine = t.engine,
            .kind = t.kind,
            .renders = t.renders,
            .stimulus_controllers = t.stimulus_controllers,
            .component_roots = t.component_roots,
        };
    }

    // --- integrations[] ------------------------------------------------
    const integration_entries = try gpa.alloc(IntegrationEntry, d.integrations.len);
    defer gpa.free(integration_entries);
    for (d.integrations, 0..) |x, i| {
        integration_entries[i] = .{ .name = x.name, .version = x.version, .evidence = x.evidence };
    }

    // --- blockers[] ----------------------------------------------------
    // NOT already sorted (Discovery.blockers' own doc): a private, sorted
    // copy, mirroring report.zig's identical "determinism is this
    // function's responsibility" stance for its own Blockers section.
    const sorted_blockers = try gpa.dupe(blockers.Blocker, d.blockers);
    defer gpa.free(sorted_blockers);
    std.mem.sort(blockers.Blocker, sorted_blockers, {}, report.blockerLessThan);

    const blocker_entries = try gpa.alloc(BlockerEntry, sorted_blockers.len);
    defer gpa.free(blocker_entries);
    for (sorted_blockers, 0..) |b, i| {
        blocker_entries[i] = .{
            .code = b.code,
            .severity = b.severity,
            .integrity = b.integrity,
            .source = .{ .file = b.path, .line = b.line },
            .message = b.detail,
            .route_id = b.route_id,
        };
    }

    // --- findings[] ------------------------------------------------------
    // NOT trusted to already be sorted (this function's own doc above):
    // a private, sorted copy, mirroring the identical stance already taken
    // for blockers[] just above.
    const sorted_findings = try gpa.dupe(findings.Finding, d.findings);
    defer gpa.free(sorted_findings);
    std.mem.sort(findings.Finding, sorted_findings, {}, findings.lessThan);

    const finding_entries = try gpa.alloc(FindingEntry, sorted_findings.len);
    defer gpa.free(finding_entries);
    for (sorted_findings, 0..) |f, i| {
        finding_entries[i] = .{
            .id = f.id,
            .code = f.code,
            .severity = f.severity,
            .source = .{ .file = f.path, .line = f.line },
            .route_id = f.route_id,
            .message = f.message,
            .choices = f.choices,
            .requires_artifact = f.requires_artifact,
        };
    }

    // --- source.version --------------------------------------------------
    // detect.detectVersion only ever sets both fields together or neither
    // (VersionEntry's own doc) -- collapsed here into one optional.
    const version_entry: ?VersionEntry = if (d.version.value) |v|
        .{ .value = v, .evidence = d.version.evidence.? }
    else
        null;

    const manifest_value: Manifest = .{
        .generator = .{ .version = in.generator_version },
        .source = .{
            .version = version_entry,
            .root_evidence = in.root_evidence,
        },
        .discovery = .{
            .route_mode = d.route_mode,
            .ruby = .{ .available = d.ruby.available, .version = d.ruby.version() },
        },
        .routes = route_entries,
        .templates = template_entries,
        .assets = d.assets,
        .integrations = integration_entries,
        .blockers = blocker_entries,
        .findings = finding_entries,
    };

    var out = try std.json.Stringify.valueAlloc(gpa, manifest_value, .{ .whitespace = .indent_2 });
    errdefer gpa.free(out);
    // A trailing newline, matching this repo's other committed JSON
    // artifacts (e.g. contract/zigbase.openapi.json) -- POSIX-text-file
    // convention, and what keeps a plain `git diff` on the written file
    // clean instead of showing a "no newline at end of file" marker on
    // every regenerate.
    out = try gpa.realloc(out, out.len + 1);
    out[out.len - 1] = '\n';
    return out;
}

const testing = std.testing;

fn testRoute(verb: []const u8, path: []const u8) routes.Route {
    return .{
        .verb = verb,
        .path = path,
        .controller = null,
        .action = null,
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
        // #167 Stage 1's three new `Discovery` fields. `Discovery` declares
        // no field defaults (deliberately -- a new escaping field that
        // silently defaults to empty is exactly how a producer ships
        // unwired), so this test helper spells the degraded value out like
        // every field above it. `build` DOES read and emit `findings` (see
        // the "findings[] is emitted last" test below); `fragments` and
        // `i18n_locale` are not rendered by the manifest at all -- they are
        // inputs `findings.derive` consumes upstream, one layer before
        // `Discovery` is built (`report.build` only consumes the findings
        // `derive` already produced, not `fragments`/`i18n_locale`
        // themselves), so this helper leaves them empty rather than wiring
        // them through here.
        .fragments = &.{},
        .findings = &.{},
        .i18n_locale = null,
        .decisions = .empty,
    };
}

test "build: a fully degraded, empty discovery still emits a manifest -- degradation stays exit 0" {
    // The brief's own requirement, verbatim: "a degraded run must still
    // emit a manifest". Nothing here should error or produce an empty
    // buffer just because every producer came back empty.
    const gpa = testing.allocator;
    const d = emptyDiscovery();
    const out = try build(gpa, .{
        .generator_version = "0.0.0-test",
        .root_evidence = &.{},
        .discovery = &d,
    });
    defer gpa.free(out);
    try testing.expect(out.len > 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(schema_id, parsed.value.object.get("schema").?.string);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("routes").?.array.items.len);
    try testing.expect(parsed.value.object.get("source").?.object.get("version").? == .null);
}

test "build: manifest bytes are EXACTLY the same across two runs of the identical input" {
    // The discriminating property, at the smallest scale: same BuildInput
    // in, byte-identical output out. The two-directory fixture test below
    // covers the same property against the real `discover` pipeline; this
    // one isolates `build` itself.
    const gpa = testing.allocator;
    var rs = [_]routes.Route{testRoute("GET", "/posts")};
    var verdicts = [_]classify.Verdict{.{ .class = .content, .reason = "x", .candidates = &.{} }};
    var rts = [_]rails.RouteTemplates{.{ .templates = &.{}, .layout = null }};
    const d: rails.Discovery = blk: {
        var v = emptyDiscovery();
        v.routes = &rs;
        v.classifications = &verdicts;
        v.route_templates = &rts;
        break :blk v;
    };
    const in: BuildInput = .{ .generator_version = "1.2.3", .root_evidence = &.{"Gemfile"}, .discovery = &d };

    const a = try build(gpa, in);
    defer gpa.free(a);
    const b = try build(gpa, in);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "build: two duplicate route declarations keep the same id (routes[].id is a label, not a key)" {
    const gpa = testing.allocator;
    var rs = [_]routes.Route{ testRoute("GET", "/posts/stats"), testRoute("GET", "/posts/stats") };
    var verdicts = [_]classify.Verdict{
        .{ .class = .backend, .reason = "x", .candidates = &.{} },
        .{ .class = .backend, .reason = "x", .candidates = &.{} },
    };
    var rts = [_]rails.RouteTemplates{ .{ .templates = &.{}, .layout = null }, .{ .templates = &.{}, .layout = null } };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &verdicts;
    d.route_templates = &rts;

    const out = try build(gpa, .{ .generator_version = "x", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const rs_json = parsed.value.object.get("routes").?.array.items;
    try testing.expectEqual(@as(usize, 2), rs_json.len);
    try testing.expectEqualStrings("GET /posts/stats", rs_json[0].object.get("id").?.string);
    try testing.expectEqualStrings("GET /posts/stats", rs_json[1].object.get("id").?.string);
}

test "build: routes[] sorts by (path, verb) regardless of Discovery's own order" {
    const gpa = testing.allocator;
    var rs = [_]routes.Route{ testRoute("POST", "/b"), testRoute("GET", "/a") };
    var verdicts = [_]classify.Verdict{
        .{ .class = .backend, .reason = "x", .candidates = &.{} },
        .{ .class = .content, .reason = "x", .candidates = &.{} },
    };
    var rts = [_]rails.RouteTemplates{ .{ .templates = &.{}, .layout = null }, .{ .templates = &.{}, .layout = null } };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &verdicts;
    d.route_templates = &rts;

    const out = try build(gpa, .{ .generator_version = "x", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const rs_json = parsed.value.object.get("routes").?.array.items;
    try testing.expectEqualStrings("/a", rs_json[0].object.get("path").?.string);
    try testing.expectEqualStrings("/b", rs_json[1].object.get("path").?.string);
}

test "build: blockers[] sorts by (code, path) and carries integrity alongside severity" {
    const gpa = testing.allocator;
    var bl = [_]blockers.Blocker{
        .{ .code = "RAILS_ROUTE_CONDITIONAL", .path = "config/routes.rb", .detail = "conditional route", .integrity = false, .severity = .warn, .route_id = "GET /x", .line = 118 },
        .{ .code = "RAILS_INVENTORY_UNREADABLE", .path = "app", .detail = "AccessDenied", .integrity = true, .severity = .@"error", .route_id = null, .line = null },
    };
    var d = emptyDiscovery();
    d.blockers = &bl;

    const out = try build(gpa, .{ .generator_version = "x", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const bs = parsed.value.object.get("blockers").?.array.items;
    try testing.expectEqual(@as(usize, 2), bs.len);
    // "RAILS_INVENTORY_UNREADABLE" < "RAILS_ROUTE_CONDITIONAL" lexically.
    try testing.expectEqualStrings("RAILS_INVENTORY_UNREADABLE", bs[0].object.get("code").?.string);
    try testing.expect(bs[0].object.get("integrity").?.bool);
    try testing.expectEqualStrings("error", bs[0].object.get("severity").?.string);
    try testing.expect(bs[0].object.get("route_id").? == .null);
    try testing.expectEqualStrings("app", bs[0].object.get("source").?.object.get("file").?.string);
    // A blocker with no source line reports `line: null`, not an absent key
    // and not a fabricated `1` -- see `BlockerSource.line`'s doc.
    try testing.expect(bs[0].object.get("source").?.object.get("line").? == .null);

    try testing.expectEqualStrings("RAILS_ROUTE_CONDITIONAL", bs[1].object.get("code").?.string);
    try testing.expect(!bs[1].object.get("integrity").?.bool);
    try testing.expectEqualStrings("warn", bs[1].object.get("severity").?.string);
    try testing.expectEqualStrings("GET /x", bs[1].object.get("route_id").?.string);
    // Discriminates the actual wire value, not a constant -- an
    // implementation that always emits `null` (the pre-Task-8b state) would
    // pass every assertion above but fail this one.
    try testing.expectEqual(@as(i64, 118), bs[1].object.get("source").?.object.get("line").?.integer);
}

test "build: discovery.ruby.version passes through RubyInfo.version(), not hardcoded null" {
    // Every other test in this file leaves `RubyInfo.version_len` at its
    // zero default, so `d.ruby.version()` is `null` in all of them --
    // `discovery.ruby.version` reading as `null` would pass every one of
    // those even if `build` hardcoded `null` instead of actually calling
    // `.version()`. This is the one test that gives `RubyInfo` a REAL
    // version to prove the passthrough is live.
    const gpa = testing.allocator;
    var ruby_info: rails.RubyInfo = .{ .available = true };
    const v = "3.3.6";
    @memcpy(ruby_info.version_buf[0..v.len], v);
    ruby_info.version_len = v.len;

    var d = emptyDiscovery();
    d.ruby = ruby_info;

    const out = try build(gpa, .{ .generator_version = "x", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const ruby_json = parsed.value.object.get("discovery").?.object.get("ruby").?.object;
    try testing.expect(ruby_json.get("available").?.bool);
    try testing.expectEqualStrings("3.3.6", ruby_json.get("version").?.string);
}

test "build: confidence reflects Route.certain honestly -- certain and uncertain both round-trip" {
    // A route recovered from a construct the parser could not fully
    // evaluate must read as "uncertain", not silently as "certain" --
    // confirms `confidenceOf` is actually wired into `build`, not merely
    // declared and unused (the golden-bytes test above only exercises the
    // `certain = true` branch).
    const gpa = testing.allocator;
    var rs = [_]routes.Route{ testRoute("GET", "/a"), testRoute("GET", "/b") };
    rs[1].certain = false;
    var verdicts = [_]classify.Verdict{
        .{ .class = .content, .reason = "x", .candidates = &.{} },
        .{ .class = .backend, .reason = "x", .candidates = &.{} },
    };
    var rts = [_]rails.RouteTemplates{ .{ .templates = &.{}, .layout = null }, .{ .templates = &.{}, .layout = null } };
    var d = emptyDiscovery();
    d.routes = &rs;
    d.classifications = &verdicts;
    d.route_templates = &rts;

    const out = try build(gpa, .{ .generator_version = "x", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const rs_json = parsed.value.object.get("routes").?.array.items;
    try testing.expectEqualStrings("certain", rs_json[0].object.get("confidence").?.string);
    try testing.expectEqualStrings("uncertain", rs_json[1].object.get("confidence").?.string);
}

test "build: integrations[].version passes Integration.version through, null and non-null both" {
    // Discriminates the actual field, not a constant: Task 8 shipped with
    // `version` hardcoded to `null` here regardless of what `Integration`
    // carried (it carried nothing at all yet). An implementation that still
    // hardcodes `null` would pass the first integration below and fail the
    // second.
    const gpa = testing.allocator;
    var ints = [_]integrations.Integration{
        .{ .name = "propshaft", .version = null, .evidence = "Gemfile:propshaft" },
        .{ .name = "turbo", .version = "8.0.4", .evidence = "package.json:@hotwired/turbo-rails" },
    };
    var d = emptyDiscovery();
    d.integrations = &ints;

    const out = try build(gpa, .{ .generator_version = "x", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const is = parsed.value.object.get("integrations").?.array.items;
    try testing.expectEqual(@as(usize, 2), is.len);

    try testing.expectEqualStrings("propshaft", is[0].object.get("name").?.string);
    try testing.expect(is[0].object.get("version").? == .null);
    try testing.expectEqualStrings("Gemfile:propshaft", is[0].object.get("evidence").?.string);

    try testing.expectEqualStrings("turbo", is[1].object.get("name").?.string);
    try testing.expectEqualStrings("8.0.4", is[1].object.get("version").?.string);
    try testing.expectEqualStrings("package.json:@hotwired/turbo-rails", is[1].object.get("evidence").?.string);
}

const two_choices = [_][]const u8{ "retain", "blocked" };

fn testFinding(code: []const u8, id: []const u8, path: []const u8, line: ?u64, message: []const u8) findings.Finding {
    return .{ .id = id, .code = code, .severity = .warn, .path = path, .line = line, .route_id = null, .message = message, .choices = &two_choices, .requires_artifact = false };
}

test "build: findings[] is emitted last, sorted by findings.lessThan, with the wire field order" {
    const gpa = testing.allocator;
    var fs = [_]findings.Finding{
        testFinding("RAILS_REQUEST_TIME_STATE", "RAILS_REQUEST_TIME_STATE.app/views/p%2Ehtml%2Eerb.L2C1", "app/views/p.html.erb", 2, "request-time state `current_user`"),
        testFinding("RAILS_HELPER_UNKNOWN", "RAILS_HELPER_UNKNOWN.app/views/p%2Ehtml%2Eerb.L1C1", "app/views/p.html.erb", 1, "unknown helper `foo`"),
    };
    const d: rails.Discovery = blk: {
        var v = emptyDiscovery();
        v.findings = &fs;
        break :blk v;
    };
    const out = try build(gpa, .{ .generator_version = "0.0.0-test", .root_evidence = &.{}, .discovery = &d });
    defer gpa.free(out);

    const blockers_at = std.mem.indexOf(u8, out, "\"blockers\": [").?;
    const findings_at = std.mem.indexOf(u8, out, "\"findings\": [").?;
    try testing.expect(findings_at > blockers_at);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("findings").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("RAILS_HELPER_UNKNOWN", arr[0].object.get("code").?.string);
    try testing.expectEqualStrings("app/views/p.html.erb", arr[0].object.get("source").?.object.get("file").?.string);
    try testing.expectEqual(@as(i64, 1), arr[0].object.get("source").?.object.get("line").?.integer);
    try testing.expect(arr[0].object.get("route_id").? == .null);
    try testing.expectEqual(@as(usize, 2), arr[0].object.get("choices").?.array.items.len);
    try testing.expect(!arr[0].object.get("requires_artifact").?.bool);

    // Key order inside one finding object is the wire contract: assert the
    // byte offsets are strictly increasing within the first object.
    //
    // Self-review fix: the brief's own sketch sliced `first_obj` to end at
    // `indexOfPos(..., "\"requires_artifact\"").? + 1` -- one byte past the
    // START of that match, i.e. right after its opening quote, not past
    // its end. That truncated `first_obj` mid-key, so the loop's own final
    // search (for the full `"\"requires_artifact\""` needle) could never
    // find it inside the very slice constructed to contain it, and panicked
    // on the resulting `.?` instead of failing as a normal `expect`. Ending
    // the slice one byte past the FULL needle's length is what actually
    // keeps the last key inside `first_obj`.
    const requires_artifact_key = "\"requires_artifact\"";
    const first_obj = out[findings_at .. std.mem.indexOfPos(u8, out, findings_at, requires_artifact_key).? + requires_artifact_key.len];
    const keys = [_][]const u8{ "\"id\"", "\"code\"", "\"severity\"", "\"source\"", "\"route_id\"", "\"message\"", "\"choices\"", requires_artifact_key };
    var last: usize = 0;
    for (keys) |k| {
        const at = std.mem.indexOfPos(u8, first_obj, last, k).?;
        try testing.expect(at >= last);
        last = at + k.len;
    }
}

test "manifestGoldenBytes: exact bytes for a minimal manifest, pinning key order byte-for-byte" {
    // The strongest form of "key ordering is explicit, not incidental" the
    // module doc promises: this doesn't just check that "path" appears
    // before "verb" somewhere, it pins the ENTIRE rendered object. Any
    // future field reorder, addition, or removal fails this test even
    // before it would show up as drift gate output.
    const gpa = testing.allocator;
    var rs = [_]routes.Route{.{
        .verb = "GET",
        .path = "/articles/:id",
        .controller = "articles",
        .action = "show",
        .name = "article",
        .certain = true,
        .origin = .static_ast,
        .source = .{ .file = "config/routes.rb", .line = 42 },
    }};
    var verdicts = [_]classify.Verdict{.{
        .class = .content,
        .reason = "static-safe view",
        .candidates = &.{.{ .target = "content", .evidence = "no request-time state in view" }},
    }};
    var tpl_list = [_][]const u8{"app/views/articles/show.html.erb"};
    var rts = [_]rails.RouteTemplates{.{ .templates = &tpl_list, .layout = "app/views/layouts/application.html.erb" }};
    // The spec's own example objects, verbatim (design doc, "The manifest")
    // -- Stage 4 Task 8b is what makes both of these render with their real
    // `version`/`source.line` instead of always `null`, so this canary now
    // exercises the exact fields that task closed.
    var ints = [_]integrations.Integration{.{ .name = "turbo", .version = "8.0.4", .evidence = "package.json:@hotwired/turbo-rails" }};
    var bl = [_]blockers.Blocker{.{
        .code = "RAILS_ROUTE_DYNAMIC_PATH",
        .path = "config/routes.rb",
        .detail = "route path is built from an interpolated expression",
        .integrity = false,
        .severity = .warn,
        .route_id = null,
        .line = 118,
    }};

    var d = emptyDiscovery();
    d.route_mode = "static_ast";
    d.ruby = .{ .available = true };
    d.routes = &rs;
    d.classifications = &verdicts;
    d.route_templates = &rts;
    d.version = .{ .value = @constCast("7.1.3"), .evidence = @constCast("Gemfile.lock:rails (7.1.3)") };
    d.integrations = &ints;
    d.blockers = &bl;

    const evidence = [_][]const u8{ "Gemfile", "config/application.rb", "app/views" };
    const out = try build(gpa, .{ .generator_version = "0.4.0", .root_evidence = &evidence, .discovery = &d });
    defer gpa.free(out);

    const want =
        \\{
        \\  "schema": "zigapagos.rails-presentation/1",
        \\  "schema_version": 1,
        \\  "generator": {
        \\    "tool": "zigapagos",
        \\    "version": "0.4.0"
        \\  },
        \\  "source": {
        \\    "framework": "rails",
        \\    "version": {
        \\      "value": "7.1.3",
        \\      "evidence": "Gemfile.lock:rails (7.1.3)"
        \\    },
        \\    "root_evidence": [
        \\      "Gemfile",
        \\      "config/application.rb",
        \\      "app/views"
        \\    ]
        \\  },
        \\  "discovery": {
        \\    "route_mode": "static_ast",
        \\    "ruby": {
        \\      "available": true,
        \\      "version": null
        \\    }
        \\  },
        \\  "routes": [
        \\    {
        \\      "id": "GET /articles/:id",
        \\      "verb": "GET",
        \\      "path": "/articles/:id",
        \\      "controller": "articles",
        \\      "action": "show",
        \\      "name": "article",
        \\      "source": {
        \\        "file": "config/routes.rb",
        \\        "line": 42
        \\      },
        \\      "origin": "static_ast",
        \\      "confidence": "certain",
        \\      "classification": "content",
        \\      "reason": "static-safe view",
        \\      "candidates": [
        \\        {
        \\          "target": "content",
        \\          "evidence": "no request-time state in view"
        \\        }
        \\      ],
        \\      "templates": [
        \\        "app/views/articles/show.html.erb"
        \\      ],
        \\      "layout": "app/views/layouts/application.html.erb"
        \\    }
        \\  ],
        \\  "templates": [],
        \\  "assets": [],
        \\  "integrations": [
        \\    {
        \\      "name": "turbo",
        \\      "version": "8.0.4",
        \\      "evidence": "package.json:@hotwired/turbo-rails"
        \\    }
        \\  ],
        \\  "blockers": [
        \\    {
        \\      "code": "RAILS_ROUTE_DYNAMIC_PATH",
        \\      "severity": "warn",
        \\      "integrity": false,
        \\      "source": {
        \\        "file": "config/routes.rb",
        \\        "line": 118
        \\      },
        \\      "message": "route path is built from an interpolated expression",
        \\      "route_id": null
        \\    }
        \\  ],
        \\  "findings": []
        \\}
        \\
    ;
    try testing.expectEqualStrings(want, out);
}

/// Test-only recursive copy: `src` (opened with `.iterate = true`) into
/// `dst`, used by the two-directory determinism test below to build two
/// independent, differently-rooted copies of the checked-in fixture rather
/// than pointing `discover` at the same directory twice under two names --
/// a real filesystem copy is what makes the two runs' `root: Io.Dir`
/// handles genuinely unrelated, not just two references to one inode.
/// Directories are created implicitly (via `createDirPathOpen` on each
/// file's parent) rather than copied as their own walk entries: `Walker`'s
/// own doc says entry order is undefined, so a file cannot assume its
/// parent directory entry was already visited.
fn copyTree(io: std.Io, gpa: Allocator, src: std.Io.Dir, dst: std.Io.Dir) !void {
    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try src.readFileAlloc(io, entry.path, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(data);
        if (std.fs.path.dirname(entry.path)) |parent| {
            var d = try dst.createDirPathOpen(io, parent, .{});
            d.close(io);
        }
        try dst.writeFile(io, .{ .sub_path = entry.path, .data = data });
    }
}

test "build: two runs from differently-named directories produce byte-identical manifests" {
    // THE discriminating property for this task (brief, verbatim): the
    // same app analysed from two differently-named directories must
    // produce byte-identical manifests. Stage 3 shipped an absolute-path
    // leak that a check shaped exactly like this one would have caught --
    // see routes.zig's module doc on RAILS_SIDECAR_FAILED's `path`/`detail`
    // for the one place that story could still leak an app_path/abs_root
    // string into blocker data on a FAILURE path (not exercised here, since
    // both copies are real, accessible directories and discovery should
    // succeed normally).
    //
    // Needs `ruby` on PATH + ZIGAPAGOS_RUNTIME_DIR, like the sibling
    // "reachable end to end" test in rails.zig -- skips rather than fails
    // when the toolchain genuinely isn't available, same reasoning as that
    // test's own doc.
    const gpa = testing.allocator;
    const io = std.testing.io;

    var src_dir = std.Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{ .iterate = true }) catch return error.SkipZigTest;
    defer src_dir.close(io);

    // Deliberately dissimilar in both length and shape, not two random
    // same-length tokens (std.testing.tmpDir's own naming would not
    // discriminate a bug that only shows up when the two paths differ in
    // length, e.g. a fixed-width buffer silently truncating one and not
    // the other).
    const name_a = ".zig-cache/tmp/manifest-determinism-app-one-with-a-long-name";
    const name_b = ".zig-cache/tmp/mdt2";

    std.Io.Dir.cwd().deleteTree(io, name_a) catch {};
    std.Io.Dir.cwd().deleteTree(io, name_b) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, name_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, name_b) catch {};

    var dir_a = try std.Io.Dir.cwd().createDirPathOpen(io, name_a, .{ .open_options = .{ .iterate = true } });
    defer dir_a.close(io);
    var dir_b = try std.Io.Dir.cwd().createDirPathOpen(io, name_b, .{ .open_options = .{ .iterate = true } });
    defer dir_b.close(io);

    try copyTree(io, gpa, src_dir, dir_a);
    try copyTree(io, gpa, src_dir, dir_b);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("ZIGAPAGOS_RUNTIME_DIR", "runtime");

    const da = try rails.discover(io, gpa, dir_a, name_a, &env_map, .{});
    defer rails.freeDiscovery(gpa, da);
    const db = try rails.discover(io, gpa, dir_b, name_b, &env_map, .{});
    defer rails.freeDiscovery(gpa, db);

    if (!std.mem.eql(u8, da.route_mode, "static_ast")) {
        // Ruby genuinely unavailable in this environment.
        return error.SkipZigTest;
    }

    // `generator_version`/`root_evidence` are caller-supplied constants,
    // identical for both calls -- this test is about what `discover`
    // itself produces from two differently-named roots, not about the
    // caller accidentally varying an unrelated input.
    const evidence = [_][]const u8{ "Gemfile", "config/application.rb", "app/views" };
    const ma = try build(gpa, .{ .generator_version = "0.0.0-test", .root_evidence = &evidence, .discovery = &da });
    defer gpa.free(ma);
    const mb = try build(gpa, .{ .generator_version = "0.0.0-test", .root_evidence = &evidence, .discovery = &db });
    defer gpa.free(mb);

    try testing.expectEqualStrings(ma, mb);
    // Sanity that this test actually exercised the real fixture, not two
    // empty discoveries that would trivially compare equal.
    try testing.expect(std.mem.indexOf(u8, ma, "\"routes\": [") != null);
    try testing.expect(da.routes.len > 0);
}
