//! Package root for the Rails migration adapter, and the `standalone` test
//! suite root for `zig build test-rails`.
//!
//! Everything below is std-only: no import escapes `src/cli/rails/`, so this
//! compiles as its own module. `fatal.*` handling belongs to migrate.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const assets = @import("assets.zig");
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
pub const manifest = @import("manifest.zig");

// Pulls the suites of every sibling file into this module so `test-rails`
// runs them all. Without this the standalone binary never sees them --
// `_ = sidecar_client` is required here even though that file currently has
// no `test` blocks of its own: without the `_ =` reference this module's
// lazy analysis (Zig 0.16) never reaches `sidecar_client.zig`'s decls at
// all, so a test ADDED there later would silently not run either.
test {
    std.testing.refAllDecls(@This());
    _ = assets;
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
    _ = manifest;
}

/// Discovery's result: the rendered report plus how many of its blockers mean
/// the inventory itself can't be trusted (`Blocker.integrity`).
/// `src/cli/migrate.zig`'s Rails block turns a nonzero
/// `integrity_blocker_count` into a non-zero exit -- the report is still
/// written either way, per the "report, never omit silently" rule; only the
/// process exit status changes.
///
/// Contract 2 (owned-result) as of Stage 4 Task 4: `report` used to be the
/// one escaping allocation (see `discover`'s own doc, pre-Task-4), but
/// `route_templates`/`templates` below now escape too -- both own real
/// `gpa` strings dupe'd out of `wr.entries`, which `discover` frees before
/// returning (see `RouteTemplates`'/`TemplateNode`'s docs for why duping,
/// not borrowing, was the only option). Release the whole struct with
/// `freeDiscovery`, not a bare `gpa.free(discovery.report)` anymore.
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
    /// Count of blockers by `Blocker.severity` (fix round 1,
    /// task-1-fixes.md item 2): the brief asks for "the count of each [on
    /// the fixture]" to be discriminated, but `report.build` does not
    /// render `severity` at all (that is Task 8's manifest's job, not this
    /// report's -- growing the report's format just to make a shell-level
    /// grep possible would be the wrong trade). These two counts exist so a
    /// test can assert the fixture's exact severity distribution at the Zig
    /// level, the same way `integrity_blocker_count` above already lets one
    /// assert the `integrity` distribution without the report rendering
    /// THAT either. Computed in the same loop as `integrity_blocker_count`
    /// or `route_blocker` -- they read the same short-lived `blocker_list`
    /// before it is freed, so there is no reason to spend a second pass.
    severity_error_count: usize,
    severity_warn_count: usize,
    /// `discovery.ruby` (spec, "The manifest"): the COMBINED answer for
    /// whether Ruby was available to this run, built by `combineRuby` from
    /// `route_result.ruby` (`routes` op) and `ctrl_result.ruby`
    /// (`controllers` op) -- see `RubyInfo`'s own doc for why this exists
    /// (Stage 4's task-2-fixes.md item 1).
    ruby: RubyInfo,
    /// Stage 4 Task 4: the template graph the transitive scan already walks,
    /// surfaced for Task 8's (not-yet-built) manifest emitter --
    /// `routes[].templates[]` / `routes[].layout` (spec, "The manifest").
    /// Index-aligned with `route_result.routes`, the same alignment
    /// `classifications` already relied on before `report.build` consumed
    /// and discarded it. See `RouteTemplates`'s doc for the duping choice.
    route_templates: []RouteTemplates,
    /// The ROUTE-REACHABLE, deduplicated template catalog -- manifest's
    /// top-level `templates[]` (spec, "The manifest"), one entry per
    /// DISTINCT path across every route's scan, sorted by path
    /// (determinism). Not app-wide (F4a, phase-2-review.md): a template no
    /// recovered route's scan ever reaches (e.g. a mailer view) is simply
    /// absent from this list, with no blocker naming the gap.
    templates: []TemplateNode,
    /// Stage 4 Task 6: the manifest's top-level `assets[]` (spec, "The
    /// manifest") -- one `assets.Asset` per `Kind.asset` inventory entry,
    /// already in path order (see `assets.scan`'s doc for why no separate
    /// sort is needed here). Escapes into this struct the same way
    /// `route_templates`/`templates` do; released by `freeDiscovery`.
    assets: []assets.Asset,
    /// Fix round 2 (phase-1-review.md F5 / phase-1-fixes.md section 2):
    /// manifest's `source.version` (spec, "The manifest") -- `detect.
    /// detectVersion`'s result, called from HERE rather than left as a
    /// producer with no caller (Task 7 shipped the parser but never wired
    /// it: `detectVersion` had no production caller anywhere, so `source.
    /// version` was unproduced end to end and `RAILS_GEMFILE_LOCK_
    /// UNAVAILABLE` was unreachable). Called from inside `discover` rather
    /// than by a future Phase 2 emitter after `discover` returns because
    /// the blocker it can append belongs in THIS run's `blocker_list`,
    /// which is created and freed inside this function -- there is no
    /// later seam for a blocker to land in.
    version: detect.Version,
    /// Fix round 2 (phase-1-review.md F7 / phase-1-fixes.md section 2): the
    /// manifest's `routes[]` (spec, "The manifest") -- `route_result.routes`
    /// duped into a Discovery-owned copy (see `dupeRoutesForDiscovery`'s
    /// doc for why: `route_result` itself is freed via `discover`'s own
    /// `defer routes.freeResult(...)` before this struct reaches ITS
    /// caller). Without this, `source{file,line}`, `origin`, `certain`, and
    /// `name` -- the spec's mandatory per-route fields -- had no path to a
    /// manifest emitter at all; `route_count`/`route_mode` above are a
    /// SUMMARY of this, not a substitute for it. Index-aligned with
    /// `route_templates` above, same alignment `classifications` already
    /// relied on before `report.build` consumed it.
    routes: []routes.Route,
    /// Stage 4 Task 8: the manifest's `routes[].classification`/
    /// `.candidates` (spec, "The manifest") -- index-aligned with `routes`
    /// above, same alignment `route_templates` already relies on. This is
    /// the SAME reachability gap `route_templates`/`templates`/`assets`/
    /// `version`/`routes` above each closed in their own fix round:
    /// `classifyRoutes`'s result (`classify_result.verdicts`) was computed,
    /// handed to `report.build`, and then freed -- `classify.Verdict` owns
    /// nothing itself (classify.zig's own module doc: every `reason`/
    /// `Candidate` field is a rodata string literal), so only the SLICE
    /// needed to start escaping, not a deep free; see `freeDiscovery`.
    classifications: []classify.Verdict,
    /// Stage 4 Task 8: the manifest's top-level `integrations[]` (spec, "The
    /// manifest"). Same reachability gap as `classifications` above --
    /// `integrations.scan`'s result was computed for `report.build` and then
    /// freed with no seam out of `discover` at all. Contract 2: `.evidence`
    /// and (when non-null, since Stage 4 Task 8b) `.version` are fresh `gpa`
    /// allocations per `integrations.freeIntegrations`'s own doc (`.name` is
    /// always a static literal from the fixed gem/package lookup table and
    /// is never freed).
    integrations: []integrations.Integration,
    /// Stage 4 Task 8: the manifest's top-level `blockers[]` (spec, "The
    /// manifest") -- every blocker this run appended, in `blocker_list`'s
    /// own append order (NOT sorted; `manifest.zig`'s own emitter is
    /// responsible for determinism at the point it renders bytes, exactly
    /// like `report.build` already sorts its own copy rather than trusting
    /// discovery order -- see that file's `blockerLessThan`/`routeLessThan`
    /// docs). This used to be summarized only as `integrity_blocker_count`/
    /// `severity_error_count`/`severity_warn_count` above, with the actual
    /// `Blocker` values (`code`, `path`, `detail`, `route_id`) never
    /// escaping `discover` at all -- the same reachability gap
    /// `classifications`/`integrations` close. Contract 2: owned via
    /// `blocker_list.toOwnedSlice`, released by `blockers.free`.
    blockers: []blockers.Blocker,
};

/// Contract 2 counterpart to `Discovery`: releases `report` plus the Task 4
/// template-graph fields, the Task 6 asset list, and (fix round 2) the
/// `version`/`routes` fields added to close the reachability gap
/// phase-1-review.md's F5/F7 found. `migrate.zig`'s Rails call site uses
/// this instead of the bare `gpa.free(discovery.report)` it used before
/// Task 4.
pub fn freeDiscovery(gpa: Allocator, d: Discovery) void {
    gpa.free(d.report);
    freeRouteTemplates(gpa, d.route_templates);
    freeTemplateNodes(gpa, d.templates);
    assets.freeAssets(gpa, d.assets);
    detect.freeVersion(gpa, d.version);
    routes.freeRoutes(gpa, d.routes);
    // Stage 4 Task 8: releases the three reachability-gap fields added
    // alongside `Discovery.classifications`'s own doc above.
    gpa.free(d.classifications);
    integrations.freeIntegrations(gpa, d.integrations);
    blockers.free(gpa, d.blockers);
}

/// `discovery.ruby`, combined across BOTH sidecar ops. Each op
/// (`routes.zig`'s `discoverRoutes`, `controllers.zig`'s
/// `discoverControllers`) spawns its OWN, separate Ruby process and reports
/// its own half (`routes.Result.ruby` / `controllers.Result.ruby`) --
/// reading either half alone as "the" answer is exactly this stage's
/// recurring hazard, a field meaning something other than what it says.
/// Concretely: an app with `app/controllers/` present but no
/// `config/routes.rb` degrades the `routes` op to `RAILS_ROUTES_MISSING`
/// (Ruby never spawns for it, `route_result.ruby.available = false`) while
/// the SEPARATE `controllers` op's sidecar runs and answers normally --
/// Ruby was demonstrably available, just not asked about by the op this
/// field happened to read before this fix. `discover`'s `combineRuby` is
/// what actually computes this field's value; see that function's doc for
/// the OR-together / version-mismatch logic.
pub const RubyInfo = struct {
    available: bool,
    /// Bounded, NOT `gpa`-owned: `RUBY_VERSION` is always a short semver-ish
    /// string (e.g. `"3.3.6"`), and keeping this a fixed buffer -- rather
    /// than an owned `?[]const u8` -- avoids adding a THIRD kind of
    /// escaping allocation to `Discovery` (report, plus Stage 4 Task 4's
    /// `route_templates`/`templates`, both released via `freeDiscovery`) for
    /// no benefit: a second heap allocation here would need its own entry in
    /// that same free function for no reason, when a fixed buffer needs
    /// none.
    version_buf: [32]u8 = undefined,
    version_len: u8 = 0,

    /// `null` ONLY when no op supplied a version at all (`version_len ==
    /// 0`). A version that does NOT fit `version_buf` is silently
    /// TRUNCATED to the buffer's 32 bytes and returned AS that truncated
    /// string -- never dropped to `null`. Fix round 2 (phase-1-review.md F4
    /// / phase-1-fixes.md finding 12): this doc used to read "`null` when
    /// no op supplied a version, OR the supplied version did not fit
    /// `version_buf`", which -- taken at face value -- claims the SECOND
    /// case also returns `null`; the code has always truncated and
    /// returned instead, and the sibling test below was even NAMED "...is
    /// dropped, not corrupted" while its own body asserted the truncated,
    /// non-null 32-byte result. Under this stage's organising rule (an
    /// absent-or-null field beats a present-and-wrong one, but a doc/test
    /// name that CLAIMS null when the code does not deliver it is its own
    /// kind of wrong answer) the fix is to make the doc, the test name, and
    /// the code agree on what the code actually does: truncate, don't drop.
    /// `RUBY_VERSION` in practice is well under 32 bytes, so truncation is
    /// not expected to fire on any real Ruby.
    pub fn version(self: *const RubyInfo) ?[]const u8 {
        if (self.version_len == 0) return null;
        return self.version_buf[0..self.version_len];
    }
};

/// Contract 1 (self-freeing): the only allocation this function's own
/// return value could hold would be a `gpa`-owned `version` string, and
/// `RubyInfo` deliberately has none (see its own doc) -- so there is
/// nothing here for a caller to free. Any allocation this function DOES
/// perform is through `blockers.append`, into the caller's own
/// already-`gpa`-owned `blocker_list` -- the identical reasoning
/// `classifyRoutes` already documents for its own `blockers.append` calls.
///
/// `available` is true when EITHER op's sidecar answered (see `RubyInfo`'s
/// doc for why reading either op alone is wrong). `version` is read from
/// whichever op supplied one, preferring `route_ruby` when both did. When
/// BOTH ops supplied a version and they disagree, that is worth surfacing
/// rather than silently picking one -- the two sidecar processes should be
/// the SAME interpreter -- so this appends a `RAILS_RUBY_VERSION_MISMATCH`
/// blocker (`severity = .warn`: both ops answered and are correctly
/// reporting what each saw, not "the analysis is untrustworthy" the way
/// Task 1's wholesale-degradation codes are; `integrity = false`, same
/// non-integrity reasoning as every other Ruby-discovery blocker -- this
/// says nothing about `inventory.walk`'s own findings).
///
/// The blocker's `path` names the sidecar script rather than `""`.
/// `Blocker.path` is documented as an app-relative source path; an empty
/// string is not one, and it sorts ahead of every real path in both the
/// report and the manifest. Both ops run `analyze.rb`, and the sibling
/// sidecar codes (`RAILS_SIDECAR_MISSING`, `RAILS_CONTROLLERS_UNAVAILABLE`)
/// already name it, so a disagreement between the two belongs there too.
fn combineRuby(
    gpa: Allocator,
    route_ruby: sidecar_client.Ruby,
    controllers_ruby: sidecar_client.Ruby,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!RubyInfo {
    var info: RubyInfo = .{ .available = route_ruby.available or controllers_ruby.available };

    const chosen = route_ruby.version orelse controllers_ruby.version;
    if (chosen) |v| {
        const n = @min(v.len, info.version_buf.len);
        @memcpy(info.version_buf[0..n], v[0..n]);
        info.version_len = @intCast(n);
    }

    if (route_ruby.version != null and controllers_ruby.version != null and
        !std.mem.eql(u8, route_ruby.version.?, controllers_ruby.version.?))
    {
        var buf: [192]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &buf,
            "routes op reported ruby {s}, controllers op reported ruby {s}",
            .{ route_ruby.version.?, controllers_ruby.version.? },
        ) catch "routes/controllers ops reported different ruby versions";
        // Takes BOTH sides of the rebase: main's app-relative path (an empty
        // string is not a path and sorted ahead of every real one) and this
        // task's `line`, which is null because a disagreement between two
        // sidecar processes has no source line to point at.
        try blockers.append(gpa, blocker_list, "RAILS_RUBY_VERSION_MISMATCH", "sidecar/rails/analyze.rb", detail, false, .warn, null, null);
    }

    return info;
}

test "combineRuby: neither op answered -> available false" {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const info = try combineRuby(
        std.testing.allocator,
        .{ .available = false, .version = null },
        .{ .available = false, .version = null },
        &blocker_list,
    );
    try std.testing.expect(!info.available);
    try std.testing.expectEqual(@as(?[]const u8, null), info.version());
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

// This is the exact defect the fix round found: an app with `app/
// controllers/` present but no `config/routes.rb` degrades the `routes` op
// alone (`route_ruby.available = false`) while the `controllers` op's
// sidecar answers normally. Reading `route_ruby.available` alone (the
// pre-fix behavior) reports `false` here even though Ruby demonstrably
// ran; a test covering only "both true" and "both false" would pass
// against that broken implementation just as easily as against the fix,
// which is why this ONE-SIDED case gets its own test.
test "combineRuby: only the controllers op answered (routes op never spawned Ruby) -> available true" {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const info = try combineRuby(
        std.testing.allocator,
        .{ .available = false, .version = null },
        .{ .available = true, .version = "3.3.6" },
        &blocker_list,
    );
    try std.testing.expect(info.available);
    try std.testing.expectEqualStrings("3.3.6", info.version().?);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

// The mirror image: only the routes op answered (e.g. a hypothetical future
// app/controllers/-less app). Pinned separately from the sibling test above
// so neither direction is the one left unchecked.
test "combineRuby: only the routes op answered (controllers op never spawned Ruby) -> available true" {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const info = try combineRuby(
        std.testing.allocator,
        .{ .available = true, .version = "3.4.1" },
        .{ .available = false, .version = null },
        &blocker_list,
    );
    try std.testing.expect(info.available);
    try std.testing.expectEqualStrings("3.4.1", info.version().?);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "combineRuby: both ops answered with the SAME version -> no mismatch blocker" {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const info = try combineRuby(
        std.testing.allocator,
        .{ .available = true, .version = "3.3.6" },
        .{ .available = true, .version = "3.3.6" },
        &blocker_list,
    );
    try std.testing.expect(info.available);
    try std.testing.expectEqualStrings("3.3.6", info.version().?);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "combineRuby: both ops answered with DIFFERENT versions -> a warn, non-integrity mismatch blocker" {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const info = try combineRuby(
        std.testing.allocator,
        .{ .available = true, .version = "3.3.6" },
        .{ .available = true, .version = "3.4.1" },
        &blocker_list,
    );
    // Still available -- a mismatch is a finding to surface, not a reason
    // to say Ruby was unavailable.
    try std.testing.expect(info.available);
    // Prefers route_ruby's version when both are present -- documented,
    // not incidental (route_ruby is passed first).
    try std.testing.expectEqualStrings("3.3.6", info.version().?);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_RUBY_VERSION_MISMATCH", blocker_list.items[0].code);
    // Pins the PATH too, not just the code. `Blocker.path` is documented as
    // an app-relative source path, an empty string is not one, and it sorts
    // ahead of every real path. Asserting only the code is what let it ship.
    try std.testing.expectEqualStrings("sidecar/rails/analyze.rb", blocker_list.items[0].path);
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "3.3.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocker_list.items[0].detail, "3.4.1") != null);
}

// Fix round (task-2-3-fixes.md item 2): the sibling "RubyInfo.version..."
// test below exercises the READER (`RubyInfo.version()`) by hand-setting
// `version_buf`/`version_len` directly -- it never calls `combineRuby` at
// all, so `combineRuby`'s own `@min(v.len, info.version_buf.len)` bound
// (rails.zig:161 at the time of writing) is unverified: deleting it left
// `test-rails` green. This calls `combineRuby` itself with an
// over-length version and pins the EXACT truncated bytes, not merely that
// something non-empty came back -- a version that silently dropped the
// bound would write straight through `version_buf` into whatever memory
// follows `RubyInfo` on the stack, and only an exact-content assertion
// (not a length-only one) would even have a chance of noticing a
// corrupted, still-32-byte, wrong-content result.
test "combineRuby: a version string longer than the fixed buffer is truncated, not overflowed" {
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(std.testing.allocator, blocker_list.toOwnedSlice(std.testing.allocator) catch unreachable);

    const too_long = "3." ++ "9" ** 40; // 42 bytes, far past version_buf's 32
    try std.testing.expect(too_long.len > 32);

    const info = try combineRuby(
        std.testing.allocator,
        .{ .available = true, .version = too_long },
        .{ .available = false, .version = null },
        &blocker_list,
    );

    // The exact first 32 bytes of the input, nothing shifted, nothing
    // padded, nothing from adjacent memory.
    try std.testing.expectEqualStrings(too_long[0..32], info.version().?);
    try std.testing.expectEqual(@as(usize, 32), info.version().?.len);
    // Only one op supplied a version, so there is nothing to disagree with.
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "RubyInfo.version: a version longer than the fixed buffer is truncated, not dropped or corrupted" {
    // Fix round 2 (phase-1-review.md F4 / phase-1-fixes.md finding 12):
    // renamed from "...is dropped, not corrupted" -- the OLD name and this
    // test's OWN body disagreed (the body has always asserted a non-null,
    // 32-byte truncated result, never `null`). See `version`'s doc for the
    // full reasoning.
    var info: RubyInfo = .{ .available = true };
    const too_long = "3." ++ "9" ** 40; // far past version_buf's 32 bytes
    const n = @min(too_long.len, info.version_buf.len);
    @memcpy(info.version_buf[0..n], too_long[0..n]);
    info.version_len = @intCast(n);
    // Sanity: this test's own setup actually exceeds the buffer -- if a
    // future edit shrinks `too_long` below 32 bytes this assertion (not the
    // one below) is what would catch it.
    try std.testing.expect(too_long.len > info.version_buf.len);
    try std.testing.expectEqual(@as(usize, info.version_buf.len), info.version().?.len);
}

/// Fix round 2 (phase-1-review.md F7 / phase-1-fixes.md section 2): dupes
/// one already-owned `routes.Route` (from `route_result.routes`, which
/// `discover`'s own `defer routes.freeResult(...)` frees before this
/// struct's caller ever sees it) into a SECOND, independently-owned copy
/// that escapes into `Discovery.routes` instead. Not `routes.zig`'s own
/// private `dupeRoute`: that function dupes from a `WireRoute` (the JSON
/// wire shape), not from an already-`Route`-typed value, so it is a
/// different transform over a different input type, not a duplicate of
/// this one.
///
/// Contract 2 (owned-result): every string field is a fresh `gpa`
/// allocation; `origin`, `certain`, and `source.line` are plain values with
/// nothing to free. Released via `routes.freeRoutes`, the SAME release
/// `routes.zig`'s own producer uses -- one free function for the type,
/// regardless of which of its two producers built a given value.
fn dupeRouteForDiscovery(gpa: Allocator, r: routes.Route) Allocator.Error!routes.Route {
    const verb = try gpa.dupe(u8, r.verb);
    errdefer gpa.free(verb);
    const path = try gpa.dupe(u8, r.path);
    errdefer gpa.free(path);
    const controller: ?[]const u8 = if (r.controller) |c| try gpa.dupe(u8, c) else null;
    errdefer if (controller) |c| gpa.free(c);
    const action: ?[]const u8 = if (r.action) |a| try gpa.dupe(u8, a) else null;
    errdefer if (action) |a| gpa.free(a);
    const name: ?[]const u8 = if (r.name) |n| try gpa.dupe(u8, n) else null;
    errdefer if (name) |n| gpa.free(n);
    const source_file = try gpa.dupe(u8, r.source.file);
    return .{
        .verb = verb,
        .path = path,
        .controller = controller,
        .action = action,
        .name = name,
        .certain = r.certain,
        .origin = r.origin,
        .source = .{ .file = source_file, .line = r.source.line },
    };
}

fn freeDupedRouteFields(gpa: Allocator, r: routes.Route) void {
    gpa.free(r.verb);
    gpa.free(r.path);
    if (r.controller) |c| gpa.free(c);
    if (r.action) |a| gpa.free(a);
    if (r.name) |n| gpa.free(n);
    gpa.free(r.source.file);
}

/// Contract 2 (owned-result): dupes every route in `list`. On a partial
/// failure, releases every ALREADY-duped route's fields (`out[0..filled]`)
/// plus the one full backing array -- the same `filled`-counter shape
/// `routes.zig`'s own `decodeResponse` uses for the identical
/// partial-array-build problem. Not `routes.freeRoutes` for the partial
/// case: that function's own `gpa.free(routes)` expects the slice IT is
/// handed to be the whole original allocation, and `out[0..filled]` is a
/// narrower sub-slice of it once `filled < list.len`.
fn dupeRoutesForDiscovery(gpa: Allocator, list: []const routes.Route) Allocator.Error![]routes.Route {
    const out = try gpa.alloc(routes.Route, list.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |r| freeDupedRouteFields(gpa, r);
        gpa.free(out);
    }
    for (list, 0..) |r, i| {
        out[i] = try dupeRouteForDiscovery(gpa, r);
        filled = i + 1;
    }
    return out;
}

/// Contract 2 (owned-result), widened by Stage 4 Task 4: every intermediate
/// (entries, blockers, integrations, file reads) is still released here, but
/// the returned `Discovery` is no longer contract 1 -- `route_templates`/
/// `templates` escape alongside `report` now (see `Discovery`'s own doc).
/// Release the whole thing with `freeDiscovery`.
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
    // -- exactly what `blockers.freeList` expects. This used to be the one
    // remaining hand-rolled release on this branch (a loop freeing
    // `path`/`detail` plus a bare `.deinit(gpa)`); functionally identical,
    // but every other site on this branch already uses the one-call form.
    // Fix round 2 (phase-1-review.md finding 16): this used to be `blockers.
    // free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable)` -- a
    // `defer` cannot propagate `toOwnedSlice`'s genuinely reachable
    // `error.OutOfMemory`, so `catch unreachable` was an assertion over a
    // real failure mode, not a proof. `freeList` operates on the
    // `ArrayListUnmanaged` directly and never allocates.
    //
    // Stage 4 Task 8: `defer` widened to `errdefer` -- `Discovery.blockers`
    // now escapes via `blocker_list.toOwnedSlice` at the very end of this
    // function (the last read of `blocker_list.items`, see that call site's
    // own comment), so the success path must free nothing here. This stays
    // armed for every fallible step below until that `toOwnedSlice` call:
    // on any earlier error, `blocker_list` still owns its backing storage
    // and `freeList` is exactly the right release for it.
    errdefer blockers.freeList(gpa, &blocker_list);

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

    // Fix round 2 (phase-1-review.md F5 / phase-1-fixes.md section 2):
    // `detectVersion` had NO production caller anywhere before this --
    // Task 7 shipped the Gemfile.lock parser but the plan never specified
    // wiring it into `discover`, so `source.version` was unproduced end to
    // end and `RAILS_GEMFILE_LOCK_UNAVAILABLE` was unreachable outside its
    // own unit tests. Called here, not by a future Phase 2 emitter after
    // `discover` returns, because the blocker it can append belongs in
    // THIS run's `blocker_list` -- which is created and freed inside this
    // function, so there is no later seam for it to land in.
    //
    // Stage 4 Task 8b: reads `Gemfile.lock` ONCE via `readGemfileLock`
    // rather than calling `detect.detectVersion` (which would read it
    // again internally) -- `gemfile_lock`'s content is also handed to
    // `integrations.scan` below for gem-sourced `Integration.version`, and
    // a second read would append `RAILS_GEMFILE_LOCK_UNAVAILABLE` twice on
    // a missing/unreadable lock file. See `readGemfileLock`'s own doc.
    const gemfile_lock = try detect.readGemfileLock(io, gpa, root, &blocker_list);
    defer if (gemfile_lock) |gl| gpa.free(gl);

    const version = if (gemfile_lock) |gl|
        try detect.versionFromLock(gpa, gl, &blocker_list)
    else
        detect.Version{};
    errdefer detect.freeVersion(gpa, version);

    const ints = try integrations.scan(gpa, gemfile, pkg, gemfile_lock, &blocker_list);
    // Stage 4 Task 8: `defer` widened to `errdefer` -- `Discovery.
    // integrations` now escapes (see that field's own doc), released by
    // `freeDiscovery` on the success path instead of here.
    errdefer integrations.freeIntegrations(gpa, ints);

    // Stage 4 Task 6: the asset inventory, threading the SAME blocker_list
    // -- every case where a public URL can't be derived statically (unknown
    // pipeline, ERB-preprocessed content, a missing/unusable/incomplete
    // Sprockets manifest) appends a non-integrity blocker rather than
    // guessing a URL. `gemfile` is still alive here (freed by the `defer`
    // above only at this function's return), and `wr.entries` outlives this
    // call the same way. `errdefer` covers every later fallible step in this
    // function; `freeDiscovery` covers the success path.
    const asset_list = try assets.scan(io, gpa, root, wr.entries, gemfile, &blocker_list);
    errdefer assets.freeAssets(gpa, asset_list);

    // Route discovery threads the SAME blocker_list: every degradation path
    // it can hit (missing Ruby, missing sidecar, a spawn/response failure,
    // no config/routes.rb) appends here rather than failing this function,
    // so `integrity_blocker_count` below already accounts for it.
    const route_result = try routes.discoverRoutes(io, gpa, root, app_path, &blocker_list, environ_map);
    // freeResult, not freeRoutes: Task 2 added `Result.ruby.version`, a
    // second gpa-owned allocation alongside `routes` -- freeRoutes alone
    // would leak it.
    defer routes.freeResult(gpa, route_result);

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
    const ctrl_result = try controllers.discoverControllers(io, gpa, root, app_path, &blocker_list, environ_map);
    defer controllers.freeResult(gpa, ctrl_result);
    const controller_evidence_available = controllerEvidenceAvailable(blocker_list.items[blockers_before_controllers..]);

    // `discovery.ruby`, combined across both sidecar ops -- see
    // `combineRuby`'s own doc for why neither op's own `.ruby` half may be
    // read alone (Stage 4's task-2-fixes.md item 1). Both `discoverRoutes`
    // and `discoverControllers` have already run by this point, so both
    // halves are in hand.
    const ruby_info = try combineRuby(gpa, route_result.ruby, ctrl_result.ruby, &blocker_list);

    // Stage 3's join: one classify.Verdict per route, index-aligned with
    // route_result.routes. See classifyRoutes's own doc for why template
    // bytes must stay alive across the classify.classify call that borrows
    // from them, not just across the read. Stage 4 Task 4 widened the
    // result to also carry the template graph (`route_templates`/
    // `templates`) that same scan already produces -- those two escape into
    // the `Discovery` this function returns (see `Discovery`'s doc), so
    // they are NOT freed here the way `classifications` is; the `errdefer`s
    // below cover only the remaining fallible step in this function
    // (`report.build`), releasing them if THAT fails.
    const classify_result = try classifyRoutes(
        io,
        gpa,
        root,
        wr.entries,
        route_result.routes,
        ctrl_result.actions,
        controller_evidence_available,
        &blocker_list,
    );
    const classifications = classify_result.verdicts;
    // Stage 4 Task 8: `defer` widened to `errdefer` -- `Discovery.
    // classifications` now escapes alongside `route_templates`/`templates`
    // (see that field's own doc), released by `freeDiscovery` on the
    // success path instead of here.
    errdefer gpa.free(classifications);
    errdefer freeRouteTemplates(gpa, classify_result.route_templates);
    errdefer freeTemplateNodes(gpa, classify_result.templates);

    var integrity_blocker_count: usize = 0;
    var route_blocker = false;
    var severity_error_count: usize = 0;
    var severity_warn_count: usize = 0;
    for (blocker_list.items) |b| {
        if (b.integrity) integrity_blocker_count += 1;
        if (blockers.isRouteRelated(b.code)) route_blocker = true;
        switch (b.severity) {
            .@"error" => severity_error_count += 1,
            .warn => severity_warn_count += 1,
        }
    }

    // Fix round 2 (phase-1-review.md F7 / phase-1-fixes.md section 2):
    // `route_result.routes` itself does not survive this function --
    // `defer routes.freeResult(gpa, route_result)` above releases it before
    // `discover` returns -- so the manifest's `routes[]` needs its OWN,
    // independently-owned copy to escape into `Discovery`.
    const duped_routes = try dupeRoutesForDiscovery(gpa, route_result.routes);
    errdefer routes.freeRoutes(gpa, duped_routes);

    const body = try report.build(gpa, .{
        .app_path = app_path,
        .entries = wr.entries,
        .integrations = ints,
        .blockers = blocker_list.items,
        .routes = route_result.routes,
        .route_mode = route_result.mode,
        .classifications = classifications,
    });
    errdefer gpa.free(body);

    // Stage 4 Task 8: the LAST read of `blocker_list.items` in this
    // function (the counts loop above and `report.build` just above both
    // already finished with it) -- `toOwnedSlice` invalidates the
    // `ArrayListUnmanaged`, handing this function's own `blocker_list`
    // storage over to `Discovery.blockers` (see that field's own doc). Every
    // `errdefer` above that still names `blocker_list`/`&blocker_list`
    // remains correct up to this point (the list still owns its storage
    // until this call succeeds); nothing after this line can fail, so there
    // is no later use of `blocker_list` this ownership transfer could race.
    const blockers_owned = try blocker_list.toOwnedSlice(gpa);

    return .{
        .report = body,
        .integrity_blocker_count = integrity_blocker_count,
        .route_count = route_result.routes.len,
        .route_mode = route_result.mode,
        .route_blocker = route_blocker,
        .severity_error_count = severity_error_count,
        .severity_warn_count = severity_warn_count,
        .ruby = ruby_info,
        .route_templates = classify_result.route_templates,
        .templates = classify_result.templates,
        .assets = asset_list,
        .version = version,
        .routes = duped_routes,
        .classifications = classifications,
        .integrations = ints,
        .blockers = blockers_owned,
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

/// Stage 4 Task 4: one edge `transitiveScan`'s BFS already walked -- the
/// template it visited, plus the OTHER templates it resolved a `render`
/// call to (never the literal argument -- see `TemplateNode`'s doc, which
/// this generalizes once the caller dupes it). `entry` and every `renders`
/// element BORROW from `entries` (the same `inventory.Entry.path` aliasing
/// every other resolver in this file returns -- `resolveViewEntry`,
/// `resolveLayoutEntry`, `resolvePartialTarget`), NOT from `buffers`: no
/// field here is a name `template_scan.scan`/`scanRenders` returned, so the
/// `buffers`-lifetime hazard `TransitiveScan`'s own doc describes does not
/// apply to this type at all. It is still only a BORROW, though -- of
/// `entries`, which does not outlive `discover()` -- which is exactly why
/// `buildRouteTemplates`/`mergeGlobalTemplates` dupe every string that
/// escapes `classifyRoutes` through this.
const GraphNode = struct {
    entry: inventory.Entry,
    /// Owned backing array (this scan's own allocation, freed by
    /// `freeTransitiveScan`); each element is a borrow, per this type's doc.
    /// Empty for a node whose own `render` targets were never resolved --
    /// either it renders nothing, or (the depth-cap case) the walk
    /// deliberately stopped resolving before reaching this node's targets;
    /// see `transitiveScan`'s doc for why the latter is left empty rather
    /// than resolved out-of-band from the recursion it gates.
    renders: [][]const u8,
    /// Fix round 2 (phase-1-review.md F6 / phase-1-fixes.md section 2):
    /// this NODE's OWN markers from its own `template_scan.scan` call --
    /// deliberately NOT `TransitiveScan.markers`, which unions every node's
    /// markers into a per-ROUTE bundle Rule 6 reads. `templates[]`
    /// (`TemplateNode`, below) needs the PER-TEMPLATE answer instead: which
    /// Stimulus controllers/component roots THIS ONE FILE names, not the
    /// union its route happens to pull in from a shared layout or partial.
    /// `BoundedNames` (`template_scan.zig`) has no allocation of its own, so
    /// copying it here by value needs no separate free -- it is still only
    /// a BORROW of `src`'s bytes, exactly like `TransitiveScan.markers` is,
    /// which is why `mergeGlobalTemplates` dupes every name into a fresh
    /// `gpa` allocation before it escapes into `TemplateNode`, same as it
    /// already does for `renders` above.
    stimulus_controllers: template_scan.StimulusControllers,
    component_roots: template_scan.ComponentRoots,
};

/// The result of scanning one route's view template, its resolved layout,
/// and every partial either of them (transitively, up to
/// `max_partial_depth`) renders, merged into one evidence bundle.
///
/// Contract 2 (owned-result): `buffers` holds one fresh `gpa`-owned
/// allocation per file this scan actually read; `.markers.request_state`
/// and every name in `.markers.stimulus_controllers`/`.component_roots`
/// BORROW from one of those buffers (`template_scan.scan`'s own borrowing
/// rule, extended across however many buffers this scan visited), so
/// `buffers` must stay alive for as long as `.markers` is
/// read. Release both together with `freeTransitiveScan`, and only AFTER
/// the caller is done reading `.markers` -- in `classifyRoutes`, that means
/// after the `classify.classify` call that consumes it, exactly the same
/// ordering `classifyRoutes`'s own doc already requires for the
/// single-buffer case this generalizes.
///
/// `graph`/`layout_path` are a SEPARATE lifetime story from `.markers`
/// (Stage 4 Task 4) -- see `GraphNode`'s doc: they borrow `entries`, not
/// `buffers`, so they remain valid for as long as `entries` does, which
/// outlives this whole scan. `freeTransitiveScan` still releases `graph`'s
/// own backing allocations (the array itself, and each node's `renders`
/// array), because those ARE this scan's own allocations even though their
/// ELEMENTS are borrowed.
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
    /// The resolved layout's `inventory.Entry.path` (borrowed from
    /// `entries`, same as everywhere else in this file), or `null` when
    /// `resolveLayoutEntry` found neither a per-controller nor an
    /// `application` layout. Set once, near the top of `transitiveScan`,
    /// before the BFS below runs -- carried on the result so
    /// `buildRouteTemplates` can tell the layout node in `graph` apart from
    /// every other node without re-deriving it.
    layout_path: ?[]const u8 = null,
    /// One `GraphNode` per template this scan successfully READ (view,
    /// layout, and every partial resolved and read up to
    /// `max_partial_depth`) -- Stage 4 Task 4's `routes[].templates[]` /
    /// `routes[].layout` / `templates[].renders[]` (spec, "The manifest").
    /// An unreadable node (view or otherwise) contributes nothing here: its
    /// own render targets are genuinely unknown, and a node with an empty
    /// `renders` list would misreport "renders nothing" as fact rather than
    /// "never read". Order is BFS visit order (view and layout first, at
    /// depth 0, partials afterward) -- deterministic given `entries`' own
    /// sorted order and `scanRenders`' fixed source-occurrence order, but
    /// not alphabetical; `buildRouteTemplates` sorts by path itself where
    /// the manifest's determinism rule requires it.
    graph: std.ArrayListUnmanaged(GraphNode) = .empty,
};

/// Contract 2 counterpart to `transitiveScan`: releases every buffer plus
/// the list itself. Call only after every read of `.markers`/
/// `.request_state_source` is done. Also releases `graph`'s own backing
/// allocations (see `TransitiveScan.graph`'s doc for why THIS release is
/// unconditional -- unlike `buffers`, `graph`'s borrowed elements do not
/// depend on `buffers`' lifetime, only on `entries`', which outlives this
/// whole call).
fn freeTransitiveScan(gpa: Allocator, r: *TransitiveScan) void {
    for (r.buffers.items) |b| gpa.free(b);
    r.buffers.deinit(gpa);
    for (r.graph.items) |g| gpa.free(g.renders);
    r.graph.deinit(gpa);
}

/// Scans `view_entry` and everything it (transitively, through its
/// resolved layout and any `render`ed partials) pulls in, merging markers
/// per classify.zig's module doc: `stimulus_controllers`/`component_roots`
/// UNION (every distinct name found anywhere in the view/layout/partial
/// chain, deduplicated by `BoundedNames.addUnique` -- see
/// `template_scan.zig`'s doc); `request_state` takes the first non-null in
/// view-then-layout-then-partial order (the BFS below visits the view first, the layout second
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
/// Big enough for any real Rails route (`verb` is at most a handful of
/// ASCII letters; `path` is a source-authored URI pattern) with generous
/// headroom -- see `formatRouteId`'s doc for what happens on the
/// not-expected-in-practice case that it isn't.
///
/// `pub` (Stage 4 Task 8): `manifest.zig` builds `routes[].id` by calling
/// `formatRouteId` itself rather than reimplementing the `verb`+' '+`path`
/// concatenation a second time -- two construction sites for one id is
/// exactly the drift this field's sibling doc warns about (a blocker's
/// `route_id` and a route's own `id` disagreeing on the first edit to
/// either). The buffer type has to travel with the function: a caller
/// cannot declare `var buf: [route_id_buf_len]u8` to pass by pointer
/// without the constant also being visible.
pub const route_id_buf_len = 512;

/// The manifest's `routes[].id` shape (spec, "The manifest": `"id": "GET
/// /articles/:id"`) -- `route.verb`, a single space, then `route.path`.
/// Stage 4 Task 5: this is the SAME id a blocker's `route_id` must carry to
/// name the route that produced it, and a later stage's manifest emitter
/// builds `routes[].id` from the identical two fields -- one function
/// rather than two independently-concatenating call sites is what keeps
/// those two never disagreeing.
///
/// Contract 3 (caller-buffer): allocates nothing, formats into `buf` and
/// returns the written slice (a borrow of `buf`, not of `r`). On the
/// practically-unreachable case that `verb`+' '+`path` doesn't fit
/// `route_id_buf_len` bytes, falls back to `path` alone -- still
/// route-specific and non-null, rather than silently dropping the whole id
/// (a later drift gate diffs committed manifest bytes, so an outright
/// omission here would be worse than an imperfect fallback).
///
/// **Not a unique identifier** (phase-1-review.md finding 13 /
/// phase-1-fixes.md finding 13): two identical route DECLARATIONS (e.g. the
/// same `get "/posts/stats"` line appearing twice in `routes.rb`, which
/// this stage's parser does not reject) produce the SAME `verb`+`path`
/// pair and therefore the same id -- an ordinary, if unusual, occurrence in
/// a real Rails app, not a defect this function should paper over with a
/// disambiguator (a counter suffix, `source.line` folded in, ...) that
/// would make the id depend on scan order or invent a distinction the
/// route table itself doesn't have. Phase 2's manifest schema must document
/// `routes[].id` as a LABEL, not a key a consumer may join on uniquely --
/// see `Ruling 9`/finding 9 in progress.md and phase-1-review.md for the
/// companion case (a blocker's `route_id` naming only ONE of several routes
/// a shared, unreadable template affects).
pub fn formatRouteId(buf: *[route_id_buf_len]u8, r: routes.Route) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ r.verb, r.path }) catch r.path;
}

/// See `TransitiveScan`'s doc for the ownership contract this returns
/// under.
///
/// `route_id` (Stage 4 Task 5) is the caller's route -- `classifyRoutes`
/// only ever calls this from inside its per-route loop, with a real,
/// already-recovered `routes.Route` in hand, so this is a required
/// parameter, not `?[]const u8`. Threaded into both blockers this function
/// can emit (`RAILS_TEMPLATE_UNREADABLE`, `RAILS_TEMPLATE_RENDER_DEPTH_
/// EXCEEDED`): both fire from inside a specific route's template-graph
/// walk, unlike `routes.zig`'s/`controllers.zig`'s own `unresolved[]`
/// blockers, which describe a construct that never became a recovered
/// route or action at all (see those call sites' own comments for why
/// `route_id` stays `null` there).
fn transitiveScan(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    entries: []const inventory.Entry,
    view_entry: inventory.Entry,
    controller: []const u8,
    route_id: []const u8,
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
    result.layout_path = layout_path;

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
                    // `.warn`: one template file the transitive scan
                    // correctly identified as unreadable -- the route(s)
                    // that depend on it classify as unresolved (see below),
                    // but nothing else this run found is called into
                    // question. See `Blocker.severity`'s doc.
                    try blockers.append(gpa, blocker_list, "RAILS_TEMPLATE_UNREADABLE", item.entry.path, @errorName(err), false, .warn, route_id, null);
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
        // Union, not first-wins: every distinct name this file's scan found
        // is evidence the merged result should carry, regardless of
        // whether an earlier file in the walk already contributed a
        // (different) name. `addUnique` is the dedup.
        for (m.stimulus_controllers.slice()) |name| result.markers.stimulus_controllers.addUnique(name);
        for (m.component_roots.slice()) |name| result.markers.component_roots.addUnique(name);
        // OR, not first-wins, matching the two lists above: any file in the
        // chain naming a malformed `data-controller=` attribute is evidence
        // the route-level union should carry (fix round 2, phase-1-fixes.md
        // section 4 -- see `Markers.malformed_stimulus_attr`'s doc).
        if (m.malformed_stimulus_attr) result.markers.malformed_stimulus_attr = true;

        const targets = try template_scan.scanRenders(gpa, src);
        defer gpa.free(targets);

        // Task 4: every successfully-read node becomes exactly one
        // `GraphNode`, regardless of which branch below fires -- restructured
        // from the original `if (targets.len == 0) continue;` / depth-cap
        // `continue` pair into `if/else` so both still reach the single
        // `result.graph.append` at the bottom, rather than duplicating it
        // per branch. Behaviorally identical to the pre-Task-4 control flow
        // otherwise: when `targets.len == 0` the block below is skipped
        // entirely (same as the old early `continue`), and the depth-cap
        // check still fires the same blocker and still declines to resolve
        // this node's own targets (see `GraphNode`'s doc for why that means
        // an EMPTY `renders`, not a resolved-but-not-followed one -- this
        // scan genuinely never looked).
        var node_renders: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer node_renders.deinit(gpa);

        if (targets.len > 0) {
            if (item.depth >= max_partial_depth) {
                if (result.unresolved_render == null) result.unresolved_render = .depth_cap;
                // `.warn`: a known limit of this scan, correctly detected and
                // reported for one template chain -- not evidence anything else
                // this run found is untrustworthy.
                try blockers.append(
                    gpa,
                    blocker_list,
                    "RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED",
                    item.entry.path,
                    "partial nesting exceeds the depth this scan follows; unify or flatten these partials",
                    false,
                    .warn,
                    route_id,
                    null,
                );
            } else {
                const containing_dir = templateDirOf(item.entry.path);
                for (targets) |t| {
                    if (!t.resolved) {
                        if (result.unresolved_render == null) result.unresolved_render = .dynamic;
                        // F2 (phase-2-review.md): without this blocker,
                        // `templates[].renders` for THIS node reads as
                        // "renders nothing" -- indistinguishable from a
                        // template that genuinely has no more render calls
                        // -- when the true story is "one target was dropped
                        // here, unread". `.warn`: this scan correctly
                        // identified one unresolvable render target, the
                        // same non-integrity reasoning
                        // RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED already uses
                        // just above.
                        var buf: [256]u8 = undefined;
                        const detail = std.fmt.bufPrint(
                            &buf,
                            "renders a dynamic partial target that cannot be resolved statically: {s}",
                            .{t.text},
                        ) catch "renders a dynamic partial target that cannot be resolved statically";
                        try blockers.append(gpa, blocker_list, "RAILS_TEMPLATE_RENDER_UNRESOLVED", item.entry.path, detail, false, .warn, route_id, null);
                        continue;
                    }
                    if (resolvePartialTarget(entries, containing_dir, t.text)) |partial_entry| {
                        // Recorded regardless of whether this target was
                        // already visited -- `renders[]` describes what THIS
                        // node points to, not which edges were newly
                        // discovered by the BFS (a cycle or a
                        // shared-partial re-render still belongs in the
                        // graph).
                        try node_renders.append(gpa, partial_entry.path);
                        if (!containsPath(visited.items, partial_entry.path)) {
                            try visited.append(gpa, partial_entry.path);
                            try queue.append(gpa, .{ .entry = partial_entry, .depth = item.depth + 1 });
                        }
                    } else {
                        if (result.unresolved_render == null) result.unresolved_render = .unmatched;
                        // Same F2 reasoning as the dynamic branch above --
                        // a literal target naming no known template is
                        // still a dropped edge, not "renders nothing".
                        var buf: [256]u8 = undefined;
                        const detail = std.fmt.bufPrint(
                            &buf,
                            "renders a partial target that does not match any known template: {s}",
                            .{t.text},
                        ) catch "renders a partial target that does not match any known template";
                        try blockers.append(gpa, blocker_list, "RAILS_TEMPLATE_RENDER_UNRESOLVED", item.entry.path, detail, false, .warn, route_id, null);
                    }
                }
            }
        }

        const node_renders_owned = try node_renders.toOwnedSlice(gpa);
        errdefer gpa.free(node_renders_owned);
        try result.graph.append(gpa, .{
            .entry = item.entry,
            .renders = node_renders_owned,
            // `m` is still in scope from this node's own `template_scan.scan`
            // call above -- copied by value (no allocation), per
            // `GraphNode.stimulus_controllers`'s doc.
            .stimulus_controllers = m.stimulus_controllers,
            .component_roots = m.component_roots,
        });
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

/// Stage 4 Task 4: one template file in the route-reachable, deduplicated catalog
/// -- manifest's top-level `templates[]` (spec, "The manifest"). `renders`
/// names every OTHER template this one resolves a `render` call to, by the
/// ACTUAL RESOLVED path, never the literal argument -- e.g. `render "nav"`
/// written inside `app/views/layouts/posts.html.erb` surfaces here as
/// `app/views/layouts/_nav.html.erb`, not `"nav"`. A render target the scan
/// could not resolve (dynamic, unmatched, or past `max_partial_depth`)
/// contributes nothing to `renders` -- see `GraphNode`'s doc, which this
/// dupes from.
///
/// `path`/`renders` are fresh `gpa` dupes, not slices into `entries`:
/// `mergeGlobalTemplates` (which builds these) is called from
/// `classifyRoutes`, whose caller's caller (`discover`) frees `entries`
/// (`wr.entries`) before returning `Discovery` to ITS OWN caller, while a
/// `TemplateNode` is meant to survive that -- it is Task 8's manifest
/// emitter's input. `template_scan.Markers`' buffer-lifetime hazard
/// (`TransitiveScan.buffers`) is a SEPARATE, unrelated constraint that does
/// not apply here at all: nothing in this type is a name
/// `template_scan.scan`/`scanRenders` returned.
///
/// `stimulus_controllers`/`component_roots` (fix round 2, phase-1-review.md
/// F6 / phase-1-fixes.md section 2): manifest's `templates[].stimulus_
/// controllers[]`/`.component_roots[]` (spec, "The manifest") -- THIS
/// template's own names, dupe'd from `GraphNode.stimulus_controllers`/
/// `.component_roots` (see that type's doc for why those still need duping
/// even though they are already a per-NODE, not per-route, answer: they
/// borrow `TransitiveScan.buffers`, which is freed before a `TemplateNode`
/// escapes `classifyRoutes`). This is deliberately NOT the same list as
/// `TransitiveScan.markers.stimulus_controllers`/`.component_roots`, which
/// is a per-ROUTE union across a view, its layout, and every partial either
/// renders -- handing a route-level union to one template here would credit
/// e.g. the shared `application` layout with every Stimulus controller any
/// view anywhere in the app happens to use.
///
/// Contract 2 (owned-result): release via `freeTemplateNodes`.
pub const TemplateNode = struct {
    path: []const u8,
    kind: inventory.Kind,
    engine: inventory.Engine,
    renders: [][]const u8,
    stimulus_controllers: [][]const u8,
    component_roots: [][]const u8,
};

/// Contract 2 (owned-result): dupes every name in `names` into a fresh
/// `gpa`-owned slice of fresh `gpa`-owned strings; release with
/// `freeNameList`. Shared by `mergeGlobalTemplates`'s three identical
/// name-list dupes (`renders`, `stimulus_controllers`, `component_roots`)
/// so the element-then-array errdefer shape below -- found necessary by the
/// Task 4 FailingAllocator sweep on `renders` alone (see the comment that
/// used to sit on that dupe, now generalized here) -- is written once
/// rather than three times.
fn dupeNameList(gpa: Allocator, names: []const []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    for (names) |n| {
        const dup = try gpa.dupe(u8, n);
        errdefer gpa.free(dup);
        try out.append(gpa, dup);
    }
    const owned = try out.toOwnedSlice(gpa);
    // Frees every ELEMENT too, not just the backing array -- `gpa.free
    // (owned)` alone would leak each individually-dupe'd string if a LATER
    // step (the caller's own subsequent `dupeNameList` call, or the
    // `template_nodes.append` at the end of `mergeGlobalTemplates`) fails.
    // This is the exact gap the Task 4 FailingAllocator sweep found on
    // `renders` before this helper existed.
    errdefer freeNameList(gpa, owned);
    return owned;
}

/// Contract 2 counterpart to `dupeNameList`: releases every element plus
/// the backing slice.
fn freeNameList(gpa: Allocator, names: []const []const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn freeTemplateNodesElements(gpa: Allocator, items: []const TemplateNode) void {
    for (items) |n| {
        gpa.free(n.path);
        freeNameList(gpa, n.renders);
        freeNameList(gpa, n.stimulus_controllers);
        freeNameList(gpa, n.component_roots);
    }
}

/// Contract 2 counterpart to `TemplateNode`: releases every node's owned
/// strings plus the slice itself.
pub fn freeTemplateNodes(gpa: Allocator, nodes: []TemplateNode) void {
    freeTemplateNodesElements(gpa, nodes);
    gpa.free(nodes);
}

/// Stage 4 Task 4: one route's template graph -- manifest's
/// `routes[].templates[]` / `routes[].layout` (spec, "The manifest").
/// `templates` is the view plus every partial (direct or nested, via
/// either the view's or the resolved layout's own render chain) this
/// route's transitive scan resolved AND READ, sorted by path
/// (determinism) -- the layout itself is named separately in `.layout`,
/// never duplicated into `.templates`. Both default to "nothing resolved"
/// (`templates = &.{}`, `layout = null`) for a route whose view could not
/// be resolved or read at all; that default is indistinguishable from "a
/// view resolved, but genuinely has no layout" (`resolveLayoutEntry`
/// legitimately returning `null`) -- a real ambiguity, left as-is because a
/// manifest consumer already has `classification`/`reason` to tell those
/// cases apart, and resolving it here would require a second field this
/// stage's brief does not ask for.
///
/// Same duping rationale as `TemplateNode`: fresh `gpa` dupes, not slices
/// into `entries`.
///
/// Contract 2 (owned-result): release via `freeRouteTemplates`.
pub const RouteTemplates = struct {
    templates: [][]const u8,
    layout: ?[]const u8,
};

fn freeRouteTemplatesElements(gpa: Allocator, items: []const RouteTemplates) void {
    for (items) |rt| {
        for (rt.templates) |t| gpa.free(t);
        gpa.free(rt.templates);
        if (rt.layout) |l| gpa.free(l);
    }
}

/// Contract 2 counterpart to `RouteTemplates`.
pub fn freeRouteTemplates(gpa: Allocator, list: []RouteTemplates) void {
    freeRouteTemplatesElements(gpa, list);
    gpa.free(list);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn templateNodeLessThan(_: void, a: TemplateNode, b: TemplateNode) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn containsTemplatePath(items: []const TemplateNode, path: []const u8) bool {
    for (items) |n| {
        if (std.mem.eql(u8, n.path, path)) return true;
    }
    return false;
}

/// Builds one route's `RouteTemplates` from `scan_result.graph` -- the
/// EXACT graph `transitiveScan`'s BFS already walked for this route (see
/// that function's/`GraphNode`'s docs); this does not re-walk anything, it
/// only dupes and reshapes what the scan already found. Called only from
/// the branch in `classifyRoutes` where `scan_result.view_unreadable ==
/// false`, i.e. while `scan_result` (and the `entries` storage its `graph`
/// borrows from) is still known-good.
///
/// Contract 2 (owned-result), fix round 2 (phase-1-review.md F11 /
/// phase-1-fixes.md 1c): borrows nothing from `scan_result` or `entries` --
/// every string in the returned `RouteTemplates` is a fresh `gpa` dupe
/// (`RouteTemplates`'s own doc explains why duping, not borrowing, is
/// required). Released via `freeRouteTemplatesElements`/
/// `freeRouteTemplates`; on this function's own error return nothing has
/// escaped yet, so there is nothing for the caller to clean up beyond its
/// own `errdefer` on the partially-built value (see `classifyRoutes`'s call
/// site).
fn buildRouteTemplates(gpa: Allocator, scan_result: *const TransitiveScan) Allocator.Error!RouteTemplates {
    var layout: ?[]const u8 = null;
    if (scan_result.layout_path) |lp| layout = try gpa.dupe(u8, lp);
    errdefer if (layout) |l| gpa.free(l);

    var templates: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (templates.items) |t| gpa.free(t);
        templates.deinit(gpa);
    }

    for (scan_result.graph.items) |edge| {
        if (scan_result.layout_path) |lp| {
            if (std.mem.eql(u8, edge.entry.path, lp)) continue;
        }
        const dup = try gpa.dupe(u8, edge.entry.path);
        errdefer gpa.free(dup);
        try templates.append(gpa, dup);
    }

    const owned = try templates.toOwnedSlice(gpa);
    std.mem.sort([]const u8, owned, {}, lessThanStr);
    return .{ .templates = owned, .layout = layout };
}

/// Adds one `TemplateNode` per DISTINCT path in `scan_result.graph` to
/// `template_nodes`, the FIRST time `classifyRoutes`' whole run encounters
/// that path -- the same one-entry-per-FILE dedup rationale
/// `reported_unreadable_templates` already uses for blocker emission (two
/// routes sharing a view, or every route in the app sharing one `application`
/// layout, must not each contribute their own copy). Safe to skip the
/// duplicate outright: a file's `renders` are deterministic given only its
/// own content and its own containing directory, so a later route's copy
/// would always be byte-identical to the first, never a correction of it.
///
/// Not itself contract 1/2/3 in the return-value sense (fix round 2,
/// phase-1-review.md F11 / phase-1-fixes.md 1c): this function returns
/// `void` and instead APPENDS owned `TemplateNode`s into the CALLER-owned
/// `template_nodes` list. Every allocation it makes either escapes into a
/// successfully-appended `TemplateNode` (owned by `template_nodes`
/// thereafter, the caller's responsibility) or is freed by this function's
/// own `errdefer` chain before an error propagates -- nothing is
/// half-owned. `template_nodes` itself is caller-buffer in the sense that
/// this function neither allocates nor frees the list's own backing array
/// (only appends to it); `classifyRoutes`'s own `errdefer` over
/// `template_nodes.items` covers whatever this call already appended if a
/// LATER step in the loop (not this call itself) fails.
fn mergeGlobalTemplates(
    gpa: Allocator,
    template_nodes: *std.ArrayListUnmanaged(TemplateNode),
    scan_result: *const TransitiveScan,
) Allocator.Error!void {
    for (scan_result.graph.items) |edge| {
        if (containsTemplatePath(template_nodes.items, edge.entry.path)) continue;

        const path_dup = try gpa.dupe(u8, edge.entry.path);
        errdefer gpa.free(path_dup);

        const renders_owned = try dupeNameList(gpa, edge.renders);
        errdefer freeNameList(gpa, renders_owned);

        // Fix round 2 (phase-1-review.md F6 / phase-1-fixes.md section 2):
        // `edge.stimulus_controllers`/`.component_roots` borrow
        // `TransitiveScan.buffers`, which `freeTransitiveScan` releases
        // before `classifyRoutes` returns -- these two dupes are what make
        // this ONE template's own markers survive that, into `TemplateNode`.
        const stimulus_owned = try dupeNameList(gpa, edge.stimulus_controllers.slice());
        errdefer freeNameList(gpa, stimulus_owned);
        const component_owned = try dupeNameList(gpa, edge.component_roots.slice());
        errdefer freeNameList(gpa, component_owned);

        try template_nodes.append(gpa, .{
            .path = path_dup,
            .kind = edge.entry.kind,
            .engine = edge.entry.engine,
            .renders = renders_owned,
            .stimulus_controllers = stimulus_owned,
            .component_roots = component_owned,
        });
    }
}

/// `classifyRoutes`' full result: the per-route verdicts, plus the Stage 4
/// Task 4 template graph the same scan already produces alongside them
/// (`route_templates`, index-aligned with `verdicts`/`route_list` exactly
/// like `report.build`'s `Input.classifications` already relies on; and
/// `templates`, the route-reachable deduplicated catalog sorted by path).
///
/// Contract 2 (owned-result): release with `freeClassifyResult`.
pub const ClassifyResult = struct {
    verdicts: []classify.Verdict,
    route_templates: []RouteTemplates,
    templates: []TemplateNode,
};

/// Contract 2 counterpart to `ClassifyResult`.
pub fn freeClassifyResult(gpa: Allocator, r: ClassifyResult) void {
    gpa.free(r.verdicts);
    freeRouteTemplates(gpa, r.route_templates);
    freeTemplateNodes(gpa, r.templates);
}

/// Joins each route's verb, resolved view (if any), and resolved controller
/// action (if any) into one `classify.Verdict`, index-aligned with
/// `route_list` -- `report.build`'s `Input.classifications` depends on that
/// alignment to pair each rendered route with its verdict.
///
/// Contract 2 (owned-result), widened by Stage 4 Task 4: `verdicts` itself
/// still owns nothing per-element (see classify.zig's module doc: `reason`
/// and every `Candidate` field are static string literals) -- only the
/// slice is an allocation -- but `route_templates`/`templates` (new in this
/// task) each own real `gpa` strings that must outlive `entries`, so the
/// RESULT as a whole is contract 2, released via `freeClassifyResult`.
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
) Allocator.Error!ClassifyResult {
    const out = try gpa.alloc(classify.Verdict, route_list.len);
    errdefer gpa.free(out);

    // Task 4: `route_templates` is index-aligned with `out`/`route_list`,
    // same alignment contract `out` itself already carries; `template_nodes`
    // is the route-reachable dedup accumulator `mergeGlobalTemplates` builds into.
    // Both own real `gpa` strings (unlike `out`'s elements), so both need
    // their own partial-failure cleanup -- an `errdefer` freeing whatever
    // had already been appended, mirroring `freeRouteTemplates`/
    // `freeTemplateNodes`'s per-element logic but operating on the
    // in-progress `ArrayListUnmanaged` rather than a finished slice.
    var route_templates: std.ArrayListUnmanaged(RouteTemplates) = .empty;
    errdefer {
        freeRouteTemplatesElements(gpa, route_templates.items);
        route_templates.deinit(gpa);
    }
    var template_nodes: std.ArrayListUnmanaged(TemplateNode) = .empty;
    errdefer {
        freeTemplateNodesElements(gpa, template_nodes.items);
        template_nodes.deinit(gpa);
    }

    // Shared across every route this call scans (fix round B / B4): dedupes
    // `RAILS_TEMPLATE_UNREADABLE` emission by FILE across the whole run --
    // see `transitiveScan`'s doc. Holds borrowed `entries` paths (never
    // freed independently; `entries` outlives this function), so this list
    // owns only its own backing array.
    var reported_unreadable_templates: std.ArrayListUnmanaged([]const u8) = .empty;
    defer reported_unreadable_templates.deinit(gpa);

    for (route_list, 0..) |r, i| {
        const action = actionFor(actions, r);
        // Task 4: this route's template graph. Defaults to "nothing
        // resolved" (see `RouteTemplates`'s doc) and is only replaced in the
        // one branch below that actually resolved and read a view.
        // Appended to `route_templates` exactly once per iteration -- on
        // every path through this loop, mirroring `out[i]` itself being set
        // unconditionally -- so the two stay index-aligned.
        var route_tpl: RouteTemplates = .{ .templates = &.{}, .layout = null };
        // Stage 4 Task 5: this route's manifest id (`routes[].id` shape),
        // formatted once per iteration and threaded into `transitiveScan` so
        // the two blockers it can emit -- both fired with this exact `r` in
        // scope -- carry the route that actually produced them, not
        // whichever route happened to run last.
        var route_id_buf: [route_id_buf_len]u8 = undefined;
        const route_id = formatRouteId(&route_id_buf, r);

        if (r.controller) |c| {
            if (r.action) |a| {
                if (resolveViewEntry(entries, c, a)) |entry| {
                    var scan_result = try transitiveScan(io, gpa, root, entries, entry, c, route_id, blocker_list, &reported_unreadable_templates);
                    defer freeTransitiveScan(gpa, &scan_result);

                    if (scan_result.view_unreadable) {
                        out[i] = classify.classify(.{
                            .verb = r.verb,
                            .view = null,
                            .action = action,
                            .controller_evidence_available = controller_evidence_available,
                        });
                        try route_templates.append(gpa, route_tpl);
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

                    // Task 4: surface the template graph THIS scan already
                    // walked -- `scan_result.graph` is still in scope here,
                    // exactly like `scan_result.markers` read just above
                    // (both are consumed before `defer
                    // freeTransitiveScan(...)` fires at the end of this
                    // block). See `buildRouteTemplates`'/
                    // `mergeGlobalTemplates`'s docs for why both dupe rather
                    // than borrow.
                    route_tpl = try buildRouteTemplates(gpa, &scan_result);
                    // Armed from here until `route_templates.append` below
                    // actually transfers ownership: `route_tpl` is a
                    // complete, owned value the instant `buildRouteTemplates`
                    // returns, so if `mergeGlobalTemplates` OR the append
                    // itself fails, THIS is what frees it -- without this,
                    // an OOM landing in that gap orphans `route_tpl`'s
                    // strings (found by the FailingAllocator sweep test
                    // below, not by inspection).
                    errdefer {
                        for (route_tpl.templates) |t| gpa.free(t);
                        gpa.free(route_tpl.templates);
                        if (route_tpl.layout) |l| gpa.free(l);
                    }
                    try mergeGlobalTemplates(gpa, &template_nodes, &scan_result);

                    try route_templates.append(gpa, route_tpl);
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
        try route_templates.append(gpa, route_tpl);
    }

    const route_templates_owned = try route_templates.toOwnedSlice(gpa);
    errdefer freeRouteTemplates(gpa, route_templates_owned);

    const templates_owned = try template_nodes.toOwnedSlice(gpa);
    // Determinism (spec, "Determinism": "templates ... by path"): BFS visit
    // order is deterministic given `entries`' own sorted order, but is not
    // itself alphabetical (view/layout first, partials after) -- sort
    // explicitly rather than relying on incidental insertion order.
    std.mem.sort(TemplateNode, templates_owned, {}, templateNodeLessThan);

    return .{ .verdicts = out, .route_templates = route_templates_owned, .templates = templates_owned };
}

test "formatRouteId: verb, one space, path -- the exact manifest routes[].id shape" {
    var buf: [route_id_buf_len]u8 = undefined;
    const r = routes.Route{
        .verb = "GET",
        .path = "/articles/:id",
        .controller = "articles",
        .action = "show",
        .name = null,
        .certain = true,
        .origin = .static_ast,
    };
    try std.testing.expectEqualStrings("GET /articles/:id", formatRouteId(&buf, r));
}

test "formatRouteId: two different routes format to two different ids -- not the same buffer content reused" {
    // A discriminating pair, not a single-route smoke test: this is exactly
    // what would fail if a broken implementation (say, one that captured
    // `r` by an index into a stale slice, or forgot to re-slice `buf`) ever
    // returned the SAME bytes for two distinct routes.
    var buf_a: [route_id_buf_len]u8 = undefined;
    var buf_b: [route_id_buf_len]u8 = undefined;
    const a = formatRouteId(&buf_a, .{ .verb = "GET", .path = "/posts", .controller = null, .action = null, .name = null, .certain = true, .origin = .static_ast });
    const b = formatRouteId(&buf_b, .{ .verb = "POST", .path = "/posts", .controller = null, .action = null, .name = null, .certain = true, .origin = .static_ast });
    try std.testing.expectEqualStrings("GET /posts", a);
    try std.testing.expectEqualStrings("POST /posts", b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
    // Stage 4 Task 5: the blocker fired from inside THIS route's own
    // classification loop, so it must carry this route's manifest id.
    try std.testing.expectEqualStrings("GET /posts", blocker_list.items[0].route_id.?);
}

test "classifyRoutes: two routes with two DIFFERENT unreadable templates each carry their OWN route_id, not the other's" {
    // Stage 4 Task 5's own discriminating case: an implementation that
    // stamps the SAME route_id on every blocker (e.g. always the last route
    // processed, or a hardcoded first route) would pass a test that only
    // checks "some route_id is present." Two routes, two DISTINCT unreadable
    // templates, each getting its own blocker (no dedup in play, unlike the
    // sibling "sharing one unreadable template" test above) is what proves
    // attribution rather than mere presence.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Neither view file actually exists -- deterministic read failure for
    // both, same trick the sibling tests use.

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
        .{ .path = "app/views/comments/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/comments", .controller = "comments", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{
        .{ .controller = "posts", .action = "index" },
        .{ .controller = "comments", .action = "index" },
    };

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 2), blocker_list.items.len);

    // Find each blocker by its `path` (which template it's about) rather
    // than assuming array order matches route order -- the assertion below
    // is about CORRECT attribution, not about iteration order happening to
    // line up.
    var posts_blocker: ?blockers.Blocker = null;
    var comments_blocker: ?blockers.Blocker = null;
    for (blocker_list.items) |b| {
        try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNREADABLE", b.code);
        if (std.mem.eql(u8, b.path, "app/views/posts/index.html.erb")) posts_blocker = b;
        if (std.mem.eql(u8, b.path, "app/views/comments/index.html.erb")) comments_blocker = b;
    }
    try std.testing.expectEqualStrings("GET /posts", posts_blocker.?.route_id.?);
    try std.testing.expectEqualStrings("GET /comments", comments_blocker.?.route_id.?);
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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

    try std.testing.expectEqual(@as(usize, 2), verdicts.len);
    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqual(classify.Class.unresolved, verdicts[1].class);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", blocker_list.items[0].path);
    // Dedup is by FILE, not by route (see this test's own doc above) -- the
    // one blocker that survives is the one `GET /` (index 0, visited first)
    // produced, not `GET /posts`'s. `route_id` must reflect that, not
    // whichever route happens to be handed to the caller last.
    try std.testing.expectEqualStrings("GET /", blocker_list.items[0].route_id.?);
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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

    try std.testing.expectEqual(classify.Class.island, verdicts[0].class);
}

test "transitive scan: a MALFORMED data-controller attribute in a rendered partial still ORs into the route-level union and reaches island (fix round 2)" {
    // Companion to the sibling test above, for `Markers.malformed_
    // stimulus_attr` rather than a real name: `transitiveScan`'s per-node
    // BFS loop merges `m.malformed_stimulus_attr` into `result.markers.
    // malformed_stimulus_attr` with `if (m.malformed_stimulus_attr) result.
    // markers.malformed_stimulus_attr = true;` -- a ONE-LINE addition
    // alongside the pre-existing `stimulus_controllers`/`component_roots`
    // union loop, easy to omit without any OTHER test noticing (deleting
    // it left `test-rails` green: `classify.zig`'s own Rule 6 unit test
    // builds `Markers` directly and never exercises this merge at all).
    // The VIEW here carries no marker of its own; only the PARTIAL it
    // renders has the malformed attribute -- so this only passes if the
    // flag actually survives the per-file union, not just the single-file
    // `template_scan.scan` call.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n<%= render partial: \"widget\" %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_widget.html.erb", "<div data-controller=\"\"></div>\n");

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("template's partial nesting exceeds the depth this scan follows", verdicts[0].reason);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_RENDER_DEPTH_EXCEEDED", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("app/views/posts/_p3.html.erb", blocker_list.items[0].path);
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
    try std.testing.expectEqualStrings("GET /posts", blocker_list.items[0].route_id.?);
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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

    try std.testing.expectEqual(classify.Class.unresolved, verdicts[0].class);
    try std.testing.expectEqualStrings("a layout or partial this template renders could not be read", verdicts[0].reason);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expectEqualStrings("GET /posts", blocker_list.items[0].route_id.?);
}

// --- Stage 4 Task 4: routes[].templates[]/layout, templates[].renders[] ---

test "Task 4: renders[] names the RESOLVED partial path, not the literal render argument -- including from the LAYOUT" {
    // The brief's own discriminating example: `render \"nav\"` written
    // inside app/views/layouts/posts.html.erb must surface as
    // app/views/layouts/_nav.html.erb in `templates[].renders[]`, never the
    // bare literal `"nav"`. An implementation that just echoed the render
    // argument back out (or omitted resolution entirely) would pass a test
    // that only checked `renders.len > 0`; this checks the actual string.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n");
    try writeTemplate(tmp, io, "app/views/layouts/posts.html.erb", "<%= render \"nav\" %><%= yield %>\n");
    try writeTemplate(tmp, io, "app/views/layouts/_nav.html.erb", "<nav>Home</nav>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/_nav.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/layouts/posts.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);

    // Nothing here reads request-time state or interactivity, and the
    // action was recovered -- rule 7 -- so this reaches `content`. Pinned
    // as a sanity check that the graph data below describes a route that
    // actually classified successfully, not a degraded/unresolved one.
    try std.testing.expectEqual(classify.Class.content, result.verdicts[0].class);

    // routes[].layout: resolved to the per-controller layout, by path.
    try std.testing.expectEqual(@as(usize, 1), result.route_templates.len);
    try std.testing.expectEqualStrings("app/views/layouts/posts.html.erb", result.route_templates[0].layout.?);

    // routes[].templates[]: the view AND the layout's own partial -- NOT
    // the layout itself (that's `.layout`, not duplicated here) -- sorted
    // by path (determinism), not BFS/source order.
    try std.testing.expectEqual(@as(usize, 2), result.route_templates[0].templates.len);
    try std.testing.expectEqualStrings("app/views/layouts/_nav.html.erb", result.route_templates[0].templates[0]);
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", result.route_templates[0].templates[1]);

    // templates[]: the route-reachable catalog, sorted by path. Three entries: the
    // partial, the layout, the view.
    try std.testing.expectEqual(@as(usize, 3), result.templates.len);

    try std.testing.expectEqualStrings("app/views/layouts/_nav.html.erb", result.templates[0].path);
    try std.testing.expectEqual(inventory.Kind.partial, result.templates[0].kind);
    try std.testing.expectEqual(@as(usize, 0), result.templates[0].renders.len);

    try std.testing.expectEqualStrings("app/views/layouts/posts.html.erb", result.templates[1].path);
    try std.testing.expectEqual(inventory.Kind.layout, result.templates[1].kind);
    // THE discriminating assertion: the layout's `renders[]` is the
    // RESOLVED partial path, never the literal `"nav"` argument.
    try std.testing.expectEqual(@as(usize, 1), result.templates[1].renders.len);
    try std.testing.expectEqualStrings("app/views/layouts/_nav.html.erb", result.templates[1].renders[0]);

    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", result.templates[2].path);
    try std.testing.expectEqual(inventory.Kind.view, result.templates[2].kind);
    try std.testing.expectEqual(@as(usize, 0), result.templates[2].renders.len);
}

test "Task 4: two routes sharing one view produce ONE global templates[] entry, but two (index-aligned) route_templates entries" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    // Mirrors the `resources :posts` shape: `GET /` and `GET /posts` both
    // resolve to posts#index, sharing one view. `mergeGlobalTemplates`'s
    // dedup must not double the global entry, while each route's OWN
    // `route_templates` entry still names it (index-alignment must hold
    // regardless of the dedup).
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/", .controller = "posts", .action = "index", .name = "root", .certain = true, .origin = .static_ast },
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 2), result.route_templates.len);
    for (result.route_templates) |rt| {
        try std.testing.expectEqual(@as(usize, 1), rt.templates.len);
        try std.testing.expectEqualStrings("app/views/posts/index.html.erb", rt.templates[0]);
        try std.testing.expect(rt.layout == null);
    }

    // The dedup: ONE global entry, not two, despite two routes visiting it.
    try std.testing.expectEqual(@as(usize, 1), result.templates.len);
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", result.templates[0].path);
}

test "Task 4: an unresolved render target (a dynamic expression) contributes nothing to renders[]" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One resolvable partial, one dynamic (unresolvable) render -- if
    // renders[] echoed unresolved targets too (e.g. as a raw evidence
    // string), this would see 2 entries instead of 1.
    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<%= render partial: \"post\" %><%= render @thing %>\n");
    try writeTemplate(tmp, io, "app/views/posts/_post.html.erb", "<article></article>\n");

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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);

    // The dynamic render target still does its OTHER job (forcing
    // unresolved, never content) -- confirms this fixture actually
    // exercises the unresolved-render path the renders[] assertion below
    // depends on, not a fixture that never hit it.
    try std.testing.expectEqual(classify.Class.unresolved, result.verdicts[0].class);

    var found = false;
    for (result.templates) |n| {
        if (!std.mem.eql(u8, n.path, "app/views/posts/index.html.erb")) continue;
        found = true;
        try std.testing.expectEqual(@as(usize, 1), n.renders.len);
        try std.testing.expectEqualStrings("app/views/posts/_post.html.erb", n.renders[0]);
    }
    try std.testing.expect(found);
}

test "Task 4: a node past the depth cap contributes an EMPTY renders[] -- the scan never resolved it, so it must not claim to" {
    // Same view -> _p1 -> _p2 -> _p3 (-> _p4, past the cap) chain as the
    // sibling depth-cap test above, but asserting the GRAPH this time:
    // _p3 sits exactly at `max_partial_depth`, so its own `render partial:
    // "p4"` is never resolved -- `_p4` must not appear ANYWHERE in
    // `templates[]` (the walk never reached it), and `_p3`'s own `renders`
    // must be empty (not, say, a placeholder or the unresolved evidence
    // text) -- see `GraphNode`'s doc for why "never looked" and "looked,
    // found nothing" are kept distinct.
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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);

    try std.testing.expectEqual(classify.Class.unresolved, result.verdicts[0].class);

    // Exactly 4 templates known: view, _p1, _p2, _p3 -- NOT _p4, which the
    // scan never reached.
    try std.testing.expectEqual(@as(usize, 4), result.templates.len);
    for (result.templates) |n| {
        try std.testing.expect(!std.mem.eql(u8, n.path, "app/views/posts/_p4.html.erb"));
    }

    var found_p3 = false;
    for (result.templates) |n| {
        if (!std.mem.eql(u8, n.path, "app/views/posts/_p3.html.erb")) continue;
        found_p3 = true;
        try std.testing.expectEqual(@as(usize, 0), n.renders.len);
    }
    try std.testing.expect(found_p3);
}

test "Task 4: a route whose view was never resolved gets the zero-value RouteTemplates, still index-aligned with the others" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(tmp, io, "app/views/posts/index.html.erb", "<h1>Posts</h1>\n");

    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/index.html.erb", .kind = .view, .engine = .erb },
    };
    // Route 0 has a real view; route 1 (a non-GET verb, so it never even
    // attempts view resolution) does not. Both must still produce exactly
    // one `route_templates` entry each, in order, so a consumer can zip
    // `routes[]` with `route_templates[]` by index without the arrays ever
    // drifting apart.
    const route_list = [_]routes.Route{
        .{ .verb = "GET", .path = "/posts", .controller = "posts", .action = "index", .name = null, .certain = true, .origin = .static_ast },
        .{ .verb = "POST", .path = "/posts", .controller = "posts", .action = "create", .name = null, .certain = true, .origin = .static_ast },
    };
    const acts = [_]controllers.ActionInfo{.{ .controller = "posts", .action = "index" }};
    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list);
    defer freeClassifyResult(gpa, result);

    try std.testing.expectEqual(@as(usize, 2), result.verdicts.len);
    try std.testing.expectEqual(@as(usize, 2), result.route_templates.len);

    try std.testing.expectEqual(@as(usize, 1), result.route_templates[0].templates.len);
    try std.testing.expectEqualStrings("app/views/posts/index.html.erb", result.route_templates[0].templates[0]);

    try std.testing.expectEqual(@as(usize, 0), result.route_templates[1].templates.len);
    try std.testing.expect(result.route_templates[1].layout == null);

    // The global catalog only ever hears about the ONE view that a route
    // actually resolved and read.
    try std.testing.expectEqual(@as(usize, 1), result.templates.len);
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

    const result = try classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, acts, false, &blocker_list);
    defer freeClassifyResult(gpa, result);
    const verdicts = result.verdicts;

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

        if (classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list)) |result| {
            // Freed via `std.testing.allocator` directly, not `gpa` (the
            // FailingAllocator wrapper): by the time this branch runs,
            // `fail_index` is past every allocation this call makes, so the
            // real underlying allocator is what actually owns the memory --
            // same reasoning the pre-Task-4 `verdicts` free here already
            // used.
            defer freeClassifyResult(std.testing.allocator, result);
            const verdicts = result.verdicts;
            try std.testing.expectEqual(@as(usize, 1), verdicts.len);
            try std.testing.expectEqual(classify.Class.content, verdicts[0].class);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "mergeGlobalTemplates: an OOM at any point while duping stimulus_controllers/component_roots leaks nothing" {
    // Fix round 2 (phase-1-review.md F6 / phase-1-fixes.md section 2): the
    // sibling sweep above never exercises `dupeNameList`'s ALLOCATING path
    // for `stimulus_controllers`/`component_roots` -- its fixture has no
    // `data-controller=`/component-root marker anywhere, so both lists are
    // empty on every node and `dupeNameList(gpa, &.{})` never actually
    // dupes a name. This fixture's view carries a REAL Stimulus controller
    // AND a component root, so a fail_index landing inside either dupe (or
    // between one dupe finishing and the next starting) is reachable.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTemplate(
        tmp,
        io,
        "app/views/posts/index.html.erb",
        "<div data-controller=\"reveal modal\"></div><%= react_component(\"Chart\") %>\n",
    );

    const entries = [_]inventory.Entry{
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

        if (classifyRoutes(io, gpa, tmp.dir, &entries, &route_list, &acts, true, &blocker_list)) |result| {
            defer freeClassifyResult(std.testing.allocator, result);
            try std.testing.expectEqual(@as(usize, 1), result.templates.len);
            const n = result.templates[0];
            try std.testing.expectEqual(@as(usize, 2), n.stimulus_controllers.len);
            try std.testing.expect(n.stimulus_controllers[0].len > 0 or n.stimulus_controllers[1].len > 0);
            try std.testing.expectEqual(@as(usize, 1), n.component_roots.len);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "discover: the fixture's blockers break down 0 error / 5 warn -- the fixture-level severity count the brief asks for" {
    // Fix round 1 (task-1-fixes.md item 2): the brief asks for "the count
    // of each [severity] on the fixture" to be discriminated. `report.
    // build` does not render `severity` at all -- that's deliberately
    // Task 8's manifest's job, not this report's -- so asserting this via
    // `tests/migrate/rails.sh` grepping the rendered report would require
    // inventing a rendering just to make the assertion possible, which the
    // fix explicitly says not to do. This asserts the same fixture's exact
    // counts at the Zig level instead, via `Discovery.severity_error_count`/
    // `severity_warn_count` (added alongside this test, computed in the
    // same pass as the pre-existing `integrity_blocker_count`).
    //
    // Needs `ruby` on PATH and `ZIGAPAGOS_RUNTIME_DIR` (mirrors the existing
    // "spawns the real Ruby sidecar" test in routes.zig): degrades to
    // RAILS_RUBY_UNAVAILABLE, not a hard failure, when ruby genuinely isn't
    // installed -- skip rather than fail in that case, same as that test.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("ZIGAPAGOS_RUNTIME_DIR", "runtime");

    const d = try discover(io, gpa, app_dir, "tests/migrate/rails-sample", &env_map);
    defer freeDiscovery(gpa, d);

    if (!std.mem.eql(u8, d.route_mode, "static_ast")) {
        // Ruby genuinely unavailable in this environment -- the fixture's
        // route-dependent blockers (RAILS_ROUTE_CONDITIONAL, RAILS_ROUTE_
        // ENGINE_MOUNT) never fire, so the counts below don't apply.
        return error.SkipZigTest;
    }

    // The healthy-toolchain run: 0 error (nothing about the app tree,
    // Gemfile, package.json, or discovery itself is unreadable/missing/
    // failed) and exactly 5 warn -- RAILS_ROUTE_CONDITIONAL (the `if
    // Rails.env...` guarded route), RAILS_ROUTE_ENGINE_MOUNT (the Sidekiq
    // mount), RAILS_TEMPLATE_ENGINE_UNSUPPORTED (the one Haml view),
    // (Stage 4 Task 6) RAILS_ASSET_DIGEST_UNAVAILABLE for
    // app/assets/stylesheets/application.css.erb, and (phase-2-fixes.md
    // item 2 / F2) RAILS_TEMPLATE_RENDER_UNRESOLVED for `featured.html.
    // erb`'s `render @post` (a dynamic target `transitiveScan` cannot
    // resolve statically) -- each a correctly-detected, scoped finding,
    // none of them evidence the rest of this run is untrustworthy.
    // Confirmed by running this test with `std.debug.print`ed counts and
    // the rendered Blockers section before pinning these exact numbers.
    try std.testing.expectEqual(@as(usize, 0), d.severity_error_count);
    try std.testing.expectEqual(@as(usize, 5), d.severity_warn_count);
    // Sanity: every blocker on a healthy run is accounted for by one axis
    // or the other (no third severity value exists).
    try std.testing.expectEqual(@as(usize, 0), d.integrity_blocker_count);
}

test "discover: the fixture's assets discriminate -- logo.png is deterministic, the ERB stylesheet is not" {
    // Stage 4 Task 6's own required property (its brief, verbatim): a
    // fixture containing BOTH a deterministic and a non-deterministic
    // asset, under the SAME pipeline. An implementation that hardcoded
    // `deterministic = true` for every asset would still pass every OTHER
    // test in this file (report rendering, route counts, ...) -- only this
    // assertion, against the real fixture `discover` actually runs on,
    // catches it. Needs no Ruby/sidecar at all: asset scanning is pure Zig
    // (Gemfile text + file content), so this runs unconditionally, unlike
    // the route-dependent tests above and below it.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("ZIGAPAGOS_RUNTIME_DIR", "runtime");

    const d = try discover(io, gpa, app_dir, "tests/migrate/rails-sample", &env_map);
    defer freeDiscovery(gpa, d);

    // 4 Kind.asset entries: app/assets/images/logo.png,
    // app/assets/stylesheets/application.css.erb (Task 6's fixture
    // addition), public/favicon.ico, and public/assets/.manifest.json
    // itself (fix round 1's fixture addition -- Propshaft's own compiled
    // manifest, which `inventory.walk` inventories like any other file
    // under public/, since it IS one).
    try std.testing.expectEqual(@as(usize, 4), d.assets.len);

    var found_logo = false;
    var found_stylesheet = false;
    var found_favicon = false;
    var found_manifest_file = false;
    for (d.assets) |a| {
        if (std.mem.eql(u8, a.source, "app/assets/images/logo.png")) {
            found_logo = true;
            // Fix round 1: this used to assert a SHA-256 digest this code
            // computed itself -- verified as A correct SHA-256, never
            // verified as Propshaft's actual scheme (Propshaft is not
            // installed here to check against). Now it's read verbatim
            // from the fixture's own public/assets/.manifest.json, the
            // same ground-truth story the sprockets tests already prove.
            try std.testing.expect(a.deterministic);
            try std.testing.expectEqualStrings("/assets/images/logo-9f86d081884c.png", a.public_url.?);
            try std.testing.expectEqual(assets.Pipeline.propshaft, a.pipeline.?);
        } else if (std.mem.eql(u8, a.source, "app/assets/stylesheets/application.css.erb")) {
            found_stylesheet = true;
            // The discriminating half: same pipeline (propshaft, from the
            // SAME Gemfile as logo.png above), same app, same manifest --
            // but the manifest does not list this asset under its (pre-ERB)
            // source filename, so its digested URL cannot be read as fact.
            // deterministic must be false, and it must say why rather than
            // guessing a URL.
            try std.testing.expect(!a.deterministic);
            try std.testing.expectEqual(@as(?[]const u8, null), a.public_url);
            try std.testing.expectEqual(assets.Pipeline.propshaft, a.pipeline.?);
        } else if (std.mem.eql(u8, a.source, "public/favicon.ico")) {
            found_favicon = true;
            try std.testing.expect(a.deterministic);
            try std.testing.expectEqualStrings("/favicon.ico", a.public_url.?);
        } else if (std.mem.eql(u8, a.source, "public/assets/.manifest.json")) {
            found_manifest_file = true;
            // The manifest file itself is JUST another public/-rooted
            // static file as far as this stage is concerned -- served
            // as-is, same bypass reasoning as favicon.ico.
            try std.testing.expect(a.deterministic);
            try std.testing.expectEqualStrings("/assets/.manifest.json", a.public_url.?);
        }
    }
    try std.testing.expect(found_logo);
    try std.testing.expect(found_stylesheet);
    try std.testing.expect(found_favicon);
    try std.testing.expect(found_manifest_file);

    // The non-deterministic asset's reason is visible in the rendered
    // report, not just in the in-memory `Discovery.assets` this test reads
    // directly -- a human running `zigapagos migrate` sees the same fact.
    try std.testing.expect(std.mem.indexOf(u8, d.report, "RAILS_ASSET_DIGEST_UNAVAILABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.report, "app/assets/stylesheets/application.css.erb") != null);
}

test "discover: reachability -- source.version, per-route source{file,line}/certain, and per-template stimulus_controllers are all present on a real Discovery, not merely produced somewhere" {
    // Fix round 2 (phase-1-review.md section 2 / phase-1-fixes.md section
    // 2): "Phase 1 delivered 5 of 7 wired producers, not 7" -- three of
    // Stage 4's own tasks computed data `discover`'s caller could never
    // reach: `detect.detectVersion` had no production caller at all,
    // `TemplateNode` carried no per-template Stimulus/component names (only
    // a per-ROUTE union that died with `TransitiveScan.buffers`), and
    // `Discovery` carried a route COUNT, never `routes[]` itself. Each
    // producer's OWN unit tests were green throughout -- this is
    // deliberately not another unit test. It walks a REAL `Discovery` built
    // from the checked-in fixture and asserts every field the manifest
    // needs is actually sitting on it, present and non-empty exactly where
    // the fixture makes it so. This is the acceptance test the brief says
    // Phase 1 should have had from the start.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var app_dir = Io.Dir.cwd().openDir(io, "tests/migrate/rails-sample", .{}) catch return error.SkipZigTest;
    defer app_dir.close(io);

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("ZIGAPAGOS_RUNTIME_DIR", "runtime");

    const d = try discover(io, gpa, app_dir, "tests/migrate/rails-sample", &env_map);
    defer freeDiscovery(gpa, d);

    if (!std.mem.eql(u8, d.route_mode, "static_ast")) {
        // Ruby genuinely unavailable in this environment -- `d.routes` is
        // empty on every degradation path, so the route/template
        // assertions below don't apply (`source.version` alone has no
        // Ruby dependency, but this test's point is proving ALL of these
        // are reachable together, so it skips wholesale rather than
        // partially asserting).
        return error.SkipZigTest;
    }

    // --- source.version: reachable end to end, not just parsed in
    // isolation by detect.zig's own tests. The fixture's checked-in
    // Gemfile.lock (added alongside this test, confirmed tracked via `git
    // archive`) locks rails at 7.1.3.
    try std.testing.expectEqualStrings("7.1.3", d.version.value.?);
    try std.testing.expectEqualStrings("Gemfile.lock:rails (7.1.3)", d.version.evidence.?);

    // --- routes[]: `Discovery.route_count` alone (already covered by other
    // tests) cannot prove `source`/`origin`/`certain`/`name` reach a
    // consumer -- only the routes themselves can.
    try std.testing.expect(d.routes.len > 0);
    var found_root = false;
    var found_admin_health = false;
    for (d.routes) |r| {
        if (std.mem.eql(u8, r.path, "/") and std.mem.eql(u8, r.verb, "GET")) {
            found_root = true;
            try std.testing.expectEqualStrings("config/routes.rb", r.source.file);
            // `root "posts#index"` is line 2 of the fixture's routes.rb.
            try std.testing.expectEqual(@as(u64, 2), r.source.line);
            try std.testing.expectEqual(routes.Origin.static_ast, r.origin);
            try std.testing.expect(r.certain);
            try std.testing.expectEqualStrings("posts", r.controller.?);
            try std.testing.expectEqualStrings("index", r.action.?);
        }
        if (std.mem.eql(u8, r.path, "/admin/health")) {
            found_admin_health = true;
            // Declared inside `if ENV["ADMIN_UI"]` -- the parser can see
            // its shape but not whether it is active, so `certain` must be
            // `false` here specifically (not just present-and-true
            // everywhere, which a bugged producer that always stamps
            // `true` would also satisfy).
            try std.testing.expect(!r.certain);
            try std.testing.expectEqual(@as(u64, 32), r.source.line);
        }
    }
    try std.testing.expect(found_root);
    try std.testing.expect(found_admin_health);

    // --- templates[].stimulus_controllers: per-TEMPLATE, not the per-route
    // union `TransitiveScan.markers` merges across a view, its layout, and
    // every partial either renders. `app/views/posts/dashboard.html.erb`
    // (routed at GET /posts/dashboard) is the one file in the fixture with
    // its own `data-controller="reveal modal"` -- Stage 4 Task 12's fixture
    // addition (multi-controller attribute) turned this from a single name
    // into two, discriminating the space-separated split end to end on the
    // SAME fixture `discover` actually runs on (`template_scan.zig`'s own
    // unit tests already covered the split in isolation; this is the
    // reachability half, the same distinction `rails.zig`'s "reachability"
    // test elsewhere in this file draws for `source.version`/`routes[]`).
    // Its resolved layout, `app/views/layouts/posts.html.erb`, has none of
    // its own. A producer that (incorrectly) surfaced the per-ROUTE union
    // instead of the per-node capture would show both names on the layout
    // too.
    var found_dashboard = false;
    var found_posts_layout = false;
    for (d.templates) |n| {
        if (std.mem.eql(u8, n.path, "app/views/posts/dashboard.html.erb")) {
            found_dashboard = true;
            try std.testing.expectEqual(@as(usize, 2), n.stimulus_controllers.len);
            try std.testing.expectEqualStrings("reveal", n.stimulus_controllers[0]);
            try std.testing.expectEqualStrings("modal", n.stimulus_controllers[1]);
            try std.testing.expectEqual(@as(usize, 0), n.component_roots.len);
        }
        if (std.mem.eql(u8, n.path, "app/views/layouts/posts.html.erb")) {
            found_posts_layout = true;
            try std.testing.expectEqual(@as(usize, 0), n.stimulus_controllers.len);
        }
    }
    try std.testing.expect(found_dashboard);
    try std.testing.expect(found_posts_layout);
}

test "discover: config/routes.rb absent but app/controllers/ present still reports ruby.available (Stage 4's task-2-fixes.md item 1)" {
    // The exact scenario the fix round confirmed end to end: `routes.zig`'s
    // `discoverRoutes` degrades to RAILS_ROUTES_MISSING and never spawns
    // Ruby (route_result.ruby.available = false), while `controllers.zig`'s
    // `discoverControllers` runs its OWN, separate sidecar process against
    // a real `app/controllers/` and succeeds -- Ruby was demonstrably
    // available for THIS run, just not for the routes op specifically. A
    // combineRuby that (like the pre-fix code) read route_result.ruby alone
    // would report `available: false` here despite that.
    //
    // Needs `ruby` on PATH and `ZIGAPAGOS_RUNTIME_DIR`, same as the sibling
    // "spawns the real Ruby sidecar" tests -- degrades to a
    // RAILS_RUBY_UNAVAILABLE/RAILS_CONTROLLERS_UNAVAILABLE blocker, not a
    // hard failure, when ruby genuinely isn't installed on this runner.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var ctrl_dir = try tmp.dir.createDirPathOpen(io, "app/controllers", .{});
    ctrl_dir.close(io);
    const f = try tmp.dir.createFile(io, "app/controllers/widgets_controller.rb", .{});
    try f.writeStreamingAll(io,
        \\class WidgetsController < ApplicationController
        \\  def index; end
        \\end
    );
    f.close(io);
    // Deliberately no config/ directory at all -- config/routes.rb is
    // absent, not merely empty, which is what makes discoverRoutes degrade
    // client-side before ever touching Ruby.

    // The sidecar needs an ABSOLUTE root that matches `tmp.dir` itself (a
    // relative "." would resolve against the real process cwd via
    // `sidecar_client.resolveAbsRoot`, not this temp directory) -- same
    // reasoning `routes.zig`'s own "ZIGAPAGOS_RUNTIME_DIR with no sidecar"
    // test applies to `runtime_dir_abs`.
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_abs_n = try tmp.dir.realPath(io, &root_buf);
    const root_abs = root_buf[0..root_abs_n];

    var env_map: std.process.Environ.Map = .init(gpa);
    defer env_map.deinit();
    try env_map.put("ZIGAPAGOS_RUNTIME_DIR", "runtime");

    const d = try discover(io, gpa, tmp.dir, root_abs, &env_map);
    defer freeDiscovery(gpa, d);

    if (!d.ruby.available) {
        if (std.mem.indexOf(u8, d.report, "RAILS_RUBY_UNAVAILABLE") != null or
            std.mem.indexOf(u8, d.report, "RAILS_CONTROLLERS_UNAVAILABLE") != null)
        {
            return error.SkipZigTest; // no working ruby on this runner
        }
        std.debug.print("discover degraded unexpectedly:\n{s}\n", .{d.report});
        return error.UnexpectedRubyDiscoveryDegradation;
    }

    // The property under test. A version of combineRuby (or of Discovery)
    // that reads only route_result.ruby -- the pre-fix bug -- reports
    // `false` here; only reading BOTH ops' answers gets this right.
    try std.testing.expect(d.ruby.available);
    try std.testing.expect(d.ruby.version() != null);
    // And the routes half of this same run genuinely did degrade -- this
    // is not a test that accidentally works because ruby.available is true
    // for some unrelated reason.
    try std.testing.expectEqualStrings("none", d.route_mode);
    try std.testing.expect(std.mem.indexOf(u8, d.report, "RAILS_ROUTES_MISSING") != null);
}
