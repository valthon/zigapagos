//! The blocker channel: failures and expected-but-unconverted findings that
//! Rails discovery cannot silently drop. std-only, see the note in
//! detect.zig.
//!
//! Before this file existed, a failed `openDir`/`walker.next`/Gemfile read
//! had nowhere to go and was swallowed into "absent"/"skip it" -- which
//! could make a partial or unreadable inventory print `Blockers: None.` and
//! exit 0 (P1/P5 in the PR review that added this file). Every site that
//! used to do that now appends a `Blocker` here instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `error` when the inventory or the analysis is untrustworthy: something
/// the pipeline needed to read or evaluate could not be, and there is
/// nothing else to fall back on -- `RAILS_INVENTORY_UNREADABLE` (part of the
/// app tree could not be walked) or `RAILS_ROUTES_MISSING` (route discovery
/// never ran at all, which is a different story than "ran and found zero").
///
/// `warn` when this is an expected finding that was correctly detected and
/// reported: the analysis worked, and this is its honest, scoped answer
/// about one file or one route -- `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` (a
/// Haml view is a fact, not a failure) or `RAILS_ROUTE_CONDITIONAL` (this
/// one route could not be statically resolved; the rest of the recovered
/// route graph is unaffected).
///
/// `@"error"` rather than `err`: the manifest spec (Stage 4 Task 7) names
/// this value `"error"`, and Zig types are meant to be the schema's source
/// of truth, so the tag matches the wire value exactly rather than needing a
/// translation table later. `@""` escapes the reserved keyword the same way
/// `WireResponse.@"error"` already does in routes.zig/controllers.zig.
pub const Severity = enum {
    @"error",
    warn,
};

pub const Blocker = struct {
    /// Stable, machine-greppable code. Stage 4 turns these into manifest
    /// entries. Always a static string literal -- never freed by `free`.
    code: []const u8,
    /// Source path the blocker concerns, relative to the app root.
    path: []const u8,
    /// Human detail, e.g. the error name.
    detail: []const u8,
    /// True when this blocker means the inventory itself is untrustworthy
    /// (as opposed to an expected finding like an unsupported template
    /// engine). `src/cli/migrate.zig`'s Rails block turns any integrity
    /// blocker into a non-zero exit.
    integrity: bool = false,
    /// A DIFFERENT axis from `integrity` above, for a different reader: this
    /// is descriptive metadata for a consumer of the manifest, not an exit-
    /// code signal. `--strict` (Stage 4 Task 10) fails on ANY blocker,
    /// severity-blind by design -- do not wire this field into an exit code.
    ///
    /// Not derivable from `integrity` mechanically: several route/controller
    /// degradation codes carry `integrity = false` (the route/action graph
    /// is a separate, optional layer on top of the inventory -- see
    /// `routes.zig`'s module doc) while still being `severity = .error`
    /// here, because a WHOLESALE discovery failure (no Ruby, no sidecar, no
    /// `config/routes.rb`) leaves the caller with no route evidence at all,
    /// which is a materially worse story than one specific unresolvable
    /// route among many that otherwise resolved fine. See `append`'s call
    /// sites for the per-code reasoning; there is no lookup table here on
    /// purpose, so each site states its own considered answer instead of
    /// inheriting one from a shared switch.
    ///
    /// No default: every `append`/`appendCopy` caller states this
    /// explicitly, the same way `integrity` already has no silent default
    /// worth relying on.
    severity: Severity,
    /// The route this blocker is about, when the call site can name one.
    /// `null` for every producer as of Stage 4 Task 1 -- this task only adds
    /// the field. No route has a stable id to reference yet (Task 2 adds
    /// `source: {file, line}` to `Route`, not an id), so wiring an actual
    /// association is left to whichever later stage has one to give.
    route_id: ?[]const u8 = null,
    /// The 1-based source line inside `path` this blocker is about, when
    /// the producer that appended it could name one. Stage 4 Task 8b: the
    /// Ruby-side static walk already sends `unresolved[].line` across the
    /// wire for the `RAILS_ROUTE_*`/`RAILS_CONTROLLER_*` unresolved-code
    /// families (`routes.zig`/`controllers.zig`'s `WireUnresolved.line`),
    /// and both `decodeResponse`s were decoding it and then dropping it on
    /// the floor -- this field is the fix, threaded from those two fold
    /// sites. `null` for every OTHER blocker: a whole-file finding (an
    /// unreadable Gemfile, a missing sidecar, an unsupported template
    /// engine) genuinely has no single line to point at. Never a stand-in
    /// like `1` -- a fabricated location is worse than an absent one,
    /// because someone will open the file and look at it.
    ///
    /// No default, the same discipline `severity` already uses: every
    /// `append`/`appendCopy` call site, and every hand-written `Blocker`
    /// literal in this codebase's tests, must state this explicitly rather
    /// than silently inheriting `null`.
    line: ?u64,
};

/// Contract 2 (owned-result): copies `path`, `detail`, and (when non-null)
/// `route_id` into new allocations that escape into `list` and are released
/// by `blockers.free`, never here. `code` is always a static string literal
/// and is never duplicated, so `free` must not free it. `severity`/`line`
/// are plain values with nothing to copy. `OutOfMemory` propagates without
/// partially mutating `list` (every dupe is freed via `errdefer` before the
/// append can fail, in reverse order of acquisition).
pub fn append(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Blocker),
    code: []const u8,
    path: []const u8,
    detail: []const u8,
    integrity: bool,
    severity: Severity,
    route_id: ?[]const u8,
    line: ?u64,
) Allocator.Error!void {
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);
    const detail_copy = try gpa.dupe(u8, detail);
    errdefer gpa.free(detail_copy);
    const route_id_copy: ?[]const u8 = if (route_id) |rid| try gpa.dupe(u8, rid) else null;
    errdefer if (route_id_copy) |rid| gpa.free(rid);
    try list.append(gpa, .{
        .code = code,
        .path = path_copy,
        .detail = detail_copy,
        .integrity = integrity,
        .severity = severity,
        .route_id = route_id_copy,
        .line = line,
    });
}

/// Contract 2 (owned-result), inherited from `append`: copies an existing
/// `Blocker` (e.g. one owned by another list that is about to be freed) into
/// `list`, whose contents are released by `blockers.free`. Forwards the
/// source blocker's own `severity`/`route_id`/`line` rather than re-deriving
/// them, so a blocker copied between lists (e.g. `rails.zig`'s `discover`
/// folding `inventory.walk`'s blockers into its run-wide list) keeps the
/// exact values its original `append` call chose.
pub fn appendCopy(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Blocker),
    b: Blocker,
) Allocator.Error!void {
    return append(gpa, list, b.code, b.path, b.detail, b.integrity, b.severity, b.route_id, b.line);
}

/// Releases the owned fields of every `Blocker` in `items` -- `path`,
/// `detail`, and (when non-null) `route_id` -- WITHOUT touching `items`
/// itself. Shared by `free` (which also frees the backing slice) and
/// `freeList` (which instead hands the backing array to
/// `std.ArrayListUnmanaged.deinit`, which knows the array's real capacity;
/// `free`'s own `gpa.free(items)` assumes `items` IS the exact original
/// allocation, which an in-progress list's `.items` is not guaranteed to
/// be). Also what `inventory.zig`'s `walk` calls directly in its own
/// errdefer, replacing a hand-rolled copy of this same loop that was
/// missing `route_id` (fix round 2, phase-1-review.md finding 14 /
/// phase-1-fixes.md section 3) -- a second hand-rolled copy is exactly the
/// drift `discover`'s own top-level `defer` already eliminated for itself
/// (see `freeList`'s doc) by calling a shared function instead.
pub fn freeItems(gpa: Allocator, items: []const Blocker) void {
    for (items) |b| {
        gpa.free(b.path);
        gpa.free(b.detail);
        if (b.route_id) |rid| gpa.free(rid);
    }
}

/// Contract 2 counterpart: releases `path`/`detail`/(non-null) `route_id` on
/// every blocker plus the slice itself. Does not free `code` -- those point
/// at static string literals owned by their call sites, not allocations.
pub fn free(gpa: Allocator, items: []Blocker) void {
    freeItems(gpa, items);
    gpa.free(items);
}

/// Contract 2 counterpart to `append`/`appendCopy`, operating on the
/// in-progress `ArrayListUnmanaged` directly rather than a `toOwnedSlice`'d
/// result. Fix round 2 (phase-1-review.md finding 16 / phase-1-fixes.md
/// section 3): `rails.zig`'s `discover` used to call `list.toOwnedSlice(gpa)
/// catch unreachable` inside its own top-level `defer` to get a `[]Blocker`
/// for `free`, but `toOwnedSlice` genuinely CAN return `error.OutOfMemory`
/// (it may shrink-reallocate to fit), which a `defer` has nowhere to route
/// -- `catch unreachable` was a plausible-looking assertion over a
/// genuinely reachable error, not a proof of anything. This never
/// allocates (`freeItems` only frees; `list.deinit` frees the list's own
/// already-owned backing array), so it cannot fail.
pub fn freeList(gpa: Allocator, list: *std.ArrayListUnmanaged(Blocker)) void {
    freeItems(gpa, list.items);
    list.deinit(gpa);
}

/// True when `code` names a blocker `routes.discoverRoutes` (or its callee
/// `decodeResponse`) can append: every route-discovery degradation path
/// (`RAILS_RUBY_UNAVAILABLE`, `RAILS_SIDECAR_MISSING`, `RAILS_SIDECAR_
/// FAILED`, `RAILS_ROUTES_MISSING`) plus every `unresolved[].code` `routes.
/// rb` emits (`RAILS_ROUTES_PARSE_ERROR`, and the `RAILS_ROUTE_*` family --
/// see `routes.zig`'s `known_unresolved_codes` and its `RAILS_ROUTE_
/// UNRESOLVED` fallback).
///
/// Matched by PREFIX rather than an exhaustive list, so a new `RAILS_ROUTE_*`
/// unresolved code lands covered without a second edit here. `"RAILS_ROUTE"`
/// alone already covers `RAILS_ROUTES_MISSING`/`RAILS_ROUTES_PARSE_ERROR`
/// (`"RAILS_ROUTES_..."` starts with `"RAILS_ROUTE"`); `"RAILS_SIDECAR"` and
/// `"RAILS_RUBY"` are listed separately because those two codes don't share
/// that stem.
///
/// Used by `report.zig` (to decide whether a zero-route run legitimately
/// found nothing, vs. found something it couldn't resolve) and by `rails.
/// zig`'s `discover` (to hand `migrate.zig` the same signal via `Discovery.
/// route_blocker`, so the CLI summary and the report never disagree about
/// which of those two zero-route stories is true).
pub fn isRouteRelated(code: []const u8) bool {
    const prefixes = [_][]const u8{ "RAILS_ROUTE", "RAILS_SIDECAR", "RAILS_RUBY" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, code, p)) return true;
    }
    return false;
}

test "isRouteRelated matches every route-discovery degradation and unresolved code" {
    const yes = [_][]const u8{
        "RAILS_ROUTES_MISSING",
        "RAILS_ROUTES_PARSE_ERROR",
        "RAILS_ROUTE_CONDITIONAL",
        "RAILS_ROUTE_ENGINE_MOUNT",
        "RAILS_ROUTE_UNRESOLVED",
        "RAILS_SIDECAR_MISSING",
        "RAILS_SIDECAR_FAILED",
        "RAILS_RUBY_UNAVAILABLE",
    };
    for (yes) |c| try std.testing.expect(isRouteRelated(c));

    const no = [_][]const u8{
        "RAILS_TEMPLATE_ENGINE_UNSUPPORTED",
        "RAILS_INVENTORY_UNREADABLE",
        "RAILS_INVENTORY_TRUNCATED",
        "RAILS_GEMFILE_UNREADABLE",
        "RAILS_PACKAGE_JSON_UNREADABLE",
        "RAILS_PACKAGE_JSON_MALFORMED",
        "RAILS_ASSET_PIPELINE_UNKNOWN",
        "RAILS_ASSET_DIGEST_UNAVAILABLE",
        "RAILS_ASSET_MANIFEST_MISSING",
    };
    for (no) |c| try std.testing.expect(!isRouteRelated(c));
}

fn expectBlockers(items: []const Blocker, want: []const Blocker) !void {
    try std.testing.expectEqual(want.len, items.len);
    for (items, want) |got, expected| {
        try std.testing.expectEqualStrings(expected.code, got.code);
        try std.testing.expectEqualStrings(expected.path, got.path);
        try std.testing.expectEqualStrings(expected.detail, got.detail);
        try std.testing.expectEqual(expected.integrity, got.integrity);
        try std.testing.expectEqual(expected.severity, got.severity);
        if (expected.route_id) |want_rid| {
            try std.testing.expectEqualStrings(want_rid, got.route_id.?);
        } else {
            try std.testing.expectEqual(@as(?[]const u8, null), got.route_id);
        }
        try std.testing.expectEqual(expected.line, got.line);
    }
}

test "append copies path and detail, leaves code pointing at the literal" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(Blocker) = .empty;
    defer free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    var path_buf = [_]u8{ 'a', '.', 'r', 'b' };
    try append(gpa, &list, "RAILS_GEMFILE_UNREADABLE", &path_buf, "AccessDenied", true, .@"error", null, null);
    path_buf[0] = 'z'; // mutate the caller's buffer; the copy must be unaffected

    try expectBlockers(list.items, &.{
        .{ .code = "RAILS_GEMFILE_UNREADABLE", .path = "a.rb", .detail = "AccessDenied", .integrity = true, .severity = .@"error", .line = null },
    });
}

test "append copies route_id, leaves it unaffected by mutating the caller's buffer" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(Blocker) = .empty;
    defer free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    var rid_buf = [_]u8{ 'r', '1' };
    try append(gpa, &list, "RAILS_ROUTE_CONDITIONAL", "config/routes.rb", "conditional route", false, .warn, &rid_buf, 118);

    try expectBlockers(list.items, &.{
        .{ .code = "RAILS_ROUTE_CONDITIONAL", .path = "config/routes.rb", .detail = "conditional route", .integrity = false, .severity = .warn, .route_id = "r1", .line = 118 },
    });
    rid_buf[0] = 'z';
    try std.testing.expectEqualStrings("r1", list.items[0].route_id.?);
}

test "appendCopy duplicates rather than aliasing the source blocker, including line" {
    const gpa = std.testing.allocator;
    var src: std.ArrayListUnmanaged(Blocker) = .empty;
    try append(gpa, &src, "RAILS_INVENTORY_TRUNCATED", "app", "AccessDenied", true, .@"error", null, null);
    try append(gpa, &src, "RAILS_ROUTE_CONDITIONAL", "config/routes.rb", "conditional route", false, .warn, null, 42);
    const src_items = try src.toOwnedSlice(gpa);

    var dst: std.ArrayListUnmanaged(Blocker) = .empty;
    defer free(gpa, dst.toOwnedSlice(gpa) catch unreachable);
    try appendCopy(gpa, &dst, src_items[0]);
    try appendCopy(gpa, &dst, src_items[1]);

    free(gpa, src_items); // frees the source; dst's copies must survive
    try expectBlockers(dst.items, &.{
        .{ .code = "RAILS_INVENTORY_TRUNCATED", .path = "app", .detail = "AccessDenied", .integrity = true, .severity = .@"error", .line = null },
        .{ .code = "RAILS_ROUTE_CONDITIONAL", .path = "config/routes.rb", .detail = "conditional route", .integrity = false, .severity = .warn, .line = 42 },
    });
}

// Severity is PER-CODE, not a constant `append`/its callers happen to always
// pass. An implementation that returned `.warn` (or `.@"error"`) for every
// code would satisfy "the field exists" while failing this: it pins that
// `RAILS_INVENTORY_UNREADABLE` (untrustworthy inventory) and
// `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` (a correctly-detected, expected
// finding) -- the exact two codes the brief itself contrasts -- disagree on
// severity, appended through the SAME `append` call in the SAME list.
test "severity is per-code: an inventory-integrity code and a detected-finding code disagree" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(Blocker) = .empty;
    defer free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    try append(gpa, &list, "RAILS_INVENTORY_UNREADABLE", "public", "AccessDenied", true, .@"error", null, null);
    try append(gpa, &list, "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", "app/views/x.html.haml", "Haml template is not converted", false, .warn, null, null);

    try std.testing.expectEqual(Severity.@"error", list.items[0].severity);
    try std.testing.expectEqual(Severity.warn, list.items[1].severity);
}
