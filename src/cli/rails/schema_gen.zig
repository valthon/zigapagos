//! Stage 4 Task 9: generates `contract/rails-presentation.v1.schema.json`
//! FROM `manifest.zig`'s own Zig types, rather than hand-maintaining a
//! parallel document -- see `manifest.zig`'s module doc, "**The types below
//! ARE the schema**", which is the reason this file exists at all. `build/
//! rails_schema.zig` wires `generate` below into `rails-schema` (write) and
//! `rails-check` (regenerate + `git diff --cached --exit-code`, mirroring
//! `build/codegen.zig`'s `api-check`).
//!
//! #167 Stage 2 Task 5 added a SECOND generated document on the same walk:
//! `contract/rails-handoff.v1.schema.json`, from `handoff.zig`'s wire types
//! (`generateHandoff`). The two differ only in their root type, their
//! override table and their three header strings -- everything below
//! `generateDoc` is document-agnostic, which is why a second contract cost
//! a table and an entry point rather than a second generator. `main` picks
//! one per invocation (`--handoff`), so each schema gets its own build step
//! and a failing gate can name the file that drifted.
//!
//! ## Why this lives INSIDE `src/cli/rails/`, not `build/`
//!
//! `manifest.zig`'s module doc requires every file in this directory to stay
//! std-only (no `@import` escapes `src/cli/rails/`), so `manifest.Manifest`
//! and its field types are ordinary Zig structs/enums with no dependency on
//! anything outside this directory. Walking them with `@typeInfo`/`std.meta.
//! fields` needs nothing more than `std` plus a same-directory `@import
//! ("manifest.zig")` -- so this generator satisfies the std-only constraint
//! for free, and putting it anywhere else (`build/`, `runtime/scripts/`)
//! would only add an import boundary the walk does not need to cross.
//! `apigen.ts` lives in `runtime/scripts/` instead because ITS input
//! (`contract/zigbase.openapi.json`) is data, not a Zig type it could walk
//! at comptime -- this generator has no such reason to leave Zig.
//!
//! ## What is generated vs. hand-written
//!
//! The STRUCTURE below -- every field, its JSON type, its nullability, its
//! nesting, every enum's exact member set -- comes from `@typeInfo(T)` /
//! `std.meta.fields(T)`, walked in each struct's OWN declaration order (a
//! comptime-fixed, therefore deterministic, order -- there is no unordered
//! iteration anywhere in this file to sort). A struct edit in `manifest.zig`
//! changes this file's OUTPUT the next time it runs, without this file
//! changing at all; that is the whole point.
//!
//! The `manifest_overrides`/`handoff_overrides` tables below are the one
//! genuinely hand-written part: Zig
//! has no comptime-reflectable doc comments, so the four honesty
//! requirements `manifest.zig`'s own module doc numbers 1-4 (plus the two
//! "null is a real, expected answer" notes for `BlockerSource.line` and
//! `IntegrationEntry.version`) have to be attached to the walked schema by
//! (type name, field name) lookup rather than lifted automatically. Getting
//! one of these wrong is a schema-authoring bug, not a structural-drift bug
//! -- `rails-check` cannot catch a wrong description, only a wrong shape.
//!
//! `@typeName(T)` (not a manually threaded label) is the lookup key: Zig
//! reports a `pub const` struct/enum's declaring module + name (e.g.
//! `"manifest.RouteEntry"`, `"routes.Source"` for the `RouteSource` alias),
//! which is itself derived from the type declarations rather than
//! independently chosen here, so a struct rename changes the lookup key
//! automatically instead of silently losing its override.
//!
//! `@typeName`'s full result is qualified by the WHOLE import chain from
//! whichever module is the compilation root, not just the declaring file --
//! `rails_schema_gen`'s own build (`build/rails_schema.zig`, this file as
//! root) resolves `manifest.RouteEntry` to exactly that two-segment string,
//! but a caller that reaches `manifest.zig` through more hops (this
//! directory's own `rails.zig` re-exports `manifest`, and `migrate.zig` /
//! `main.zig` import THAT) resolves the identical type to
//! `"cli.rails.manifest.RouteEntry"` instead -- confirmed by instrumenting
//! `overrideFor` while diagnosing a crash that only reproduced under `zig
//! build test-init` (main.zig's exe-module compile, which the module doc on
//! `rails.zig`'s own `test` block explains pulls every sibling file's tests
//! in too), never under this file's own tests or `rails-check` -- both of
//! those only ever exercise the schema_gen-as-root path, so the mismatch
//! was invisible until something elsewhere in the exe module pulled these
//! tests into a DIFFERENT root. `overrideFor` therefore keys on `@typeName`'s
//! last TWO dot-separated segments (`localTypeName`) -- the declaring
//! type's own name plus its immediate module -- which is fixed by `manifest.
//! zig`'s own boundary regardless of how many hops precede it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const handoff = @import("handoff.zig");

const draft = "https://json-schema.org/draft/2020-12/schema";
const schema_url = "https://zigapagos.dev/schema/rails-presentation/1";
const schema_title = "zigapagos Rails presentation manifest";
const schema_description =
    "The `zigapagos.rails-presentation/1` manifest emitted by " ++
    "`zigapagos migrate --from rails`. Written by `src/cli/rails/" ++
    "manifest.zig`'s `build`, which is the binding shape -- this schema " ++
    "is generated FROM that file's Zig types (`src/cli/rails/schema_gen." ++
    "zig`), not maintained by hand. Field order in every object below " ++
    "matches the manifest's actual emitted key order, which is part of " ++
    "the wire contract (see `manifest.zig`'s module doc).\n\n" ++
    "STABILITY. Every declared field appears in `required`, because the " ++
    "emitter always writes every key -- `null` included -- rather than " ++
    "omitting absent ones. Schema `/1` has not shipped in a release " ++
    "(the manifest landed after v0.4.0), so its shape is still being " ++
    "completed and a required field may still be added to it. Once a " ++
    "release carries `/1`, that stops: adding a required key to a " ++
    "published version would make two documents claiming the same " ++
    "version id disagree about what a conforming document contains, and " ++
    "the id would then assert a compatibility it does not have. After " ++
    "that point, additions bump the version.";

/// One hand-written description, attached to a field by (declaring type's
/// `@typeName`, field name). See the module doc's "What is generated vs.
/// hand-written" section for why this table -- and only this table -- is
/// not comptime-derived.
const Override = struct {
    type_name: []const u8,
    field: []const u8,
    text: []const u8,
};

const manifest_overrides = [_]Override{
    .{
        .type_name = "manifest.RouteEntry",
        .field = "id",
        .text = "`verb` + one space + `path` (e.g. \"GET /articles/:id\"). " ++
            "NOT a unique key: two identical route declarations in " ++
            "config/routes.rb -- an ordinary, if unusual, occurrence the " ++
            "parser does not reject -- produce the same id. Do not join " ++
            "on this field expecting uniqueness; a repeated id is a fact " ++
            "about the route table, not a generator defect to " ++
            "disambiguate away.",
    },
    .{
        .type_name = "manifest.BlockerEntry",
        .field = "route_id",
        .text = "Names ONE route affected by this blocker, not " ++
            "necessarily every route affected. RAILS_TEMPLATE_UNREADABLE " ++
            "in particular is deduplicated per FILE: a layout shared by " ++
            "twenty routes yields a single blocker carrying whichever " ++
            "route's scan happened to hit the unreadable file first. Do " ++
            "not treat this field as exhaustive -- fixing only the named " ++
            "route can leave every other affected route still broken. " ++
            "`null` when the blocker names no single route (e.g. an " ++
            "unreadable Gemfile).",
    },
    .{
        .type_name = "manifest.TemplateEntry",
        .field = "renders",
        .text = "The partials (and other templates) this template's scan " ++
            "resolved AND successfully read. NOT guaranteed complete: an " ++
            "empty array at the scan's depth cap means \"the walk stopped " ++
            "looking here\", not \"this template renders nothing\" (a " ++
            "RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED blocker names where the " ++
            "walk stopped), and a shorter-than-source array can mean one " ++
            "or more of this template's OWN render calls named a target " ++
            "the scan could not resolve -- a dynamic expression (`render " ++
            "@post`) or a literal matching no known template -- in which " ++
            "case a RAILS_TEMPLATE_RENDER_UNRESOLVED blocker on this same " ++
            "`path` names the dropped call. An unreadable template never " ++
            "becomes a `templates[]` entry at all, so every entry present " ++
            "here was itself successfully read; only its own render " ++
            "targets may be unresolved.",
    },
    .{
        .type_name = "manifest.BlockerSource",
        .field = "file",
        .text = "Source path the blocker concerns, relative to the app " ++
            "root -- never an absolute path from the machine that ran " ++
            "this tool. A blocker about the toolchain itself rather than " ++
            "one app file (e.g. a missing Ruby interpreter) names the " ++
            "sidecar script it ran (`sidecar/rails/analyze.rb`) here; " ++
            "machine-specific detail belongs in `message`, never in this " ++
            "field, so two machines running the same app produce the " ++
            "same manifest bytes.",
    },
    .{
        .type_name = "manifest.Manifest",
        .field = "templates",
        .text = "Every template this run's route scans resolved and " ++
            "read, deduplicated by path -- ROUTE-REACHABLE, not an " ++
            "app-wide listing of every file under app/views/. A template " ++
            "no recovered route's scan ever reaches (e.g. a mailer view) " ++
            "is simply absent, with no blocker naming the gap.",
    },
    .{
        .type_name = "manifest.RouteEntry",
        .field = "templates",
        .text = "The view plus every partial (direct or nested) this " ++
            "route's scan resolved and read. Can be SHORTER than the " ++
            "route's true template set: when a shared template (e.g. a " ++
            "layout) is unreadable, it drops out of every route that " ++
            "uses it, but RAILS_TEMPLATE_UNREADABLE names only ONE of " ++
            "those routes (see `blockers[].route_id`'s description) -- " ++
            "the other affected routes' shortened lists carry no " ++
            "blocker of their own.",
    },
    .{
        .type_name = "manifest.BlockerEntry",
        .field = "severity",
        .text = "Descriptive metadata about the finding -- a DIFFERENT " ++
            "axis from `integrity` on this same object (see that " ++
            "field's description); do not derive one from the other. A " ++
            "run that merely lacks Ruby reports `severity: \"error\"` " ++
            "blockers with `integrity: false`: filtering on `severity == " ++
            "\"error\"` alone will surface those on an otherwise " ++
            "perfectly healthy run.",
    },
    .{
        .type_name = "manifest.BlockerEntry",
        .field = "integrity",
        .text = "Whether this blocker means the manifest itself is " ++
            "untrustworthy -- this is the field the tool's exit code is " ++
            "computed from. A DIFFERENT axis from `severity` on this " ++
            "same object (see that field's description); do not derive " ++
            "one from the other. `integrity: false` blockers (e.g. Ruby " ++
            "genuinely unavailable) describe expected, non-failing " ++
            "degradation, not a defect to fix.",
    },
    .{
        .type_name = "manifest.BlockerSource",
        .field = "line",
        .text = "1-based source line, or `null` when this blocker " ++
            "genuinely has no single source line (an unreadable " ++
            "Gemfile, a missing sidecar). `null` here is a real, " ++
            "expected answer, never a placeholder for an unset value.",
    },
    .{
        .type_name = "manifest.IntegrationEntry",
        .field = "version",
        .text = "The Gemfile.lock-resolved version for a gem-sourced " ++
            "integration, the package.json dependency value for an " ++
            "npm-sourced one, or `null` when neither source names a " ++
            "version. `null` here is a real, expected answer, never a " ++
            "placeholder.",
    },
    .{
        .type_name = "manifest.Manifest",
        .field = "findings",
        .text = "Questions for the operator this run could not answer on " ++
            "its own -- each meant to be answered by id in a Stage 2 " ++
            "MIGRATION.decisions.json, not positionally. A SEPARATE array " ++
            "from `blockers[]` on purpose: a blocker is a fact about what " ++
            "discovery could or couldn't establish (drives the exit code " ++
            "via `integrity`); a finding is a per-fragment CHOICE this run " ++
            "leaves to the operator (keep an ERB helper as an island, " ++
            "retire it, block the route). A consumer filtering `blockers[]` " ++
            "for integrity facts must never see operator questions mixed in.",
    },
    .{
        .type_name = "manifest.FindingEntry",
        .field = "id",
        .text = "`<code>.<path>.<loc>` with `%` and `.` reversibly escaped " ++
            "(`%` -> `%25`, then `.` -> `%2E`) -- rails2zb's own scheme, " ++
            "reused rather than reimplemented. Stable across a reworded " ++
            "`message` or a template edit elsewhere in the file, so a " ++
            "Stage 2 decision file can reconcile against a PRIOR run's " ++
            "recorded operator choice even after either changes. This is " ++
            "the join key; `message` is prose and deliberately not part " ++
            "of it.",
    },
    .{
        .type_name = "manifest.FindingEntry",
        .field = "choices",
        .text = "The fixed set of answers an operator may record against " ++
            "this finding (e.g. \"island\", \"retain\", \"blocked\"). " ++
            "Always non-empty and always drawn from the derivation " ++
            "table's static choice sets -- never computed per finding.",
    },
    .{
        .type_name = "manifest.FindingEntry",
        .field = "requires_artifact",
        .text = "Whether resolving this finding requires generating an " ++
            "artifact (e.g. an island component) rather than merely " ++
            "recording a choice. `false` for every finding this generator " ++
            "version produces; reserved for a later finding kind that " ++
            "needs Stage 2 to emit something, not just record a decision.",
    },
};

const handoff_url = "https://zigapagos.dev/schema/rails-handoff/1";
const handoff_title = "zigapagos Rails migration handoff";
const handoff_description =
    "The `zigapagos.rails-handoff/1` document emitted as " ++
    "`MIGRATION.handoff.json` by `zigapagos migrate --from rails " ++
    "--target DIR`. Written by `src/cli/rails/handoff.zig`'s `build`, " ++
    "which is the binding shape -- this schema is generated FROM that " ++
    "file's Zig types (`src/cli/rails/schema_gen.zig`), not maintained " ++
    "by hand. Field order in every object below matches the emitted key " ++
    "order, which is part of the wire contract.\n\n" ++
    "A SEPARATE artifact from `zigapagos.rails-presentation/1`, and " ++
    "separately versioned: the manifest records what DISCOVERY " ++
    "established about the Rails app; this document records what the " ++
    "CONVERSION produced, and is expected to change on every run of the " ++
    "decide-then-re-run loop. Where a route's `status` here and the " ++
    "manifest's `classification` disagree, the conversion wins.\n\n" ++
    "STABILITY. Every declared field appears in `required`, because the " ++
    "emitter always writes every key -- `null` included -- rather than " ++
    "omitting absent ones. Schema `/1` has not shipped in a release, so " ++
    "its shape is still being completed and a required field may still " ++
    "be added while the remaining Stage 5 parity contract is completed. Once a " ++
    "release carries `/1`, that stops: adding a required key to a " ++
    "published version would make two documents claiming the same " ++
    "version id disagree about what a conforming document contains. " ++
    "After that point, additions bump the version.";

/// The handoff's own hand-written descriptions. A SECOND table rather than
/// more rows in `manifest_overrides`: `overrideFor` keys on (`localTypeName`,
/// field), and both documents declare a `RouteEntry` -- one table would let
/// a manifest row silently attach itself to a handoff field, or vice versa,
/// the moment the two modules' type names converged. Keeping the tables
/// per-document makes that impossible by construction and keeps each
/// document's "every override matched" check scoped to its own walk.
const handoff_overrides = [_]Override{
    .{
        .type_name = "handoff.RouteEntry",
        .field = "route_id",
        .text = "`verb` + one space + `path` (e.g. \"GET /about\"), the " ++
            "same label the manifest's `routes[].id` carries. NOT a " ++
            "unique key: two identical route declarations in " ++
            "config/routes.rb produce the same id, and this document may " ++
            "additionally carry more than one entry for one route. Do " ++
            "not join on this field expecting uniqueness.",
    },
    .{
        .type_name = "handoff.RouteEntry",
        .field = "status",
        .text = "What the CONVERSION produced for this route -- a " ++
            "different question from the manifest's `classification`, " ++
            "which is discovery's verdict about the Rails route and is " ++
            "never revised. Where the two disagree, this field wins. " ++
            "`open` is the default and means neither the converter nor " ++
            "an operator decision has accounted for the route yet.",
    },
    .{
        .type_name = "handoff.RouteEntry",
        .field = "endpoint",
        .text = "The backend endpoint this route became. ALWAYS `null` " ++
            "in the version of the tool that generated this schema -- no " ++
            "route becomes an endpoint yet; the field is on the wire " ++
            "anyway so a consumer reads one shape across versions.",
    },
    .{
        .type_name = "handoff.RouteEntry",
        .field = "findings",
        .text = "`findings[].id`s from the companion manifest that this " ++
            "route left OPEN -- the join key an operator answers in " ++
            "MIGRATION.decisions.json. Sorted lexicographically. An " ++
            "empty array means this route asks nothing, NOT that the " ++
            "route converted: read `status` for that.",
    },
    .{
        .type_name = "handoff.RouteEntry",
        .field = "note",
        .text = "Free prose for a human reader (e.g. \"deferred to Stage " ++
            "3/4\"). Not identity, not a stable string, and not parsed " ++
            "by anything -- never branch on its content.",
    },
    .{
        .type_name = "handoff.Handoff",
        .field = "complete",
        .text = "True iff EVERY route whose verb is GET or HEAD has " ++
            "`status` in {migrated, redirect, backend}, or `retained`/" ++
            "`blocked` with a non-null `decision`. Deliberately says " ++
            "nothing about POST/PATCH/DELETE routes: those are form/API " ++
            "traffic a later stage handles, and leaving them unconverted " ++
            "does not make the site broken to browse. `backend` counts " ++
            "for the same reason -- it marks a route that needs no page " ++
            "at all; which endpoint it maps to is asked separately, by a " ++
            "RAILS_BACKEND_ENDPOINT finding. A user-facing route with no " ++
            "entry in `routes[]` at all counts as open, so a converter " ++
            "that silently skipped a route cannot report completion.",
    },
    .{
        .type_name = "handoff.Handoff",
        .field = "backend",
        .text = "The backend contract this migration used, or `null` when " ++
            "the operator supplied no `--backend` document. Its file is a " ++
            "basename so the handoff never leaks a machine path.",
    },
    .{
        .type_name = "handoff.Handoff",
        .field = "parity",
        .text = "Deterministic replayable checks derived from written " ++
            "migration artifacts or applied endpoints. Each `kind` is " ++
            "correlated with its typed `expect` payload by the `oneOf` " ++
            "arms. An empty array means this run produced no replayable " ++
            "evidence, not that parity was proved.",
    },
    .{
        .type_name = "handoff.AssetEntry",
        .field = "rails_url",
        .text = "The URL Rails served this asset at. `null` is a real, " ++
            "expected answer -- an asset the run could not attribute a " ++
            "Rails URL to (no fingerprinted manifest entry, or a " ++
            "`public/`-relative file Rails served directly) -- not a " ++
            "value the generator failed to compute.",
    },
    .{
        .type_name = "handoff.RedirectEntry",
        .field = "to",
        .text = "`null` when the redirect's target could not be resolved " ++
            "to a URL on the migrated site, which is a real answer: the " ++
            "operator has to supply the destination in host config. Not " ++
            "a placeholder for a value this generator gave up on " ++
            "silently.",
    },
};

/// F5 (phase-2-review.md, MEDIUM): how many times each override entry
/// actually matched a walked (type, field) pair during the most recent
/// generate call for that document -- test-only instrumentation, reset at
/// the top of `generateDoc`. `overrideFor`'s lookup already broke once,
/// silently, under `@typeName`'s module-path variance (see `localTypeName`'s
/// doc); this is what turns a repeat of that shape -- an override whose
/// `type_name`/`field` no longer matches ANYTHING walked -- into a test
/// failure instead of a description that quietly stopped reaching the
/// schema. Not part of the generator's own output and not read by
/// `generateDoc` itself, so it carries no allocation and needs no contract
/// label. One array per document, for the reason `handoff_overrides`'s doc
/// gives.
var manifest_override_hits: [manifest_overrides.len]u32 = @splat(0);
var handoff_override_hits: [handoff_overrides.len]u32 = @splat(0);

/// `table` is comptime and `hits` is its matching counter array, threaded
/// down the walk rather than read from a module-level "currently active
/// document" variable: two documents share this walk, and a hidden global
/// would make which table applies depend on call order.
fn overrideFor(
    comptime table: []const Override,
    hits: []u32,
    type_name: []const u8,
    field: []const u8,
) ?[]const u8 {
    const local = localTypeName(type_name);
    for (table, 0..) |o, i| {
        if (std.mem.eql(u8, o.type_name, local) and
            std.mem.eql(u8, o.field, field))
        {
            hits[i] += 1;
            return o.text;
        }
    }
    return null;
}

/// The last two dot-separated segments of `@typeName`'s result (e.g.
/// `"cli.rails.manifest.RouteEntry"` -> `"manifest.RouteEntry"`) -- see the
/// module doc's note on why `overrideFor` cannot key on the full qualified
/// name. Falls back to `type_name` unchanged when it has fewer than two
/// dots (defensive; every type this file ever looks up has at least
/// `<module>.<Name>`, but a shorter name is a harmless no-op here rather
/// than an out-of-bounds slice).
fn localTypeName(type_name: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, type_name, '.') orelse return type_name;
    const second_last_dot = std.mem.lastIndexOfScalar(u8, type_name[0..last_dot], '.') orelse return type_name;
    return type_name[second_last_dot + 1 ..];
}

test "localTypeName: strips every prefix but the declaring module and type" {
    try std.testing.expectEqualStrings("manifest.RouteEntry", localTypeName("manifest.RouteEntry"));
    try std.testing.expectEqualStrings("manifest.RouteEntry", localTypeName("cli.rails.manifest.RouteEntry"));
    try std.testing.expectEqualStrings("manifest.RouteEntry", localTypeName("root.migrate.rails.manifest.RouteEntry"));
    // Fewer than two segments: returned unchanged rather than panicking.
    try std.testing.expectEqualStrings("RouteEntry", localTypeName("RouteEntry"));
}

fn strVal(s: []const u8) std.json.Value {
    return .{ .string = s };
}

/// Contract 1 (self-freeing): the only allocation is the returned object's
/// backing storage, which is `arena`-owned -- `arena` itself is never
/// deinited by this function (that is the caller's, i.e. `generate`'s, job,
/// per the module doc on why `schemaFor` and friends are `generate`'s
/// private implementation, not an independent arena-scoped contract 4
/// surface: nothing here is ever called with a bare `Allocator` that isn't
/// `generate`'s own single internal arena).
fn simpleType(arena: Allocator, name: []const u8) Allocator.Error!std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "type", strVal(name));
    return .{ .object = o };
}

/// Turns `inner` (an already-built schema object) into its nullable form by
/// widening its own `"type"` entry into a two-element array ending in
/// `"null"`, in place -- `inner` is always a schema object freshly built by
/// this same call chain (never a shared/reused value), so mutating it here
/// cannot alias anything a caller still depends on unmodified.
///
/// F1 (phase-2-review.md, HIGH): `type` and a sibling `enum` are
/// CONJUNCTIVE in JSON Schema, so widening `type` alone leaves an enum'd
/// field like `{"type":["string","null"],"enum":["propshaft",
/// "sprockets"]}` -- `null` satisfies `type` but fails `enum`, so it can
/// never validate. `assets.Asset.pipeline` (`?Pipeline`) is not exotic:
/// EVERY `public/`-relative asset emits `pipeline: null`, so the published
/// schema rejected the manifest the tool actually produces on the
/// unmodified fixture. Widening a present `enum` array with `null` too --
/// generically, for ANY nullable enum a future type adds, not just this
/// one -- is what closes that: `null` then satisfies both keywords, exactly
/// like every other nullable scalar here already does.
fn nullableOf(arena: Allocator, inner: std.json.Value) Allocator.Error!std.json.Value {
    var v = inner;
    const base_type = v.object.get("type").?;
    var types: std.json.Array = .init(arena);
    try types.append(base_type);
    try types.append(strVal("null"));
    try v.object.put(arena, "type", .{ .array = types });
    if (v.object.getPtr("enum")) |enum_field| {
        try enum_field.array.append(.null);
    }
    return v;
}

fn enumSchema(comptime T: type, arena: Allocator) Allocator.Error!std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "type", strVal("string"));
    var members: std.json.Array = .init(arena);
    // `@typeInfo(T).@"enum".fields` is comptime-ordered exactly as `T`'s
    // own declaration lists its members -- no runtime iteration to sort.
    inline for (@typeInfo(T).@"enum".fields) |f| {
        try members.append(strVal(f.name));
    }
    try o.put(arena, "enum", .{ .array = members });
    return .{ .object = o };
}

fn structSchema(
    comptime T: type,
    comptime table: []const Override,
    hits: []u32,
    arena: Allocator,
) Allocator.Error!std.json.Value {
    const type_name = @typeName(T);
    var props: std.json.ObjectMap = .empty;
    var required: std.json.Array = .init(arena);
    // `std.meta.fields(T)` walks in T's own declaration order (comptime,
    // therefore fixed on every run) -- this IS the wire key order the
    // manifest emitter (`manifest.zig`'s `build`, via `std.json.
    // Stringify`) actually produces, per that file's own "key ordering is
    // the wire contract" doc. Every field is listed in `required`: the
    // emitter always writes every declared key, `null` included, for an
    // optional field -- see `manifest.zig`'s golden-bytes test, where
    // `"version": null` is a present key, not an absent one.
    inline for (std.meta.fields(T)) |f| {
        var field_schema = try schemaFor(f.type, table, hits, arena);
        if (overrideFor(table, hits, type_name, f.name)) |text| {
            try field_schema.object.put(arena, "description", strVal(text));
        }
        try props.put(arena, f.name, field_schema);
        try required.append(strVal(f.name));
    }
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "type", strVal("object"));
    try o.put(arena, "properties", .{ .object = props });
    try o.put(arena, "required", .{ .array = required });
    try o.put(arena, "additionalProperties", .{ .bool = false });
    return .{ .object = o };
}

/// Schema for a tagged union whose type declares `json_schema_tag_field` and
/// whose custom JSON serializer flattens each struct payload, inserting that
/// tag after the payload's first field. The metadata lives on the wire type,
/// so this remains a structural walk rather than a ParityEntry special case.
fn flattenedTaggedUnionSchema(
    comptime T: type,
    comptime table: []const Override,
    hits: []u32,
    arena: Allocator,
) Allocator.Error!std.json.Value {
    if (!@hasDecl(T, "json_schema_tag_field")) {
        @compileError("rails schema_gen: tagged union needs json_schema_tag_field: " ++ @typeName(T));
    }
    const tag_field: []const u8 = @field(T, "json_schema_tag_field");
    const info = @typeInfo(T).@"union";
    if (info.tag_type == null) {
        @compileError("rails schema_gen: untagged union unsupported: " ++ @typeName(T));
    }

    var arms: std.json.Array = .init(arena);
    inline for (info.fields) |variant| {
        const payload_info = @typeInfo(variant.type);
        if (payload_info != .@"struct") {
            @compileError("rails schema_gen: flattened union payload must be a struct: " ++ @typeName(variant.type));
        }

        var props: std.json.ObjectMap = .empty;
        var required: std.json.Array = .init(arena);
        inline for (std.meta.fields(variant.type), 0..) |field, i| {
            var field_schema = try schemaFor(field.type, table, hits, arena);
            if (overrideFor(table, hits, @typeName(variant.type), field.name)) |text| {
                try field_schema.object.put(arena, "description", strVal(text));
            }
            try props.put(arena, field.name, field_schema);
            try required.append(strVal(field.name));
            if (i == 0) {
                var tag_schema: std.json.ObjectMap = .empty;
                try tag_schema.put(arena, "type", strVal("string"));
                try tag_schema.put(arena, "const", strVal(variant.name));
                try props.put(arena, tag_field, .{ .object = tag_schema });
                try required.append(strVal(tag_field));
            }
        }
        var arm: std.json.ObjectMap = .empty;
        try arm.put(arena, "type", strVal("object"));
        try arm.put(arena, "properties", .{ .object = props });
        try arm.put(arena, "required", .{ .array = required });
        try arm.put(arena, "additionalProperties", .{ .bool = false });
        try arms.append(.{ .object = arm });
    }

    var out: std.json.ObjectMap = .empty;
    try out.put(arena, "oneOf", .{ .array = arms });
    return .{ .object = out };
}

/// The comptime type walk. Every branch returns a JSON Schema OBJECT value
/// (never a bare scalar), so a caller may always widen the result via
/// `field_schema.object.put(arena, ...)` (`structSchema` does exactly that to
/// attach an `overrides` description) without a tag check.
fn schemaFor(
    comptime T: type,
    comptime table: []const Override,
    hits: []u32,
    arena: Allocator,
) Allocator.Error!std.json.Value {
    return switch (@typeInfo(T)) {
        .bool => simpleType(arena, "boolean"),
        .int => |info| blk: {
            var o: std.json.ObjectMap = .empty;
            try o.put(arena, "type", strVal("integer"));
            if (info.signedness == .unsigned) try o.put(arena, "minimum", .{ .integer = 0 });
            break :blk .{ .object = o };
        },
        .@"enum" => enumSchema(T, arena),
        .optional => |opt| blk: {
            const inner = try schemaFor(opt.child, table, hits, arena);
            break :blk try nullableOf(arena, inner);
        },
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) {
                @compileError("rails schema_gen: unsupported pointer kind for " ++ @typeName(T));
            }
            if (ptr.child == u8) break :blk try simpleType(arena, "string");
            const items = try schemaFor(ptr.child, table, hits, arena);
            var o: std.json.ObjectMap = .empty;
            try o.put(arena, "type", strVal("array"));
            try o.put(arena, "items", items);
            break :blk .{ .object = o };
        },
        .@"struct" => structSchema(T, table, hits, arena),
        .@"union" => flattenedTaggedUnionSchema(T, table, hits, arena),
        else => @compileError("rails schema_gen: unsupported type " ++ @typeName(T)),
    };
}

/// Contract 1 (self-freeing): builds the whole JSON Schema document in a
/// private arena over `gpa` (scratch: every `std.json.ObjectMap`/`Array`
/// the walk above allocates), frees that arena unconditionally via `defer`,
/// and returns the ONE allocation that escapes -- the serialized bytes,
/// allocated straight from `gpa` by `std.json.Stringify.valueAlloc` (which
/// does not need the `std.json.Value` tree it serializes to share its own
/// allocator). Mirrors `manifest.build`'s identical shape one level up: a
/// scratch structure freed in full, a single owned buffer returned.
fn generateDoc(
    comptime T: type,
    comptime table: []const Override,
    hits: []u32,
    gpa: Allocator,
    url: []const u8,
    title: []const u8,
    description: []const u8,
) Allocator.Error![]u8 {
    // Reset this document's override hits before its walk -- see their doc.
    @memset(hits, 0);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try structSchema(T, table, hits, arena);

    var doc: std.json.ObjectMap = .empty;
    try doc.put(arena, "$schema", strVal(draft));
    try doc.put(arena, "$id", strVal(url));
    try doc.put(arena, "title", strVal(title));
    try doc.put(arena, "description", strVal(description));
    try doc.put(arena, "type", root.object.get("type").?);
    try doc.put(arena, "properties", root.object.get("properties").?);
    try doc.put(arena, "required", root.object.get("required").?);
    try doc.put(arena, "additionalProperties", root.object.get("additionalProperties").?);

    var out = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = doc }, .{ .whitespace = .indent_2 });
    errdefer gpa.free(out);
    // Trailing newline, matching `manifest.zig`'s `build` and this repo's
    // other committed JSON artifacts (e.g. contract/zigbase.openapi.json) --
    // what keeps a plain `git diff` on the written file clean.
    out = try gpa.realloc(out, out.len + 1);
    out[out.len - 1] = '\n';
    return out;
}

/// `contract/rails-presentation.v1.schema.json`, from `manifest.Manifest`.
pub fn generate(gpa: Allocator) Allocator.Error![]u8 {
    return generateDoc(
        manifest.Manifest,
        &manifest_overrides,
        &manifest_override_hits,
        gpa,
        schema_url,
        schema_title,
        schema_description,
    );
}

/// `contract/rails-handoff.v1.schema.json`, from `handoff.Handoff`. A second
/// entry point rather than a second generator: the `@typeInfo` walk above is
/// document-agnostic, and the only per-document inputs are the root type,
/// its override table and the three header strings.
pub fn generateHandoff(gpa: Allocator) Allocator.Error![]u8 {
    return generateDoc(
        handoff.Handoff,
        &handoff_overrides,
        &handoff_override_hits,
        gpa,
        handoff_url,
        handoff_title,
        handoff_description,
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    // One document per invocation, selected by `--handoff`, rather than two
    // output paths in one run: `build/rails_schema.zig` gives each schema
    // its own Run/`git add`/`git diff` chain so a failing gate names the
    // file that drifted. A single combined step could only say "one of the
    // two".
    const handoff_mode = args.len == 3 and std.mem.eql(u8, args[1], "--handoff");
    if (!handoff_mode and args.len != 2) fatal(
        "usage: rails_schema_gen [--handoff] <out-path>\n" ++
            "  default: the generated JSON Schema for the rails-presentation/1\n" ++
            "           manifest (src/cli/rails/manifest.zig's types)\n" ++
            "  --handoff: the generated JSON Schema for the rails-handoff/1\n" ++
            "           document (src/cli/rails/handoff.zig's types)\n",
        .{},
    );
    const out_path = args[args.len - 1];

    // `generate`/`generateHandoff` are Contract 1 -- `arena` here is the
    // process's own top-level arena (freed whole at process exit), so
    // passing it as their `gpa` is a normal CLI-main allocation choice, not
    // the "arena wraps testing.allocator" pattern `scripts/check-allocator-
    // contracts.sh` flags: there is no `const gpa = testing.allocator;`
    // alias anywhere in this file for that scanner to find.
    const bytes = if (handoff_mode) try generateHandoff(arena) else try generate(arena);

    const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch |err| fatal(
        "error creating '{s}': {t}\n",
        .{ out_path, err },
    );
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

const testing = std.testing;

test "generate: produces well-formed, parseable JSON" {
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(out[out.len - 1] == '\n');

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(draft, parsed.value.object.get("$schema").?.string);
    try testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);
}

test "generate: is byte-identical across two independent runs" {
    // The property `rails-check` (build/rails_schema.zig) rests on: this
    // generator must never depend on anything unordered. If it did, this
    // test -- not just the drift gate -- would flap.
    const gpa = testing.allocator;
    const a = try generate(gpa);
    defer gpa.free(a);
    const b = try generate(gpa);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "generate: top-level required lists every Manifest field, in declaration order" {
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const required = parsed.value.object.get("required").?.array.items;
    const want = [_][]const u8{
        "schema",       "schema_version", "generator", "source",
        "discovery",    "routes",         "templates", "assets",
        "integrations", "blockers",       "findings",
    };
    try testing.expectEqual(want.len, required.len);
    for (want, required) |w, r| try testing.expectEqualStrings(w, r.string);
}

test "generate: routes[].id carries the 'not a unique key' override" {
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const route_props = parsed.value.object.get("properties").?.object
        .get("routes").?.object.get("items").?.object
        .get("properties").?.object;
    const id_desc = route_props.get("id").?.object.get("description").?.string;
    try testing.expect(std.mem.indexOf(u8, id_desc, "NOT a unique key") != null);
}

test "generate: BlockerSource.line is nullable integer, not a bare integer" {
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const blocker_props = parsed.value.object.get("properties").?.object
        .get("blockers").?.object.get("items").?.object
        .get("properties").?.object;
    const source_props = blocker_props.get("source").?.object
        .get("properties").?.object;
    const line_types = source_props.get("line").?.object.get("type").?.array.items;
    try testing.expectEqual(@as(usize, 2), line_types.len);
    try testing.expectEqualStrings("integer", line_types[0].string);
    try testing.expectEqualStrings("null", line_types[1].string);
}

test "generate: Confidence enum lists exactly certain/uncertain" {
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const route_props = parsed.value.object.get("properties").?.object
        .get("routes").?.object.get("items").?.object
        .get("properties").?.object;
    const members = route_props.get("confidence").?.object.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 2), members.len);
    try testing.expectEqualStrings("certain", members[0].string);
    try testing.expectEqualStrings("uncertain", members[1].string);
}

test "generate: Severity enum reports the wire value 'error', not the escaped identifier" {
    // blockers.Severity's first member is spelled `@\"error\"` in Zig
    // (a reserved word needs escaping); the WIRE value -- and this
    // schema's enum member -- must be the bare string "error".
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const blocker_props = parsed.value.object.get("properties").?.object
        .get("blockers").?.object.get("items").?.object
        .get("properties").?.object;
    const members = blocker_props.get("severity").?.object.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 2), members.len);
    try testing.expectEqualStrings("error", members[0].string);
    try testing.expectEqualStrings("warn", members[1].string);
}

test "generate: assets[].pipeline (a nullable enum) admits null in BOTH type and enum, not just type" {
    // F1 (phase-2-review.md, HIGH): `type` and a sibling `enum` are
    // conjunctive in JSON Schema -- widening only `type` left `null`
    // satisfying `type` but failing `enum`, so the generated schema
    // rejected `pipeline: null`, which every `public/`-relative asset in
    // the real fixture emits. Fixed generically in `nullableOf` (any
    // nullable enum), not by special-casing this one field -- this test
    // exercises it through the one nullable enum the format has today.
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const asset_props = parsed.value.object.get("properties").?.object
        .get("assets").?.object.get("items").?.object
        .get("properties").?.object;
    const pipeline = asset_props.get("pipeline").?.object;

    const types = pipeline.get("type").?.array.items;
    try testing.expectEqual(@as(usize, 2), types.len);
    try testing.expectEqualStrings("string", types[0].string);
    try testing.expectEqualStrings("null", types[1].string);

    const members = pipeline.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 3), members.len);
    try testing.expectEqualStrings("propshaft", members[0].string);
    try testing.expectEqualStrings("sprockets", members[1].string);
    try testing.expect(members[2] == .null);
}

test "generate: every override entry matches at least one walked (type, field) pair" {
    // F5 (phase-2-review.md, MEDIUM): confirmed by mutation -- pointing
    // one override's `type_name` at a typo left BOTH `test-rails` and
    // `test-init` green, because only `routes[].id`'s override had a
    // dedicated test asserting its text reached the schema. This asserts
    // the WHOLE table stays reachable, not just the one entry a prior test
    // happened to check.
    const gpa = testing.allocator;
    const out = try generate(gpa);
    defer gpa.free(out);

    for (manifest_overrides, manifest_override_hits) |o, hits| {
        if (hits == 0) std.debug.print(
            "unmatched schema override: {s}.{s} -- overrideFor never matched this (type, field) pair\n",
            .{ o.type_name, o.field },
        );
        try testing.expect(hits > 0);
    }
}

test "generateHandoff: every override entry matches at least one walked (type, field) pair" {
    // Same guarantee as the manifest table's, for the handoff's own table.
    // Written as its own test rather than folded into the one above because
    // the hit counters are per-DOCUMENT: a run of `generate` leaves the
    // handoff counters at whatever the previous `generateHandoff` set, so
    // the assertion has to follow the call that populated them.
    const gpa = testing.allocator;
    const out = try generateHandoff(gpa);
    defer gpa.free(out);

    for (handoff_overrides, handoff_override_hits) |o, hits| {
        if (hits == 0) std.debug.print(
            "unmatched handoff schema override: {s}.{s} -- overrideFor never matched this (type, field) pair\n",
            .{ o.type_name, o.field },
        );
        try testing.expect(hits > 0);
    }
}

test "generateHandoff: produces well-formed JSON with the handoff document's own header" {
    const gpa = testing.allocator;
    const out = try generateHandoff(gpa);
    defer gpa.free(out);
    try testing.expect(out.len > 0);
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(draft, parsed.value.object.get("$schema").?.string);
    try testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);
    // The two documents must not share an `$id`: a consumer resolving one
    // and getting the other's shape is exactly what a distinct id prevents.
    try testing.expectEqualStrings(handoff_url, parsed.value.object.get("$id").?.string);
    try testing.expect(!std.mem.eql(u8, schema_url, handoff_url));
}

test "generateHandoff: is byte-identical across two independent runs" {
    // The property the handoff half of `rails-check` rests on, asserted for
    // this document too rather than assumed to follow from the manifest's.
    const gpa = testing.allocator;
    const a = try generateHandoff(gpa);
    defer gpa.free(a);
    const b = try generateHandoff(gpa);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "generateHandoff: top-level required lists every Handoff field, in declaration order" {
    const gpa = testing.allocator;
    const out = try generateHandoff(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const required = parsed.value.object.get("required").?.array.items;
    const want = [_][]const u8{
        "schema", "schema_version", "generator", "backend", "complete",
        "routes", "assets",         "redirects", "parity",
    };
    try testing.expectEqual(want.len, required.len);
    for (want, required) |w, r| try testing.expectEqualStrings(w, r.string);
}

test "generateHandoff: routes[] items carry the wire field order and the Status enum" {
    const gpa = testing.allocator;
    const out = try generateHandoff(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("properties").?.object
        .get("routes").?.object.get("items").?.object;
    const required = items.get("required").?.array.items;
    const want = [_][]const u8{
        "route_id", "status",   "artifacts", "endpoint",
        "decision", "findings", "note",
    };
    try testing.expectEqual(want.len, required.len);
    for (want, required) |w, r| try testing.expectEqualStrings(w, r.string);

    const members = items.get("properties").?.object.get("status").?.object
        .get("enum").?.array.items;
    const want_members = [_][]const u8{
        "migrated", "open", "blocked", "retained", "backend", "redirect",
    };
    try testing.expectEqual(want_members.len, members.len);
    for (want_members, members) |w, m| try testing.expectEqualStrings(w, m.string);
}

test "generateHandoff: backend and routes[].endpoint are nullable objects, not bare objects" {
    // Both are `null` in every document this version emits. A schema that
    // typed them as a bare object would reject every real handoff.
    const gpa = testing.allocator;
    const out = try generateHandoff(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;

    const backend_types = props.get("backend").?.object.get("type").?.array.items;
    try testing.expectEqual(@as(usize, 2), backend_types.len);
    try testing.expectEqualStrings("object", backend_types[0].string);
    try testing.expectEqualStrings("null", backend_types[1].string);

    const endpoint = props.get("routes").?.object.get("items").?.object
        .get("properties").?.object.get("endpoint").?.object;
    const endpoint_types = endpoint.get("type").?.array.items;
    try testing.expectEqual(@as(usize, 2), endpoint_types.len);
    try testing.expectEqualStrings("object", endpoint_types[0].string);
    try testing.expectEqualStrings("null", endpoint_types[1].string);
}

test "generateHandoff: parity oneOf correlates each kind with its expect payload" {
    const gpa = testing.allocator;
    const out = try generateHandoff(gpa);
    defer gpa.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const parity_items = parsed.value.object.get("properties").?.object
        .get("parity").?.object.get("items").?.object;
    const arms = parity_items.get("oneOf").?.array.items;
    try testing.expectEqual(@as(usize, 7), arms.len);
    const kinds = [_][]const u8{ "navigate", "asset", "signup", "signin", "submit_allowed", "submit_denied", "validation_error" };
    for (kinds, arms) |kind, arm| {
        try testing.expectEqualStrings(kind, arm.object.get("properties").?.object.get("kind").?.object.get("const").?.string);
    }

    const navigate = arms[0].object;
    const required = navigate.get("required").?.array.items;
    const want = [_][]const u8{ "id", "kind", "url", "expect" };
    try testing.expectEqual(want.len, required.len);
    for (want, required) |expected, actual| try testing.expectEqualStrings(expected, actual.string);
    const props = navigate.get("properties").?.object;
    try testing.expectEqualStrings("navigate", props.get("kind").?.object.get("const").?.string);
    const expect_required = props.get("expect").?.object.get("required").?.array.items;
    const expect_want = [_][]const u8{ "status", "title", "h1", "links" };
    try testing.expectEqual(expect_want.len, expect_required.len);
    for (expect_want, expect_required) |expected, actual| try testing.expectEqualStrings(expected, actual.string);
}

test "generate/generateHandoff: the two documents do not share an override table" {
    // `overrideFor` keys on the last two segments of `@typeName`, and BOTH
    // modules declare a `RouteEntry`. One shared table would let a manifest
    // description land on a handoff field. Asserted through the output:
    // the manifest's `routes[].id` caveat must not appear anywhere in the
    // handoff document, and vice versa for the handoff's `complete` rule.
    const gpa = testing.allocator;
    const m = try generate(gpa);
    defer gpa.free(m);
    const h = try generateHandoff(gpa);
    defer gpa.free(h);

    try testing.expect(std.mem.indexOf(u8, m, "NOT a unique key") != null);
    try testing.expect(std.mem.indexOf(u8, h, "NOT a unique key") != null);
    // The manifest's own text, verbatim, must NOT have leaked across.
    try testing.expect(std.mem.indexOf(u8, h, "a repeated id is a fact about the route table") == null);
    try testing.expect(std.mem.indexOf(u8, m, "does not make the site broken to browse") == null);
    try testing.expect(std.mem.indexOf(u8, h, "does not make the site broken to browse") != null);
}
