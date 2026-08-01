const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const spa_mod = @import("../spa.zig");
const diag = @import("../diag.zig");
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;
const RenderArena = @import("../islands/render_arena.zig").RenderArena;

pub fn release(
    io: Io,
    gpa: Allocator,
    args: []const []const u8,
    environ_map: *const std.process.Environ.Map,
) bool {
    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    var cmd: Command = try .parse(gpa, args);
    // Authoritative assignment: main.zig's scanArgv already set diag.format
    // as a stderr-suppression optimisation (before std.Progress/the banners),
    // but Command.parse -- which validates the value and reports a proper
    // usage error on garbage -- is what this build actually honors.
    diag.format = cmd.format;

    // Paths the npm launcher supplies for the runtime tree it ships next to the
    // binary; a no-op everywhere else (see `runtime_dir_env`). Resolved BEFORE
    // `Config.load` only because everything downstream — the sidecar spawn and
    // the island bundling below — reads the filled-in `cmd`.
    var rt_defaults: ?RuntimeDefaults = null;
    defer if (rt_defaults) |*d| d.deinit(gpa);
    if (environ_map.get(runtime_dir_env)) |raw| {
        const dir = std.mem.trim(u8, raw, " \t\r\n");
        if (dir.len != 0) rt_defaults = try runtimeDefaults(gpa, dir);
    }
    applyDefaults(&cmd, rt_defaults);

    // Entries the user did not enumerate. Gated on `rt_defaults` — i.e. on this
    // being the npm path — because that is exactly the case with no configure
    // step to enumerate them, and because a `zig build` invocation passing an
    // explicit (possibly empty) set must keep meaning what it says.
    var discovered_islands: ?[]const []const u8 = null;
    defer if (discovered_islands) |d| {
        for (d) |p| gpa.free(p);
        gpa.free(d);
    };
    if (rt_defaults != null and cmd.islands.len == 0) {
        const d = try discoverEntries(io, gpa, cmd.island_src_dir orelse ".", ".island.tsx");
        if (d.len > 0) {
            discovered_islands = d;
            gpa.free(cmd.islands);
            cmd.islands = d;
        } else gpa.free(d);
    }
    // The same scan for `*.spa.tsx`. A SPA declared in source and not on the
    // command line is otherwise just absent from the output — no error, and
    // nothing to notice — and `build.zig`'s `Spa` list is the enumeration this
    // path has no equivalent of. The declared base is left empty, which
    // `src/spa.zig` reads as "take it from the module's own `spa.base` and skip
    // the agreement check": there is no second place here for it to disagree
    // with, so restating it would only invent a way to be wrong.
    var discovered_spas: ?[]const []const u8 = null;
    defer if (discovered_spas) |d| {
        for (d) |p| gpa.free(p);
        gpa.free(d);
    };
    if (rt_defaults != null and cmd.spas.len == 0) {
        const d = try discoverEntries(io, gpa, cmd.island_src_dir orelse ".", ".spa.tsx");
        discovered_spas = d;
        if (d.len > 0) {
            const specs = try gpa.alloc(root.SpaSpec, d.len);
            for (specs, d) |*sp, src| sp.* = .{ .src = src, .base = "" };
            gpa.free(cmd.spas);
            cmd.spas = specs;
        }
    }

    // SPAs whose CLIENT half this process has to build itself. Same condition,
    // and same reason, as the discovery above: `rt_defaults` is set exactly when
    // this binary was shipped with its runtime tree and no build graph, which is
    // the one case where nobody else produced the bundle. Under `zig build` the
    // specs arrive with `--spa-chunks`/`--spa-slice` already attached to bundles
    // `build/bundles.zig` built, so this stays empty and that path is untouched.
    const cli_spas: []root.SpaSpec = if (rt_defaults != null) cmd.spas else &.{};

    const cfg, const base_dir_path = root.Config.load(io, gpa);

    // Client bundles for every `--island=` and every CLI-built SPA, staged and
    // registered as build assets before `root.run` reaches its install phase —
    // and, for a SPA, before the prerender pass that reads the chunk/slice
    // manifests this produces. Empty (and so a complete no-op) for every `zig
    // build` invocation. The arena outlives `root.run`: defers unwind
    // last-in-first-out, and this one is declared above it.
    var bundle_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer bundle_arena_state.deinit();
    if (cmd.islands.len > 0 or cli_spas.len > 0) bundleClient(
        io,
        RenderArena.from(&bundle_arena_state),
        &cmd,
        cli_spas,
        rt_defaults,
        environ_map,
    ) catch |err| fatal.msg(
        "error: bundling for the browser failed: {s}\n",
        .{@errorName(err)},
    );

    // Incremental content re-render. `zigapagos dev` sets
    // `ZIGAPAGOS_CHANGED_FILES` (newline-separated base-relative content page
    // paths) when — and only when — every changed file is a content page; the
    // env var rides through the intervening `zig build` into this process. When
    // present and non-empty it restricts the render + emit pass to just those
    // pages (see `root.Options.changed_files`). Absent/empty (every ordinary
    // release build, and the dev loop's full-rebuild fallback) = render the
    // whole site.
    const changed_files = parseChangedFiles(gpa, environ_map);
    // Only the outer slice is owned here: the inner path elements are borrowed
    // views into the env-map value (see `parseChangedFiles`), not separate
    // allocations, and `root.run` only reads them (into a local set) rather than
    // taking ownership — so free the backing array, not the elements.
    defer gpa.free(changed_files);

    // Dev-only island-usage manifest. Set only by `zigapagos dev`;
    // borrowed view into the env-map value, read (and written to disk) inside
    // `root.run` before this frame returns.
    const island_manifest_path = parseIslandManifestPath(environ_map);

    worker.start(io);
    defer if (builtin.mode == .Debug) worker.stopWaitAndDeinit(io);

    const build = root.run(io, gpa, &cfg, .{
        .base_dir_path = base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .{
            .disk = .{
                .check_empty_output = !cmd.force,
                .output_dir_path = cmd.output_dir_path,
            },
        },
        .bun_path = cmd.bun_path,
        .island_sidecar = cmd.island_sidecar,
        .island_src_dir = cmd.island_src_dir,
        .css_minify_driver = cmd.css_minify_driver,
        .island_props_check = cmd.island_props_check,
        .islands_slice_json = cmd.islands_slice,
        .spas = cmd.spas,
        .spa_not_found = cmd.spa_not_found,
        .changed_files = changed_files,
        .island_manifest_path = island_manifest_path,
        .allow_missing_pages = cmd.allow_missing_pages,
        .summary = cmd.summary,
    }) catch fatal.oom();

    defer if (builtin.mode == .Debug) build.deinit(io, gpa);

    if (tracy.enable) {
        tracy.frameMarkNamed("waiting for tracy");
        var progress_tracy = root.progress.start("Tracy", 0);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        progress_tracy.end();
    }

    if (build.any_prerendering_error or
        build.any_rendering_error.load(.acquire))
    {
        return true;
    }

    return false;
}

/// Environment variable `zigapagos dev` uses to hand this `release` process the
/// set of changed content pages for an incremental rebuild. The
/// value is a newline-separated list of base-relative source paths (e.g.
/// `content/blog/foo.md`). It travels via the environment — not argv — because
/// the dev loop's rebuild command is the project's own `zig build`, which owns
/// the `zigapagos release` argv; the environment is the one channel that rides
/// through untouched.
pub const changed_files_env = "ZIGAPAGOS_CHANGED_FILES";

/// Environment variable `zigapagos dev` uses to ask this `release` process to
/// write the dev-only island-usage manifest at the given absolute
/// path (see `src/islands/manifest.zig`). Rides through the intervening
/// `zig build` exactly like `changed_files_env`. Unset/empty — every ordinary
/// release build — means no manifest is written or collected: zero effect on
/// release output.
pub const island_manifest_env = "ZIGAPAGOS_ISLAND_MANIFEST";

/// Parses `island_manifest_env` into the manifest's absolute output path.
/// Returns null (→ no manifest, the release default) when the var is unset,
/// empty, or only whitespace; otherwise the trimmed path (a borrowed view
/// into the env-map value).
fn parseIslandManifestPath(
    environ_map: *const std.process.Environ.Map,
) ?[]const u8 {
    const raw = environ_map.get(island_manifest_env) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Parses `changed_files_env` into a slice of base-relative content paths.
/// Returns an empty slice (→ a full render) when the var is unset, empty, or
/// only blank lines. Splits on '\n' and trims surrounding whitespace/`\r` so a
/// trailing newline or CRLF authoring never produces a phantom "" entry.
fn parseChangedFiles(
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) []const []const u8 {
    const raw = environ_map.get(changed_files_env) orelse return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        list.append(gpa, trimmed) catch fatal.oom();
    }
    return list.toOwnedSlice(gpa) catch fatal.oom();
}

pub const Command = struct {
    output_dir_path: ?[]const u8,
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,
    force: bool,
    bun_path: ?[]const u8,
    island_sidecar: ?[]const u8,
    island_src_dir: ?[]const u8,
    /// `--island=SRC` (repeatable): an island entry this command must bundle
    /// FOR THE BROWSER itself, rather than receive pre-bundled as a
    /// `--build-asset`. Empty for every `build.zig`-driven invocation, where
    /// `build/bundles.zig` runs the same driver as its own Run steps (so the
    /// zig build cache tracks each bundle's TS import closure) and hands the
    /// results over as build assets. Non-empty is the toolchain-free path —
    /// an npm install has bun and this binary and no build graph at all — and
    /// the two are mutually exclusive per asset name: colliding with a
    /// `--build-asset` of the same name is a usage error, not a silent
    /// overwrite. See `bundleIslands`.
    islands: []const []const u8 = &.{},
    /// `--island-runtime-entry=PATH`: the shared client runtime's entry
    /// (`runtime/src/browser-entry.ts`), bundled to `/zigapagos-runtime.js`.
    /// Only read when `islands` is non-empty.
    island_runtime_entry: ?[]const u8 = null,
    /// `--island-bundle-driver=PATH`: the Bun bundling driver
    /// (`runtime/sidecar/bundle-island.ts`). The SAME driver `build/bundles.zig`
    /// invokes, so a CLI-bundled island is byte-identical to a `zig build` one.
    /// Only read when `islands` is non-empty.
    island_bundle_driver: ?[]const u8 = null,
    /// `--css-minify-driver=PATH`: the Bun script that minifies a single `.css`
    /// site asset during the release install phase. Null (the
    /// default, e.g. a hand-written `release` invocation) keeps the historical
    /// verbatim byte-copy. Requires `--bun` to be set as well.
    css_minify_driver: ?[]const u8 = null,
    island_props_check: @import("../islands/props_check.zig").Mode = .off,
    /// `--islands-slice=PATH`: the per-SITE islands runtime slice manifest
    /// (`runtime/scripts/build-islands-runtime.ts`). Null (the default, and every
    /// hand-written invocation) means no slice was built, so every island page
    /// loads the shared `/zigapagos-runtime.js` exactly as before. Unlike
    /// `--spa-slice` there is no per-deployable key, so this is a single `=`
    /// token with no second argv word.
    islands_slice: ?[]const u8 = null,
    /// Declared native SPAs. MUTABLE, unlike the other list fields: on the
    /// toolchain-free path `bundleSpas` builds each SPA's client half itself and
    /// then attaches the `chunks_json`/`slice_json` the drivers just wrote, which
    /// is the same information `zig build` supplies up front via `--spa-chunks`
    /// and `--spa-slice`. Coerces to the `[]const SpaSpec` `root.Options` takes.
    spas: []root.SpaSpec,
    /// `--spa-not-found=<name>`: the SPA whose "/" shell backs the
    /// universal 404.html, named by its `spaName(src)` basename. Null (the
    /// default) keeps the historical behavior: the FIRST declared SPA.
    spa_not_found: ?[]const u8 = null,
    /// `--allow-missing-pages`: see `root.Options.allow_missing_pages` for why
    /// the tolerance is not mode-dependent. `dev` has no flag of its own for
    /// it -- put it in the rebuild command after `--`.
    allow_missing_pages: bool = false,
    /// `--format=text|json` (issue #46 / DX-27): text (default) is the
    /// historical multi-line prose; json emits one NDJSON diagnostic per line
    /// on stderr with a stable `code`. See `src/diag.zig`.
    format: diag.Format = .text,
    /// `--summary` (issue #42): print an inventory of the files this build
    /// emitted, grouped by category, on stdout after every pass has run. See
    /// `root.Options.summary`. Off by default — a build that prints a page list
    /// nobody asked for is noise on a 5,000-page site.
    summary: bool = false,

    pub fn deinit(co: *const Command, gpa: Allocator) void {
        gpa.free(co.spas);
        gpa.free(co.islands);
        var ba = co.build_assets;
        ba.deinit(gpa);
    }

    pub fn parse(gpa: Allocator, args: []const []const u8) !Command {
        var output_dir_path: ?[]const u8 = null;
        var build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
        var drafts = false;
        var force = false;
        var bun_path: ?[]const u8 = null;
        var island_sidecar: ?[]const u8 = null;
        var island_src_dir: ?[]const u8 = null;
        var islands: std.ArrayListUnmanaged([]const u8) = .empty;
        var island_runtime_entry: ?[]const u8 = null;
        var island_bundle_driver: ?[]const u8 = null;
        var css_minify_driver: ?[]const u8 = null;
        var island_props_check: @import("../islands/props_check.zig").Mode = .off;
        var islands_slice: ?[]const u8 = null;
        var spas: std.ArrayListUnmanaged(root.SpaSpec) = .empty;
        var spa_not_found: ?[]const u8 = null;
        var allow_missing_pages = false;
        var format: diag.Format = .text;
        var summary = false;
        // src -> spa-chunks.json path. Collected separately because `--spa-chunks`
        // args precede the `--spa=` args, so the specs don't exist yet; attached
        // to the specs after the arg loop.
        var spa_chunks: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        // The map storage is scratch (keys/values are borrowed slices attached to
        // the specs before return); free it on the way out.
        defer spa_chunks.deinit(gpa);
        // src -> per-SPA runtime slice-manifest path. Same late-attach reason as
        // spa_chunks: `--spa-slice` args precede the `--spa=` args.
        var spa_slices: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer spa_slices.deinit(gpa);

        const eql = std.mem.eql;
        const startsWith = std.mem.startsWith;
        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
                fatal.usage(help_message, .{});
            } else if (eql(u8, arg, "-f") or eql(u8, arg, "--force")) {
                force = true;
            } else if (eql(u8, arg, "-o") or eql(u8, arg, "--output")) {
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing argument to '{s}'",
                    .{arg},
                );
                output_dir_path = args[idx];
            } else if (startsWith(u8, arg, "--output=")) {
                output_dir_path = arg["--output=".len..];
            } else if (startsWith(u8, arg, "--bun=")) {
                bun_path = arg["--bun=".len..];
            } else if (startsWith(u8, arg, "--island-sidecar=")) {
                island_sidecar = arg["--island-sidecar=".len..];
            } else if (startsWith(u8, arg, "--island-src-dir=")) {
                island_src_dir = arg["--island-src-dir=".len..];
            } else if (startsWith(u8, arg, "--island-runtime-entry=")) {
                island_runtime_entry = arg["--island-runtime-entry=".len..];
            } else if (startsWith(u8, arg, "--island-bundle-driver=")) {
                island_bundle_driver = arg["--island-bundle-driver=".len..];
            } else if (startsWith(u8, arg, "--island=")) {
                // Order-independent: the `=` is part of the prefix, so
                // `--island=` cannot swallow `--island-sidecar=`,
                // `--island-props-check=` or `--islands-slice=` — each differs
                // from it at the byte where this one requires '='.
                try islands.append(gpa, arg["--island=".len..]);
            } else if (startsWith(u8, arg, "--css-minify-driver=")) {
                css_minify_driver = arg["--css-minify-driver=".len..];
            } else if (startsWith(u8, arg, "--islands-slice=")) {
                islands_slice = arg["--islands-slice=".len..];
            } else if (startsWith(u8, arg, "--island-props-check=")) {
                const v = arg["--island-props-check=".len..];
                island_props_check = @import("../islands/props_check.zig").parseMode(v) orelse {
                    fatal.msg("error: invalid --island-props-check value '{s}' (want off|warn|error)\n", .{v});
                };
            } else if (startsWith(u8, arg, "--spa=")) {
                // `<src>|<base>` — `base` is the DECLARED base restated from
                // `build.zig`'s `Spa.base` (see `root.SpaSpec`); `src` never
                // contains '|' (validated at configure time by
                // `build.zig`'s `validateSpas`), so splitting on the FIRST
                // '|' is unambiguous. No '|' at all (defensive: e.g. a
                // hand-written `--spa=` invocation) yields an empty declared
                // base, which `spa.zig` treats as "skip the agreement check".
                const v = arg["--spa=".len..];
                if (std.mem.indexOfScalar(u8, v, '|')) |i| {
                    try spas.append(gpa, .{ .src = v[0..i], .base = v[i + 1 ..] });
                } else {
                    try spas.append(gpa, .{ .src = v, .base = "" });
                }
            } else if (startsWith(u8, arg, "--spa-not-found=")) {
                // Which SPA's "/" shell backs the universal 404.html, named
                // by its `spaName(src)` basename. Validated
                // against the declared `--spa=` set at prerender time
                // (`src/spa.zig`), where the full spec list is known.
                spa_not_found = arg["--spa-not-found=".len..];
            } else if (startsWith(u8, arg, "--spa-chunks=")) {
                // `--spa-chunks=<src>` followed by the spa-chunks.json path.
                const src = arg["--spa-chunks=".len..];
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing chunks-json path for '--spa-chunks={s}'\n",
                    .{src},
                );
                try spa_chunks.put(gpa, src, args[idx]);
            } else if (startsWith(u8, arg, "--spa-slice=")) {
                // `--spa-slice=<src>` followed by the slice-manifest json path.
                const src = arg["--spa-slice=".len..];
                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing slice-manifest path for '--spa-slice={s}'\n",
                    .{src},
                );
                try spa_slices.put(gpa, src, args[idx]);
            } else if (startsWith(u8, arg, "--build-asset=")) {
                const name = arg["--build-asset=".len..];

                idx += 1;
                if (idx >= args.len) fatal.msg(
                    "error: missing build asset sub-argument for '{s}'",
                    .{name},
                );

                const input_path = args[idx];

                idx += 1;
                var install_path: ?[]const u8 = null;
                var install_always = false;
                if (idx < args.len) {
                    const next = args[idx];
                    if (startsWith(u8, next, "--install=")) {
                        install_path = next["--install=".len..];
                    } else if (startsWith(u8, next, "--install-always=")) {
                        install_always = true;
                        install_path = next["--install-always=".len..];
                    } else {
                        idx -= 1;
                    }
                }

                const gop = try build_assets.getOrPut(gpa, name);
                if (gop.found_existing) fatal.msg(
                    "error: duplicate build asset name '{s}'",
                    .{name},
                );

                gop.value_ptr.* = .{
                    .input_path = input_path,
                    .install_path = install_path,
                    .install_always = install_always,
                    .rc = .{ .raw = @intFromBool(install_always) },
                };
            } else if (eql(u8, arg, "--drafts")) {
                drafts = true;
            } else if (eql(u8, arg, "--allow-missing-pages")) {
                allow_missing_pages = true;
            } else if (eql(u8, arg, "--summary")) {
                summary = true;
            } else if (startsWith(u8, arg, "--format=")) {
                const v = arg["--format=".len..];
                format = diag.parseFormat(v) orelse fatal.usageError(
                    "error: invalid --format value '{s}' (want text|json)\n",
                    .{v},
                );
            } else {
                fatal.msg("error: unexpected cli argument '{s}'\n", .{arg});
            }
        }

        // Attach each SPA's chunk map (parsed separately since `--spa-chunks`
        // precedes `--spa=`).
        for (spas.items) |*sp| {
            if (spa_chunks.get(sp.src)) |p| sp.chunks_json = p;
            if (spa_slices.get(sp.src)) |p| sp.slice_json = p;
        }

        return .{
            .output_dir_path = output_dir_path,
            .build_assets = build_assets,
            .drafts = drafts,
            .force = force,
            .bun_path = bun_path,
            .island_sidecar = island_sidecar,
            .island_src_dir = island_src_dir,
            .islands = try islands.toOwnedSlice(gpa),
            .island_runtime_entry = island_runtime_entry,
            .island_bundle_driver = island_bundle_driver,
            .css_minify_driver = css_minify_driver,
            .island_props_check = island_props_check,
            .islands_slice = islands_slice,
            .spas = try spas.toOwnedSlice(gpa),
            .spa_not_found = spa_not_found,
            .allow_missing_pages = allow_missing_pages,
            .summary = summary,
            .format = format,
        };
    }
};

const help_message =
    \\Usage: zigapagos release [OPTIONS]
    \\
    \\Command specific options:
    \\  --output, -o DIR      Directory where to output the website (default 'public/')
    \\  --force, -f           Ignore presence of other files in the output directory
    \\  --bun=PATH            Path to the Bun executable (default: 'bun' on PATH)
    \\  --island-sidecar=PATH Path to the island render sidecar script
    \\  --island-src-dir=DIR  Island project root (cwd for the Bun sidecar)
    \\  --island=SRC          Bundle this island for the browser (repeatable).
    \\                        Omit under 'zig build', which bundles islands as
    \\                        build-graph steps and passes --build-asset instead
    \\  --island-runtime-entry=PATH  Entry for the shared /zigapagos-runtime.js
    \\  --island-bundle-driver=PATH  Bun script that bundles one island/entry
    \\  --css-minify-driver=PATH  Bun script that minifies .css site assets on
    \\                        install (needs --bun; omit to copy CSS verbatim)
    \\  --island-props-check=MODE  off | warn | error — typecheck island props (default off)
    \\  --islands-slice=PATH  The per-site islands runtime slice manifest; a page
    \\                        whose every island the slice covers loads it instead
    \\                        of the full shared runtime (omit: shared runtime)
    \\  --spa=SRC|BASE        Register a native SPA entry (repeatable); BASE
    \\                        is the declared base, checked against the
    \\                        module's exported spa.base at prerender time
    \\  --spa-not-found=NAME  Which SPA's "/" shell backs the universal
    \\                        404.html, by its file basename sans .spa.tsx
    \\                        (default: the first --spa declared)
    \\  --spa-chunks=SRC PATH Attach a SPA's spa-chunks.json (lazy-route map)
    \\  --spa-slice=SRC PATH  Attach a SPA's per-deployable runtime slice manifest
    \\  --allow-missing-pages Tolerate a dangling $link.page/$site.page reference
    \\                        to a page that doesn't exist YET (emits a real,
    \\                        would-be href + a build-log warning instead of
    \\                        failing the build)
    \\  --format=FORMAT       text (default) | json -- emit diagnostics as
    \\                        NDJSON on stderr with stable error codes; see
    \\                        'zigapagos explain-code'
    \\  --summary             After the build, print on stdout an inventory of
    \\                        the files it emitted, grouped by category (pages,
    \\                        assets, SPA shells and routing manifests)
    // \\  --build-assets FILE    Path to a file containing a list of build assets
    \\  --help, -h            Show this help menu
    \\
    \\
;

/// Environment variable naming the directory that holds the `@z/runtime` tree
/// this binary was shipped alongside — `sidecar/`, `src/` and `scripts/`, i.e.
/// the repository's `runtime/` laid out unchanged.
///
/// WHY AN ENVIRONMENT VARIABLE AND NOT SELF-EXE DISCOVERY. On npm the binary and
/// the runtime sources live in DIFFERENT packages: the binary is in
/// `@zigapagos/cli-<platform>/` (one per host, carrying nothing else) and the
/// sources are in `@zigapagos/cli/`, which is the package that knows where both
/// halves are. Its Node launcher already resolves the binary's path to exec it,
/// so it is the one component that can state this without guessing, and it does
/// (`npm/cli/bin/zigapagos.js`). Walking up from `argv[0]` would have to encode
/// npm's layout — including whether the platform package was hoisted — inside a
/// binary that also ships outside npm.
///
/// Unset for every other distribution (a `zig build` checkout passes the paths
/// explicitly; a hand-built binary has no bundled runtime), where it must stay a
/// no-op: absent, empty, or blank is treated as "no bundled runtime".
pub const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

/// The paths `runtime_dir_env` implies. NO_SLOP.md §2.2a contract 2
/// (owned-result): the caller `deinit`s, and the strings outlive the `Command`
/// fields that borrow them.
///
/// The island trio (`sidecar`, `runtime_entry`, `bundle_driver`) is also exposed
/// as explicit `--island-*` flags, because a checkout legitimately points them at
/// its own working tree. The SPA quintet below is NOT: those five are fixed parts
/// of one runtime tree that the SPA drivers require together, nothing would be
/// gained by letting them disagree, and `zig build` passes its own equivalents
/// through the build graph rather than through this struct.
pub const RuntimeDefaults = struct {
    /// The SELF-CONTAINED sidecar entry, not `render.ts`: a consumer island
    /// imports `@z/runtime` by its bare name, which resolves to nothing in a
    /// tree where the runtime lives inside `@zigapagos/cli` rather than in the
    /// site's own `node_modules`. `standalone.ts` is `render.ts` plus the
    /// module overrides that answer that name. See its module doc.
    sidecar: []const u8,
    runtime_entry: []const u8,
    bundle_driver: []const u8,
    /// The SELF-CONTAINED client-bundler entry, not `bundle-island.ts`, for the
    /// SPA (code-splitting) mode only. The bundle itself keeps `@z/runtime`
    /// external and so resolves nothing — but the driver IMPORTS the SPA entry
    /// in-process to map each lazy route to its chunk, and that import needs the
    /// bare name answered. See `runtime/sidecar/bundle-standalone.ts`.
    spa_bundle_driver: []const u8,
    /// `runtime/scripts/build-spa-runtime.ts` — the per-SPA runtime slicer.
    spa_runtime_driver: []const u8,
    /// The three modules the slicer needs by path: the core SPA runtime entry it
    /// bundles, and the two modules whose members it analyses/redirects.
    spa_entry: []const u8,
    host_module: []const u8,
    ssr_env_module: []const u8,

    pub fn deinit(rd: *const RuntimeDefaults, gpa: Allocator) void {
        gpa.free(rd.sidecar);
        gpa.free(rd.runtime_entry);
        gpa.free(rd.bundle_driver);
        gpa.free(rd.spa_bundle_driver);
        gpa.free(rd.spa_runtime_driver);
        gpa.free(rd.spa_entry);
        gpa.free(rd.host_module);
        gpa.free(rd.ssr_env_module);
    }
};

/// Join `dir` with each bundled-runtime path. Pure string work, so it is
/// testable without a filesystem: whether the files EXIST is not checked here,
/// because a missing one must fail where it is used — `Sidecar.spawn`'s error
/// names the script, and `bundleIslands`/`bundleSpas` name the driver — rather
/// than as a generic complaint about an environment variable the user never set.
pub fn runtimeDefaults(gpa: Allocator, dir: []const u8) Allocator.Error!RuntimeDefaults {
    // Every join is `errdefer`-guarded in declaration order so a failure part-way
    // through frees exactly what was built, rather than leaking the prefix.
    const sidecar = try std.fs.path.join(gpa, &.{ dir, "sidecar", "standalone.ts" });
    errdefer gpa.free(sidecar);
    const runtime_entry = try std.fs.path.join(gpa, &.{ dir, "src", "browser-entry.ts" });
    errdefer gpa.free(runtime_entry);
    const bundle_driver = try std.fs.path.join(gpa, &.{ dir, "sidecar", "bundle-island.ts" });
    errdefer gpa.free(bundle_driver);
    const spa_bundle_driver = try std.fs.path.join(gpa, &.{ dir, "sidecar", "bundle-standalone.ts" });
    errdefer gpa.free(spa_bundle_driver);
    const spa_runtime_driver = try std.fs.path.join(gpa, &.{ dir, "scripts", "build-spa-runtime.ts" });
    errdefer gpa.free(spa_runtime_driver);
    const spa_entry = try std.fs.path.join(gpa, &.{ dir, "src", "spa-entry.ts" });
    errdefer gpa.free(spa_entry);
    const host_module = try std.fs.path.join(gpa, &.{ dir, "src", "host.ts" });
    errdefer gpa.free(host_module);
    const ssr_env_module = try std.fs.path.join(gpa, &.{ dir, "src", "ssr-env.ts" });
    return .{
        .sidecar = sidecar,
        .runtime_entry = runtime_entry,
        .bundle_driver = bundle_driver,
        .spa_bundle_driver = spa_bundle_driver,
        .spa_runtime_driver = spa_runtime_driver,
        .spa_entry = spa_entry,
        .host_module = host_module,
        .ssr_env_module = ssr_env_module,
    };
}

/// Fill in the island paths that a `zig build` invocation always passes
/// explicitly and a toolchain-free one cannot know, WITHOUT ever overriding an
/// explicit flag — so a checkout that points `--island-sidecar` at its own
/// working tree keeps doing exactly that even with the variable set.
///
/// `bun_path` and `island_src_dir` get defaults too, and deliberately not from
/// `defaults`: "bun" (found on `PATH`, which is where `npm i -D bun` puts it for
/// `npm run`/`npx`) and "." (the site root, which is the process cwd for every
/// `zigapagos release`). Both are gated on a sidecar actually being configured,
/// because `root.run` spawns the sidecar only when all three are non-null and a
/// site with no islands must not acquire a bun dependency by accident.
fn applyDefaults(cmd: *Command, defaults: ?RuntimeDefaults) void {
    if (defaults) |d| {
        if (cmd.island_sidecar == null) cmd.island_sidecar = d.sidecar;
        if (cmd.island_runtime_entry == null) cmd.island_runtime_entry = d.runtime_entry;
        if (cmd.island_bundle_driver == null) cmd.island_bundle_driver = d.bundle_driver;
    }
    if (cmd.island_sidecar != null) {
        if (cmd.bun_path == null) cmd.bun_path = "bun";
        if (cmd.island_src_dir == null) cmd.island_src_dir = ".";
    }
}

/// Every file under `src_dir` whose basename ends in `suffix` (`.island.tsx` or
/// `.spa.tsx`), as paths relative to it — the list a `build.zig` would have
/// produced at configure time, recovered by scanning because a toolchain-free
/// install has no configure step.
///
/// WHY THIS IS NOT OPTIONAL POLISH. For an island, the SSR pass and the client
/// bundle come from different places and only the SSR half is automatic: a page
/// that mounts an island gets its markup spliced in with a
/// `data-z-module="/islands/<name>.js"` pointing at a bundle that `--island=` is
/// what asks for. Leave the list empty and the build SUCCEEDS, emitting a page
/// that server-renders correctly and then 404s the moment the browser tries to
/// hydrate it — no error, no warning, and nothing wrong-looking in the output
/// tree. For a SPA the miss is quieter but no more findable: an unlisted
/// `.spa.tsx` is simply not built, and nothing says so. Discovering the entries
/// is what keeps source and output in step without making the user enumerate
/// them.
///
/// Only ever called on the npm path (see the call sites' `rt_defaults` guard), so
/// a `zig build` — where `build/bundles.zig` hands the bundles over as
/// `--build-asset`/`--spa-chunks` and the entry lists are already exact — is
/// untouched.
///
/// NO_SLOP.md §2.2a contract 2 (owned-result): the caller owns the slice and each
/// path in it.
pub fn discoverEntries(
    io: Io,
    gpa: Allocator,
    src_dir: []const u8,
    suffix: []const u8,
) Allocator.Error![]const []const u8 {
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (found.items) |p| gpa.free(p);
        found.deinit(gpa);
    }

    var dir = Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true }) catch
        return found.toOwnedSlice(gpa);
    defer dir.close(io);

    var it = dir.walk(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer it.deinit();

    // A walk error is swallowed per entry rather than failing the build: an
    // unreadable subdirectory somewhere under the site root must not stop a
    // content site from building, and an island that genuinely cannot be read
    // fails loudly at its own bundle step instead.
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, suffix)) continue;
        // Directories that are never authored source. `node_modules` matters
        // most: an npm install puts the runtime's OWN test fixtures there, and
        // several of them are `.island.tsx` files that would otherwise be
        // bundled into the user's site.
        if (containsComponent(entry.path, "node_modules")) continue;
        if (containsComponent(entry.path, ".git")) continue;
        if (containsComponent(entry.path, "zig-out")) continue;
        if (containsComponent(entry.path, ".zig-cache")) continue;
        if (containsComponent(entry.path, ".zigapagos-cache")) continue;
        try found.append(gpa, try gpa.dupe(u8, entry.path));
    }
    return found.toOwnedSlice(gpa);
}

/// Whether any `/`-separated component of `path` equals `name`. A substring test
/// would also match `my-node_modules-notes/`, and a prefix test would miss a
/// nested `packages/x/node_modules/`.
fn containsComponent(path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

/// Where `--island=` bundles are staged. Project-local (not a temp dir) so a
/// failed build leaves the bundles that were produced for inspection, and so
/// two projects built concurrently cannot collide. Wiped at the start of every
/// bundling run: a stale bundle from a PREVIOUS build must never reach the
/// output tree, which is the failure mode `zig build` is immune to by
/// construction (content-addressed cache) and this path is not.
const bundle_cache_path = ".zigapagos-cache/bundles";

/// Environment variable asking for fast-refresh island bundles; see
/// `hotIslands`. Defined here rather than in dev.zig because THIS file is the
/// reader, and dev.zig already imports this one (the reverse would be a cycle).
pub const hot_islands_env = "ZIGAPAGOS_HOT_ISLANDS";

/// `src` -> the basename the browser bundle is served under, dropping the
/// directory and the FINAL extension only: `components/Counter.island.tsx` ->
/// `Counter.island`, so the URL is `/islands/Counter.island.js`.
///
/// Duplicated from `build/validate.zig`'s `islandName` rather than shared: that
/// file is part of the build-system surface `build.zig` exposes to a consumer's
/// `build.zig`, and `src/` cannot import it (nor should the shipped binary
/// depend on the build package). `src/islands/pass.zig`'s `islandModuleName`
/// derives the same name for the URL it writes into `data-z-module`, and
/// `test "parse: --island name matches the module URL pass.zig emits"` below
/// pins the two against each other — a drift here is a 404 on every island.
fn bundleName(src: []const u8) []const u8 {
    var name = src;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[0..dot];
    return name;
}

/// A copy of this process's environment with `NODE_ENV=production` forced.
///
/// The value is load-bearing, not hygiene: Bun picks the `jsx-runtime` vs
/// `jsx-dev-runtime` import from its OWN `NODE_ENV` at transform time (a
/// `--define` only rewrites code, it cannot change that choice), so without this
/// a CLI-built bundle imports the dev JSX entry while a `zig build` one — where
/// `build/bundles.zig` sets the same variable on every bundling Run step —
/// imports the production one. Same bytes, same decision, either way.
///
/// Contract 2 (owned-result): caller `deinit`s.
fn prodEnv(
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) Allocator.Error!std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    const ks = environ_map.keys();
    const vs = environ_map.values();
    for (ks, vs) |k, v| try env.put(k, v);
    try env.put("NODE_ENV", "production");
    return env;
}

/// Run `bun <driver> <args…>` from `cwd`, failing loudly on a non-zero exit.
/// stderr is inherited so Bun's own diagnostic — which is the actionable half of
/// a bundling failure — reaches the build log verbatim instead of being reduced
/// to an error name.
fn runDriver(
    io: Io,
    gpa: Allocator,
    bun_path: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
) !void {
    var args = try std.ArrayList([]const u8).initCapacity(gpa, 1 + argv.len);
    defer args.deinit(gpa);
    args.appendAssumeCapacity(bun_path);
    for (argv) |a| args.appendAssumeCapacity(a);
    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stderr = .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.BundleFailed,
        else => return error.BundleFailed,
    }
}

/// Build the browser half of this site — the shared `/zigapagos-runtime.js`, one
/// `/islands/<name>.js` per `--island=`, and one code-split `/spa/…` directory
/// per CLI-built SPA — and register every artifact as an `install_always` build
/// asset, exactly as `build/bundles.zig` does through the build graph.
///
/// WHY THIS EXISTS AT ALL. A page with an island, or a SPA shell, needs two
/// artifacts that come from different places: the SSR'd markup (this process, via
/// the Bun sidecar) and the client bundle (Bun, via `bundle-island.ts`). Under
/// `zig build` the second is a set of Run steps whose outputs arrive here as
/// `--build-asset` / `--spa-chunks`, which is the right shape there — the zig
/// cache tracks each bundle's TS import closure through a depfile and skips
/// unchanged work. An npm install has bun and this binary and no build graph, so
/// without this the SSR'd markup would ship pointing at a `/islands/<name>.js` or
/// `/spa/<name>.js` that nothing ever wrote: output that renders correctly and
/// then 404s on hydration, which is the worst of the available failure modes
/// because it looks fine in the output tree.
///
/// The drivers, their flags and the install paths are the SAME as
/// `build/bundles.zig`'s, so the two paths produce identical bytes. The bundling
/// itself is not reimplemented anywhere: both paths shell out to the same two Bun
/// drivers, and what differs is only how the outputs are handed to the installer
/// (a build-graph `addInstallDirectory` there, `install_always` assets here — see
/// `installBundleDir`). The ONE thing not reproduced here is the per-SITE islands
/// runtime SLICE (`--islands-slice`), which needs a second pass over the built
/// bundles; its absence is the documented no-slice default — every island page
/// loads the full shared runtime — not a broken build. The per-SPA slice IS
/// reproduced, because a SPA shell's import map names the sliced runtime by path
/// and would 404 without it.
///
/// NO_SLOP.md §2.2a contract 4 (arena-scoped). Justification: every string it
/// produces (asset names, absolute bundle paths, the chunk/slice manifest paths
/// attached to `cmd.spas`) is registered as a borrowed view inside
/// `cmd.build_assets` / `root.Options` and must stay valid until `root.run` has
/// finished the install phase. Freeing them individually would mean tracking a
/// handful of allocations per entry across loops whose only exit is the end of
/// `release`, where the arena is dropped wholesale; `RenderArena` is what keeps a
/// GPA from reaching that pattern by accident. Every helper below inherits this
/// contract for the same reason, and takes `RenderArena` rather than an
/// `Allocator` so it cannot be called with one.
fn bundleClient(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    spas: []root.SpaSpec,
    rt: ?RuntimeDefaults,
    environ_map: *const std.process.Environ.Map,
) !void {
    const gpa = arena.a;
    const bun_path = cmd.bun_path orelse "bun";
    const src_dir = cmd.island_src_dir orelse ".";

    Io.Dir.cwd().deleteTree(io, bundle_cache_path) catch {};
    Io.Dir.cwd().createDirPath(io, bundle_cache_path) catch |err| fatal.msg(
        "error: client bundle cache '{s}': {s}\n",
        .{ bundle_cache_path, @errorName(err) },
    );
    // Absolute, because `--outfile`/`--outdir` are interpreted by bun, whose cwd
    // is `src_dir` rather than this process's.
    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| fatal.msg(
        "error: unable to get current working directory: {s}\n",
        .{@errorName(err)},
    );
    const cache_abs = try std.fs.path.join(gpa, &.{ cwd_path, bundle_cache_path });

    var env = try prodEnv(gpa, environ_map);
    defer env.deinit();

    try bundleSharedRuntime(io, arena, cmd, bun_path, src_dir, cache_abs, &env);
    if (cmd.islands.len > 0)
        try bundleIslands(io, arena, cmd, bun_path, src_dir, cache_abs, &env, hotIslands(environ_map));
    // `rt.?` is safe by construction: the caller only fills `spas` when
    // `rt_defaults` is non-null (see `cli_spas`), because the SPA drivers are
    // paths INTO the shipped runtime tree and there is nowhere else to get them.
    if (spas.len > 0)
        try bundleSpas(io, arena, cmd, spas, rt.?, bun_path, src_dir, cache_abs, &env);
}

/// The ONE shared runtime, at `/zigapagos-runtime.js`: no `--external`, so Preact
/// is bundled in. This is the module an island page's import map points
/// `@z/runtime` at, which is what makes the whole page share ONE Preact instance.
///
/// Built whenever islands OR SPAs are present, matching
/// `build/bundles.zig`'s `addSharedRuntimeAsset` and for the same reason: it is
/// every SPA's fallback, loaded by any SPA whose runtime slice bails to
/// `{"fallback":true}`, and that decision is only known once the slicer has run.
///
/// Contract 4 (arena-scoped) — see `bundleClient`.
fn bundleSharedRuntime(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    bun_path: []const u8,
    src_dir: []const u8,
    cache_abs: []const u8,
    env: *const std.process.Environ.Map,
) !void {
    const gpa = arena.a;
    const driver = cmd.island_bundle_driver orelse fatal.msg(
        "error: building for the browser requires --island-bundle-driver=<path> (runtime/sidecar/bundle-island.ts)\n",
        .{},
    );
    const runtime_entry = cmd.island_runtime_entry orelse fatal.msg(
        "error: building for the browser requires --island-runtime-entry=<path> (runtime/src/browser-entry.ts)\n",
        .{},
    );
    const rt_out = try std.fs.path.join(gpa, &.{ cache_abs, "zigapagos-runtime.js" });
    const rt_dep = try std.fs.path.join(gpa, &.{ cache_abs, "zigapagos-runtime.d" });
    try runDriver(io, gpa, bun_path, src_dir, &.{
        driver,
        try std.fmt.allocPrint(gpa, "--entry={s}", .{runtime_entry}),
        try std.fmt.allocPrint(gpa, "--outfile={s}", .{rt_out}),
        try std.fmt.allocPrint(gpa, "--depfile={s}", .{rt_dep}),
        "--minify",
    }, env);
    try addBundleAsset(gpa, cmd, "zigapagos-runtime", rt_out, "zigapagos-runtime.js");
}

/// True when the environment asks for fast-refresh island bundles.
///
/// `zigapagos dev` sets ZIGAPAGOS_HOT_ISLANDS=1 in the rebuild command's
/// environment (src/cli/dev.zig's `hot_islands_env`), and since `dev` now
/// rebuilds through `zigapagos release` by default, THIS is the reader that
/// makes island hot-swap work. `build/bundles.zig` reads the same variable for
/// the `zig build` path and must keep the same spelling and the same
/// truthiness rule — a bare `!= null` here would make `=0` mean "on" in one
/// path and "off" in the other.
fn hotIslands(environ_map: *const std.process.Environ.Map) bool {
    const v = environ_map.get(hot_islands_env) orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// One `/islands/<name>.js` per `--island=` entry.
/// Contract 4 (arena-scoped) — see `bundleClient`.
fn bundleIslands(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    bun_path: []const u8,
    src_dir: []const u8,
    cache_abs: []const u8,
    env: *const std.process.Environ.Map,
    hot: bool,
) !void {
    const gpa = arena.a;
    const driver = cmd.island_bundle_driver.?; // checked by bundleSharedRuntime
    for (cmd.islands) |src| {
        const name = bundleName(src);
        const out = try std.fmt.allocPrint(gpa, "{s}/{s}.js", .{ cache_abs, name });
        const dep = try std.fmt.allocPrint(gpa, "{s}/{s}.d", .{ cache_abs, name });
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.appendSlice(gpa, &.{
            driver,
            try std.fmt.allocPrint(gpa, "--entry={s}", .{src}),
            try std.fmt.allocPrint(gpa, "--outfile={s}", .{out}),
            try std.fmt.allocPrint(gpa, "--depfile={s}", .{dep}),
            // Kept external so the bundle imports the bare specifier and the
            // page's import map resolves it to the shared runtime above.
            // Inlining it would give the page a SECOND Preact.
            "--external=@z/runtime",
            "--external=@z/runtime/jsx-runtime",
            "--minify",
        });
        // Routes the entry's components through @z/runtime's hot registry, so a
        // dev hot-swap preserves plain useState/useReducer state. Never set for
        // a plain `zigapagos release`, which is what keeps release bundles
        // byte-identical to a hot-free build.
        if (hot) try argv.append(gpa, "--hot");
        try runDriver(io, gpa, bun_path, src_dir, argv.items, env);
        try addBundleAsset(
            gpa,
            cmd,
            try std.fmt.allocPrint(gpa, "island_{s}", .{name}),
            out,
            try std.fmt.allocPrint(gpa, "islands/{s}.js", .{name}),
        );
    }
}

/// The client half of every CLI-built SPA: the code-split bundle (entry chunk +
/// one content-hashed chunk per lazy `import()`) and the per-SPA runtime slice,
/// both installed under `/spa/`, plus the two manifests the prerender reads.
///
/// WHY A DIRECTORY IS THE HARD PART. A `.spa.tsx` client bundle is bun's
/// code-splitting mode: `--outdir` plus a `spa-chunks.json` naming the entry and
/// mapping each lazy route to its chunk. The chunk names are content-hashed, so
/// `build/bundles.zig` — which has to declare its outputs at CONFIGURE time,
/// before anything is built — cannot name them and installs the whole output
/// directory with `addInstallDirectory` instead. Here the bundler has already RUN
/// by the time the outputs are registered, so the names are simply known: the
/// directory is enumerated and each file becomes an ordinary `install_always`
/// asset (`installBundleDir`). That is why this needs no new "install a
/// directory" concept in `root.zig`, and why the refusal this replaces — which
/// cited "this CLI only knows how to register single-file assets" — was reasoning
/// from the build graph's constraint rather than this one's.
///
/// The two manifests are attached to the specs afterwards, which is exactly what
/// `--spa-chunks`/`--spa-slice` do under `zig build`; the prerender pass inside
/// `root.run` then reads them for the per-route `modulepreload`, the manifest's
/// `chunks` map and the shell's import map. Attaching them here, before
/// `root.run`, is what keeps the pass order in `src/root.zig` untouched.
///
/// Contract 4 (arena-scoped) — see `bundleClient`.
fn bundleSpas(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    spas: []root.SpaSpec,
    rt: RuntimeDefaults,
    bun_path: []const u8,
    src_dir: []const u8,
    cache_abs: []const u8,
    env: *const std.process.Environ.Map,
) !void {
    const gpa = arena.a;
    for (spas) |*sp| {
        // Both halves of the same decision made twice — the same usage error
        // `addBundleAsset` reports for `--island=` plus a colliding
        // `--build-asset`. Nothing on this path can have produced a chunks
        // manifest, so a supplied one is a mistake worth naming rather than
        // something to resolve by picking a winner silently.
        if (sp.chunks_json != null or sp.slice_json != null) fatal.msg(
            "error: --spa-chunks/--spa-slice were given for '{s}', but this build has no\n" ++
                "  build graph that could have produced them; drop them and let the CLI bundle it\n",
            .{sp.src},
        );
        const name = spa_mod.spaName(sp.src);

        // 1. The code-split client bundle. `--external=@z/runtime` keeps the SPA
        // on the page's ONE Preact, exactly as an island bundle does.
        const outdir = try std.fmt.allocPrint(gpa, "{s}/spa-{s}", .{ cache_abs, name });
        const chunks_json = try std.fmt.allocPrint(gpa, "{s}/{s}-chunks.json", .{ cache_abs, name });
        try runDriver(io, gpa, bun_path, src_dir, &.{
            rt.spa_bundle_driver,
            try std.fmt.allocPrint(gpa, "--entry={s}", .{sp.src}),
            try std.fmt.allocPrint(gpa, "--outdir={s}", .{outdir}),
            try std.fmt.allocPrint(gpa, "--entry-name={s}.js", .{name}),
            try std.fmt.allocPrint(gpa, "--chunks-json={s}", .{chunks_json}),
            try std.fmt.allocPrint(gpa, "--depfile={s}/{s}.d", .{ cache_abs, name }),
            "--external=@z/runtime",
            "--external=@z/runtime/jsx-runtime",
            "--minify",
        }, env);
        try installBundleDir(io, arena, cmd, outdir, try std.fmt.allocPrint(gpa, "spa_{s}", .{name}));
        sp.chunks_json = chunks_json;

        // 2. The per-deployable runtime slice. On the SLICED decision this writes
        // `<name>-runtime.js` into its outdir and a manifest naming it; on the
        // FALLBACK decision it writes an empty directory and a
        // `{"fallback":true}` manifest, so the loop below installs nothing and
        // the SPA's shells point at the shared runtime instead. Both outcomes are
        // normal, which is why the empty directory is not an error here.
        const rt_outdir = try std.fmt.allocPrint(gpa, "{s}/spa-rt-{s}", .{ cache_abs, name });
        const slice_json = try std.fmt.allocPrint(gpa, "{s}/{s}-slice.json", .{ cache_abs, name });
        try runDriver(io, gpa, bun_path, src_dir, &.{
            rt.spa_runtime_driver,
            try std.fmt.allocPrint(gpa, "--entry={s}", .{sp.src}),
            try std.fmt.allocPrint(gpa, "--spa-entry={s}", .{rt.spa_entry}),
            try std.fmt.allocPrint(gpa, "--host-module={s}", .{rt.host_module}),
            try std.fmt.allocPrint(gpa, "--ssr-env-module={s}", .{rt.ssr_env_module}),
            try std.fmt.allocPrint(gpa, "--outdir={s}", .{rt_outdir}),
            try std.fmt.allocPrint(gpa, "--name={s}", .{name}),
            try std.fmt.allocPrint(gpa, "--manifest={s}", .{slice_json}),
            try std.fmt.allocPrint(gpa, "--depfile={s}/{s}-rt.d", .{ cache_abs, name }),
            "--minify",
        }, env);
        try installBundleDir(io, arena, cmd, rt_outdir, try std.fmt.allocPrint(gpa, "spa_rt_{s}", .{name}));
        sp.slice_json = slice_json;
    }
}

/// Register every FILE a driver wrote into `dir` as an `install_always` build
/// asset under `spa/<basename>`, which is where `build/bundles.zig`'s
/// `addInstallDirectory` puts the same directory. `key` namespaces the asset
/// names so two SPAs cannot collide in the asset map even when they emit a chunk
/// of the same name (they then also install to the same path — content-hashed
/// names mean equal names imply equal bytes, which is exactly what the build
/// graph's two `addInstallDirectory` calls into one `spa/` already do).
///
/// A missing or empty directory is not an error: the runtime slicer's FALLBACK
/// decision deliberately writes no bundle at all.
///
/// Subdirectories are ignored rather than walked, because the drivers emit a flat
/// directory (entry, chunks, `.map`s) — a nested file would be a shape neither
/// this nor `addInstallDirectory`'s flat `/spa/` URL space has a place for, and
/// silently flattening it would collide.
///
/// Contract 4 (arena-scoped) — see `bundleClient`.
fn installBundleDir(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    dir: []const u8,
    key: []const u8,
) !void {
    const gpa = arena.a;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        try addBundleAsset(
            gpa,
            cmd,
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ key, entry.name }),
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, entry.name }),
            try std.fmt.allocPrint(gpa, "spa/{s}", .{entry.name}),
        );
    }
}

/// Register one CLI-built bundle under the same asset name and install path
/// `build/bundles.zig` uses. A name already present means the caller passed BOTH
/// `--island=` and a `--build-asset` for the same island — the two halves of the
/// same decision made twice — which is a usage error rather than something to
/// resolve by picking a winner silently.
fn addBundleAsset(
    gpa: Allocator,
    cmd: *Command,
    name: []const u8,
    input_path: []const u8,
    install_path: []const u8,
) Allocator.Error!void {
    const gop = try cmd.build_assets.getOrPut(gpa, name);
    if (gop.found_existing) fatal.msg(
        "error: --island already provides build asset '{s}'; drop the matching --build-asset\n",
        .{name},
    );
    gop.value_ptr.* = .{
        .input_path = input_path,
        .install_path = install_path,
        .install_always = true,
        .rc = .{ .raw = 1 },
    };
}

test "parseChangedFiles: unset env → empty (full render)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const changed = parseChangedFiles(gpa, &env);
    defer gpa.free(changed);
    try std.testing.expectEqual(@as(usize, 0), changed.len);
}

test "parseChangedFiles: newline-separated paths, blank/CRLF lines dropped" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // A trailing newline and a stray blank line must not yield phantom "" entries;
    // a '\r' (CRLF authoring) is trimmed.
    try env.put(changed_files_env, "content/a.md\ncontent/b/c.smd\r\n\ncontent/d.markdown\n");
    const changed = parseChangedFiles(gpa, &env);
    defer gpa.free(changed);
    try std.testing.expectEqual(@as(usize, 3), changed.len);
    try std.testing.expectEqualStrings("content/a.md", changed[0]);
    try std.testing.expectEqualStrings("content/b/c.smd", changed[1]);
    try std.testing.expectEqualStrings("content/d.markdown", changed[2]);
}

test "parseChangedFiles: only-blank value → empty (full render)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(changed_files_env, "\n  \n\r\n");
    const changed = parseChangedFiles(gpa, &env);
    defer gpa.free(changed);
    try std.testing.expectEqual(@as(usize, 0), changed.len);
}

test "parseIslandManifestPath: unset/empty/blank → null (no manifest)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try std.testing.expect(parseIslandManifestPath(&env) == null);
    try env.put(island_manifest_env, "");
    try std.testing.expect(parseIslandManifestPath(&env) == null);
    try env.put(island_manifest_env, "  \t\r\n");
    try std.testing.expect(parseIslandManifestPath(&env) == null);
}

test "parseIslandManifestPath: value passthrough (trimmed)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(island_manifest_env, " /site/.zigbase/islands-manifest.json\n");
    try std.testing.expectEqualStrings(
        "/site/.zigbase/islands-manifest.json",
        parseIslandManifestPath(&env).?,
    );
}

test "parse recognizes the island sidecar args" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{ "--bun=/usr/bin/bun", "--island-sidecar=runtime/sidecar/render.ts", "--island-src-dir=." });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("/usr/bin/bun", cmd.bun_path.?);
    try std.testing.expectEqualStrings("runtime/sidecar/render.ts", cmd.island_sidecar.?);
    try std.testing.expectEqualStrings(".", cmd.island_src_dir.?);
}

test "parse recognizes --css-minify-driver (and defaults it to null)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--css-minify-driver=runtime/sidecar/minify-css.ts"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("runtime/sidecar/minify-css.ts", cmd.css_minify_driver.?);

    var cmd_default = try Command.parse(gpa, &.{});
    defer cmd_default.deinit(gpa);
    try std.testing.expect(cmd_default.css_minify_driver == null);
}

test "parse recognizes --islands-slice" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--islands-slice=/cache/islands-slice.json"});
    defer cmd.deinit(gpa);
    // Single `=` token: unlike --spa-slice there is no per-deployable key, so
    // the path must NOT be read from a following argv word.
    try std.testing.expectEqualStrings("/cache/islands-slice.json", cmd.islands_slice.?);
}

test "parse leaves islands_slice null when --islands-slice is absent" {
    // Null is the no-slicing decision: every island page loads the shared
    // runtime, byte-identically to before the slicer existed.
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--force"});
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.islands_slice == null);
}

test "parse recognizes --island-props-check" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--island-props-check=error"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@import("../islands/props_check.zig").Mode.err, cmd.island_props_check);
}

test "parse collects repeated --spa= args" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{ "--spa=app/App.spa.tsx|/app", "--spa=admin/Admin.spa.tsx|/admin" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), cmd.spas.len);
    try std.testing.expectEqualStrings("app/App.spa.tsx", cmd.spas[0].src);
    try std.testing.expectEqualStrings("/app", cmd.spas[0].base);
    try std.testing.expectEqualStrings("admin/Admin.spa.tsx", cmd.spas[1].src);
    try std.testing.expectEqualStrings("/admin", cmd.spas[1].base);
}

test "parse tolerates a --spa= value with no '|' (empty declared base)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--spa=app/App.spa.tsx"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cmd.spas.len);
    try std.testing.expectEqualStrings("app/App.spa.tsx", cmd.spas[0].src);
    try std.testing.expectEqualStrings("", cmd.spas[0].base);
}

test "parse attaches --spa-chunks and --spa-slice to the matching spec" {
    const gpa = std.testing.allocator;
    // `--spa-chunks`/`--spa-slice` precede `--spa=` (mirrors build.zig arg order).
    var cmd = try Command.parse(gpa, &.{
        "--spa-chunks=app/App.spa.tsx", "/cache/App-chunks.json",
        "--spa-slice=app/App.spa.tsx",  "/cache/App-slice.json",
        "--spa=app/App.spa.tsx|/app",
    });
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cmd.spas.len);
    try std.testing.expectEqualStrings("/cache/App-chunks.json", cmd.spas[0].chunks_json.?);
    try std.testing.expectEqualStrings("/cache/App-slice.json", cmd.spas[0].slice_json.?);
}

test "parse recognizes --spa-not-found (and defaults it to null)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{ "--spa=app/App.spa.tsx|/app", "--spa-not-found=App" });
    defer cmd.deinit(gpa);
    try std.testing.expectEqualStrings("App", cmd.spa_not_found.?);

    var cmd_default = try Command.parse(gpa, &.{"--spa=app/App.spa.tsx|/app"});
    defer cmd_default.deinit(gpa);
    try std.testing.expect(cmd_default.spa_not_found == null);
}

test "parse leaves slice_json null when no --spa-slice is given" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--spa=app/App.spa.tsx|/app"});
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.spas[0].slice_json == null);
}

test "parse recognizes --summary (and defaults it to false)" {
    // Issue #42. The default matters as much as the flag: a `zig build website`
    // that started printing a page inventory nobody asked for would be a
    // regression on every site with more than a handful of pages.
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--summary"});
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.summary);

    var cmd_default = try Command.parse(gpa, &.{"--force"});
    defer cmd_default.deinit(gpa);
    try std.testing.expect(!cmd_default.summary);
}

test "parse recognizes --allow-missing-pages (and defaults it to false)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--allow-missing-pages"});
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.allow_missing_pages);

    var cmd_default = try Command.parse(gpa, &.{});
    defer cmd_default.deinit(gpa);
    try std.testing.expect(!cmd_default.allow_missing_pages);
}

test "parse defaults spas to empty" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), cmd.spas.len);
}

test "parse recognizes --format=json (and defaults to text)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--format=json"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(diag.Format.json, cmd.format);

    var cmd_default = try Command.parse(gpa, &.{});
    defer cmd_default.deinit(gpa);
    try std.testing.expectEqual(diag.Format.text, cmd_default.format);
}

test "discoverEntries finds *.island.tsx and skips the trees that are not authored source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for ([_][]const u8{ "components", "deep/nested", "node_modules/@z/runtime/test/fixtures", ".git", "app" }) |d| {
        var sub = try tmp.dir.createDirPathOpen(io, d, .{});
        sub.close(io);
    }
    // Two genuine entries, at different depths.
    try tmp.dir.writeFile(io, .{ .sub_path = "components/Counter.island.tsx", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deep/nested/Panel.island.tsx", .data = "" });
    // A fixture inside node_modules. An npm install really does put `.island.tsx`
    // files there (the runtime ships its own test fixtures), and bundling one into
    // the user's site would be a silent, wrong inclusion — this is the case the
    // component-wise skip list exists for.
    try tmp.dir.writeFile(io, .{
        .sub_path = "node_modules/@z/runtime/test/fixtures/Clock.island.tsx",
        .data = "",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/Hook.island.tsx", .data = "" });
    // Neither of these is an island entry, and the second is the one a naive
    // `indexOf(".island.tsx")` would wrongly accept.
    try tmp.dir.writeFile(io, .{ .sub_path = "components/helper.tsx", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "components/Counter.island.tsx.bak", .data = "" });
    // A SPA entry, which the island scan must NOT pick up (and vice versa): the
    // two suffixes select disjoint sets, and mixing them would hand a `.spa.tsx`
    // to the island bundler.
    try tmp.dir.writeFile(io, .{ .sub_path = "app/App.spa.tsx", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const found = try discoverEntries(io, gpa, abs, ".island.tsx");
    defer {
        for (found) |p| gpa.free(p);
        gpa.free(found);
    }

    try std.testing.expectEqual(@as(usize, 2), found.len);
    var saw_counter = false;
    var saw_panel = false;
    for (found) |p| {
        if (std.mem.eql(u8, p, "components/Counter.island.tsx")) saw_counter = true;
        if (std.mem.eql(u8, p, "deep/nested/Panel.island.tsx")) saw_panel = true;
    }
    try std.testing.expect(saw_counter);
    try std.testing.expect(saw_panel);

    const spas = try discoverEntries(io, gpa, abs, ".spa.tsx");
    defer {
        for (spas) |p| gpa.free(p);
        gpa.free(spas);
    }
    try std.testing.expectEqual(@as(usize, 1), spas.len);
    try std.testing.expectEqualStrings("app/App.spa.tsx", spas[0]);
}

test "discoverEntries returns empty rather than failing when the dir is absent" {
    const gpa = std.testing.allocator;
    // A site with no island/SPA source dir is the common case, not an error: the
    // caller must get an empty list so `release` skips bundling entirely.
    const found = try discoverEntries(std.testing.io, gpa, "definitely-not-a-directory-xyz", ".island.tsx");
    defer gpa.free(found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "containsComponent matches whole path components only" {
    // A substring test would skip `my-node_modules-notes/`, and a prefix test
    // would miss a nested one — both are wrong in a way that silently changes
    // which islands get bundled.
    try std.testing.expect(containsComponent("a/node_modules/b/X.island.tsx", "node_modules"));
    try std.testing.expect(containsComponent("node_modules/X.island.tsx", "node_modules"));
    try std.testing.expect(!containsComponent("my-node_modules-notes/X.island.tsx", "node_modules"));
    try std.testing.expect(!containsComponent("src/node_modulesish/X.island.tsx", "node_modules"));
}
