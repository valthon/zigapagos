//! Detects the asset pipeline and frontend runtime a Rails app uses, from
//! durable declarations (Gemfile, package.json) rather than file sniffing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const detect = @import("detect.zig");
const blockers = @import("blockers.zig");

pub const Integration = struct {
    name: []const u8,
    /// The resolved version, when one is discoverable -- Stage 4 Task 8b.
    /// A gem-sourced integration's version comes from `Gemfile.lock`
    /// (`detect.lockedVersion`, by the gem's own name, never the Gemfile's
    /// unresolved constraint); an npm-sourced one's comes from the matched
    /// `package.json` dependency VALUE (the key proves the integration,
    /// the value names its version). `null` when neither source names one
    /// -- e.g. a `Gemfile.lock` this run never read, or a `package.json`
    /// dependency value that isn't a plain string (a workspace/`file:`/git
    /// protocol reference). Never a guess and never an empty string: an
    /// integration this scan cannot version reports `null`, honestly.
    version: ?[]const u8,
    /// Where the conclusion came from, e.g. `Gemfile:propshaft`.
    evidence: []const u8,
};

/// One installable package declaration copied from package.json. Both
/// fields are owned because the JSON parse tree is released before this
/// value reaches discovery's consumers.
pub const NpmDep = struct {
    name: []const u8,
    version: []const u8,
};

/// Contract 2 (owned-result): returns every string-valued dependency and
/// devDependency, sorted by name, with both fields freshly allocated.
/// `dependencies` wins when a malformed package declares the same name in
/// both sections, matching package managers' effective dependency view.
/// Malformed JSON yields an empty owned slice: `scan` is the single place
/// that reports `RAILS_PACKAGE_JSON_MALFORMED` for the same bytes.
pub fn dependencyVersions(gpa: Allocator, package_json: []const u8) Allocator.Error![]NpmDep {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, package_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return gpa.alloc(NpmDep, 0),
    };
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(NpmDep) = .empty;
    errdefer {
        for (list.items) |dep| {
            gpa.free(dep.name);
            gpa.free(dep.version);
        }
        list.deinit(gpa);
    }
    if (parsed.value == .object) {
        for ([_][]const u8{ "dependencies", "devDependencies" }) |section| {
            const deps = parsed.value.object.get(section) orelse continue;
            if (deps != .object) continue;
            var it = deps.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string) continue;
                var duplicate = false;
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing.name, entry.key_ptr.*)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                const name = try gpa.dupe(u8, entry.key_ptr.*);
                errdefer gpa.free(name);
                const version = try gpa.dupe(u8, entry.value_ptr.string);
                errdefer gpa.free(version);
                try list.append(gpa, .{ .name = name, .version = version });
            }
        }
    }
    const out = try list.toOwnedSlice(gpa);
    std.mem.sort(NpmDep, out, {}, struct {
        fn lessThan(_: void, a: NpmDep, b: NpmDep) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return out;
}

/// Contract 2 counterpart to `dependencyVersions`.
pub fn freeDependencyVersions(gpa: Allocator, items: []NpmDep) void {
    for (items) |dep| {
        gpa.free(dep.name);
        gpa.free(dep.version);
    }
    gpa.free(items);
}

/// Test helper: runs `scan` with a throwaway blocker list and asserts it came
/// back empty, so every existing happy-path test doesn't have to thread one
/// through by hand. Malformed-JSON tests below construct the list directly
/// instead of using this helper.
fn testScan(gemfile: ?[]const u8, package_json: ?[]const u8) ![]Integration {
    return testScanWithLock(gemfile, package_json, null);
}

/// Companion to `testScan` for the tests below that also need to supply
/// `Gemfile.lock` content (the gem-sourced `version` path).
fn testScanWithLock(gemfile: ?[]const u8, package_json: ?[]const u8, gemfile_lock: ?[]const u8) ![]Integration {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, list.toOwnedSlice(gpa) catch unreachable);
    const items = try scan(gpa, gemfile, package_json, gemfile_lock, &list);
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

test "dependencyVersions returns every string dependency sorted by name" {
    const gpa = std.testing.allocator;
    const items = try dependencyVersions(gpa,
        \\{"dependencies":{"react":"19.0.0","x":{"workspace":"*"}},"devDependencies":{"@types/react":"19.0.1","react":"ignored-duplicate"}}
    );
    defer freeDependencyVersions(gpa, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("@types/react", items[0].name);
    try std.testing.expectEqualStrings("19.0.1", items[0].version);
    try std.testing.expectEqualStrings("react", items[1].name);
    try std.testing.expectEqualStrings("19.0.0", items[1].version);
}

test "dependencyVersions: FailingAllocator sweep" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 200) return error.SweepNeverReachedSuccess;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (dependencyVersions(failing.allocator(), "{\"dependencies\":{\"react\":\"19\",\"d3\":\"7\"}}")) |items| {
            defer freeDependencyVersions(std.testing.allocator, items);
            try std.testing.expectEqual(@as(usize, 2), items.len);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "malformed package.json emits a blocker, not a silent zero integrations" {
    // P4: a malformed package.json must not silently mean "no
    // integrations" -- the inventory otherwise looks confidently empty.
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    const items = try scan(gpa, null, "{not valid json", null, &list);
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

// --- Stage 4 Task 8b: integrations[].version -------------------------------
//
// Three genuinely different cases, all covered so a hardcoded `null` (Task
// 8's honest-but-incomplete state) cannot pass silently: a gem-sourced
// integration resolves its version from `Gemfile.lock`; an npm-sourced one
// resolves it from `package.json`'s own dependency value; one with neither
// source reports `null`.

test "a gem-sourced integration's version comes from Gemfile.lock, by the GEM's own name" {
    const gemfile =
        \\gem "turbo-rails"
    ;
    const lock =
        \\GEM
        \\  remote: https://rubygems.org/
        \\  specs:
        \\    turbo-rails (1.5.0)
        \\      railties (>= 6.0.0)
        \\
        \\PLATFORMS
        \\  ruby
        \\
        \\DEPENDENCIES
        \\  turbo-rails
        \\
    ;
    const items = try testScanWithLock(gemfile, null, lock);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("turbo", items[0].name);
    try std.testing.expectEqualStrings("1.5.0", items[0].version.?);
}

test "an npm-sourced integration's version comes from package.json's own dependency value" {
    const pkg =
        \\{"dependencies":{"@hotwired/turbo":"7.3.0"}}
    ;
    const items = try testScan(null, pkg);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("turbo", items[0].name);
    try std.testing.expectEqualStrings("7.3.0", items[0].version.?);
}

test "an integration with neither a Gemfile.lock entry nor a resolvable package.json value reports version null" {
    // Gem-sourced but no Gemfile.lock was ever supplied to this scan (a
    // missing/unreadable lock file, upstream of this function).
    const gemfile =
        \\gem "propshaft"
    ;
    const items = try testScan(gemfile, null);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("propshaft", items[0].name);
    try std.testing.expectEqual(@as(?[]const u8, null), items[0].version);
}

test "a Gemfile.lock that never locks the declared gem still reports version null, not a crash" {
    const gemfile =
        \\gem "propshaft"
    ;
    const lock =
        \\GEM
        \\  remote: https://rubygems.org/
        \\  specs:
        \\    sinatra (3.1.0)
        \\
        \\PLATFORMS
        \\  ruby
        \\
        \\DEPENDENCIES
        \\  sinatra
        \\
    ;
    const items = try testScanWithLock(gemfile, null, lock);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), items[0].version);
}

test "an npm dependency value that is not a plain string reports version null, not a fabricated one" {
    // A workspace/`file:`/git-protocol reference is valid `package.json`
    // but not a version string -- this scan must not coerce it into one.
    const pkg =
        \\{"dependencies":{"react":{"workspace":"*"}}}
    ;
    const items = try testScan(null, pkg);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("react", items[0].name);
    try std.testing.expectEqual(@as(?[]const u8, null), items[0].version);
}

test "gem-proved integration's version comes from the lock, not from an npm-declared duplicate's package.json value" {
    // Companion to "a gem-proved integration wins over the same npm-declared
    // one" above, extended to `version`: the winning (Gemfile) evidence
    // must carry the winning (Gemfile.lock) version, not the npm value the
    // pkg_rules loop would have used had it not deduped against `has`.
    const gemfile =
        \\gem "turbo-rails"
    ;
    const pkg =
        \\{"dependencies":{"@hotwired/turbo":"7.3.0"}}
    ;
    const lock =
        \\GEM
        \\  remote: https://rubygems.org/
        \\  specs:
        \\    turbo-rails (1.5.0)
        \\      railties (>= 6.0.0)
        \\
        \\PLATFORMS
        \\  ruby
        \\
        \\DEPENDENCIES
        \\  turbo-rails
        \\
    ;
    const items = try testScanWithLock(gemfile, pkg, lock);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Gemfile:turbo-rails", items[0].evidence);
    // Not "7.3.0" (the npm value) -- proves the version resolution follows
    // the SAME evidence source that won, not an independent lookup that
    // happens to agree.
    try std.testing.expectEqualStrings("1.5.0", items[0].version.?);
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
/// review). Returns the matched dependency's own JSON VALUE (Stage 4 Task
/// 8b: `null` still means "not declared"; a declared-but-non-string value,
/// e.g. a workspace reference, is distinguished by the caller checking the
/// returned `std.json.Value`'s tag, not by this function).
fn packageValue(root: std.json.Value, pkg: []const u8) ?std.json.Value {
    if (root != .object) return null;
    for ([_][]const u8{ "dependencies", "devDependencies" }) |section| {
        const deps = root.object.get(section) orelse continue;
        if (deps != .object) continue;
        if (deps.object.get(pkg)) |v| return v;
    }
    return null;
}

fn has(items: []const Integration, name: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i.name, name)) return true;
    return false;
}

/// Contract 2 (owned-result): caller releases with `freeIntegrations`.
/// `name` in each returned `Integration` points at a static string literal
/// from the rule tables above and is never freed; `evidence` is always
/// allocated per-item, and `version` is allocated per-item when non-null
/// (see `Integration.version`'s own doc for when that is).
///
/// `gemfile_lock`, when supplied, is the ALREADY-READ contents of
/// `Gemfile.lock` -- read once by `rails.zig`'s `discover` (which also
/// resolves Rails' own version from it via `detect.versionFromLock`) and
/// handed to both callers, rather than this function reading the file a
/// second time: a second read would append `RAILS_GEMFILE_LOCK_UNAVAILABLE`
/// twice on a missing/unreadable lock file. `detect.lockedVersion` (Task 7)
/// is reused for the per-gem lookup rather than re-parsed here -- two
/// parsers for one file diverge on the first edit.
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
    gemfile_lock: ?[]const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error![]Integration {
    var list: std.ArrayListUnmanaged(Integration) = .empty;
    errdefer {
        for (list.items) |i| {
            gpa.free(i.evidence);
            if (i.version) |v| gpa.free(v);
        }
        list.deinit(gpa);
    }

    if (gemfile) |src| {
        for (gem_rules) |rule| {
            if (!detect.gemfileDeclares(src, rule.gem)) continue;
            const ev = try std.fmt.allocPrint(gpa, "Gemfile:{s}", .{rule.gem});
            errdefer gpa.free(ev);
            const version: ?[]const u8 = if (gemfile_lock) |lock| blk: {
                const found = detect.lockedVersion(lock, rule.gem) orelse break :blk null;
                break :blk try gpa.dupe(u8, found);
            } else null;
            errdefer if (version) |v| gpa.free(v);
            try list.append(gpa, .{ .name = rule.name, .version = version, .evidence = ev });
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
                try blockers.append(gpa, blocker_list, "RAILS_PACKAGE_JSON_MALFORMED", "package.json", @errorName(err), false, .warn, null, null);
                break :pkg_blk;
            },
        };
        defer parsed.deinit();
        for (pkg_rules) |rule| {
            const val = packageValue(parsed.value, rule.pkg) orelse continue;
            if (has(list.items, rule.name)) continue; // gem already proved it
            const ev = try std.fmt.allocPrint(gpa, "package.json:{s}", .{rule.pkg});
            errdefer gpa.free(ev);
            // The dependency's VALUE is the version, but only when it is
            // actually a JSON string -- a workspace/`file:`/git-protocol
            // reference is a valid dependency value that names no version
            // at all, and coercing it into one would be exactly the
            // fabricated-value failure this stage exists to avoid.
            const version: ?[]const u8 = if (val == .string) try gpa.dupe(u8, val.string) else null;
            errdefer if (version) |v| gpa.free(v);
            try list.append(gpa, .{ .name = rule.name, .version = version, .evidence = ev });
        }
    }
    return list.toOwnedSlice(gpa);
}

/// Contract 2 counterpart: releases the slice and every `evidence`/(non-null)
/// `version` returned by `scan`. Does not free `name` -- those point at
/// static string literals owned by the rule tables, not allocations.
pub fn freeIntegrations(gpa: Allocator, items: []Integration) void {
    for (items) |i| {
        gpa.free(i.evidence);
        if (i.version) |v| gpa.free(v);
    }
    gpa.free(items);
}
