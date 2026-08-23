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
};

/// Contract 2 (owned-result): copies `path` and `detail` into new allocations
/// that escape into `list` and are released by `blockers.free`, never here.
/// `code` is always a static string literal and is never duplicated, so `free`
/// must not free it. `OutOfMemory` propagates without partially mutating
/// `list` (both dupes are freed via `errdefer` before the append can fail).
pub fn append(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Blocker),
    code: []const u8,
    path: []const u8,
    detail: []const u8,
    integrity: bool,
) Allocator.Error!void {
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);
    const detail_copy = try gpa.dupe(u8, detail);
    errdefer gpa.free(detail_copy);
    try list.append(gpa, .{
        .code = code,
        .path = path_copy,
        .detail = detail_copy,
        .integrity = integrity,
    });
}

/// Contract 2 (owned-result), inherited from `append`: copies an existing
/// `Blocker` (e.g. one owned by another list that is about to be freed) into
/// `list`, whose contents are released by `blockers.free`.
pub fn appendCopy(
    gpa: Allocator,
    list: *std.ArrayListUnmanaged(Blocker),
    b: Blocker,
) Allocator.Error!void {
    return append(gpa, list, b.code, b.path, b.detail, b.integrity);
}

/// Contract 2 counterpart: releases `path`/`detail` on every blocker plus the
/// slice itself. Does not free `code` -- those point at static string
/// literals owned by their call sites, not allocations.
pub fn free(gpa: Allocator, items: []Blocker) void {
    for (items) |b| {
        gpa.free(b.path);
        gpa.free(b.detail);
    }
    gpa.free(items);
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
    }
}

test "append copies path and detail, leaves code pointing at the literal" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(Blocker) = .empty;
    defer free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    var path_buf = [_]u8{ 'a', '.', 'r', 'b' };
    try append(gpa, &list, "RAILS_GEMFILE_UNREADABLE", &path_buf, "AccessDenied", true);
    path_buf[0] = 'z'; // mutate the caller's buffer; the copy must be unaffected

    try expectBlockers(list.items, &.{
        .{ .code = "RAILS_GEMFILE_UNREADABLE", .path = "a.rb", .detail = "AccessDenied", .integrity = true },
    });
}

test "appendCopy duplicates rather than aliasing the source blocker" {
    const gpa = std.testing.allocator;
    var src: std.ArrayListUnmanaged(Blocker) = .empty;
    try append(gpa, &src, "RAILS_INVENTORY_TRUNCATED", "app", "AccessDenied", true);
    const src_items = try src.toOwnedSlice(gpa);

    var dst: std.ArrayListUnmanaged(Blocker) = .empty;
    defer free(gpa, dst.toOwnedSlice(gpa) catch unreachable);
    try appendCopy(gpa, &dst, src_items[0]);

    free(gpa, src_items); // frees the source; dst's copy must survive
    try expectBlockers(dst.items, &.{
        .{ .code = "RAILS_INVENTORY_TRUNCATED", .path = "app", .detail = "AccessDenied", .integrity = true },
    });
}
