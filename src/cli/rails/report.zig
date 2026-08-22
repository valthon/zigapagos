//! Renders the human MIGRATION.md worklist. Pure: takes in-memory inventory
//! data and returns markdown, so it is testable without a filesystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const inventory = @import("inventory.zig");
const integrations = @import("integrations.zig");
const blockers = @import("blockers.zig");

pub const Input = struct {
    app_path: []const u8,
    entries: []const inventory.Entry,
    integrations: []const integrations.Integration,
    /// Every blocker to render, from every source (inventory read failures,
    /// unsupported template engines, unreadable/malformed Gemfile and
    /// package.json). `build` only renders this list -- it constructs none
    /// of it itself, so there is a single blocker-construction path (the
    /// callers of `build`) rather than the report special-casing template
    /// engines on top of a separately populated list.
    blockers: []const blockers.Blocker,
};

test "report lists counts, integrations, and flags unsupported engines" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.haml", .kind = .view, .engine = .haml },
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
        // Joins engineFor's .slim classification (tested in inventory.zig)
        // with this module's "Slim" label mapping, so the two halves are
        // actually exercised together at least once.
        .{ .path = "app/views/posts/legacy.html.slim", .kind = .view, .engine = .slim },
    };
    const ints = [_]integrations.Integration{
        .{ .name = "propshaft", .evidence = "Gemfile:propshaft" },
    };
    // Constructed by hand rather than via
    // `inventory.appendUnsupportedEngineBlockers` -- that function has its
    // own test in inventory.zig; this file's tests are about rendering, not
    // construction, so they only need literal `Blocker` values to render.
    const rail_blockers = [_]blockers.Blocker{
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/posts/index.html.haml", .detail = "Haml template is not converted" },
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/posts/legacy.html.slim", .detail = "Slim template is not converted" },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "my-app",
        .entries = &entries,
        .integrations = &ints,
        .blockers = &rail_blockers,
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "# Migrating my-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Views | 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "propshaft") != null);
    // The Haml and Slim views must both be named as blockers, never silently
    // counted as done.
    try std.testing.expect(std.mem.indexOf(u8, md, "RAILS_TEMPLATE_ENGINE_UNSUPPORTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "app/views/posts/index.html.haml") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Slim") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "app/views/posts/legacy.html.slim") != null);
}

test "blockers render in (code, path) order regardless of input order" {
    const unsorted = [_]blockers.Blocker{
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/z.html.haml", .detail = "Haml template is not converted" },
        .{ .code = "RAILS_INVENTORY_UNREADABLE", .path = "public", .detail = "AccessDenied", .integrity = true },
        .{ .code = "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", .path = "app/views/a.html.haml", .detail = "Haml template is not converted" },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "x",
        .entries = &.{},
        .integrations = &.{},
        .blockers = &unsorted,
    });
    defer std.testing.allocator.free(md);

    const inventory_pos = std.mem.indexOf(u8, md, "RAILS_INVENTORY_UNREADABLE").?;
    const first_haml_pos = std.mem.indexOf(u8, md, "app/views/a.html.haml").?;
    const second_haml_pos = std.mem.indexOf(u8, md, "app/views/z.html.haml").?;
    // "RAILS_INVENTORY_UNREADABLE" < "RAILS_TEMPLATE_ENGINE_UNSUPPORTED"
    // lexically, and within the latter code, a.html.haml < z.html.haml.
    try std.testing.expect(inventory_pos < first_haml_pos);
    try std.testing.expect(first_haml_pos < second_haml_pos);
}

test "report is byte-identical across runs" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
    };
    const a = try build(std.testing.allocator, .{ .app_path = "x", .entries = &entries, .integrations = &.{}, .blockers = &.{} });
    defer std.testing.allocator.free(a);
    const b = try build(std.testing.allocator, .{ .app_path = "x", .entries = &entries, .integrations = &.{}, .blockers = &.{} });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

fn countOf(entries: []const inventory.Entry, kind: inventory.Kind) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.kind == kind) n += 1;
    }
    return n;
}

/// Contract 1 (self-freeing): all scratch is released; the returned markdown is
/// the single escaping allocation and is owned by the caller.
///
/// Contains no timestamp on purpose -- determinism is an acceptance criterion,
/// and a wall-clock stamp would make identical input produce differing output.
///
/// Deviation from the brief: the brief sketched `out.writer(gpa)` on an
/// `ArrayListUnmanaged(u8)`, but that method doesn't exist on 0.16.0's
/// `ArrayListUnmanaged` -- `migrate.zig`'s `buildOtherReport`/`buildReport`
/// (the real precedent for this exact job) instead use
/// `std.Io.Writer.Allocating`, whose `print`/`writeAll` return
/// `error{WriteFailed}`, not `Allocator.Error`. Since an `Allocating` writer's
/// only failure mode is the backing allocator running out of memory, each call
/// is `catch return error.OutOfMemory` to keep this function's declared
/// `Allocator.Error!` signature intact. `errdefer aw.deinit()` covers that
/// path; `migrate.zig` skips it because its caller (`fatal.oom()`) never
/// returns, but this module is std-only and must actually free on error.
pub fn build(gpa: Allocator, in: Input) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    w.print("# Migrating {s} to Zigapagos\n\n", .{in.app_path}) catch return error.OutOfMemory;
    w.writeAll(
        \\Rails source discovery. This worklist inventories the presentation
        \\layer; it converts nothing. Routes are not included at this stage.
        \\
        \\## Inventory
        \\
        \\| Kind | Count |
        \\| --- | --- |
        \\
    ) catch return error.OutOfMemory;
    w.print("| Views | {d} |\n", .{countOf(in.entries, .view)}) catch return error.OutOfMemory;
    w.print("| Layouts | {d} |\n", .{countOf(in.entries, .layout)}) catch return error.OutOfMemory;
    w.print("| Partials | {d} |\n", .{countOf(in.entries, .partial)}) catch return error.OutOfMemory;
    w.print("| Mailer views | {d} |\n", .{countOf(in.entries, .mailer_view)}) catch return error.OutOfMemory;
    w.print("| Controllers | {d} |\n", .{countOf(in.entries, .controller)}) catch return error.OutOfMemory;
    w.print("| Helpers | {d} |\n", .{countOf(in.entries, .helper)}) catch return error.OutOfMemory;
    w.print("| Stimulus controllers | {d} |\n", .{countOf(in.entries, .stimulus_controller)}) catch return error.OutOfMemory;
    w.print("| JS entrypoints | {d} |\n", .{countOf(in.entries, .js_entry)}) catch return error.OutOfMemory;
    w.print("| JS modules | {d} |\n", .{countOf(in.entries, .js_module)}) catch return error.OutOfMemory;
    w.print("| Assets | {d} |\n", .{countOf(in.entries, .asset)}) catch return error.OutOfMemory;

    w.writeAll("\n## Detected integrations\n\n") catch return error.OutOfMemory;
    if (in.integrations.len == 0) {
        w.writeAll("None detected.\n") catch return error.OutOfMemory;
    } else {
        for (in.integrations) |i| w.print("- `{s}` ({s})\n", .{ i.name, i.evidence }) catch return error.OutOfMemory;
    }

    w.writeAll("\n## Blockers\n\n") catch return error.OutOfMemory;
    if (in.blockers.len == 0) {
        w.writeAll("None.\n") catch return error.OutOfMemory;
    } else {
        // Sorted in a private copy so callers don't have to hand `build` a
        // pre-sorted list -- determinism (see the "byte-identical across
        // runs" test) is this function's responsibility, independent of
        // blocker *discovery* order (e.g. a truncated app/ walk happening
        // before a package.json read failure).
        const sorted = try gpa.dupe(Blocker, in.blockers);
        defer gpa.free(sorted);
        std.mem.sort(Blocker, sorted, {}, blockerLessThan);
        for (sorted) |b| {
            w.print("- `{s}` {s}: {s}\n", .{ b.code, b.path, b.detail }) catch return error.OutOfMemory;
        }
    }

    return aw.toOwnedSlice();
}

const Blocker = blockers.Blocker;

fn blockerLessThan(_: void, a: Blocker, b: Blocker) bool {
    return switch (std.mem.order(u8, a.code, b.code)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.path, b.path),
    };
}
