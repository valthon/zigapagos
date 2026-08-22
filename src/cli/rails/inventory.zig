//! Rails presentation inventory: pure path classification plus the app/ walker.
//! std-only by design (see the note in detect.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");
const Blocker = blockers.Blocker;

pub const Kind = enum {
    view,
    layout,
    partial,
    mailer_view,
    controller,
    helper,
    stimulus_controller,
    js_entry,
    js_module,
    asset,
    other,
};

pub const Engine = enum { erb, haml, slim, jbuilder, builder, none };

test "engineFor reads the template engine off the compound extension" {
    try std.testing.expectEqual(Engine.erb, engineFor("app/views/posts/show.html.erb"));
    try std.testing.expectEqual(Engine.haml, engineFor("app/views/posts/show.html.haml"));
    try std.testing.expectEqual(Engine.slim, engineFor("app/views/posts/show.html.slim"));
    try std.testing.expectEqual(Engine.jbuilder, engineFor("app/views/posts/index.json.jbuilder"));
    try std.testing.expectEqual(Engine.none, engineFor("app/controllers/posts_controller.rb"));
}

test "a leading underscore means partial, even inside layouts/" {
    // Rails resolves app/views/layouts/_nav.html.erb as a partial, not a layout.
    try std.testing.expectEqual(Kind.partial, classify("app/views/layouts/_nav.html.erb"));
    try std.testing.expectEqual(Kind.partial, classify("app/views/posts/_post.html.erb"));
}

test "layouts, mailer views and plain views are distinguished" {
    try std.testing.expectEqual(Kind.layout, classify("app/views/layouts/application.html.erb"));
    try std.testing.expectEqual(Kind.mailer_view, classify("app/views/user_mailer/welcome.html.erb"));
    try std.testing.expectEqual(Kind.view, classify("app/views/posts/show.html.erb"));
    // A namespaced mailer: the `_mailer` segment is the last directory, not
    // the first. Checking the first segment would see `admin` and classify
    // this as a plain view.
    try std.testing.expectEqual(
        Kind.mailer_view,
        classify("app/views/admin/user_mailer/digest.html.erb"),
    );
    // ...but a namespace that merely CONTAINS a mailer must not drag its
    // sibling views along.
    try std.testing.expectEqual(Kind.view, classify("app/views/admin/posts/show.html.erb"));
}

test "code, stimulus and asset paths are classified" {
    try std.testing.expectEqual(Kind.controller, classify("app/controllers/posts_controller.rb"));
    try std.testing.expectEqual(Kind.helper, classify("app/helpers/posts_helper.rb"));
    try std.testing.expectEqual(
        Kind.stimulus_controller,
        classify("app/javascript/controllers/reveal_controller.js"),
    );
    try std.testing.expectEqual(Kind.js_entry, classify("app/javascript/application.js"));
    try std.testing.expectEqual(Kind.asset, classify("app/assets/images/logo.png"));
    try std.testing.expectEqual(Kind.asset, classify("public/favicon.ico"));
    try std.testing.expectEqual(Kind.other, classify("config/database.yml"));
}

test "a TypeScript Stimulus controller nested under controllers/ is still recognized" {
    // Any depth under controllers/, and a script extension beyond .js --
    // this was P2 in the PR review: only *_controller.js was recognized,
    // so a TS controller fell through to the catch-all js_entry rule below.
    try std.testing.expectEqual(
        Kind.stimulus_controller,
        classify("app/javascript/controllers/toggle_controller.ts"),
    );
    try std.testing.expectEqual(
        Kind.stimulus_controller,
        classify("app/javascript/controllers/nested/deep_controller.jsx"),
    );
}

test "a non-entrypoint file under app/javascript/ is a js_module, not a js_entry" {
    // P2: everything under app/javascript/ used to be labeled js_entry,
    // which corrupted the inventory for React/Vue apps -- a shared
    // component or library isn't a bundler entrypoint.
    try std.testing.expectEqual(Kind.js_module, classify("app/javascript/components/Button.jsx"));
    try std.testing.expectEqual(Kind.js_module, classify("app/javascript/lib/format.js"));
    // A non-_controller file directly inside controllers/ is a module too,
    // not a Stimulus controller.
    try std.testing.expectEqual(Kind.js_module, classify("app/javascript/controllers/index.js"));
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

const script_exts = [_][]const u8{ ".js", ".mjs", ".ts", ".jsx", ".tsx" };

fn hasScriptExt(path: []const u8) bool {
    for (script_exts) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

/// Strips a recognized script extension, or returns `null` when `path` has
/// none (e.g. a `.json` or extensionless file under `app/javascript/`).
fn stripScriptExt(path: []const u8) ?[]const u8 {
    for (script_exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return path[0 .. path.len - ext.len];
    }
    return null;
}

/// Contract 3 (caller-buffer): allocates nothing, returns a view-free enum.
pub fn engineFor(path: []const u8) Engine {
    if (std.mem.endsWith(u8, path, ".erb")) return .erb;
    if (std.mem.endsWith(u8, path, ".haml")) return .haml;
    if (std.mem.endsWith(u8, path, ".slim")) return .slim;
    if (std.mem.endsWith(u8, path, ".jbuilder")) return .jbuilder;
    if (std.mem.endsWith(u8, path, ".builder")) return .builder;
    return .none;
}

/// Contract 3 (caller-buffer). `rel_path` is relative to the Rails app root and
/// always uses forward slashes.
pub fn classify(rel_path: []const u8) Kind {
    if (std.mem.startsWith(u8, rel_path, "app/views/")) {
        // Checked before the layouts/ prefix: a partial keeps partial semantics
        // wherever it lives.
        if (basename(rel_path).len > 0 and basename(rel_path)[0] == '_') return .partial;
        if (std.mem.startsWith(u8, rel_path, "app/views/layouts/")) return .layout;
        const rest = rel_path["app/views/".len..];
        if (std.mem.lastIndexOfScalar(u8, rest, '/')) |slash| {
            // A mailer renders from the directory named after it, which is the
            // LAST segment before the template: `Admin::UserMailer` renders
            // from `app/views/admin/user_mailer/`. Checking the first segment
            // instead sees `admin` and misses every namespaced mailer.
            const dir = rest[0..slash];
            const leaf = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |cut| dir[cut + 1 ..] else dir;
            if (std.mem.endsWith(u8, leaf, "_mailer")) return .mailer_view;
        }
        return .view;
    }
    if (std.mem.startsWith(u8, rel_path, "app/controllers/") and
        std.mem.endsWith(u8, rel_path, "_controller.rb")) return .controller;
    if (std.mem.startsWith(u8, rel_path, "app/helpers/")) return .helper;
    if (std.mem.startsWith(u8, rel_path, "app/javascript/controllers/")) {
        // Stimulus controllers can live at any depth under controllers/ (a
        // namespaced controller directory is a normal Rails/Stimulus
        // convention) and can be authored in any recognized script
        // extension, not just plain .js.
        if (stripScriptExt(rel_path)) |stem| {
            if (std.mem.endsWith(u8, basename(stem), "_controller")) return .stimulus_controller;
        }
    }
    if (std.mem.startsWith(u8, rel_path, "app/javascript/")) {
        const rest = rel_path["app/javascript/".len..];
        const is_direct_child = std.mem.indexOfScalar(u8, rest, '/') == null;
        // Matches the jsbundling-rails convention: only a top-level file
        // directly under app/javascript/ is a built entrypoint. Everything
        // else (nested files, and top-level files with no script
        // extension) is a module the entrypoint imports, not an entrypoint
        // itself.
        if (is_direct_child and hasScriptExt(rel_path)) return .js_entry;
        return .js_module;
    }
    if (std.mem.startsWith(u8, rel_path, "app/assets/")) return .asset;
    if (std.mem.startsWith(u8, rel_path, "public/")) return .asset;
    return .other;
}

pub const Entry = struct {
    /// Relative to the Rails app root, forward slashes.
    path: []const u8,
    kind: Kind,
    engine: Engine,
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

const roots = [_][]const u8{ "app", "public" };

pub const WalkResult = struct {
    entries: []Entry,
    blockers: []Blocker,
};

/// Contract 2 (owned-result): every slice here -- `entries`, every `path` in
/// it, and `blockers` (with its `path`/`detail`) -- is owned by the caller;
/// release with `freeWalkResult`.
///
/// `entries` is sorted by path so the emitted report and manifest are
/// byte-deterministic. `error.OutOfMemory` always propagates as an error and
/// never becomes a blocker.
pub fn walk(io: Io, gpa: Allocator, root: Io.Dir) Allocator.Error!WalkResult {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    var blocker_list: std.ArrayListUnmanaged(Blocker) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.path);
        list.deinit(gpa);
        for (blocker_list.items) |b| {
            gpa.free(b.path);
            gpa.free(b.detail);
        }
        blocker_list.deinit(gpa);
    }

    for (roots) |top| {
        var dir = root.openDir(io, top, .{ .iterate = true }) catch |err| {
            // FileNotFound is the expected, silent case: public/ legitimately
            // may not exist in a Rails app that serves everything through
            // the asset pipeline. Any other open failure (permission denied,
            // a transient I/O error, ...) means this root's contents are
            // simply unknown -- silently treating that the same as "doesn't
            // exist" is what let a permission error produce a confident,
            // undercounted "Blockers: None." report (P1 in the PR review).
            if (err == error.FileNotFound) continue;
            try blockers.append(gpa, &blocker_list, "RAILS_INVENTORY_UNREADABLE", top, @errorName(err), true);
            continue;
        };
        defer dir.close(io);
        // Unlike migrate.zig's `copyAssetRoot` walk, `Io.Dir.walk` here is
        // typed `Allocator.Error!Walker` (0.16.0) -- OutOfMemory is the only
        // possible failure, so it propagates directly rather than being
        // switched on.
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (true) {
            const maybe_entry = walker.next(io) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                // A mid-walk error ends this root's iteration; whatever was
                // collected is kept ("partial discovery is still useful"),
                // but the blocker says so explicitly rather than leaving an
                // undercounted report with no indication anything was
                // skipped.
                try blockers.append(gpa, &blocker_list, "RAILS_INVENTORY_TRUNCATED", top, @errorName(err), true);
                break;
            };
            const entry = maybe_entry orelse break;
            if (entry.kind != .file) continue;
            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ top, entry.path });
            errdefer gpa.free(rel);
            // Normalize Windows separators so classification and output are
            // platform-independent.
            for (rel) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            try list.append(gpa, .{
                .path = rel,
                .kind = classify(rel),
                .engine = engineFor(rel),
            });
        }
    }

    const out = try list.toOwnedSlice(gpa);
    std.mem.sort(Entry, out, {}, lessThan);
    errdefer freeEntries(gpa, out);
    const out_blockers = try blocker_list.toOwnedSlice(gpa);
    return .{ .entries = out, .blockers = out_blockers };
}

/// Contract 2 counterpart: releases the slice and every `path` returned by
/// `walk`.
pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.path);
    gpa.free(entries);
}

/// Contract 2 counterpart for `walk`'s full result: releases `entries` (via
/// `freeEntries`) and `blockers` (via `blockers.free`).
pub fn freeWalkResult(gpa: Allocator, result: WalkResult) void {
    freeEntries(gpa, result.entries);
    blockers.free(gpa, result.blockers);
}

/// Contract 2 (owned-result), inherited from `blockers.append`: everything it
/// allocates escapes into `blocker_list` and is released by `blockers.free`.
///
/// Appends a `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` blocker for every *template*
/// entry whose engine has no converter yet (Haml, Slim). Not an integrity
/// blocker: this is an expected, correctly-detected finding, not evidence the
/// inventory itself is untrustworthy.
///
/// This is the one place template-engine blockers are constructed --
/// `report.build` only renders whatever blocker list it is given, so there is
/// a single blocker path rather than the report special-casing engines at
/// render time on top of a separately-populated blocker list.
///
/// Gated on `Kind`, not just `Engine`: `engineFor` reads the engine off the
/// compound extension alone, so a non-template file that merely happens to
/// end in `.haml`/`.slim` (e.g. `public/download.slim`, classified `.asset`)
/// used to be misreported as an unsupported template even though nothing in
/// this codebase ever renders it as one (P2 in the PR review that added this
/// gate). The switch below is explicit and exhaustive over `Kind` rather than
/// a negative "skip .asset/.controller/..." list, so a future `Kind` variant
/// has to be classified as template-or-not deliberately instead of silently
/// falling into whichever bucket the list-writer forgot.
pub fn appendUnsupportedEngineBlockers(
    gpa: Allocator,
    entries: []const Entry,
    blocker_list: *std.ArrayListUnmanaged(Blocker),
) Allocator.Error!void {
    for (entries) |e| {
        const is_template = switch (e.kind) {
            .view, .layout, .partial, .mailer_view => true,
            .controller, .helper, .stimulus_controller, .js_entry, .js_module, .asset, .other => false,
        };
        if (!is_template) continue;
        const label = switch (e.engine) {
            .haml => "Haml",
            .slim => "Slim",
            else => continue,
        };
        var buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s} template is not converted", .{label}) catch unreachable;
        try blockers.append(gpa, blocker_list, "RAILS_TEMPLATE_ENGINE_UNSUPPORTED", e.path, detail, false);
    }
}

test "walk collects app/ and public/, classifies each entry, skips everything else, and sorts by path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var views_dir = try tmp.dir.createDirPathOpen(io, "app/views/posts", .{});
    views_dir.close(io);
    var layouts_dir = try tmp.dir.createDirPathOpen(io, "app/views/layouts", .{});
    layouts_dir.close(io);
    var controllers_dir = try tmp.dir.createDirPathOpen(io, "app/controllers", .{});
    controllers_dir.close(io);
    var config_dir = try tmp.dir.createDirPathOpen(io, "config", .{});
    config_dir.close(io);
    var public_dir = try tmp.dir.createDirPathOpen(io, "public", .{});
    public_dir.close(io);

    try tmp.dir.writeFile(io, .{ .sub_path = "app/views/posts/show.html.erb", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/views/layouts/_nav.html.erb", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/controllers/posts_controller.rb", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "public/favicon.ico", .data = "" });
    // Deliberately outside app/ and public/: proves only the two declared
    // roots are walked, matching the "Gemfile/config/** not inventoried" rule.
    try tmp.dir.writeFile(io, .{ .sub_path = "config/database.yml", .data = "" });

    const wr = try walk(io, gpa, tmp.dir);
    defer freeWalkResult(gpa, wr);
    const entries = wr.entries;

    try std.testing.expectEqual(@as(usize, 4), entries.len);
    // Sorted by path: app/... entries (alphabetical) before public/favicon.ico.
    try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", entries[0].path);
    try std.testing.expectEqual(Kind.controller, entries[0].kind);
    try std.testing.expectEqual(Engine.none, entries[0].engine);

    try std.testing.expectEqualStrings("app/views/layouts/_nav.html.erb", entries[1].path);
    try std.testing.expectEqual(Kind.partial, entries[1].kind);
    try std.testing.expectEqual(Engine.erb, entries[1].engine);

    try std.testing.expectEqualStrings("app/views/posts/show.html.erb", entries[2].path);
    try std.testing.expectEqual(Kind.view, entries[2].kind);
    try std.testing.expectEqual(Engine.erb, entries[2].engine);

    try std.testing.expectEqualStrings("public/favicon.ico", entries[3].path);
    try std.testing.expectEqual(Kind.asset, entries[3].kind);

    // Both roots existed and were fully readable: no blockers at all.
    try std.testing.expectEqual(@as(usize, 0), wr.blockers.len);
}

test "walk is silent when public/ is simply absent" {
    // error.FileNotFound opening a root is the expected, common case (a
    // Rails app with no public/ asset tree) and must never produce a
    // blocker -- only a genuinely unreadable root should (see the test
    // below).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app_dir = try tmp.dir.createDirPathOpen(io, "app/controllers", .{});
    app_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/controllers/posts_controller.rb", .data = "" });

    const wr = try walk(io, gpa, tmp.dir);
    defer freeWalkResult(gpa, wr);

    try std.testing.expectEqual(@as(usize, 1), wr.entries.len);
    try std.testing.expectEqual(@as(usize, 0), wr.blockers.len);
}

test "an unreadable app/ root produces an integrity blocker, not a silent empty inventory" {
    // Regression for P1 (PR review): a permission error opening a root used
    // to be swallowed by `catch continue`, producing a confident-looking
    // empty inventory ("Blockers: None.") instead of flagging that the walk
    // couldn't be trusted.
    //
    // This needs a real permission-denied directory. Skipped at comptime on
    // platforms where `Permissions` isn't POSIX mode bits (Windows/WASI --
    // stripping permissions there wouldn't block the open the way this test
    // needs), and skipped at runtime if stripping permissions doesn't
    // actually prevent the open (e.g. running as root, or a sandbox/CI
    // filesystem that ignores mode bits) -- this is the "platform makes it
    // unreliable" case the PR review calls out; everything else in this file
    // runs unconditionally.
    if (!Io.Dir.Permissions.has_executable_bit) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var app_dir = try tmp.dir.createDirPathOpen(io, "app", .{ .open_options = .{ .iterate = true } });
    try app_dir.setPermissions(io, .fromMode(0));
    defer {
        // Restore write+execute before cleanup tries to remove it; some
        // platforms need parent-dir permissions rather than the child's own
        // to unlink it, but this is cheap insurance either way.
        app_dir.setPermissions(io, .fromMode(0o755)) catch {};
        app_dir.close(io);
    }

    const wr = try walk(io, gpa, tmp.dir);
    defer freeWalkResult(gpa, wr);

    if (wr.blockers.len == 0) {
        // Permission enforcement didn't actually block the open in this
        // environment -- nothing to assert.
        return error.SkipZigTest;
    }

    try std.testing.expectEqual(@as(usize, 0), wr.entries.len);
    try std.testing.expectEqual(@as(usize, 1), wr.blockers.len);
    try std.testing.expectEqualStrings("RAILS_INVENTORY_UNREADABLE", wr.blockers[0].code);
    try std.testing.expectEqualStrings("app", wr.blockers[0].path);
    try std.testing.expect(wr.blockers[0].integrity);
}

test "an unreadable nested directory truncates that root's walk but keeps what was already found" {
    // Same reliability caveat as the previous test; see its comment.
    if (!Io.Dir.Permissions.has_executable_bit) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var controllers_dir = try tmp.dir.createDirPathOpen(io, "app/controllers", .{});
    controllers_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "app/controllers/posts_controller.rb", .data = "" });

    var blocked_dir = try tmp.dir.createDirPathOpen(io, "app/views", .{ .open_options = .{ .iterate = true } });
    try blocked_dir.setPermissions(io, .fromMode(0));
    defer {
        blocked_dir.setPermissions(io, .fromMode(0o755)) catch {};
        blocked_dir.close(io);
    }

    const wr = try walk(io, gpa, tmp.dir);
    defer freeWalkResult(gpa, wr);

    if (wr.blockers.len == 0) {
        return error.SkipZigTest;
    }

    // Directory-entry enumeration order for two siblings ("controllers" and
    // "views") is not something this code controls or should need to --
    // POSIX readdir() makes no ordering guarantee. So either the controller
    // was enumerated before the unreadable views/ and survives ("partial
    // discovery is still useful"), or views/ was enumerated first and the
    // walk of this root ends with nothing collected yet. Both are correct;
    // what must hold regardless of order is that nothing is ever silently
    // lost or duplicated, and the blocker still fires either way.
    try std.testing.expect(wr.entries.len <= 1);
    if (wr.entries.len == 1) {
        try std.testing.expectEqualStrings("app/controllers/posts_controller.rb", wr.entries[0].path);
    }

    try std.testing.expectEqual(@as(usize, 1), wr.blockers.len);
    try std.testing.expectEqualStrings("RAILS_INVENTORY_TRUNCATED", wr.blockers[0].code);
    try std.testing.expectEqualStrings("app", wr.blockers[0].path);
    try std.testing.expect(wr.blockers[0].integrity);
}

test "appendUnsupportedEngineBlockers flags Haml and Slim template kinds but not erb, non-template kinds, or other kinds" {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
        .{ .path = "app/views/posts/index.html.haml", .kind = .view, .engine = .haml },
        .{ .path = "app/views/posts/_post.html.slim", .kind = .partial, .engine = .slim },
        .{ .path = "app/views/layouts/legacy.html.slim", .kind = .layout, .engine = .slim },
        .{ .path = "app/views/user_mailer/welcome.html.haml", .kind = .mailer_view, .engine = .haml },
        // P2 in the PR review: `engineFor` reads the engine off the compound
        // extension alone, with no regard for `kind`. A `.haml`/`.slim` file
        // that classify() puts in a NON-template bucket (public/download.slim
        // is a real repro: it's under public/, so it's classified `.asset`,
        // but its extension still reads as the Slim engine) must not be
        // reported as an unsupported template -- nothing in this codebase
        // ever renders it as one.
        .{ .path = "public/download.slim", .kind = .asset, .engine = .slim },
        .{ .path = "app/helpers/legacy_helper.slim", .kind = .helper, .engine = .slim },
    };
    var list: std.ArrayListUnmanaged(Blocker) = .empty;
    defer blockers.free(gpa, list.toOwnedSlice(gpa) catch unreachable);

    try appendUnsupportedEngineBlockers(gpa, &entries, &list);

    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("RAILS_TEMPLATE_ENGINE_UNSUPPORTED", list.items[0].code);
    try std.testing.expectEqualStrings("app/views/posts/index.html.haml", list.items[0].path);
    try std.testing.expectEqualStrings("Haml template is not converted", list.items[0].detail);
    try std.testing.expect(!list.items[0].integrity);

    try std.testing.expectEqualStrings("app/views/posts/_post.html.slim", list.items[1].path);
    try std.testing.expectEqualStrings("Slim template is not converted", list.items[1].detail);
    try std.testing.expect(!list.items[1].integrity);

    try std.testing.expectEqualStrings("app/views/layouts/legacy.html.slim", list.items[2].path);
    try std.testing.expectEqualStrings("Slim template is not converted", list.items[2].detail);

    try std.testing.expectEqualStrings("app/views/user_mailer/welcome.html.haml", list.items[3].path);
    try std.testing.expectEqualStrings("Haml template is not converted", list.items[3].detail);

    // Neither the .asset nor the .helper entry above -- both carrying a
    // .haml/.slim EXTENSION but a non-template KIND -- produced a blocker.
    for (list.items) |b| {
        try std.testing.expect(!std.mem.eql(u8, b.path, "public/download.slim"));
        try std.testing.expect(!std.mem.eql(u8, b.path, "app/helpers/legacy_helper.slim"));
    }
}
