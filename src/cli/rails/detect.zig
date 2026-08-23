//! Rails detection: evidence collection (I/O) and the pure decision over it.
//!
//! Deliberately std-only so this file can back a `standalone` test suite; all
//! `fatal.*` handling stays in `src/cli/migrate.zig`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blockers = @import("blockers.zig");

/// Tri-state result of probing a path: `.absent` is the confident,
/// silent case (`error.FileNotFound`/`error.NotDir`); anything else the
/// filesystem hands back (permission denied, a transient I/O error, ...)
/// is `.unreadable` -- evidence we couldn't collect, not evidence of
/// absence. Collapsing those two into one `bool` is what let `--from rails`
/// reject a real Rails tree whose Gemfile merely couldn't be opened (P2 in
/// the PR review that added this type).
pub const Probe = enum { present, absent, unreadable };

/// Durable, filesystem-observable facts about a candidate project root.
///
/// Each `*_unreadable` companion is true only when the corresponding probe
/// came back `.unreadable` -- never when it came back `.absent`. A probe
/// that is neither present nor unreadable leaves both fields false, i.e.
/// genuinely absent.
pub const Evidence = struct {
    has_application_rb: bool = false,
    application_rb_unreadable: bool = false,
    has_routes_rb: bool = false,
    routes_rb_unreadable: bool = false,
    has_app_views: bool = false,
    app_views_unreadable: bool = false,
    gemfile_declares_rails: bool = false,
    gemfile_unreadable: bool = false,
    /// Jekyll ships a Gemfile too. Its config is a hard veto.
    has_jekyll_config: bool = false,
};

/// Three-valued outcome of `verdict`. A plain `bool` can't say "the
/// structural evidence is Rails-shaped but a piece needed to confirm it was
/// unreadable" -- it has to collapse that into either a false positive
/// (claiming Rails when we don't actually know) or a false negative
/// (rejecting a real Rails tree because of a permission error). See
/// `verdict`'s doc comment for how each consumer must react.
pub const Verdict = enum { rails, not_rails, indeterminate };

test "a Gemfile alone is never enough to mean Rails" {
    try std.testing.expectEqual(Verdict.not_rails, verdict(.{ .gemfile_declares_rails = true }));
}

test "Jekyll config vetoes Rails even with Rails-looking evidence" {
    try std.testing.expectEqual(Verdict.not_rails, verdict(.{
        .has_application_rb = true,
        .has_app_views = true,
        .has_jekyll_config = true,
    }));
}

test "Jekyll config vetoes Rails even when the Gemfile is merely unreadable" {
    // The veto must run before the indeterminate logic below gets a chance
    // to treat the unreadable Gemfile as ambiguous, Rails-shaped evidence.
    try std.testing.expectEqual(Verdict.not_rails, verdict(.{
        .has_routes_rb = true,
        .has_app_views = true,
        .gemfile_unreadable = true,
        .has_jekyll_config = true,
    }));
}

test "config/application.rb plus app/views is conclusive" {
    try std.testing.expectEqual(Verdict.rails, verdict(.{ .has_application_rb = true, .has_app_views = true }));
}

test "routes.rb plus app/views plus a rails gem is conclusive" {
    try std.testing.expectEqual(Verdict.rails, verdict(.{
        .has_routes_rb = true,
        .has_app_views = true,
        .gemfile_declares_rails = true,
    }));
}

test "a plain Ruby gem with no app tree is not Rails" {
    try std.testing.expectEqual(Verdict.not_rails, verdict(.{ .gemfile_declares_rails = true, .has_routes_rb = true }));
}

test "routes.rb plus app/views plus an unreadable Gemfile is indeterminate, not absent" {
    // The motivating case: branch B's structural half (routes.rb + app/views)
    // is confirmed present, but the piece that would confirm the gem
    // dependency couldn't be read. That is not the same as a Gemfile that
    // simply doesn't declare rails.
    try std.testing.expectEqual(Verdict.indeterminate, verdict(.{
        .has_routes_rb = true,
        .has_app_views = true,
        .gemfile_unreadable = true,
    }));
}

test "app/views present plus an unreadable application.rb is indeterminate (branch A blocked)" {
    try std.testing.expectEqual(Verdict.indeterminate, verdict(.{
        .has_app_views = true,
        .application_rb_unreadable = true,
    }));
}

test "unreadable evidence alone is not Rails: something must be confirmed present" {
    // An entirely inaccessible directory makes every probe `.unreadable`.
    // That is not weak evidence of Rails, it is no evidence at all -- the
    // honest answer is "could not read this directory", so the verdict must
    // stay `.not_rails` rather than drifting into `.indeterminate` and being
    // reported as a Rails app.
    try std.testing.expectEqual(Verdict.not_rails, verdict(.{
        .application_rb_unreadable = true,
        .app_views_unreadable = true,
    }));
    try std.testing.expectEqual(Verdict.not_rails, verdict(.{
        .application_rb_unreadable = true,
        .routes_rb_unreadable = true,
        .app_views_unreadable = true,
        .gemfile_unreadable = true,
    }));
}

test "an unreadable app/views alongside a confirmed routes.rb and rails gem is indeterminate (branch B blocked)" {
    try std.testing.expectEqual(Verdict.indeterminate, verdict(.{
        .has_routes_rb = true,
        .app_views_unreadable = true,
        .gemfile_declares_rails = true,
    }));
}

/// Pure decision over collected evidence. Contract 3 (caller-buffer):
/// allocates nothing.
///
/// The veto comes first on purpose: `configMarker` already treats a Gemfile as
/// Jekyll evidence, so without it a Jekyll site with an `app/` directory could
/// match both sources and trip `detectSource`'s ambiguity fatal.
///
/// After the veto, each conclusive branch is checked exactly as before this
/// type existed (`.rails`). What's new is the fallback: rather than treating
/// any non-conclusive evidence as `.not_rails`, an "optimistic" reading of
/// each branch treats `.unreadable` as "maybe present" -- if a branch would
/// have been conclusive had its unreadable piece(s) turned out to be
/// present, the verdict is `.indeterminate` rather than a confident
/// `.not_rails`. Consumers (`migrate.zig`) must NOT treat `.indeterminate`
/// as `.not_rails`: explicit `--from rails` proceeds and lets discovery
/// report the unreadable evidence as a blocker; auto-detection treats it as
/// Rails too, for the same reason.
pub fn verdict(e: Evidence) Verdict {
    if (e.has_jekyll_config) return .not_rails;
    if (e.has_application_rb and e.has_app_views) return .rails;
    if (e.has_routes_rb and e.has_app_views and e.gemfile_declares_rails) return .rails;

    const app_maybe = e.has_application_rb or e.application_rb_unreadable;
    const routes_maybe = e.has_routes_rb or e.routes_rb_unreadable;
    const views_maybe = e.has_app_views or e.app_views_unreadable;
    const gem_maybe = e.gemfile_declares_rails or e.gemfile_unreadable;

    // "Maybe" evidence alone is not enough: at least one piece of the branch
    // must be CONFIRMED present. Without this an entirely inaccessible
    // directory -- every probe `.unreadable`, nothing structurally confirmed
    // -- would read as `.indeterminate` and be reported as Rails, when the
    // honest answer is "this directory could not be read". Unreadability
    // must not manufacture evidence, only refuse to rule it out.
    const branch_a_blocked = app_maybe and views_maybe and
        (e.application_rb_unreadable or e.app_views_unreadable) and
        (e.has_application_rb or e.has_app_views);
    const branch_b_blocked = routes_maybe and views_maybe and gem_maybe and
        (e.routes_rb_unreadable or e.app_views_unreadable or e.gemfile_unreadable) and
        (e.has_routes_rb or e.has_app_views or e.gemfile_declares_rails);

    if (branch_a_blocked or branch_b_blocked) return .indeterminate;
    return .not_rails;
}

/// Probes for a file's presence without reading its contents. `.absent` only
/// for `error.FileNotFound`/`error.NotDir`; any other open failure (most
/// notably permission denied) is `.unreadable` -- a probe, not a content
/// read, so "unreadable" here means "couldn't even confirm existence", not
/// "exists but its bytes couldn't be read".
fn probeFile(io: Io, base: Io.Dir, path: []const u8) Probe {
    const f = base.openFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .absent,
        else => .unreadable,
    };
    f.close(io);
    return .present;
}

/// Directory counterpart to `probeFile`; same absent/unreadable split.
fn probeDir(io: Io, base: Io.Dir, path: []const u8) Probe {
    const dir = base.openDir(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .absent,
        else => .unreadable,
    };
    dir.close(io);
    return .present;
}

/// Contract 1 (self-freeing): the Gemfile read is freed before returning; the
/// result is a plain struct of bools that owns nothing.
///
/// This is the detection-path entry point (`configMarker`'s auto-detection
/// and `--from rails`'s explicit-request check, both in `migrate.zig`), which
/// has no blocker channel to attach a read failure to -- see `readCapped` for
/// the discovery-path variant (`rails.discover`) that does. `error.
/// OutOfMemory` still propagates. Every other Gemfile-read failure other than
/// "genuinely absent" (`FileNotFound`/`NotDir`) sets `gemfile_unreadable`
/// rather than being swallowed -- collapsing "unreadable" into "absent" here
/// used to be what let a real branch-B Rails tree with an unreadable Gemfile
/// read as confidently not-Rails (P2 in the PR review that added this fix).
/// `verdict` is what turns that flag into `.indeterminate` instead of a false
/// negative.
pub fn collect(io: Io, gpa: Allocator, root: Io.Dir) Allocator.Error!Evidence {
    const app_rb = probeFile(io, root, "config/application.rb");
    const routes_rb = probeFile(io, root, "config/routes.rb");
    const app_views = probeDir(io, root, "app/views");
    var e: Evidence = .{
        .has_application_rb = app_rb == .present,
        .application_rb_unreadable = app_rb == .unreadable,
        .has_routes_rb = routes_rb == .present,
        .routes_rb_unreadable = routes_rb == .unreadable,
        .has_app_views = app_views == .present,
        .app_views_unreadable = app_views == .unreadable,
        // `!= .absent`, not `== .present`: the veto keys on the config file
        // EXISTING, and its contents are never read. An unreadable
        // `_config.yml` is a file that exists, so it must still veto --
        // collapsing it into "absent" would let a Jekyll site with a
        // locked-down config be claimed as Rails, which is the same
        // access-failure-reads-as-absence defect this file just fixed for the
        // Rails evidence.
        .has_jekyll_config = probeFile(io, root, "_config.yml") != .absent or
            probeFile(io, root, "_config.yaml") != .absent,
    };
    if (root.readFileAlloc(io, "Gemfile", gpa, .limited(1024 * 1024))) |src| {
        defer gpa.free(src);
        e.gemfile_declares_rails = gemfileDeclares(src, "rails");
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => {},
        else => e.gemfile_unreadable = true,
    }
    return e;
}

test "collect + verdict: an unreadable Gemfile on a branch-B tree is indeterminate, not not_rails" {
    // Reproduces the PR reviewer's repro: config/application.rb absent,
    // routes.rb + app/views present, and a Gemfile that declares rails but
    // cannot be read. Needs real permission-denied semantics -- same
    // platform caveat as the permission tests in inventory.zig: skipped at
    // comptime where `Permissions` isn't POSIX mode bits (Windows/WASI), and
    // skipped at runtime if stripping permissions doesn't actually block the
    // read here (running as root, or a sandbox/CI filesystem that ignores
    // mode bits).
    if (!Io.Dir.Permissions.has_executable_bit) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var config_dir = try tmp.dir.createDirPathOpen(io, "config", .{});
    config_dir.close(io);
    const routes_rb = try tmp.dir.createFile(io, "config/routes.rb", .{});
    routes_rb.close(io);
    var views = try tmp.dir.createDirPathOpen(io, "app/views", .{});
    views.close(io);

    var gemfile = try tmp.dir.createFile(io, "Gemfile", .{});
    try gemfile.writeStreamingAll(io, "gem \"rails\", \"~> 7.1\"\n");
    try gemfile.setPermissions(io, .fromMode(0));
    defer {
        // Restore before cleanup tries to remove it.
        gemfile.setPermissions(io, .fromMode(0o644)) catch {};
        gemfile.close(io);
    }

    const e = try collect(io, gpa, tmp.dir);
    if (!e.gemfile_unreadable) {
        // Permission enforcement didn't actually block the read in this
        // environment -- nothing to assert.
        return error.SkipZigTest;
    }

    try std.testing.expect(e.has_routes_rb);
    try std.testing.expect(e.has_app_views);
    try std.testing.expect(!e.has_application_rb);
    try std.testing.expect(!e.gemfile_declares_rails);
    try std.testing.expectEqual(Verdict.indeterminate, verdict(e));
}

/// Contract 1 (self-freeing): the single capped read either escapes as the
/// return or (on any failure) is never allocated; a blocker string escapes
/// via `blocker_list`, which the caller owns separately.
///
/// Returns `null` when `path` is genuinely absent (`FileNotFound`/`NotDir`,
/// the common, silent case -- e.g. no package.json in a non-JS Rails app).
/// Any other read failure (permission denied, the 1 MiB cap, ...) means the
/// file's contents are unknown, not that it doesn't exist: rather than
/// collapsing that into "absent" the way the pre-fix code did (P5 in the PR
/// review -- a real Rails app with an unreadable Gemfile silently read as
/// "no integrations detected"), it appends `code` to `blocker_list` with
/// `integrity = true` and still treats the file as absent for the rest of
/// this run, since there is nothing else the caller can safely do with
/// unreadable content. `error.OutOfMemory` always propagates.
///
/// Both of this function's current callers (`rails.zig`'s `discover`, for
/// `Gemfile` and `package.json`) feed a code whose severity is
/// `.@"error"`: an unreadable Gemfile means the Rails-app `verdict()` itself
/// ran on incomplete evidence, and an unreadable package.json means the
/// integration scan (`integrations.scan`) never got to look at it at all --
/// both are foundational inputs, not one file among many, so this is not the
/// "an expected, correctly-detected finding" story `Blocker.severity`'s doc
/// reserves for `.warn` (contrast `RAILS_PACKAGE_JSON_MALFORMED`, a
/// *readable* package.json this same integration scan rejects, which IS a
/// `.warn` -- see `integrations.zig`). Hardcoded here rather than threaded
/// as a parameter because every caller wants the same answer for the same
/// reason; a future caller with a different reason gets its own parameter
/// then, not a silently-reused default.
pub fn readCapped(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    path: []const u8,
    code: []const u8,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!?[]u8 {
    const src = root.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => return null,
        else => {
            try blockers.append(gpa, blocker_list, code, path, @errorName(err), true, .@"error", null);
            return null;
        },
    };
    return src;
}

// Stage 4 Task 5's other discriminating direction (the route-scoped side is
// pinned in rails.zig, e.g. "classifyRoutes: an unreadable template becomes
// a non-integrity blocker"): a `RAILS_GEMFILE_UNREADABLE`/
// `RAILS_PACKAGE_JSON_UNREADABLE` blocker describes the APP, not a route --
// `readCapped` is called by `rails.zig`'s `discover` before any route is
// even recovered, so there is no route for it to name. A test asserting
// only "route_id is null here" would pass against an implementation that
// never populated route_id ANYWHERE, which is exactly the pre-Task-5 bug;
// this is only meaningful paired with the route-scoped tests that pin a
// real, non-null, per-route id elsewhere.
test "readCapped: an unreadable file's blocker has no route_id -- it describes the app, not a route" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A directory named "Gemfile" forces `error.IsDir` -- deterministic,
    // and distinct from `FileNotFound`/`NotDir`, so this reaches the `else`
    // branch (the blocker-appending one) regardless of platform permission
    // enforcement, unlike the permission-bit tricks `inventory.zig`'s own
    // unreadable-directory tests must SkipZigTest under.
    var gemfile_dir = try tmp.dir.createDirPathOpen(io, "Gemfile", .{});
    gemfile_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const result = try readCapped(io, gpa, tmp.dir, "Gemfile", "RAILS_GEMFILE_UNREADABLE", &blocker_list);
    try std.testing.expectEqual(@as(?[]u8, null), result);

    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_GEMFILE_UNREADABLE", blocker_list.items[0].code);
    try std.testing.expectEqual(@as(?[]const u8, null), blocker_list.items[0].route_id);
}

/// True when `src` has an uncommented `gem "<name>"` (or `gem("<name>")`)
/// line. Contract 3.
///
/// Accepts `gem "x"`, `gem 'x'`, `gem("x")`, `gem( "x" )`, and a tab in place
/// of the space -- `gem\t"x"`. Requires a separator (space, tab, or `(`)
/// directly after the `gem` token so a longer identifier like `gemspec` or
/// `gem_group` is never mistaken for a call to `gem`.
pub fn gemfileDeclares(src: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "gem")) continue;
        var rest = line["gem".len..];
        if (rest.len == 0) continue;
        if (rest[0] != ' ' and rest[0] != '\t' and rest[0] != '(') continue;
        rest = std.mem.trimStart(u8, rest, " \t");
        if (std.mem.startsWith(u8, rest, "(")) {
            rest = std.mem.trimStart(u8, rest[1..], " \t");
        }
        if (rest.len < 2) continue;
        const quote = rest[0];
        if (quote != '"' and quote != '\'') continue;
        const end = std.mem.indexOfScalar(u8, rest[1..], quote) orelse continue;
        if (std.mem.eql(u8, rest[1 .. 1 + end], name)) return true;
    }
    return false;
}

test "gemfileDeclares ignores comments and substring collisions" {
    try std.testing.expect(gemfileDeclares("gem \"rails\", \"~> 7.1\"\n", "rails"));
    try std.testing.expect(!gemfileDeclares("# gem \"rails\"\n", "rails"));
    try std.testing.expect(!gemfileDeclares("gem \"rails-html-sanitizer\"\n", "rails"));
    try std.testing.expect(gemfileDeclares("gem 'propshaft'\n", "propshaft"));
}

test "gemfileDeclares accepts parenthesized and tab-separated calls" {
    // P3 in the PR review: `gem("rails")` and tab-separated calls were
    // rejected outright by the old literal `"gem "` prefix check.
    try std.testing.expect(gemfileDeclares("gem(\"rails\")\n", "rails"));
    try std.testing.expect(gemfileDeclares("gem( \"rails\" )\n", "rails"));
    try std.testing.expect(gemfileDeclares("gem('rails')\n", "rails"));
    try std.testing.expect(gemfileDeclares("gem\t\"rails\"\n", "rails"));
}

test "gemfileDeclares still rejects a longer identifier that merely starts with gem" {
    try std.testing.expect(!gemfileDeclares("gemspec\n", "rails"));
    try std.testing.expect(!gemfileDeclares("gem_group :test do\n", "rails"));
}

test "gemfileDeclares(\"rails\") still requires the whole quoted token to match" {
    // Regression companion to the collision test above, phrased against the
    // parenthesized form specifically (P3's reported repro used gem(\"rails\")).
    try std.testing.expect(!gemfileDeclares("gem(\"rails-html-sanitizer\")\n", "rails"));
}

/// `source.version` (spec, "The manifest"): the resolved Rails version read
/// from `Gemfile.lock`, plus the exact evidence string a human can verify by
/// grepping the lock file (e.g. `"Gemfile.lock:rails (7.1.3)"`). Contract 2
/// (owned-result): `value`/`evidence` are `gpa`-owned when non-null and must
/// be released via `freeVersion`; the zero value owns nothing.
pub const Version = struct {
    value: ?[]u8 = null,
    evidence: ?[]u8 = null,
};

/// Contract 2 counterpart to `Version`. Freeing a zero-value `Version` (both
/// fields `null`, the degraded-path return of `detectVersion`) is a no-op,
/// so callers don't need to special-case it.
pub fn freeVersion(gpa: Allocator, v: Version) void {
    if (v.value) |val| gpa.free(val);
    if (v.evidence) |ev| gpa.free(ev);
}

/// Resolves the `rails` gem's LOCKED version from `Gemfile.lock` -- never
/// the Gemfile's own constraint (`gem "rails", "~> 7.1"` names a range, not
/// an answer; `Gemfile.lock` is where Bundler recorded which version it
/// actually resolved to). Contract 2 (owned-result): on success both
/// `Version` fields escape as fresh `gpa` allocations, released via
/// `freeVersion`; every degradation path below returns the zero-value
/// `Version{}` instead, which owns nothing.
///
/// A missing, unreadable, or over-cap lock file and a lock file that is
/// readable but simply never locks `rails` in its `specs:` block are ALL the
/// same story to this function's caller: the version is not available this
/// run. Unlike `readCapped`'s `Gemfile`/`package.json` callers, an
/// unresolved Rails version does not make the REST of discovery
/// untrustworthy -- `Gemfile.lock` is committed by convention, not a
/// dependency the rest of this scan reads, so a project that doesn't commit
/// one (or ships one this parser can't make sense of) is still a fully
/// analyzable Rails app. That is why this appends
/// `RAILS_GEMFILE_LOCK_UNAVAILABLE` at `.warn`, `integrity = false`, rather
/// than the `.@"error"`/`integrity = true` `readCapped` uses for the
/// Gemfile/package.json reads discovery actually depends on -- every path
/// here still returns exit 0. `error.OutOfMemory` always propagates.
pub fn detectVersion(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    blocker_list: *std.ArrayListUnmanaged(blockers.Blocker),
) Allocator.Error!Version {
    const src = root.readFileAlloc(io, "Gemfile.lock", gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => {
            try blockers.append(gpa, blocker_list, "RAILS_GEMFILE_LOCK_UNAVAILABLE", "Gemfile.lock", "Gemfile.lock not found", false, .warn, null);
            return .{};
        },
        else => {
            try blockers.append(gpa, blocker_list, "RAILS_GEMFILE_LOCK_UNAVAILABLE", "Gemfile.lock", @errorName(err), false, .warn, null);
            return .{};
        },
    };
    defer gpa.free(src);

    const found = lockedVersion(src, "rails") orelse {
        try blockers.append(gpa, blocker_list, "RAILS_GEMFILE_LOCK_UNAVAILABLE", "Gemfile.lock", "no locked \"rails\" entry found in Gemfile.lock", false, .warn, null);
        return .{};
    };

    const value = try gpa.dupe(u8, found);
    errdefer gpa.free(value);
    const evidence = try std.fmt.allocPrint(gpa, "Gemfile.lock:rails ({s})", .{found});
    return .{ .value = value, .evidence = evidence };
}

/// Locates `name`'s LOCKED version inside a `Gemfile.lock`'s `specs:`
/// block(s) (`GEM`/`GIT`/`PATH` remotes all use the same layout). Contract 3
/// (caller-buffer): allocates nothing; the returned slice borrows `src`.
///
/// Bundler's lockfile format indents a spec's own gem line by exactly 4
/// spaces (`    rails (7.1.3)`), and each of THAT gem's dependencies one
/// level deeper, by 6 (`      railties (= 7.1.3)`). Matching on that exact
/// 4-space indentation, and requiring the token before the version parens to
/// equal `name` in full (not merely start with it), is what keeps this from
/// matching:
///   - a dependency line that happens to name `name` (6+ spaces -- always
///     someone else's locked entry, never this gem's own),
///   - the `DEPENDENCIES` section's 2-space `rails (~> 7.1.3)` line, which
///     is the Gemfile's CONSTRAINT surfacing again inside the lock file, not
///     the resolved version Bundler actually picked,
///   - a substring/prefix collision like `rails-html-sanitizer`,
///     `sprockets-rails`, `jsbundling-rails`, or `rails-dom-testing` --
///     ordinary companions to a real Rails app's `rails` entry, one of which
///     (`jsbundling-rails`) sorts BEFORE `rails` itself. A parser that
///     merely substring-matches `"rails"`, or returns the first
///     version-shaped token in the file, returns a confidently wrong answer
///     on a perfectly ordinary lock file -- see this file's tests for a
///     fixture built to make that wrong answer visibly different from the
///     right one, not coincidentally identical to it.
fn lockedVersion(src: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
        if (indent != 4) continue;
        const rest = line[indent..];

        var name_end: usize = 0;
        while (name_end < rest.len and rest[name_end] != ' ' and rest[name_end] != '(') : (name_end += 1) {}
        if (!std.mem.eql(u8, rest[0..name_end], name)) continue;

        var i = name_end;
        while (i < rest.len and rest[i] == ' ') : (i += 1) {}
        if (i >= rest.len or rest[i] != '(') continue;
        i += 1;
        const close = std.mem.indexOfScalarPos(u8, rest, i, ')') orelse continue;
        return rest[i..close];
    }
    return null;
}

// A realistic slice of a Rails app's Gemfile.lock, deliberately shaped so a
// wrong implementation fails LOUDLY rather than by coincidence:
//   - `concurrent-ruby` sits alphabetically first with a version that
//     matches NEITHER gem near it -- "return the first version-shaped
//     string in the file" lands on "1.2.2", visibly wrong.
//   - `actioncable`/`actionpack` are pinned to "7.0.0", one minor behind
//     `rails`'s own "7.1.3" -- so "the first CONFIRMED gem spec" still
//     lands on a wrong-but-plausible version instead of accidentally
//     matching rails' own by coincidence (the real-world trap the brief
//     warns about: same-version neighbors make a naive parser LOOK
//     correct).
//   - `jsbundling-rails` sorts before `rails` alphabetically and contains
//     "rails" as a substring -- a substring-matching parser returns "1.3.0"
//     before it ever reaches the real entry.
//   - `rails-dom-testing`/`rails-html-sanitizer`/`sprockets-rails` are
//     ordinary companions with their own versions, none of which equal
//     rails' own.
//   - `DEPENDENCIES` echoes the Gemfile's constraint, `rails (~> 7.1.3)`,
//     at 2-space indent -- reading THAT as the answer would report a
//     constraint, not a resolved version, and happens to differ from the
//     locked "7.1.3" only in spelling, not value, so a test must check the
//     exact bytes returned, not just "contains 7.1.3".
const sample_lock =
    \\GEM
    \\  remote: https://rubygems.org/
    \\  specs:
    \\    concurrent-ruby (1.2.2)
    \\    actioncable (7.0.0)
    \\      actionpack (= 7.0.0)
    \\      activesupport (= 7.0.0)
    \\    actionpack (7.0.0)
    \\      actionview (= 7.0.0)
    \\      activesupport (= 7.0.0)
    \\    jsbundling-rails (1.3.0)
    \\      railties (>= 6.0.0)
    \\    rails (7.1.3)
    \\      actioncable (= 7.1.3)
    \\      actionpack (= 7.1.3)
    \\      railties (= 7.1.3)
    \\    rails-dom-testing (2.2.0)
    \\      activesupport (>= 5.0.0)
    \\    rails-html-sanitizer (1.4.4)
    \\      loofah (~> 2.21)
    \\    sprockets-rails (3.4.2)
    \\      actionpack (>= 5.2)
    \\      sprockets (>= 3.0.0)
    \\
    \\PLATFORMS
    \\  ruby
    \\
    \\DEPENDENCIES
    \\  jsbundling-rails
    \\  rails (~> 7.1.3)
    \\  sprockets-rails
    \\
    \\BUNDLED WITH
    \\   2.5.3
    \\
;

test "lockedVersion resolves rails' own locked version, not a same-alphabetized neighbor's" {
    try std.testing.expectEqualStrings("7.1.3", lockedVersion(sample_lock, "rails").?);
}

test "lockedVersion ignores a same-named dependency line 6 spaces deep -- only the 4-space spec entry counts" {
    // `railties` never gets its own top-level `    railties (X)` spec line
    // in this fixture -- it only appears 6-space indented, as a dependency
    // of both `jsbundling-rails` and `rails`. If the indentation check were
    // missing (or off by one), this would wrongly resolve to whichever
    // dependency line it hit first.
    try std.testing.expectEqual(@as(?[]const u8, null), lockedVersion(sample_lock, "railties"));
}

test "lockedVersion discriminates rails from its near-miss companions" {
    try std.testing.expectEqualStrings("1.3.0", lockedVersion(sample_lock, "jsbundling-rails").?);
    try std.testing.expectEqualStrings("2.2.0", lockedVersion(sample_lock, "rails-dom-testing").?);
    try std.testing.expectEqualStrings("1.4.4", lockedVersion(sample_lock, "rails-html-sanitizer").?);
    try std.testing.expectEqualStrings("3.4.2", lockedVersion(sample_lock, "sprockets-rails").?);
    // None of the near-miss companions' versions leak into rails' own --
    // the discriminating property the brief names directly.
    try std.testing.expect(!std.mem.eql(u8, "1.3.0", lockedVersion(sample_lock, "rails").?));
}

test "lockedVersion ignores the DEPENDENCIES section's constraint line, not just its value" {
    // `rails (~> 7.1.3)` sits at 2-space indent in DEPENDENCIES. It is
    // excluded by indentation alone, but this also pins the exact bytes
    // returned from the real 4-space specs entry: "7.1.3", not "~> 7.1.3".
    const v = lockedVersion(sample_lock, "rails").?;
    try std.testing.expectEqualStrings("7.1.3", v);
    try std.testing.expect(!std.mem.startsWith(u8, v, "~>"));
}

test "lockedVersion returns null when the gem is not locked at all" {
    try std.testing.expectEqual(@as(?[]const u8, null), lockedVersion(sample_lock, "sinatra"));
}

test "detectVersion: a real Gemfile.lock resolves value and the exact evidence string" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var lock = try tmp.dir.createFile(io, "Gemfile.lock", .{});
    try lock.writeStreamingAll(io, sample_lock);
    lock.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const v = try detectVersion(io, gpa, tmp.dir, &blocker_list);
    defer freeVersion(gpa, v);

    try std.testing.expectEqualStrings("7.1.3", v.value.?);
    try std.testing.expectEqualStrings("Gemfile.lock:rails (7.1.3)", v.evidence.?);
    try std.testing.expectEqual(@as(usize, 0), blocker_list.items.len);
}

test "detectVersion: an absent Gemfile.lock is null plus one warn blocker, not a failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const v = try detectVersion(io, gpa, tmp.dir, &blocker_list);
    defer freeVersion(gpa, v);

    try std.testing.expectEqual(@as(?[]u8, null), v.value);
    try std.testing.expectEqual(@as(?[]u8, null), v.evidence);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_GEMFILE_LOCK_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expectEqual(blockers.Severity.warn, blocker_list.items[0].severity);
    try std.testing.expect(!blocker_list.items[0].integrity);
    try std.testing.expectEqual(@as(?[]const u8, null), blocker_list.items[0].route_id);
}

test "detectVersion: a lock file that never locks rails is null plus a warn blocker, not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var lock = try tmp.dir.createFile(io, "Gemfile.lock", .{});
    try lock.writeStreamingAll(io,
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
    );
    lock.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const v = try detectVersion(io, gpa, tmp.dir, &blocker_list);
    defer freeVersion(gpa, v);

    try std.testing.expectEqual(@as(?[]u8, null), v.value);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_GEMFILE_LOCK_UNAVAILABLE", blocker_list.items[0].code);
}

test "detectVersion: an unreadable Gemfile.lock (IsDir) is null plus a warn blocker, distinct detail from absence" {
    // Same directory-forcing trick `readCapped`'s own test uses: `error.
    // IsDir` is deterministic across platforms, unlike a permission-bit
    // test, and reaches the `else` branch distinct from `FileNotFound`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var lock_dir = try tmp.dir.createDirPathOpen(io, "Gemfile.lock", .{});
    lock_dir.close(io);

    var blocker_list: std.ArrayListUnmanaged(blockers.Blocker) = .empty;
    defer blockers.free(gpa, blocker_list.toOwnedSlice(gpa) catch unreachable);

    const v = try detectVersion(io, gpa, tmp.dir, &blocker_list);
    defer freeVersion(gpa, v);

    try std.testing.expectEqual(@as(?[]u8, null), v.value);
    try std.testing.expectEqual(@as(usize, 1), blocker_list.items.len);
    try std.testing.expectEqualStrings("RAILS_GEMFILE_LOCK_UNAVAILABLE", blocker_list.items[0].code);
    try std.testing.expect(!std.mem.eql(u8, "Gemfile.lock not found", blocker_list.items[0].detail));
}
