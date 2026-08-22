# Rails Discovery Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `zigapagos migrate <rails-app>` detect a Rails application, inventory its presentation layer, identify its frontend integrations, and write a `MIGRATION.md` worklist — with no Ruby involved.

**Architecture:** A new `src/cli/rails/` package holds Rails-shaped logic, deliberately split so that all decision logic is **pure functions over slices** (std-only, unit-testable) and all filesystem I/O is a thin walker layer. `src/cli/migrate.zig` keeps ownership of CLI parsing, detection dispatch, and `fatal.*` error exits; the rails package never calls `fatal` and returns errors instead.

**Tech Stack:** Zig 0.16, `std.Io` (`Io.Dir.openFile` / `openDir` / `walk` / `readFileAlloc`), bash for e2e.

**Spec:** `docs/superpowers/specs/2026-08-22-rails-source-discovery-design.md`

## Global Constraints

- Zig **0.16.0** exactly (`mise.toml`, `build.zig.zon` `.minimum_zig_version`). Check `zig version` before believing a configure-time error.
- **`zig fmt` is gated with no exceptions.** Run `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` before every commit. Never reformat `zig-pkg/` (gitignored vendored deps).
- **Allocator contracts (NO_SLOP.md §2.2a).** Every allocator-taking function must be exactly one of the four contracts and say which in a doc comment. Everything in this stage is **contract 1 (self-freeing)** — frees all scratch, one allocation escapes as the return — or **contract 3 (caller-buffer)**. No arena is introduced, so no `scripts/allocator-allowlist.txt` row is needed. Verify with `bash scripts/check-allocator-contracts.sh`.
- **The rails package is std-only.** It must not `@import` across the `src/` boundary (no `../fatal.zig`), so it can be registered as a `standalone` test suite. Errors return to `migrate.zig`, which owns all `fatal.*` calls.
- **Determinism is testable output.** All emitted lists sort by a stable key; paths are relative to the source root with forward slashes; no wall-clock timestamps in any artifact.
- **Source is read-only.** `migrate` must never write into the scanned project.
- **Never push to main, force-push, or merge.** Work happens on `feature/166-rails-discovery`.
- Regression tests must be **verified to fail without the fix** — that is the only way to know they pin anything.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/cli/rails/detect.zig` (create) | Rails evidence collection + the pure `isRails` decision |
| `src/cli/rails/inventory.zig` (create) | Pure path→`Kind`/`Engine` classification + the `app/` walker |
| `src/cli/rails/integrations.zig` (create) | Pure Gemfile / package.json integration sniffing |
| `src/cli/rails/report.zig` (create) | Pure `MIGRATION.md` rendering from in-memory data |
| `src/cli/rails/rails.zig` (create) | Package root: re-exports, and the one orchestrating `discover()` |
| `src/cli/migrate.zig` (modify) | `.rails` in `Source`, detection wiring, dispatch, usage text |
| `build/tests.zig` (modify) | Register the `test-rails` standalone suite |
| `.github/workflows/ci.yml` (modify) | Add `test-rails` to the hand-written suite list |
| `tests/migrate/rails-sample/` (create) | Synthetic ERB fixture app |
| `tests/migrate/rails.sh` (create) | Shell e2e contract |

---

### Task 1: Rails detection

Rails must be detected without stealing Jekyll's projects — **Jekyll's existing detection already keys off `Gemfile`** (`src/cli/migrate.zig:236-241`), so a Gemfile alone can never imply Rails.

**Files:**
- Create: `src/cli/rails/detect.zig`
- Modify: `src/cli/migrate.zig` (`Source` enum ~line 11, `parse` ~line 21, `name` ~line 34, `configMarker` ~line 229, `sourceMarker` ~line 255, `detectSource` ~line 267, `usage` ~line 60)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `pub const Evidence = struct { has_application_rb: bool = false, has_routes_rb: bool = false, has_app_views: bool = false, gemfile_declares_rails: bool = false, has_jekyll_config: bool = false }`
  - `pub fn isRails(e: Evidence) bool`
  - `pub fn collect(io: Io, gpa: Allocator, root: Io.Dir) Evidence`

- [ ] **Step 1: Write the failing test**

Create `src/cli/rails/detect.zig` containing only the tests plus the type they need:

```zig
//! Rails detection: evidence collection (I/O) and the pure decision over it.
//!
//! Deliberately std-only so this file can back a `standalone` test suite; all
//! `fatal.*` handling stays in `src/cli/migrate.zig`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Durable, filesystem-observable facts about a candidate project root.
pub const Evidence = struct {
    has_application_rb: bool = false,
    has_routes_rb: bool = false,
    has_app_views: bool = false,
    gemfile_declares_rails: bool = false,
    /// Jekyll ships a Gemfile too. Its config is a hard veto.
    has_jekyll_config: bool = false,
};

test "a Gemfile alone is never enough to mean Rails" {
    try std.testing.expect(!isRails(.{ .gemfile_declares_rails = true }));
}

test "Jekyll config vetoes Rails even with Rails-looking evidence" {
    try std.testing.expect(!isRails(.{
        .has_application_rb = true,
        .has_app_views = true,
        .has_jekyll_config = true,
    }));
}

test "config/application.rb plus app/views is conclusive" {
    try std.testing.expect(isRails(.{ .has_application_rb = true, .has_app_views = true }));
}

test "routes.rb plus app/views plus a rails gem is conclusive" {
    try std.testing.expect(isRails(.{
        .has_routes_rb = true,
        .has_app_views = true,
        .gemfile_declares_rails = true,
    }));
}

test "a plain Ruby gem with no app tree is not Rails" {
    try std.testing.expect(!isRails(.{ .gemfile_declares_rails = true, .has_routes_rb = true }));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-rails` (the step does not exist yet — Task 5 registers it). Until then verify with:
`zig test src/cli/rails/detect.zig`
Expected: FAIL — `error: use of undeclared identifier 'isRails'`

- [ ] **Step 3: Write minimal implementation**

Append to `src/cli/rails/detect.zig`:

```zig
/// Pure decision over collected evidence. Contract 3 (caller-buffer):
/// allocates nothing.
///
/// The veto comes first on purpose: `configMarker` already treats a Gemfile as
/// Jekyll evidence, so without it a Jekyll site with an `app/` directory could
/// match both sources and trip `detectSource`'s ambiguity fatal.
pub fn isRails(e: Evidence) bool {
    if (e.has_jekyll_config) return false;
    if (e.has_application_rb and e.has_app_views) return true;
    if (e.has_routes_rb and e.has_app_views and e.gemfile_declares_rails) return true;
    return false;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/cli/rails/detect.zig`
Expected: PASS (5 tests)

- [ ] **Step 5: Add the evidence collector**

Append to `src/cli/rails/detect.zig`:

```zig
fn fileExists(io: Io, base: Io.Dir, path: []const u8) bool {
    const f = base.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn dirExists(io: Io, base: Io.Dir, path: []const u8) bool {
    const dir = base.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Contract 1 (self-freeing): the Gemfile read is freed before returning; the
/// result is a plain struct of bools that owns nothing.
pub fn collect(io: Io, gpa: Allocator, root: Io.Dir) Evidence {
    var e: Evidence = .{
        .has_application_rb = fileExists(io, root, "config/application.rb"),
        .has_routes_rb = fileExists(io, root, "config/routes.rb"),
        .has_app_views = dirExists(io, root, "app/views"),
        .has_jekyll_config = fileExists(io, root, "_config.yml") or
            fileExists(io, root, "_config.yaml"),
    };
    if (root.readFileAlloc(io, "Gemfile", gpa, .limited(1024 * 1024))) |src| {
        defer gpa.free(src);
        e.gemfile_declares_rails = gemfileDeclares(src, "rails");
    } else |_| {}
    return e;
}

/// True when `src` has an uncommented `gem "<name>"` line. Contract 3.
pub fn gemfileDeclares(src: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "gem ")) continue;
        const rest = std.mem.trim(u8, line[4..], " \t");
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
```

Note the third assertion: `rails-html-sanitizer` must not satisfy `rails`, which is why this matches the full quoted token rather than using `indexOf`.

- [ ] **Step 6: Run tests**

Run: `zig test src/cli/rails/detect.zig`
Expected: PASS (6 tests)

- [ ] **Step 7: Wire `.rails` into the `Source` enum**

In `src/cli/migrate.zig`, add `rails,` to the `Source` enum (after `hexo,`), then:

```zig
        if (std.mem.eql(u8, value, "rails")) return .rails;
```
to `parse`, and:
```zig
            .rails => "Rails",
```
to `name`.

`supportsScaffold` and `contentSource` already end in `else => null` / a boolean expression that excludes `.rails`; confirm both still compile without listing `.rails` (add `.rails => null,` to `contentSource` if the switch is exhaustive).

In `configMarker`, Rails **cannot use the generic `markers` array**. `isRails` has
two conclusive branches, and branch B (routes.rb + app/views + a rails gem, with
NO `config/application.rb`) has no marker file that exists — so returning
`&.{"config/application.rb"}` would make the `for (markers)` loop find nothing and
silently defeat that branch. Short-circuit above the loop instead. Add as the
first statement of `configMarker`:

```zig
    // Rails detection is evidence-based, not marker-file-based: one of its two
    // conclusive branches has no marker file to test for, so routing it through
    // the `markers` loop below would silently defeat that branch.
    if (source == .rails) return rails_detect.isRails(rails_detect.collect(io, gpa, root));
```

and give the switch a formal `.rails => &.{},` arm to satisfy exhaustiveness
(unreachable in practice because of the early return).

This requires `configMarker` to take `gpa`; it currently does not. Change its signature to `fn configMarker(io: Io, gpa: Allocator, root: Io.Dir, source: Source) bool` and update all call sites (`sourceMarker`, `detectSource`, and the Hugo fallback below it).

In `sourceMarker`'s switch add `.rails => false,` (config marker already covers it).

In `detectSource`, add `.rails` to the **first** loop only (the config-marker loop), not the second — Rails has no `package.json` signal.

Add `rails` to the two usage strings and the `--from` line:
```
    \\  --from SOURCE         astro|next|gatsby|nuxt|vue|hugo|jekyll|11ty|hexo|rails
```
and to the `could not confidently detect` message.

Add the import near the top of `migrate.zig`:
```zig
const rails_detect = @import("rails/detect.zig");
```

- [ ] **Step 8: Verify the build and formatting**

Run: `zig build check`
Expected: compiles clean.
Run: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add src/cli/rails/detect.zig src/cli/migrate.zig
git commit -m "Detect Rails projects without stealing Jekyll's

Jekyll's detection already treats a Gemfile as evidence, so Rails keys on
config/application.rb plus an app/views tree and vetoes on a Jekyll config
outright. Gemfile matching compares the full quoted gem token so
rails-html-sanitizer cannot satisfy rails." -- src/cli/rails/detect.zig src/cli/migrate.zig
```

---

### Task 2: Presentation inventory

**Files:**
- Create: `src/cli/rails/inventory.zig`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `pub const Kind = enum { view, layout, partial, mailer_view, controller, helper, stimulus_controller, js_entry, asset, other }`
  - `pub const Engine = enum { erb, haml, slim, jbuilder, builder, none }`
  - `pub fn engineFor(path: []const u8) Engine`
  - `pub fn classify(rel_path: []const u8) Kind`
  - `pub const Entry = struct { path: []const u8, kind: Kind, engine: Engine }`
  - `pub fn walk(io: Io, gpa: Allocator, root: Io.Dir) Allocator.Error![]Entry`
  - `pub fn freeEntries(gpa: Allocator, entries: []Entry) void`

- [ ] **Step 1: Write the failing test**

Create `src/cli/rails/inventory.zig`:

```zig
//! Rails presentation inventory: pure path classification plus the app/ walker.
//! std-only by design (see the note in detect.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    view,
    layout,
    partial,
    mailer_view,
    controller,
    helper,
    stimulus_controller,
    js_entry,
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/cli/rails/inventory.zig`
Expected: FAIL — `error: use of undeclared identifier 'engineFor'`

- [ ] **Step 3: Write minimal implementation**

Append to `src/cli/rails/inventory.zig`:

```zig
fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
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
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            if (std.mem.endsWith(u8, rest[0..slash], "_mailer")) return .mailer_view;
        }
        return .view;
    }
    if (std.mem.startsWith(u8, rel_path, "app/controllers/") and
        std.mem.endsWith(u8, rel_path, "_controller.rb")) return .controller;
    if (std.mem.startsWith(u8, rel_path, "app/helpers/")) return .helper;
    if (std.mem.startsWith(u8, rel_path, "app/javascript/controllers/") and
        std.mem.endsWith(u8, rel_path, "_controller.js")) return .stimulus_controller;
    if (std.mem.startsWith(u8, rel_path, "app/javascript/")) return .js_entry;
    if (std.mem.startsWith(u8, rel_path, "app/assets/")) return .asset;
    if (std.mem.startsWith(u8, rel_path, "public/")) return .asset;
    return .other;
}
```

- [ ] **Step 4: Run tests**

Run: `zig test src/cli/rails/inventory.zig`
Expected: PASS (4 tests)

- [ ] **Step 5: Add the walker**

Append:

```zig
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

/// Contract 2 (owned-result): the returned slice and every `path` in it are
/// owned by the caller; release with `freeEntries`.
///
/// Sorted by path so the emitted report and manifest are byte-deterministic.
pub fn walk(io: Io, gpa: Allocator, root: Io.Dir) Allocator.Error![]Entry {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.path);
        list.deinit(gpa);
    }

    for (roots) |top| {
        var dir = root.openDir(io, top, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        // `walk`'s error set is wider than OutOfMemory (see migrate.zig:1297),
        // so the `else` arm is required -- an unwalkable root is skipped rather
        // than failing the whole inventory.
        var walker = dir.walk(gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer walker.deinit();
        // A mid-walk error ends this root's iteration; whatever was collected
        // is kept, matching the "partial discovery is still useful" rule.
        while (walker.next(io) catch null) |entry| {
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
    return out;
}

pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.path);
    gpa.free(entries);
}
```

- [ ] **Step 6: Verify build + format**

Run: `zig test src/cli/rails/inventory.zig` → PASS
Run: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check` → no output

- [ ] **Step 7: Commit**

```bash
git add src/cli/rails/inventory.zig
git commit -m "Inventory the Rails presentation tree

Classification is pure so it is unit-testable without a filesystem; the
walker is the only I/O. Partial detection precedes the layouts/ prefix
because Rails resolves app/views/layouts/_nav.html.erb as a partial, and
results sort by path so downstream output is byte-deterministic." -- src/cli/rails/inventory.zig
```

---

### Task 3: Integration detection

**Files:**
- Create: `src/cli/rails/integrations.zig`

**Interfaces:**
- Consumes: `detect.gemfileDeclares` (Task 1) — re-implemented locally is **not** acceptable; import it.
- Produces:
  - `pub const Integration = struct { name: []const u8, evidence: []const u8 }`
  - `pub fn scan(gpa: Allocator, gemfile: ?[]const u8, package_json: ?[]const u8) Allocator.Error![]Integration`
  - `pub fn freeIntegrations(gpa: Allocator, items: []Integration) void`

- [ ] **Step 1: Write the failing test**

Create `src/cli/rails/integrations.zig`:

```zig
//! Detects the asset pipeline and frontend runtime a Rails app uses, from
//! durable declarations (Gemfile, package.json) rather than file sniffing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const detect = @import("detect.zig");

pub const Integration = struct {
    name: []const u8,
    /// Where the conclusion came from, e.g. `Gemfile:propshaft`.
    evidence: []const u8,
};

test "gem-declared pipelines and runtimes are detected with evidence" {
    const gemfile =
        \\gem "rails", "~> 7.1"
        \\gem "propshaft"
        \\gem "turbo-rails"
        \\# gem "sprockets-rails"
    ;
    const items = try scan(std.testing.allocator, gemfile, null);
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
    const items = try scan(std.testing.allocator, null, pkg);
    defer freeIntegrations(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("react", items[0].name);
    try std.testing.expectEqualStrings("stimulus", items[1].name);
}

test "a commented gem is not an integration" {
    const items = try scan(std.testing.allocator, "# gem \"vite_rails\"\n", null);
    defer freeIntegrations(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/cli/rails/integrations.zig`
Expected: FAIL — `error: use of undeclared identifier 'scan'`

- [ ] **Step 3: Write minimal implementation**

Append:

```zig
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

fn packageDeclares(src: []const u8, pkg: []const u8) bool {
    // A substring scan of package.json, not a JSON parse -- matching the
    // existing convention in migrate.zig. The quotes and colon make a
    // dependency key unambiguous against a version string.
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{pkg}) catch return false;
    return std.mem.indexOf(u8, src, needle) != null;
}

fn has(items: []const Integration, name: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i.name, name)) return true;
    return false;
}

/// Contract 2 (owned-result): caller releases with `freeIntegrations`.
pub fn scan(
    gpa: Allocator,
    gemfile: ?[]const u8,
    package_json: ?[]const u8,
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
    if (package_json) |src| {
        for (pkg_rules) |rule| {
            if (!packageDeclares(src, rule.pkg)) continue;
            if (has(list.items, rule.name)) continue; // gem already proved it
            const ev = try std.fmt.allocPrint(gpa, "package.json:{s}", .{rule.pkg});
            errdefer gpa.free(ev);
            try list.append(gpa, .{ .name = rule.name, .evidence = ev });
        }
    }
    return list.toOwnedSlice(gpa);
}

pub fn freeIntegrations(gpa: Allocator, items: []Integration) void {
    for (items) |i| gpa.free(i.evidence);
    gpa.free(items);
}
```

- [ ] **Step 4: Run tests**

Run: `zig test src/cli/rails/integrations.zig`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/cli/rails/integrations.zig
git commit -m "Detect Rails asset pipeline and frontend integrations

Reads durable declarations rather than sniffing files, and records the
evidence string per integration so the report can cite why it concluded
each one. Rule order fixes output order to keep the report deterministic." -- src/cli/rails/integrations.zig
```

---

### Task 4: MIGRATION.md rendering

**Files:**
- Create: `src/cli/rails/report.zig`

**Interfaces:**
- Consumes: `inventory.Entry`, `inventory.Kind`, `inventory.Engine`, `integrations.Integration`.
- Produces: `pub fn build(gpa: Allocator, in: Input) Allocator.Error![]const u8` where
  `pub const Input = struct { app_path: []const u8, entries: []const inventory.Entry, integrations: []const integrations.Integration }`

- [ ] **Step 1: Write the failing test**

Create `src/cli/rails/report.zig`:

```zig
//! Renders the human MIGRATION.md worklist. Pure: takes in-memory inventory
//! data and returns markdown, so it is testable without a filesystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const inventory = @import("inventory.zig");
const integrations = @import("integrations.zig");

pub const Input = struct {
    app_path: []const u8,
    entries: []const inventory.Entry,
    integrations: []const integrations.Integration,
};

test "report lists counts, integrations, and flags unsupported engines" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/layouts/application.html.erb", .kind = .layout, .engine = .erb },
        .{ .path = "app/views/posts/_post.html.erb", .kind = .partial, .engine = .erb },
        .{ .path = "app/views/posts/index.html.haml", .kind = .view, .engine = .haml },
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
    };
    const ints = [_]integrations.Integration{
        .{ .name = "propshaft", .evidence = "Gemfile:propshaft" },
    };
    const md = try build(std.testing.allocator, .{
        .app_path = "my-app",
        .entries = &entries,
        .integrations = &ints,
    });
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "# Migrating my-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Views | 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "propshaft") != null);
    // The Haml view must be named as a blocker, never silently counted as done.
    try std.testing.expect(std.mem.indexOf(u8, md, "RAILS_TEMPLATE_ENGINE_UNSUPPORTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "app/views/posts/index.html.haml") != null);
}

test "report is byte-identical across runs" {
    const entries = [_]inventory.Entry{
        .{ .path = "app/views/posts/show.html.erb", .kind = .view, .engine = .erb },
    };
    const a = try build(std.testing.allocator, .{ .app_path = "x", .entries = &entries, .integrations = &.{} });
    defer std.testing.allocator.free(a);
    const b = try build(std.testing.allocator, .{ .app_path = "x", .entries = &entries, .integrations = &.{} });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/cli/rails/report.zig`
Expected: FAIL — `error: use of undeclared identifier 'build'`

- [ ] **Step 3: Write minimal implementation**

Append:

```zig
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
pub fn build(gpa: Allocator, in: Input) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = out.writer(gpa);

    try w.print("# Migrating {s} to Zigapagos\n\n", .{in.app_path});
    try w.writeAll(
        \\Rails source discovery. This worklist inventories the presentation
        \\layer; it converts nothing. Routes are not included at this stage.
        \\
        \\## Inventory
        \\
        \\| Kind | Count |
        \\| --- | --- |
        \\
    );
    try w.print("| Views | {d} |\n", .{countOf(in.entries, .view)});
    try w.print("| Layouts | {d} |\n", .{countOf(in.entries, .layout)});
    try w.print("| Partials | {d} |\n", .{countOf(in.entries, .partial)});
    try w.print("| Mailer views | {d} |\n", .{countOf(in.entries, .mailer_view)});
    try w.print("| Controllers | {d} |\n", .{countOf(in.entries, .controller)});
    try w.print("| Helpers | {d} |\n", .{countOf(in.entries, .helper)});
    try w.print("| Stimulus controllers | {d} |\n", .{countOf(in.entries, .stimulus_controller)});
    try w.print("| Assets | {d} |\n", .{countOf(in.entries, .asset)});

    try w.writeAll("\n## Detected integrations\n\n");
    if (in.integrations.len == 0) {
        try w.writeAll("None detected.\n");
    } else {
        for (in.integrations) |i| try w.print("- `{s}` ({s})\n", .{ i.name, i.evidence });
    }

    try w.writeAll("\n## Blockers\n\n");
    var blockers: usize = 0;
    for (in.entries) |e| {
        const label = switch (e.engine) {
            .haml => "Haml",
            .slim => "Slim",
            else => continue,
        };
        blockers += 1;
        try w.print(
            "- `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` {s}: {s} template is not converted\n",
            .{ e.path, label },
        );
    }
    if (blockers == 0) try w.writeAll("None.\n");

    return out.toOwnedSlice(gpa);
}
```

- [ ] **Step 4: Run tests**

Run: `zig test src/cli/rails/report.zig`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add src/cli/rails/report.zig
git commit -m "Render the Rails MIGRATION.md worklist

Pure rendering over in-memory inventory, so it is testable without a
filesystem and pins determinism directly. Carries no timestamp: identical
input must produce byte-identical output. Haml and Slim templates are
emitted as RAILS_TEMPLATE_ENGINE_UNSUPPORTED blockers rather than being
counted as migrated." -- src/cli/rails/report.zig
```

---

### Task 5: CLI dispatch, fixture app, and test registration

**Files:**
- Create: `src/cli/rails/rails.zig`
- Create: `tests/migrate/rails-sample/` (fixture, files listed below)
- Modify: `src/cli/migrate.zig` (dispatch in `migrate()` ~line 595)
- Modify: `build/tests.zig` (register `test-rails`)
- Modify: `.github/workflows/ci.yml` (line ~424 suite list)

**Interfaces:**
- Consumes: `detect.collect`, `inventory.walk`, `integrations.scan`, `report.build`.
- Produces: `pub fn discover(io: Io, gpa: Allocator, root: Io.Dir, app_path: []const u8) Allocator.Error![]const u8` — returns the rendered `MIGRATION.md` body.

- [ ] **Step 1: Create the package root**

Create `src/cli/rails/rails.zig`:

```zig
//! Package root for the Rails migration adapter, and the `standalone` test
//! suite root for `zig build test-rails`.
//!
//! Everything below is std-only: no import escapes `src/cli/rails/`, so this
//! compiles as its own module. `fatal.*` handling belongs to migrate.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const detect = @import("detect.zig");
pub const inventory = @import("inventory.zig");
pub const integrations = @import("integrations.zig");
pub const report = @import("report.zig");

/// Pulls the suites of every sibling file into this module so `test-rails`
/// runs them all. Without this the standalone binary only sees this file.
test {
    std.testing.refAllDecls(@This());
    _ = detect;
    _ = inventory;
    _ = integrations;
    _ = report;
}

/// Contract 1 (self-freeing): every intermediate (entries, integrations, file
/// reads) is released here; the returned markdown is the single escaping
/// allocation and belongs to the caller.
pub fn discover(
    io: Io,
    gpa: Allocator,
    root: Io.Dir,
    app_path: []const u8,
) Allocator.Error![]const u8 {
    const entries = try inventory.walk(io, gpa, root);
    defer inventory.freeEntries(gpa, entries);

    const gemfile: ?[]const u8 = root.readFileAlloc(io, "Gemfile", gpa, .limited(1024 * 1024)) catch null;
    defer if (gemfile) |g| gpa.free(g);
    const pkg: ?[]const u8 = root.readFileAlloc(io, "package.json", gpa, .limited(1024 * 1024)) catch null;
    defer if (pkg) |p| gpa.free(p);

    const ints = try integrations.scan(gpa, gemfile, pkg);
    defer integrations.freeIntegrations(gpa, ints);

    return report.build(gpa, .{
        .app_path = app_path,
        .entries = entries,
        .integrations = ints,
    });
}
```

- [ ] **Step 2: Register the test suite**

In `build/tests.zig`, add to the `standalone` table (keeping table order = `--help` order):

```zig
    .{
        .step_name = "test-rails",
        .description = "Run Rails migration adapter unit tests",
        .root_source_file = "src/cli/rails/rails.zig",
    },
```

- [ ] **Step 3: Run the suite to verify it wires up**

Run: `zig build test-rails`
Expected: PASS — all suites from Tasks 1-4 run: **17 named tests** (detect 6 + inventory 5 +
integrations 4 + report 2). This is up from the 15 originally planned: Task 2 added a walker
integration test (the only coverage of the contract-2 ownership pairing) and Task 3 added the
gem-wins-over-npm dedup regression test. Both were review-approved.
Zig may additionally report the anonymous `refAllDecls` block as an unnamed test;
that is expected. Assert the named suites ran, not an exact total.

If a sibling file's tests do **not** run, `refAllDecls` did not reach them; the explicit `_ = detect;` lines above are what guarantee it.

- [ ] **Step 4: Add `test-rails` to CI**

In `.github/workflows/ci.yml`, add `test-rails` to the hand-written list at line ~424:

```
            test-islands test-props test-migrate test-sidecar test-init \
            test-release test-debug test-spa test-assets test-e2e test-dev \
            test-doctor test-slugs test-validate test-explain test-diag \
            test-summary test-images test-sitemap test-rails
```

This list is enumerated by hand — a suite absent from it is silently never run in CI.

- [ ] **Step 5: Dispatch from migrate()**

In `src/cli/migrate.zig`, add the import:

```zig
const rails = @import("rails/rails.zig");
```

Then **replace T1's `rails_detect` alias**: `configMarker` now calls
`rails.detect.isRails(rails.detect.collect(io, gpa, root))`, and the
`const rails_detect = @import("rails/detect.zig");` line is deleted. One alias
for one package (pre-flight Ruling 2).

And, in `migrate()` immediately **before** `var res = if (source == .astro) scan(...) else scanOther(...)` (~line 592) — `scanOther` is Astro-shaped and must never see a Rails project:

```zig
    if (source == .rails) {
        const body = rails.discover(io, gpa, root, dir_path) catch |err| switch (err) {
            error.OutOfMemory => fatal.oom(),
        };
        defer gpa.free(body);

        const rf = Io.Dir.cwd().createFile(io, out_path, .{}) catch |err|
            fatal.file(out_path, err);
        defer rf.close(io);
        var rfw = rf.writer(io, &.{});
        rfw.interface.writeAll(body) catch |err| fatal.file(out_path, err);

        std.debug.print(
            "Wrote {s}: Rails, inventory only (no routes at this stage).\n" ++
                "Next: follow MIGRATION.md.\n",
            .{out_path},
        );
        // `migrate()`'s bool is any_error -- main.zig:189 does
        // `return @intFromBool(any_error)`. Success is `false`; returning
        // `true` here would exit 1 on a perfectly good run.
        return false;
    }
```

Note the variable is `out_path`, not `output_path`. This mirrors the existing
writer at `migrate.zig:606-611` exactly rather than introducing a second one.
`createFile(io, out_path, .{})` **truncates**: the report is overwritten on a
repeat run by design. The non-clobbering `.new` rule applies to scaffolded
islands and copied assets, not to the report — do not add `.new` handling here.

- [ ] **Step 6: Create the fixture app**

Create these files under `tests/migrate/rails-sample/`:

`Gemfile`:
```ruby
source "https://rubygems.org"
gem "rails", "~> 7.1"
gem "propshaft"
gem "turbo-rails"
gem "stimulus-rails"
# gem "sprockets-rails"
```

`config/application.rb`:
```ruby
require_relative "boot"
module RailsSample
  class Application < Rails::Application
    config.load_defaults 7.1
  end
end
```

`config/routes.rb`:
```ruby
Rails.application.routes.draw do
  root "posts#index"
  resources :posts do
    member { post :publish }
  end
end
```

`app/views/layouts/application.html.erb`:
```erb
<!DOCTYPE html>
<html><body><%= yield %></body></html>
```

`app/views/layouts/_nav.html.erb`:
```erb
<nav><%= link_to "Home", root_path %></nav>
```

`app/views/posts/index.html.erb`:
```erb
<h1>Posts</h1>
<%= render partial: "post", collection: @posts %>
```

`app/views/posts/_post.html.erb`:
```erb
<article><%= post.title %></article>
```

`app/views/posts/legacy.html.haml`:
```haml
%h1 Legacy
```

`app/views/user_mailer/welcome.html.erb`:
```erb
<p>Welcome</p>
```

`app/controllers/posts_controller.rb`:
```ruby
class PostsController < ApplicationController
  def index; @posts = Post.all; end
end
```

`app/helpers/posts_helper.rb`:
```ruby
module PostsHelper; end
```

`app/javascript/application.js`:
```javascript
import "@hotwired/turbo-rails";
```

`app/javascript/controllers/reveal_controller.js`:
```javascript
import { Controller } from "@hotwired/stimulus";
export default class extends Controller {}
```

`app/assets/images/logo.png` — create as a 1-byte placeholder: `printf 'x' > app/assets/images/logo.png`

`public/favicon.ico` — same: `printf 'x' > public/favicon.ico`

The Haml view is deliberate: it is what proves an unsupported engine surfaces as a blocker.

- [ ] **Step 7: Verify end to end by hand**

```bash
zig build
./zig-out/bin/zigapagos migrate tests/migrate/rails-sample -o /tmp/rails-MIGRATION.md
cat /tmp/rails-MIGRATION.md
```
Expected: detects Rails without `--from`; reports Views 2, Layouts 1, Partials 2, Mailer views 1, Controllers 1, Helpers 1, Stimulus controllers 1, Assets 2; lists `propshaft`, `turbo`, `stimulus`; and one `RAILS_TEMPLATE_ENGINE_UNSUPPORTED` blocker for the Haml view.

- [ ] **Step 8: Verify build, format, and the full gate**

```bash
zig build check
zig build check -Dsingle-threaded
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
bash scripts/check-allocator-contracts.sh
```
Expected: all clean.

- [ ] **Step 9: Commit**

```bash
git add src/cli/rails/rails.zig src/cli/migrate.zig build/tests.zig .github/workflows/ci.yml tests/migrate/rails-sample
git commit -m "Wire the Rails adapter into migrate and CI

Adds the package root (also the test-rails suite root), dispatches to it
from migrate() before the Astro-shaped scan, and registers test-rails in
both build/tests.zig and ci.yml -- that CI list is hand-written, so a
suite missing from it is silently never run.

The fixture carries a Haml view on purpose: it is what proves an
unsupported engine surfaces as a blocker rather than being counted as
migrated." -- src/cli/rails/rails.zig src/cli/migrate.zig build/tests.zig .github/workflows/ci.yml tests/migrate/rails-sample
```

---

### Task 6: Shell e2e contract

**Files:**
- Create: `tests/migrate/rails.sh`

**Interfaces:**
- Consumes: the built `zig-out/bin/zigapagos` and `tests/migrate/rails-sample/`.
- Produces: nothing (a gate).

- [ ] **Step 1: Write the failing test**

Create `tests/migrate/rails.sh` (mode 755):

```bash
#!/usr/bin/env bash
# End-to-end contract for the Rails adapter: detection, source immutability,
# determinism, non-clobbering repeat runs, and blocker honesty.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
ZIGAPAGOS="${ZIGAPAGOS:-$REPO/zig-out/bin/zigapagos}"

fail() { echo "FAIL: $*"; exit 1; }
if [[ ! -x "$ZIGAPAGOS" ]]; then
  mise exec -- zig build || fail "zig build failed"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/app"
cp -R "$REPO/tests/migrate/rails-sample" "$APP"

# --- source immutability -----------------------------------------------------
before="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"

# --- auto-detection ----------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/one.md" >/dev/null 2>&1 \
  || fail "migrate failed on the Rails fixture"
grep -q "Migrating" "$WORK/one.md" || fail "report missing header"

# --- explicit --from ---------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" --from rails -o "$WORK/from.md" >/dev/null 2>&1 \
  || fail "--from rails rejected"

# --- inventory counts --------------------------------------------------------
grep -q "Views | 2" "$WORK/one.md" || fail "expected 2 views"
grep -q "Partials | 2" "$WORK/one.md" || fail "expected 2 partials (incl. layouts/_nav)"
grep -q "Mailer views | 1" "$WORK/one.md" || fail "expected 1 mailer view"
grep -q "Stimulus controllers | 1" "$WORK/one.md" || fail "expected 1 stimulus controller"

# --- integrations ------------------------------------------------------------
grep -q "propshaft" "$WORK/one.md" || fail "propshaft not detected"
grep -q "turbo" "$WORK/one.md" || fail "turbo not detected"
grep -q "sprockets" "$WORK/one.md" && fail "commented-out gem must not be detected"

# --- blocker honesty ---------------------------------------------------------
grep -q "RAILS_TEMPLATE_ENGINE_UNSUPPORTED" "$WORK/one.md" \
  || fail "Haml view was not reported as a blocker"
grep -q "legacy.html.haml" "$WORK/one.md" || fail "blocker missing its source path"

# --- determinism -------------------------------------------------------------
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/two.md" >/dev/null 2>&1
diff -u "$WORK/one.md" "$WORK/two.md" || fail "output is not deterministic"

# --- source unchanged --------------------------------------------------------
after="$(cd "$APP" && find . -type f | sort | xargs shasum | shasum)"
[[ "$before" == "$after" ]] || fail "migrate modified the source tree"

# --- repeat run overwrites the report, and does so identically ---------------
# createFile(..., .{}) truncates by design: the report is regenerated, not
# versioned. The `.new` rule covers scaffolded islands and copied assets, which
# this stage does not emit. Assert the documented behaviour rather than a
# `.new` file that must never appear here.
cp "$WORK/one.md" "$WORK/one.before.md"
"$ZIGAPAGOS" migrate "$APP" -o "$WORK/one.md" >/dev/null 2>&1
[[ ! -e "$WORK/one.md.new" ]] || fail "report must be overwritten, not versioned to .new"
diff -u "$WORK/one.before.md" "$WORK/one.md" || fail "regenerated report differs"

echo "PASS: tests/migrate/rails.sh"
```

- [ ] **Step 2: Run it to verify it fails without the adapter**

A regression test never seen to fail pins nothing — this step is the repo's
convention and is not optional.

**`git stash` will not work here**: the adapter is already committed, so there is
nothing in the working tree to stash. Neuter detection instead, which is fast
(incremental rebuild) and proves the test depends on the adapter:

```bash
# 1. Make detection fail: temporarily force isRails to return false.
#    Edit src/cli/rails/detect.zig -> `pub fn isRails(e: Evidence) bool { return false; }`
zig build && bash tests/migrate/rails.sh   # expect FAIL: detection error
# 2. Restore the real body, rebuild, re-run.
zig build && bash tests/migrate/rails.sh   # expect PASS
# 3. Prove nothing was left modified.
git diff --exit-code && echo "tree clean"
```

Record BOTH outputs in your report. Step 3 is not optional: a verification that
leaves the tree edited is how a neutered function gets committed by accident.

- [ ] **Step 3: Run it against the real build**

```bash
chmod +x tests/migrate/rails.sh
zig build && bash tests/migrate/rails.sh
```
Expected: `PASS: tests/migrate/rails.sh`

Note: check the exit status directly. **`cmd | tail` reports `tail`'s status, not `cmd`'s**, and `${PIPESTATUS[0]}` expands empty under zsh.

- [ ] **Step 4: Confirm the glob picks it up**

CI runs every `tests/*/*.sh`; `tests/migrate/rails.sh` matches, so no workflow edit is needed. Verify:
```bash
ls tests/*/*.sh | grep rails
```
Expected: `tests/migrate/rails.sh`

- [ ] **Step 5: Commit**

```bash
git add tests/migrate/rails.sh
git commit -m "Pin the Rails adapter's end-to-end contract

Covers detection, --from rails, inventory counts, integration evidence,
determinism across runs, source immutability, and non-clobbering repeat
runs. Verified to fail against a build without the adapter.

The commented-out sprockets gem is asserted absent: it is what proves the
Gemfile scan honours comments rather than substring-matching the file." -- tests/migrate/rails.sh
```

---

## Stage 1 exit criteria

- `zig build test-rails` passes (17 named unit tests: detect 6, inventory 5, integrations 4, report 2).
- `bash tests/migrate/rails.sh` passes and was seen to fail without the adapter.
- `zig build check` and `zig build check -Dsingle-threaded` are clean.
- `zig fmt --check` over all tracked `.zig` files is clean.
- `bash scripts/check-allocator-contracts.sh` passes.
- `zigapagos migrate tests/migrate/rails-sample` detects Rails with no `--from`.

## Not in this plan

Stages 2-5 of the spec get their own plans, in order: the Ruby sidecar and route
discovery; the classifier; the versioned manifest and its drift gate; and
`--target` assembly plus docs and the `skills/` mirror. Nothing here emits a
manifest or classifies a route — Stage 1 answers only "what is in this app".
