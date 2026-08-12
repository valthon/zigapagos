const Build = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const tracy = @import("tracy");
const ziggy = @import("ziggy");
const fatal = @import("fatal.zig");
const context = @import("context.zig");
const Variant = @import("Variant.zig");
const Template = @import("Template.zig");
const PathTable = @import("PathTable.zig");
const StringTable = @import("StringTable.zig");
const root = @import("root.zig");
const BuildAsset = root.BuildAsset;
const Path = PathTable.Path;
const String = StringTable.String;
const PathName = PathTable.PathName;

const islands = @import("islands/sidecar.zig");

const log = std.log.scoped(.build);
const cache_dir_basename = ".zigapagos-cache";

cfg: *const root.Config,
build_assets: *const std.StringArrayHashMapUnmanaged(BuildAsset),
any_prerendering_error: bool = false,
any_rendering_error: std.atomic.Value(bool) = .{ .raw = false },

base_dir_path: []const u8,
base_dir: Io.Dir,
st: StringTable,
pt: PathTable,
// Fields below are only valid after the corresponding processing stage
// has been reached, see main.zig for more info.
variants: []Variant = &.{},
// Layouts and templates are only identified by filename,
// layouts are expected to be placed directly under layouts_dir_path
// while templates are expected to be nested under `templates/`.
// This is extremely restrictive but there are some design considerations
// to make about relaxing this limitation.
// Should templates allowed to be placed anywhere? Should the "templates
// subdirectory" approach be global (ie only one templates dir) or should
// it be made relative to where the layout lives (eg 'layouts/foo/templates',
// 'layouts/bar/templates')?
layouts_dir: Io.Dir,
templates: Templates = .{},
site_assets_dir: Io.Dir,
site_assets: Assets = .empty,
/// How many times each site asset was CONSUMED AT BUILD TIME without being
/// installed — `$site.asset('x').bytes()`/`.size()`/`.sriHash()`/`.ziggy()`
/// (`src/context/Asset.zig`). Keyed identically to `site_assets`: every key is
/// inserted alongside its `site_assets` entry in `scanSiteAssets`, so the two
/// key sets cannot diverge and a worker only ever bumps a counter that already
/// exists (which is what makes the concurrent `fetchAdd` safe — no insertion
/// ever happens after the scan).
///
/// It deliberately does NOT feed the install decision: an asset read into the
/// page at build time is fully inlined and must stay out of the output tree.
/// Its only consumer is `root.zig`'s `reportPrunedSiteAssets` (issue #54),
/// which would otherwise warn that a legitimately-inlined `data.ziggy` "was
/// not installed because nothing references them" and suggest two remedies
/// that are both wrong — the `static_assets` one would publish a private data
/// file.
site_asset_reads: Assets = .empty,
/// Content-hashed basenames for site assets (issue #53). Empty — the default,
/// and the whole of it unless `asset_fingerprint` is on in `zigapagos.ziggy`
/// — means every asset keeps its verbatim name, so an absent entry is not an
/// error condition anywhere (see `fingerprint.Map`).
///
/// Written ONCE, by `root.zig`'s `computeAssetFingerprints`, before the render
/// pass starts; read-only from then on. That is what makes it safe for the
/// multithreaded render workers to consult without a lock, and it is why the
/// map cannot be filled lazily as assets are referenced.
///
/// Values are gpa-owned and freed in `deinit`.
asset_fingerprints: @import("fingerprint.zig").Map = .empty,
/// Named image variants (#132): filled once by root.zig's planImageVariants
/// before the render pass, read lock-free by the render workers (the
/// asset_fingerprints discipline). Empty unless `image_optimize` is set.
/// Keys' path/name ints are interned in the SourceRef's owning tables
/// (site: Build.st/pt; page: that variant's tables). Values gpa-owned.
image_variants: @import("image/plan.zig").Map = .empty,
i18n_dir: Io.Dir,
// Translation key map. Each entry is a slice with the same length as the
// number of variants.
tks: std.StringHashMapUnmanaged([]?*context.Page) = .empty,
// Site-wide global data, parsed once at build time from `data_dir_path`.
// Keyed by file basename (without the `.ziggy` extension); exposed to
// layouts as `$site.data('<name>')`. Backed by `data_arena`.
site_data: std.StringHashMapUnmanaged(context.Map.ZiggyMap) = .empty,
data_arena: std.heap.ArenaAllocator.State = .{},
mode: Mode,
island_sidecar: ?islands.Sidecar = null,
/// SPAs declared with `--spa=<src>|<base>`, set verbatim from
/// `root.Options.spas` in `Build.load`. Consumed by the release-time
/// prerender pass (`src/spa.zig`'s `prerenderAll`).
spas: []const root.SpaSpec = &.{},
/// Which SPA's "/" shell backs the universal 404.html, named by
/// its `spaName(src)` basename; set verbatim from `root.Options.spa_not_found`
/// in `Build.load`. Null = the first declared SPA (historical default).
spa_not_found: ?[]const u8 = null,
/// Every file path `spa.zig`'s `prerenderAll` wrote to disk this build,
/// relative to the output dir (no leading slash -- the same string shape as
/// `worker.paginationOutputPath` and friends): route shells, `staticPaths`
/// concrete pages, each SPA's `routing-manifest.json`, and the site-wide
/// `404.html`. Populated UNCONDITIONALLY by `prerenderAll` (NOT gated on
/// `--summary`'s `collect`, unlike the `Summary.Category.spa_shell` records),
/// because `root.zig`'s stale-pagination prune needs it on every disk build,
/// not just a `--summary` one: an SPA's prerendered output is not a `Page`
/// and is therefore never in any `Variant.urls` -- the prune's other
/// skip-list -- so without this set the prune could delete a real SPA output
/// that happens to sit at a pagination-shaped path (e.g. a `staticPaths`
/// entry "2" under a base whose sibling section still uses `.page_dir`
/// pagination, probed by the prune's non-current-style sweep). gpa-owned
/// keys (route/manifest paths are allocated from `prerenderAll`'s per-SPA
/// arena, which is gone by the time the prune runs); freed in `deinit`.
spa_out_paths: std.StringHashMapUnmanaged(void) = .empty,
/// Every SPA route URL (browser-facing, e.g. "/app/club/1/" -- NOT the disk
/// output path `spa_out_paths` tracks) that `prerenderAll` prerendered as a
/// REAL page this build: a declared static route, or a `staticPaths`
/// concrete entry. Deliberately excludes a dynamic route's own pattern
/// shell (`_shell.html`): that file exists so an unmatched param has
/// something to render, not because "/app/club/:id" is itself a URL a
/// visitor (or a crawler) can go to. `src/sitemap.zig`'s emitter composes
/// each entry with `host_url` + `url_path_prefix` (issue #150).
///
/// Unlike `spa_out_paths`, nothing else consumes this set, so it is
/// collected only when `cfg.getSitemap()` is true -- a site with the
/// sitemap off pays nothing. gpa-owned; freed in `deinit`.
sitemap_urls: std.ArrayListUnmanaged([]const u8) = .empty,
/// Build-time props-contract check. `island_props_checks` is
/// appended to (mutex-guarded) during the render phase and consumed once after
/// it, in root.run. gpa-owned dups; freed in deinit.
island_props_check_mode: @import("islands/props_check.zig").Mode = .off,
/// See `root.Options.island_sidecar_optional`. Read by worker.zig's renderPage.
island_sidecar_optional: bool = false,
island_props_checks: std.ArrayListUnmanaged(@import("islands/props_check.zig").PropsCheck) = .empty,
island_props_checks_mutex: std.Io.Mutex = .init,
/// Dev-only island-usage collection: (island src, page source
/// path) pairs appended (mutex-guarded) during the render phase, consumed by
/// root.run's writeIslandManifest after it. Only collected when
/// `island_manifest_path` is set (the dev loop's `ZIGAPAGOS_ISLAND_MANIFEST`);
/// release builds pay nothing. gpa-owned dups; freed in deinit.
island_manifest_path: ?[]const u8 = null,
/// The per-site islands runtime slice, resolved ONCE from
/// `zigapagos release --islands-slice=<path>`. A null `url` (the default) means
/// there is no slice: every island page then loads the shared runtime,
/// byte-identically to before. gpa-owned; freed in `deinit`.
islands_slice: @import("islands/slice.zig").Manifest = .{},
island_page_usage: std.ArrayListUnmanaged(@import("islands/manifest.zig").Use) = .empty,
island_page_usage_mutex: std.Io.Mutex = .init,
/// `--allow-missing-pages`, verbatim from `root.Options.allow_missing_pages`.
/// See that field's doc comment for why the tolerance is uniform rather than
/// mode-dependent, and which CLI commands accept it. Consulted at analysis time
/// (`worker.zig`'s `analyzeContent`, the four `unknown_page` sites) and at
/// render time (`context/Site.zig`'s `page` builtin).
allow_missing_pages: bool = false,
/// Dedup state for the `--allow-missing-pages` TEMPLATE-lookup warning
/// (`$site.page(ref)` misses; the content-link path warns inline via
/// `PageAnalysisError` instead, since each dangling `$link.page` site is
/// visited at most once per build). A POINTER field: `context.Root._meta.build`
/// is `*const Build`, and `const` applies to the `Build` struct itself, not
/// through a pointer it holds -- so mutating what this pointer points AT
/// needs no `@constCast`, while a plain (non-pointer) field would be
/// unreachable through a `*const Build` at all. Backed by its OWN allocator
/// (NOT the per-render-job arena, which resets after every page) so a
/// duplicate warning for page 2 is still suppressed after page 1's render job
/// has already reset its arena; guarded by a mutex because the render pass is
/// multithreaded. Always allocated (even when the flag is off) so every call
/// site can dereference it unconditionally. Allocated in `Build.load`, freed
/// in `Build.deinit`.
missing_page_warnings: *context.MissingPage.Warnings,

pub const Mode = union(enum) {
    memory: struct {
        // Errors that don't already have a natural storage location
        // (eg page errors are stored in the page itself)
        errors: std.ArrayListUnmanaged(Error) = .empty,
    },
    disk: struct {
        output_dir: Io.Dir,
    },

    const Error = struct {
        ref: []const u8, // the file this error relates to
        msg: []const u8,
    };
};

pub const Assets = std.AutoArrayHashMapUnmanaged(PathName, std.atomic.Value(u32));
pub const Templates = std.AutoArrayHashMapUnmanaged(PathName, Template);

pub fn deinit(b: *const Build, io: Io, gpa: Allocator) void {
    {
        var dir = b.base_dir;
        dir.close(io);
    }
    b.st.deinit(gpa);
    b.pt.deinit(gpa);
    for (b.variants) |v| v.deinit(io, gpa);
    gpa.free(b.variants);
    {
        var dir = b.layouts_dir;
        dir.close(io);
    }
    for (b.templates.entries.items(.value)) |t| t.deinit(gpa);
    {
        var ts = b.templates;
        ts.deinit(gpa);
    }
    {
        var dir = b.site_assets_dir;
        dir.close(io);
    }
    // Fingerprinted basenames (issue #53): each value is one gpa `allocPrint`
    // from `fingerprint.hashName`. Keys are `PathName`s (plain integers into
    // the string/path tables), so only the values need freeing.
    {
        var fps = b.asset_fingerprints;
        var it = fps.valueIterator();
        while (it.next()) |name| gpa.free(name.*);
        fps.deinit(gpa);
    }
    // Planned image variants (#132): each `Planned.variants` slice and every
    // `Variant.basename` in it is one gpa allocation from `planImageVariants`
    // (`plan.variantBasename` / the planner's own `gpa.alloc`).
    {
        var iv = b.image_variants;
        var it = iv.valueIterator();
        while (it.next()) |planned| {
            for (planned.variants) |v| gpa.free(v.basename);
            gpa.free(planned.variants);
        }
        iv.deinit(gpa);
    }
    switch (b.mode) {
        .memory => |m| {
            // Free the build-level error messages accumulated this build
            // (AUD-004). Every `.msg` is an exact gpa allocation (allocPrint or
            // a Writer.Allocating owned slice); `.ref` is always the "" literal.
            for (m.errors.items) |e| gpa.free(e.msg);
            var errors = m.errors;
            errors.deinit(gpa);
        },
        .disk => |disk| {
            var dir = disk.output_dir;
            dir.close(io);
        },
    }

    // Translation-key table (AUD-004): keys are borrowed from page frontmatter
    // (arena-owned), but each value is a gpa-allocated `[]?*Page` slice sized to
    // the variant count. Free the values, then the map.
    {
        var it = b.tks.valueIterator();
        while (it.next()) |slice| gpa.free(slice.*);
        var tks = b.tks;
        tks.deinit(gpa);
    }

    if (b.cfg.* == .Multilingual) {
        var dir = b.i18n_dir;
        dir.close(io);
    }

    {
        var sd = b.site_data;
        sd.deinit(gpa);
        b.data_arena.promote(gpa).deinit();
    }

    // @constCast: Build.deinit takes *const by convention; Sidecar.deinit must
    // mutate (kills the child process). Blast radius is one line here vs. changing
    // the receiver + all callers in serve/release/debug.
    if (b.island_sidecar) |*sc| @constCast(sc).deinit();
    b.islands_slice.deinit(gpa);

    for (b.island_props_checks.items) |c| {
        gpa.free(c.src);
        gpa.free(c.props_json);
        gpa.free(c.page_url);
        gpa.free(c.island_id);
    }
    {
        var list = b.island_props_checks;
        list.deinit(gpa);
    }

    for (b.island_page_usage.items) |u| {
        gpa.free(u.island_src);
        gpa.free(u.page_path);
    }
    {
        var list = b.island_page_usage;
        list.deinit(gpa);
    }

    // Mirrors island_sidecar above: Build.deinit takes *const by convention,
    // but the dedup set's own gpa-backed storage must be freed and the
    // pointer itself destroyed exactly once per build. `Warnings.deinit` owns
    // freeing the `seen` keys as well as the map: they are gpa-duped on insert
    // precisely because a `ref` can be a render-time-computed string owned by
    // the per-job arena (see MissingPage.Warnings' doc comment).
    b.missing_page_warnings.deinit();
    gpa.destroy(b.missing_page_warnings);

    // spa_out_paths (see its doc comment): every key is a gpa dupe made by
    // spa.zig's recordSpaOutPath, mirroring missing_page_warnings' seen set
    // just above.
    {
        var it = b.spa_out_paths.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        var m = b.spa_out_paths;
        m.deinit(gpa);
    }

    // sitemap_urls (see its doc comment): every entry is a gpa dupe made by
    // spa.zig's recordSitemapUrl.
    {
        for (b.sitemap_urls.items) |u| gpa.free(u);
        var list = b.sitemap_urls;
        list.deinit(gpa);
    }
}

test "Build.island_sidecar defaults to null and deinit tolerates it" {
    // A compile-time contract: verify the field is present and null-initialized.
    // Runtime deinit correctness is proven by Task 7's e2e; the real GREEN signal
    // here is a successful site build with spawn wired through root.run.
    try std.testing.expect(@hasField(Build, "island_sidecar"));
    const def: Build = undefined;
    _ = def; // suppress unused-variable warning; field presence is the contract
}

/// Tries to load a zigapagos.ziggy config file by searching
/// recursivly upwards from cwd. Once the config file is found,
/// it ensures the existence of all required directories.
pub fn load(io: Io, gpa: Allocator, cfg: *const root.Config, opts: root.Options) Build {
    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    const base_dir = Io.Dir.cwd().openDir(
        io,
        opts.base_dir_path,
        .{},
    ) catch |err|
        fatal.dir(opts.base_dir_path, err);

    const layouts_dir = base_dir.createDirPathOpen(
        io,
        cfg.getLayoutsDirPath(),
        .{ .open_options = .{ .iterate = true } },
    ) catch |err| fatal.dir(cfg.getLayoutsDirPath(), err);

    const assets_dir = base_dir.createDirPathOpen(
        io,
        cfg.getAssetsDirPath(),
        .{ .open_options = .{ .iterate = true } },
    ) catch |err| fatal.dir(cfg.getAssetsDirPath(), err);

    var table: StringTable = .empty;
    _ = try table.intern(gpa, "");

    var path_table: PathTable = .empty;
    _ = try path_table.intern(gpa, &.{});

    const mode: Mode = switch (opts.mode) {
        .memory => .{ .memory = .{} },
        .disk => |disk| blk: {
            const output_base_dir = if (disk.output_dir_path == null)
                base_dir
            else
                Io.Dir.cwd();
            const output_dir = output_base_dir.createDirPathOpen(
                io,
                disk.output_dir_path orelse "public",
                .{ .open_options = .{ .iterate = true } },
            ) catch |err| fatal.dir(
                disk.output_dir_path orelse "public",
                err,
            );

            if (disk.check_empty_output) ensureEmpty(
                io,
                output_dir,
                disk.output_dir_path orelse "public",
            );

            break :blk .{ .disk = .{ .output_dir = output_dir } };
        },
    };

    const i18n_dir = switch (cfg.*) {
        .Site => undefined,
        .Multilingual => |ml| base_dir.createDirPathOpen(
            io,
            ml.i18n_dir_path,
            .{ .open_options = .{ .iterate = true } },
        ) catch |err| fatal.dir(ml.i18n_dir_path, err),
    };

    var data_arena = std.heap.ArenaAllocator.init(gpa);
    const site_data = loadSiteData(io, &data_arena, base_dir, cfg.getDataDirPath());

    // Always allocated (see the field's doc comment): every render-time call
    // site dereferences `missing_page_warnings` unconditionally, flag on or
    // off, so there is no null to check. gpa-backed (build lifetime), not the
    // per-render-job arena, which would erase the dedup set on the very next
    // job.
    const missing_page_warnings = try gpa.create(context.MissingPage.Warnings);
    missing_page_warnings.* = .init(gpa);

    return .{
        .cfg = cfg,
        .build_assets = opts.build_assets,
        .base_dir = base_dir,
        .base_dir_path = opts.base_dir_path,
        .layouts_dir = layouts_dir,
        .site_assets_dir = assets_dir,
        .st = table,
        .pt = path_table,
        .mode = mode,
        .i18n_dir = i18n_dir,
        .site_data = site_data,
        .data_arena = data_arena.state,
        .spas = opts.spas,
        .spa_not_found = opts.spa_not_found,
        .allow_missing_pages = opts.allow_missing_pages,
        .missing_page_warnings = missing_page_warnings,
    };
}

/// Scan `data_dir_path` (relative to the project base dir) for `*.ziggy`
/// files and parse each one once into a Ziggy map, keyed by basename. The
/// directory is optional: a missing directory yields an empty map. A malformed
/// data file is a fatal build error (same policy as a malformed `zigapagos.ziggy`).
fn loadSiteData(
    io: Io,
    arena_state: *std.heap.ArenaAllocator,
    base_dir: Io.Dir,
    data_dir_path: []const u8,
) std.StringHashMapUnmanaged(context.Map.ZiggyMap) {
    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    const arena = arena_state.allocator();
    var out: std.StringHashMapUnmanaged(context.Map.ZiggyMap) = .empty;

    var data_dir = base_dir.openDir(io, data_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => fatal.dir(data_dir_path, err),
    };
    defer data_dir.close(io);

    var it = data_dir.iterateAssumeFirstIteration();
    while (it.next(io) catch |err| fatal.dir(data_dir_path, err)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '.') continue;
        const ext = ".ziggy";
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;

        const name = try arena.dupe(u8, entry.name);
        const src = data_dir.readFileAllocOptions(
            io,
            name,
            arena,
            .limited(ziggy.max_size),
            .@"1",
            0,
        ) catch |err| fatal.file(name, err);

        var diag: ziggy.Diagnostic = .{ .path = name };
        const map = ziggy.parseLeaky(context.Map.ZiggyMap, arena, src, .{
            .diagnostic = &diag,
        }) catch {
            fatal.msg(
                \\Error while loading a site data file ('{s}'):
                \\
                \\{f}
                \\
                \\
            , .{ name, diag.fmt(src) });
        };

        const key = name[0 .. name.len - ext.len];
        try out.put(arena, key, map);
    }

    return out;
}

fn ensureEmpty(io: Io, dir: Io.Dir, path: []const u8) void {
    var it = dir.iterateAssumeFirstIteration();
    const next = it.next(io) catch |err| fatal.dir(path, err);
    if (next != null) {
        fatal.msg(
            \\error: the output directory is not empty
            \\
            \\info: the output path:
            \\      {s}
            \\
            \\note: use `-f` or `--force` to output a release in
            \\      a non-empty directory, but be aware that old 
            \\      files will **NOT** be removed!
            \\
            \\
        , .{path});
    }
}

pub fn scanSiteAssets(
    b: *Build,
    io: Io,
    gpa: Allocator,
    arena: Allocator,
) !void {
    const zone = tracy.trace(@src());
    defer zone.end();

    var dir_stack: std.ArrayListUnmanaged([]const u8) = .empty;
    try dir_stack.append(arena, "");

    const empty_path: Path = @enumFromInt(0);
    assert(b.pt.get(&.{}) == empty_path);

    var progress = root.progress.start("Scan assets", 0);
    defer progress.end();

    while (dir_stack.pop()) |dir_entry| {
        var dir = switch (dir_entry.len) {
            0 => b.site_assets_dir,
            else => b.site_assets_dir.openDir(io, dir_entry, .{ .iterate = true }) catch |err| {
                fatal.dir(dir_entry, err);
            },
        };
        defer if (dir_entry.len > 0) dir.close(io);

        var it = dir.iterateAssumeFirstIteration();
        while (it.next(io) catch |err| fatal.dir(dir_entry, err)) |entry| {
            // We do not ignore hidden files in assets for two reasons:
            // - Users might want to install "hidden" files on purpose
            // - Unlike other directories where one could want to place
            //   a directory that doesn't want Zigapagos to recourse into,
            //   assets is the one place where users are not expected
            //   to put anything that isn't an asset ready to be installed
            //   as needed.
            // if (std.mem.startsWith(u8, entry.name, ".")) continue;
            switch (entry.kind) {
                else => continue,
                .file, .sym_link => {
                    progress.completeOne();

                    const name = try b.st.intern(gpa, entry.name);
                    const asset_sub_path = switch (dir_entry.len) {
                        0 => empty_path,
                        else => try b.pt.internPath(
                            gpa,
                            &b.st,
                            dir_entry,
                        ),
                    };

                    const pn: PathName = .{
                        .path = asset_sub_path,
                        .name = name,
                    };

                    try b.site_assets.putNoClobber(gpa, pn, .init(0));
                    // Same key, same statement: the build-time READ counter is
                    // only ever `fetchAdd`-ed from the render workers, never
                    // inserted into, so its key set has to be complete when
                    // the scan ends. Keeping the two puts adjacent is what
                    // guarantees that.
                    try b.site_asset_reads.putNoClobber(gpa, pn, .init(0));
                },
                .directory => {
                    const path_bytes = try std.fs.path.join(arena, &.{
                        dir_entry,
                        entry.name,
                    });
                    try dir_stack.append(arena, path_bytes);
                },
            }
        }
    }
}

pub fn scanTemplates(b: *Build, io: Io, gpa: Allocator, arena: Allocator) !void {
    const zone = tracy.trace(@src());
    defer zone.end();
    var progress = root.progress.start("Scan templates", 0);
    defer progress.end();

    const layouts_dir_path = b.cfg.getLayoutsDirPath();
    log.debug("scanTemplates('{s}')", .{layouts_dir_path});

    var dir_stack: std.ArrayListUnmanaged(struct {
        p: Path,
        path: []const u8,
        templates: bool,
    }) = .empty;
    try dir_stack.append(arena, .{
        .p = @enumFromInt(0),
        .path = "",
        .templates = false,
    });

    while (dir_stack.pop()) |dir_entry| {
        var dir = if (dir_entry.path.len == 0) b.layouts_dir else b.layouts_dir.openDir(
            io,
            dir_entry.path,
            .{ .iterate = true },
        ) catch |err| fatal.dir(dir_entry.path, err);
        defer if (dir_entry.path.len > 0) dir.close(io);

        var dir_it = dir.iterateAssumeFirstIteration();
        while (dir_it.next(io) catch |err| fatal.dir(dir_entry.path, err)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            switch (entry.kind) {
                else => continue,
                .file, .sym_link => {
                    if (std.mem.endsWith(u8, entry.name, ".html")) {
                        std.debug.print("WARNING: found plain HTML file {f}, did you mean to give it a shtml extension?\n", .{
                            root.fmtJoin('/', &.{
                                layouts_dir_path,
                                dir_entry.path,
                                entry.name,
                            }),
                        });
                        continue;
                    }
                    if (std.mem.endsWith(u8, entry.name, ".shtml") or
                        std.mem.endsWith(u8, entry.name, ".xml"))
                    {
                        log.debug("new layout: '{s}'", .{entry.name});
                        progress.completeOne();

                        const str = try b.st.intern(gpa, entry.name);
                        const pn: PathName = .{
                            .path = dir_entry.p,
                            .name = str,
                        };

                        try b.templates.putNoClobber(gpa, pn, .{
                            .layout = !dir_entry.templates,
                        });
                    }
                },
                .directory => {
                    try dir_stack.append(arena, .{
                        .path = try root.join(arena, &.{ dir_entry.path, entry.name }, '/'),
                        .templates = dir_entry.templates or (dir_entry.path.len == 0 and
                            std.mem.eql(u8, entry.name, "templates")),
                        .p = try b.pt.internExtend(
                            gpa,
                            dir_entry.p,
                            try b.st.intern(gpa, entry.name),
                        ),
                    });
                },
            }
        }
    }
}

/// Resolve an image-derivation `SourceRef` to the directory it lives under
/// and the string/path tables that name it there. Both `root.zig`'s
/// `planImageVariants` (planning a variant's name before the render pass
/// needs it) and `image/derive.zig`'s `run` (reading the SAME source again
/// on a cache miss) need this exact triple, decided the exact same way — if
/// the two ever diverged, a derive job would read a DIFFERENT file than the
/// planner hashed, and the cache name would no longer describe the bytes
/// (#147: this used to be a `switch (ref.kind)` copy-pasted into both
/// files, a "must-agree pair that nothing pins").
///
/// NO_SLOP §2.2a contract 3 (caller-buffer): allocates nothing; every field
/// of the returned struct is a borrow of state already owned by `self`.
pub fn resolveImageSourceRef(self: *const Build, ref: @import("image/plan.zig").SourceRef) struct {
    dir: Io.Dir,
    st: *const StringTable,
    pt: *const PathTable,
} {
    return switch (ref.kind) {
        .site => .{ .dir = self.site_assets_dir, .st = &self.st, .pt = &self.pt },
        .page => blk: {
            const v = &self.variants[ref.variant_id];
            break :blk .{ .dir = v.content_dir, .st = &v.string_table, .pt = &v.path_table };
        },
    };
}
