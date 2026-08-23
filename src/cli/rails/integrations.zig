//! Detects the asset pipeline and frontend runtime a Rails app uses, from
//! durable declarations (Gemfile, package.json) rather than file sniffing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const detect = @import("detect.zig");
const blockers = @import("blockers.zig");

pub const Integration = struct {
    name: []const u8,
    /// Where the conclusion came from, e.g. `Gemfile:propshaft`.
    evidence: []const u8,
};

/// Test helper: runs `scan` with a throwaway blocker list and asserts it came
/// back empty, so every existing happy-path test doesn't have to thread one
/// through by hand. Malformed-JSON tests below construct the list directly
/// instead of using this helper.
fn testScan(gemfile: ?[]const u8, package_json: ?[]const u8) ![]Integration {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, list.toOwnedSlice(gpa) catch unreachable);
    const items = try scan(gpa, gemfile, package_json, &list);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    return items;
}

test "gem-declared pipelines and runtimes are detected with evidence" {
    const gemfile =
        \\gem "rails", "~> 7.1"
        \\gem "propshaft"
        \\gem "turbo-rails"
        \\# gem "sprockets-rails"
    ;
    const items = try testScan(gemfile, null);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("propshaft", items[0].name);
    try std.testing.expectEqualStrings("Gemfile:propshaft", items[0].evidence);
    try std.testing.expectEqualStrings("turbo", items[1].name);
}

test "npm-declared runtimes are detected" {
    const pkg =
        \\{"dependencies":{"react":"19.0.0","@hotwired/stimulus":"3.2.2"}}
    ;
    const items = try testScan(null, pkg);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("react", items[0].name);
    try std.testing.expectEqualStrings("stimulus", items[1].name);
}

test "npm dependencies are matched by key regardless of JSON whitespace" {
    // P4 in the PR review: the old substring scan looked for the literal
    // bytes `"react":`, so `"react" : "19"` (valid JSON, just spaced
    // differently) was missed entirely.
    const pkg =
        \\{ "dependencies" : { "react" : "19.0.0" } }
    ;
    const items = try testScan(null, pkg);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("react", items[0].name);
}

test "an unscoped key match outside dependencies/devDependencies is not an integration" {
    // P4: the old substring scan matched `"react":` anywhere in the file --
    // a script named "react", or a nested unrelated config block, would
    // false-positive. Scoping to the two dependency objects fixes that.
    const pkg =
        \\{"scripts":{"react":"echo not-a-dependency"},"dependencies":{}}
    ;
    const items = try testScan(null, pkg);
    defer freeIntegrations(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "devDependencies are scanned too" {
    const pkg =
        \\{"devDependencies":{"vite":"5.0.0"}}
    ;
    const items = try testScan(null, pkg);
    defer freeIntegrations(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("vite", items[0].name);
}

test "malformed package.json emits a blocker, not a silent zero integrations" {
    // P4: a malformed package.json must not silently mean "no
    // integrations" -- the inventory otherwise looks confidently empty.
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    const items = try scan(gpa, null, "{not valid json", &list);
    defer freeIntegrations(gpa, items);

    try std.testing.expectEqual(@as(usize, 0), items.len);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("RAILS_PACKAGE_JSON_MALFORMED", list.items[0].code);
    try std.testing.expectEqualStrings("package.json", list.items[0].path);
    // Malformed JSON is an expected finding to report, not evidence the rest
    // of the inventory (which never touched package.json) is untrustworthy.
    try std.testing.expect(!list.items[0].integrity);
    try std.testing.expectEqual(blockers.Severity.warn, list.items[0].severity);
}

test "a commented gem is not an integration" {
    const items = try testScan("# gem \"vite_rails\"\n", null);
    defer freeIntegrations(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "a gem-proved integration wins over the same npm-declared one, no duplicate" {
    const gemfile =
        \\gem "turbo-rails"
    ;
    const pkg =
        \\{"dependencies":{"@hotwired/turbo":"7.3.0"}}
    ;
    const items = try testScan(gemfile, pkg);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("turbo", items[0].name);
    // The Gemfile hit must win: if the npm rule won instead this would read
    // "package.json:@hotwired/turbo".
    try std.testing.expectEqualStrings("Gemfile:turbo-rails", items[0].evidence);
}

const GemRule = struct { gem: []const u8, name: []const u8 };
const PkgRule = struct { pkg: []const u8, name: []const u8 };

/// Order fixes the output order, which keeps the report deterministic.
const gem_rules = [_]GemRule{
    .{ .gem = "propshaft", .name = "propshaft" },
    .{ .gem = "sprockets-rails", .name = "sprockets" },
    .{ .gem = "importmap-rails", .name = "importmap" },
    .{ .gem = "jsbundling-rails", .name = "jsbundling" },
    .{ .gem = "cssbundling-rails", .name = "cssbundling" },
    .{ .gem = "vite_rails", .name = "vite" },
    .{ .gem = "turbo-rails", .name = "turbo" },
    .{ .gem = "stimulus-rails", .name = "stimulus" },
};

const pkg_rules = [_]PkgRule{
    .{ .pkg = "react", .name = "react" },
    .{ .pkg = "vue", .name = "vue" },
    .{ .pkg = "@hotwired/turbo", .name = "turbo" },
    .{ .pkg = "@hotwired/stimulus", .name = "stimulus" },
    .{ .pkg = "vite", .name = "vite" },
};

/// `root` is package.json's top-level parsed value. Looks `pkg` up as a key
/// of `dependencies` or `devDependencies` only -- not anywhere else in the
/// file, so a same-named script or an unrelated nested config block can't
/// false-positive the way the old substring scan could (P4 in the PR
/// review).
fn packageDeclares(root: std.json.Value, pkg: []const u8) bool {
    if (root != .object) return false;
    for ([_][]const u8{ "dependencies", "devDependencies" }) |section| {
        const deps = root.object.get(section) orelse continue;
        if (deps != .object) continue;
        if (deps.object.contains(pkg)) return true;
    }
    return false;
}

fn has(items: []const Integration, name: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i.name, name)) return true;
    return false;
}

/// Contract 2 (owned-result): caller releases with `freeIntegrations`.
/// `name` in each returned `Integration` points at a static string literal
/// from the rule tables above and is never freed; only `evidence` is
/// allocated per-item.
///
/// `package_json` is parsed once here (rather than once per `pkg_rules`
/// entry) into a scratch `std.json.Value` tree that is freed before this
/// function returns -- only the resulting `Integration`s escape. A malformed
/// `package.json` is not silently treated as "no npm integrations": it
/// appends `RAILS_PACKAGE_JSON_MALFORMED` to `blocker_list` (not an
/// integrity blocker -- the walked inventory never touched package.json, so
/// it stays trustworthy) and the Gemfile-derived integrations above are kept.
/// `error.OutOfMemory` always propagates.
pub fn scan(
    gpa: Allocator,
    gemfile: ?[]const u8,
    package_json: ?[]const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error![]Integration {
    var list: std.ArrayListUnmanaged(Integration) = .empty;
    errdefer {
        for (list.items) |i| gpa.free(i.evidence);
        list.deinit(gpa);
    }

    if (gemfile) |src| {
        for (gem_rules) |rule| {
            if (!detect.gemfileDeclares(src, rule.gem)) continue;
            const ev = try std.fmt.allocPrint(gpa, "Gemfile:{s}", .{rule.gem});
            errdefer gpa.free(ev);
            try list.append(gpa, .{ .name = rule.name, .evidence = ev });
        }
    }
    if (package_json) |src| pkg_blk: {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, src, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // `.warn`: package.json was read fine; its JSON just doesn't
                // parse. That is a fact about the app's own file, correctly
                // detected and reported -- not evidence anything ELSE this
                // scan produced (the Gemfile-derived integrations above, or
                // the walked inventory, which never touched package.json) is
                // untrustworthy. See this function's own doc comment.
                try blockers.append(gpa, blocker_list, "RAILS_PACKAGE_JSON_MALFORMED", "package.json", @errorName(err), false, .warn, null);
                break :pkg_blk;
            },
        };
        defer parsed.deinit();
        for (pkg_rules) |rule| {
            if (!packageDeclares(parsed.value, rule.pkg)) continue;
            if (has(list.items, rule.name)) continue; // gem already proved it
            const ev = try std.fmt.allocPrint(gpa, "package.json:{s}", .{rule.pkg});
            errdefer gpa.free(ev);
            try list.append(gpa, .{ .name = rule.name, .evidence = ev });
        }
    }
    return list.toOwnedSlice(gpa);
}

/// Contract 2 counterpart: releases the slice and every `evidence` returned
/// by `scan`. Does not free `name` -- those point at static string literals
/// owned by the rule tables, not allocations.
pub fn freeIntegrations(gpa: Allocator, items: []Integration) void {
    for (items) |i| gpa.free(i.evidence);
    gpa.free(items);
}
