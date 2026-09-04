const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const spa_mod = @import("../spa.zig");
const sitemap = @import("../sitemap.zig");
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
    // being the npm path — because that is the one way of running the binary
    // with no project-owned build script to enumerate them in, and because an
    // invocation that DOES pass an explicit (possibly empty) set must keep
    // meaning what it says.
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
    // nothing to notice. The declared base is left empty, which
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

    // SPAs whose CLIENT half this process builds. Gated on `rt_defaults`
    // because the SPA drivers (`bundle-standalone.ts`, `build-spa-runtime.ts`)
    // are paths INTO the shipped runtime tree and there is nowhere else to get
    // them: without it this process cannot bundle a SPA, only prerender one.
    // That is what the `--spa=`-only fixtures under `tests/spa/` rely on — they
    // assert on emitted shells and never load them in a browser, so paying for
    // a client bundle would buy them nothing.
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

    // A SPA shell is executable output, not a prerender-only artifact: every
    // one imports `/spa/<name>.js` and `@z/runtime` resolves to the shared
    // `/zigapagos-runtime.js` when no slice manifest is attached. The npm path
    // above registers both after building them. A project-owned build may
    // register them itself with `--build-asset`, but an explicit `--spa` with
    // neither path used must not leave a deployable-looking tree whose scripts
    // all 404.
    //
    // Check assets registered by THIS invocation rather than looking in the
    // output directory after `root.run`: `--force` deliberately preserves
    // unrelated files, so a stale bundle from an older release could make a
    // filesystem-existence check pass while the current release produced
    // nothing.
    validateSpaClientAssets(gpa, &cmd);

    // Incremental content re-render. `zigapagos dev` sets
    // `ZIGAPAGOS_CHANGED_FILES` (newline-separated base-relative content page
    // paths) when — and only when — every changed file is a content page; the
    // env var is inherited by the rebuild command and so reaches this process
    // even when that command is a project script rather than this binary. When
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

    // `sitemap.xml` (issue #150): a SIBLING pass to the bun-gated host-config
    // block below, not a step inside it -- the design caveat posted to the
    // issue is explicit that a plain content site (no islands, no SPAs,
    // never entering that block's `cmd.islands.len > 0 or cmd.spas.len > 0`
    // gate) is the most common sitemap consumer, and this pass has no bun
    // dependency to gate on in the first place.
    //
    // `changed_files.len == 0` restricts this to a FULL build. Unlike the
    // host-config block (which reads the finished DISK tree and so stays
    // correct across an incremental `zigapagos dev` rebuild for free), this
    // pass reads in-memory `Page`/SPA state -- and SPA prerendering itself
    // is skipped entirely on an incremental rebuild (`root.zig`'s
    // `if (build.mode == .disk and !incremental)` guard), which would make
    // `build.sitemap_urls` silently empty and overwrite a correct sitemap
    // with one missing every SPA route. A full build's set is always
    // complete, so gating on it is what keeps this pass from ever writing a
    // wrong sitemap; the tradeoff is that dev's incremental rebuilds simply
    // leave whatever the last full build wrote.
    if (cfg.getSitemap() and changed_files.len == 0) {
        sitemap.write(io, gpa, &build, build.mode.disk.output_dir) catch |err| fatal.msg(
            "error: emitting sitemap.xml failed: {s}\n",
            .{@errorName(err)},
        );
    }

    // Host config + strict-CSP + Cache-Control artifacts, over the tree that
    // was just written. Same gate as the bundling above and for the same
    // reason: this reads the routing manifests the SPA prerender emitted, and
    // hashes the inline importmap/bootstrap scripts an island page carries —
    // a site with neither has nothing to translate.
    //
    // This runs AFTER `root.run` rather than as part of it because it is a pass
    // over the FINISHED output tree: it globs `**/routing-manifest.json` and
    // `**/*.html` under the output directory, which only exist once the render
    // and install phases have written them.
    if (rt_defaults) |rt| if (cmd.islands.len > 0 or cmd.spas.len > 0) {
        runDriver(io, gpa, cmd.bun_path orelse "bun", ".", &.{
            rt.host_config_emitter,
            "--site",
            cmd.output_dir_path orelse "public",
        }, environ_map) catch |err| fatal.msg(
            "error: emitting host config failed: {s}\n",
            .{@errorName(err)},
        );
    };

    return false;
}

const MissingSpaClientAsset = struct {
    spa_src: []const u8,
    install_path: []u8,
};

/// Return the first browser script a declared SPA references but this release
/// did not register for installation. The returned path is caller-owned.
fn missingSpaClientAsset(
    gpa: Allocator,
    cmd: *const Command,
) Allocator.Error!?MissingSpaClientAsset {
    for (cmd.spas) |sp| {
        const entry_path = try std.fmt.allocPrint(gpa, "spa/{s}.js", .{spa_mod.spaName(sp.src)});
        if (!hasBuildAssetInstallPath(&cmd.build_assets, entry_path)) {
            return .{ .spa_src = sp.src, .install_path = entry_path };
        }
        gpa.free(entry_path);

        // `bundleSpas` always registers the shared runtime even when its slice
        // later wins. A hand-written/external invocation has no slice manifest,
        // so this is exactly the runtime URL its shells emit.
        if (!hasBuildAssetInstallPath(&cmd.build_assets, "zigapagos-runtime.js")) {
            return .{
                .spa_src = sp.src,
                .install_path = try gpa.dupe(u8, "zigapagos-runtime.js"),
            };
        }
    }
    return null;
}

fn hasBuildAssetInstallPath(
    assets: *const std.StringArrayHashMapUnmanaged(BuildAsset),
    wanted: []const u8,
) bool {
    for (assets.values()) |asset| {
        const raw = asset.install_path orelse continue;
        if (std.mem.eql(u8, std.mem.trimStart(u8, raw, "/"), std.mem.trimStart(u8, wanted, "/"))) return true;
    }
    return false;
}

fn validateSpaClientAssets(gpa: Allocator, cmd: *Command) void {
    if (missingSpaClientAsset(gpa, cmd) catch fatal.oom()) |missing| {
        defer gpa.free(missing.install_path);
        fatal.msg(
            "error: SPA '{s}' references '/{s}', but this release did not build or register that client asset.\n" ++
                "  Set ZIGAPAGOS_RUNTIME_DIR to the matching runtime tree so release can bundle the SPA,\n" ++
                "  or register its browser bundle and /zigapagos-runtime.js with --build-asset and\n" ++
                "  --install (or --install-always) for their corresponding output paths.\n" ++
                "  Refusing to emit SPA shells and a routing manifest with missing scripts.\n",
            .{ missing.spa_src, missing.install_path },
        );
    }

    // The generated shells and routing manifest are themselves references to
    // these build assets. `--install-always` assets already start at rc=1, but
    // an external orchestrator may correctly use ordinary `--install`; bumping
    // here makes that declared install happen instead of validating it and then
    // pruning it as apparently unreferenced during root.run's install pass.
    for (cmd.spas) |sp| {
        const entry_path = std.fmt.allocPrint(gpa, "spa/{s}.js", .{spa_mod.spaName(sp.src)}) catch fatal.oom();
        markBuildAssetReferencedByInstallPath(&cmd.build_assets, entry_path);
        gpa.free(entry_path);
        markBuildAssetReferencedByInstallPath(&cmd.build_assets, "zigapagos-runtime.js");
    }
}

fn markBuildAssetReferencedByInstallPath(
    assets: *std.StringArrayHashMapUnmanaged(BuildAsset),
    wanted: []const u8,
) void {
    for (assets.values()) |*asset| {
        const raw = asset.install_path orelse continue;
        if (std.mem.eql(u8, std.mem.trimStart(u8, raw, "/"), std.mem.trimStart(u8, wanted, "/"))) {
            _ = asset.rc.fetchAdd(1, .acq_rel);
            return;
        }
    }
}

/// Environment variable `zigapagos dev` uses to hand this `release` process the
/// set of changed content pages for an incremental rebuild. The
/// value is a newline-separated list of base-relative source paths (e.g.
/// `content/blog/foo.md`). It travels via the environment — not argv — because
/// the dev loop's rebuild command is overridable (anything after `--`, and a
/// project's own `build.sh` is the expected value), and that command owns the
/// `zigapagos release` argv it ultimately runs; the environment is the one
/// channel that rides through it untouched.
pub const changed_files_env = "ZIGAPAGOS_CHANGED_FILES";

/// Environment variable `zigapagos dev` uses to ask this `release` process to
/// write the dev-only island-usage manifest at the given absolute
/// path (see `src/islands/manifest.zig`). Rides through the rebuild command
/// exactly like `changed_files_env`. Unset/empty — every ordinary
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
    /// `--island=SRC` (repeatable): an island entry this command bundles FOR
    /// THE BROWSER itself. The alternative is handing the finished bundle over
    /// as a `--build-asset`, which an external orchestrator can still do; the
    /// two are mutually exclusive per asset name, and colliding with a
    /// `--build-asset` of the same name is a usage error rather than a silent
    /// overwrite. See `bundleIslands`.
    islands: []const []const u8 = &.{},
    /// `--island-runtime-entry=PATH`: the shared client runtime's entry
    /// (`runtime/src/browser-entry.ts`), bundled to `/zigapagos-runtime.js`.
    /// Only read when `islands` is non-empty.
    island_runtime_entry: ?[]const u8 = null,
    /// `--island-bundle-driver=PATH`: the Bun bundling driver
    /// (`runtime/sidecar/bundle-island.ts`). Only read when `islands` is
    /// non-empty; defaulted from the shipped runtime tree otherwise.
    island_bundle_driver: ?[]const u8 = null,
    /// `--css-minify-driver=PATH`: the Bun script that minifies a single `.css`
    /// site asset during the release install phase. Null (the
    /// default, e.g. a hand-written `release` invocation) keeps the historical
    /// verbatim byte-copy. Requires `--bun` to be set as well.
    css_minify_driver: ?[]const u8 = null,
    island_props_check: @import("../islands/props_check.zig").Mode = .off,
    /// `--islands-slice=PATH`: the per-SITE islands runtime slice manifest
    /// (`runtime/scripts/build-islands-runtime.ts`). Normally written by
    /// `sliceIslandsRuntime` and attached here; the flag exists so a manifest
    /// can be supplied directly. Null means no slice, so every island page
    /// loads the shared `/zigapagos-runtime.js`.
    islands_slice: ?[]const u8 = null,
    /// Declared native SPAs. MUTABLE, unlike the other list fields: `bundleSpas`
    /// builds each SPA's client half and then attaches the `chunks_json` and
    /// `slice_json` its drivers just wrote, which the prerender pass reads.
    /// Coerces to the `[]const SpaSpec` `root.Options` takes.
    spas: []root.SpaSpec,
    /// `--spa-not-found=<name>`: the SPA whose "/" shell backs the
    /// universal 404.html, named by its `spaName(src)` basename. Null (the
    /// default) keeps the historical behavior: the FIRST declared SPA.
    spa_not_found: ?[]const u8 = null,
    /// `--source-maps`: emit an external (linked) `.map` beside every minified
    /// island, SPA and runtime bundle and stage it into the output next to its
    /// script (`/islands/<Name>.js.map`, `/spa/<name>.js.map`,
    /// `/zigapagos-runtime.js.map`, …). This is what makes CLIENT-side
    /// symbolication work in production: the browser fetches `<script>.map` and
    /// rewrites minified frames to their original source positions.
    ///
    /// Opt-in and OFF by default: maps expose your original (pre-minification)
    /// sources to anyone who can reach the site, and many deployments prefer to
    /// symbolicate SERVER-side from privately-retained maps. Off keeps the
    /// output byte-identical to a maps-free build.
    source_maps: bool = false,
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
        errdefer build_assets.deinit(gpa);
        var drafts = false;
        var force = false;
        var bun_path: ?[]const u8 = null;
        var island_sidecar: ?[]const u8 = null;
        var island_src_dir: ?[]const u8 = null;
        var islands: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer islands.deinit(gpa);
        var island_runtime_entry: ?[]const u8 = null;
        var island_bundle_driver: ?[]const u8 = null;
        var css_minify_driver: ?[]const u8 = null;
        var island_props_check: @import("../islands/props_check.zig").Mode = .off;
        var islands_slice: ?[]const u8 = null;
        var spas: std.ArrayListUnmanaged(root.SpaSpec) = .empty;
        errdefer spas.deinit(gpa);
        var spa_not_found: ?[]const u8 = null;
        var allow_missing_pages = false;
        var source_maps = false;
        var format: diag.Format = .text;
        var summary = false;

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
                // `<src>|<base>` — `base` is the base the author DECLARES for
                // this SPA (see `root.SpaSpec`), checked at prerender time
                // against the module's own exported `spa.base`. A path
                // containing '|' is not a path anyone writes, so splitting on
                // the FIRST '|' is unambiguous; no '|' at all yields an empty
                // declared base, which `spa.zig` treats as "skip the agreement
                // check" and take the module's own.
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
            } else if (eql(u8, arg, "--source-maps")) {
                source_maps = true;
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

        const owned_islands = try islands.toOwnedSlice(gpa);
        errdefer gpa.free(owned_islands);
        const owned_spas = try spas.toOwnedSlice(gpa);
        errdefer gpa.free(owned_spas);

        return .{
            .output_dir_path = output_dir_path,
            .build_assets = build_assets,
            .drafts = drafts,
            .force = force,
            .bun_path = bun_path,
            .island_sidecar = island_sidecar,
            .island_src_dir = island_src_dir,
            .islands = owned_islands,
            .island_runtime_entry = island_runtime_entry,
            .island_bundle_driver = island_bundle_driver,
            .css_minify_driver = css_minify_driver,
            .island_props_check = island_props_check,
            .islands_slice = islands_slice,
            .spas = owned_spas,
            .spa_not_found = spa_not_found,
            .allow_missing_pages = allow_missing_pages,
            .summary = summary,
            .source_maps = source_maps,
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
    \\  --island=SRC          Bundle this island for the browser (repeatable)
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
    \\  --source-maps         Emit a linked .map next to every island, SPA and
    \\                        runtime bundle (off by default: maps expose your
    \\                        original sources to anyone who can reach the site)
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
/// Not required by any other distribution — a checkout either sets it to its own
/// `runtime/` tree (`site/build.sh` does) or points the `--island-*` flags there
/// one by one, and a hand-built binary has no bundled runtime at all — so it must
/// stay a no-op when absent, empty, or blank: "no bundled runtime".
pub const runtime_dir_env = "ZIGAPAGOS_RUNTIME_DIR";

/// The paths `runtime_dir_env` implies. NO_SLOP.md §2.2a contract 2
/// (owned-result): the caller `deinit`s, and the strings outlive the `Command`
/// fields that borrow them.
///
/// The island trio (`sidecar`, `runtime_entry`, `bundle_driver`) is also exposed
/// as explicit `--island-*` flags, because a checkout legitimately points them at
/// its own working tree. Nothing below it is: those paths are fixed parts of one
/// runtime tree that their drivers require together, nothing would be gained by
/// letting them disagree, and a flag per file would be nine more ways to
/// half-configure a build that has exactly one right answer.
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
    /// `runtime/scripts/build-islands-runtime.ts` — the per-SITE islands runtime
    /// slicer, run over the BUILT island bundles once they all exist.
    islands_runtime_driver: []const u8,
    /// The three modules the islands slicer needs by path: the hydration
    /// auto-init it always includes, and the two barrels it re-exports the
    /// proven-needed union out of.
    islands_module: []const u8,
    index_module: []const u8,
    jsx_module: []const u8,
    /// `runtime/scripts/emit-host-config.ts` — translates each namespace's
    /// routing manifest into host config and writes the site-wide CSP and
    /// Cache-Control artifacts, over the finished output tree.
    host_config_emitter: []const u8,

    pub fn deinit(rd: *const RuntimeDefaults, gpa: Allocator) void {
        gpa.free(rd.sidecar);
        gpa.free(rd.runtime_entry);
        gpa.free(rd.bundle_driver);
        gpa.free(rd.spa_bundle_driver);
        gpa.free(rd.spa_runtime_driver);
        gpa.free(rd.spa_entry);
        gpa.free(rd.host_module);
        gpa.free(rd.ssr_env_module);
        gpa.free(rd.islands_runtime_driver);
        gpa.free(rd.islands_module);
        gpa.free(rd.index_module);
        gpa.free(rd.jsx_module);
        gpa.free(rd.host_config_emitter);
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
    errdefer gpa.free(ssr_env_module);
    const islands_runtime_driver = try std.fs.path.join(gpa, &.{ dir, "scripts", "build-islands-runtime.ts" });
    errdefer gpa.free(islands_runtime_driver);
    const islands_module = try std.fs.path.join(gpa, &.{ dir, "src", "islands.ts" });
    errdefer gpa.free(islands_module);
    const index_module = try std.fs.path.join(gpa, &.{ dir, "src", "index.ts" });
    errdefer gpa.free(index_module);
    const jsx_module = try std.fs.path.join(gpa, &.{ dir, "src", "jsx-runtime.ts" });
    errdefer gpa.free(jsx_module);
    const host_config_emitter = try std.fs.path.join(gpa, &.{ dir, "scripts", "emit-host-config.ts" });
    return .{
        .sidecar = sidecar,
        .runtime_entry = runtime_entry,
        .bundle_driver = bundle_driver,
        .spa_bundle_driver = spa_bundle_driver,
        .spa_runtime_driver = spa_runtime_driver,
        .spa_entry = spa_entry,
        .host_module = host_module,
        .ssr_env_module = ssr_env_module,
        .islands_runtime_driver = islands_runtime_driver,
        .islands_module = islands_module,
        .index_module = index_module,
        .jsx_module = jsx_module,
        .host_config_emitter = host_config_emitter,
    };
}

/// Fill in the island paths that an invocation from a checkout can pass
/// explicitly and an installed, toolchain-free one cannot know, WITHOUT ever
/// overriding an explicit flag — so a checkout that points `--island-sidecar` at
/// its own working tree keeps doing exactly that even with the variable set.
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
/// `.spa.tsx`), as paths relative to it — the entry list an author did not
/// enumerate on the command line, recovered by scanning.
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
/// Only ever called when this binary ships its own runtime tree (see the call
/// sites' `rt_defaults` guard), so an invocation that enumerates its entries is
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
/// bundling run: it is a plain directory, not a cache keyed by its inputs, so
/// nothing but the wipe stops a stale bundle from a PREVIOUS build — an island
/// since renamed or deleted — from reaching the output tree.
const bundle_cache_path = ".zigapagos-cache/bundles";

/// Environment variable asking for fast-refresh island bundles; see
/// `hotIslands`. Defined here rather than in dev.zig because THIS file is the
/// reader, and dev.zig already imports this one (the reverse would be a cycle).
pub const hot_islands_env = "ZIGAPAGOS_HOT_ISLANDS";

/// `src` -> the basename the browser bundle is served under, dropping the
/// directory and the FINAL extension only: `components/Counter.island.tsx` ->
/// `Counter.island`, so the URL is `/islands/Counter.island.js`.
///
/// `src/islands/pass.zig`'s `islandModuleName` derives the same name for the URL
/// it writes into `data-z-module`, and
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
/// a bundle built from an interactive shell would import the dev JSX entry and
/// one built from a CI job with NODE_ENV=production already set would import the
/// production one. Same bytes either way.
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
/// per declared SPA — and register every artifact as an `install_always` build
/// asset.
///
/// WHY THIS EXISTS AT ALL. A page with an island, or a SPA shell, needs two
/// artifacts that come from different places: the SSR'd markup (this process, via
/// the Bun sidecar) and the client bundle (Bun, via `bundle-island.ts`). Nothing
/// else produces the second, so without this the SSR'd markup would ship pointing
/// at a `/islands/<name>.js` or `/spa/<name>.js` that nothing ever wrote: output
/// that renders correctly and then 404s on hydration, which is the worst of the
/// available failure modes because it looks fine in the output tree.
///
/// The bundling itself is not reimplemented here: this shells out to the Bun
/// drivers under `runtime/` and owns only the ORDER (shared runtime, islands, the
/// islands slice over their built bundles, then each SPA and its own slice) and
/// the registration of each output as an `install_always` asset — see
/// `installBundleDir`. Both runtime slices are built: a SPA shell's import map
/// names its sliced runtime by path, and an island page's names
/// `/islands/_runtime.js` the same way, so a tree missing either does not merely
/// ship a bigger runtime — it ships a page whose module specifiers 404.
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
    if (cmd.islands.len > 0) {
        const bundles = try bundleIslands(io, arena, cmd, bun_path, src_dir, cache_abs, &env, hotIslands(environ_map));
        // The slicer needs four paths into the shipped runtime tree and has no
        // flags of its own (see `RuntimeDefaults`), so a build with no runtime
        // tree keeps the documented no-slice default: every island page loads
        // the full shared runtime.
        if (rt) |r| if (!hotIslands(environ_map))
            try sliceIslandsRuntime(io, arena, cmd, r, bundles, bun_path, src_dir, cache_abs, &env);
    }
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
/// Built whenever islands OR SPAs are present: it is
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
    const rt_map = try std.fmt.allocPrint(gpa, "{s}.map", .{rt_out});
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{
        driver,
        try std.fmt.allocPrint(gpa, "--entry={s}", .{runtime_entry}),
        try std.fmt.allocPrint(gpa, "--outfile={s}", .{rt_out}),
        try std.fmt.allocPrint(gpa, "--depfile={s}", .{rt_dep}),
        "--minify",
    });
    // The driver writes `<mapfile>` and retargets the bundle's
    // `sourceMappingURL` to its basename, so staging the map next to the
    // runtime is all it takes for the browser to fetch it.
    if (cmd.source_maps) try argv.appendSlice(gpa, &.{
        try std.fmt.allocPrint(gpa, "--mapfile={s}", .{rt_map}),
        "--sourcemap",
    });
    try runDriver(io, gpa, bun_path, src_dir, argv.items, env);
    try addBundleAsset(gpa, cmd, "zigapagos-runtime", rt_out, "zigapagos-runtime.js");
    if (cmd.source_maps) try addBundleAsset(
        gpa,
        cmd,
        "zigapagos-runtime-map",
        rt_map,
        "zigapagos-runtime.js.map",
    );
}

/// True when the environment asks for fast-refresh island bundles.
///
/// `zigapagos dev` sets ZIGAPAGOS_HOT_ISLANDS=1 in the rebuild command's
/// environment (src/cli/dev.zig's `hot_islands_env`), and since `dev` rebuilds
/// through `zigapagos release`, THIS is the reader that makes island hot-swap
/// work. Note the truthiness rule: a bare `!= null` would make `=0` mean "on".
fn hotIslands(environ_map: *const std.process.Environ.Map) bool {
    const v = environ_map.get(hot_islands_env) orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// One `/islands/<name>.js` per `--island=` entry. Returns each BUILT bundle's
/// absolute path in declaration order — the input `sliceIslandsRuntime` analyses,
/// which is why the order is the command line's and not the filesystem's.
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
) ![]const []const u8 {
    const gpa = arena.a;
    const driver = cmd.island_bundle_driver.?; // checked by bundleSharedRuntime
    var built = try std.ArrayListUnmanaged([]const u8).initCapacity(gpa, cmd.islands.len);
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
        const map = try std.fmt.allocPrint(gpa, "{s}.map", .{out});
        if (cmd.source_maps) try argv.appendSlice(gpa, &.{
            try std.fmt.allocPrint(gpa, "--mapfile={s}", .{map}),
            "--sourcemap",
        });
        try runDriver(io, gpa, bun_path, src_dir, argv.items, env);
        built.appendAssumeCapacity(out);
        try addBundleAsset(
            gpa,
            cmd,
            try std.fmt.allocPrint(gpa, "island_{s}", .{name}),
            out,
            try std.fmt.allocPrint(gpa, "islands/{s}.js", .{name}),
        );
        if (cmd.source_maps) try addBundleAsset(
            gpa,
            cmd,
            try std.fmt.allocPrint(gpa, "island_{s}_map", .{name}),
            map,
            try std.fmt.allocPrint(gpa, "islands/{s}.js.map", .{name}),
        );
    }
    return built.items;
}

/// The per-SITE islands runtime SLICE: a second pass over the bundles
/// `bundleIslands` just wrote, unioning the named `@z/runtime` imports across the
/// islands it can prove safe and emitting a runtime containing only that union
/// plus the hydration auto-init and the JSX-transform names. The manifest names
/// the islands it covers, and `--islands-slice` points a page's import map at the
/// slice iff EVERY island on that page is covered.
///
/// This is a second pass and not a flag on the per-island bundle for the reason
/// the slicer exists: the decision is a property of the whole SET of built
/// bundles, so it cannot be made until the last one is on disk.
///
/// On the FALLBACK decision (no island provably safe) the driver writes a
/// `{"fallback":true}` manifest and NO bundle, so `installBundleDir` installs
/// nothing and every island page keeps the shared `/zigapagos-runtime.js`. The
/// manifest is threaded through either way: it is also what PRUNES a stale
/// `islands/_runtime.js` left by a previous sliced build into the same tree.
///
/// SKIPPED under `ZIGAPAGOS_HOT_ISLANDS` (the `zigapagos dev` loop), by the
/// caller: `browser-entry.ts` publishes `window.__zigapagos_hmr` at module scope
/// and a slice entry does not, so a sliced dev build would silently lose island
/// hot-swap. Payload size is irrelevant on localhost.
///
/// Contract 4 (arena-scoped) — see `bundleClient`.
fn sliceIslandsRuntime(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    rt: RuntimeDefaults,
    bundles: []const []const u8,
    bun_path: []const u8,
    src_dir: []const u8,
    cache_abs: []const u8,
    env: *const std.process.Environ.Map,
) !void {
    const gpa = arena.a;
    const outdir = try std.fmt.allocPrint(gpa, "{s}/islands-rt", .{cache_abs});
    const manifest = try std.fmt.allocPrint(gpa, "{s}/islands-slice.json", .{cache_abs});

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(gpa, rt.islands_runtime_driver);
    for (bundles) |b| try argv.append(gpa, try std.fmt.allocPrint(gpa, "--bundle={s}", .{b}));
    try argv.appendSlice(gpa, &.{
        try std.fmt.allocPrint(gpa, "--islands-module={s}", .{rt.islands_module}),
        try std.fmt.allocPrint(gpa, "--index-module={s}", .{rt.index_module}),
        try std.fmt.allocPrint(gpa, "--jsx-module={s}", .{rt.jsx_module}),
        try std.fmt.allocPrint(gpa, "--outdir={s}", .{outdir}),
        try std.fmt.allocPrint(gpa, "--manifest={s}", .{manifest}),
        try std.fmt.allocPrint(gpa, "--depfile={s}/islands-rt.d", .{cache_abs}),
        "--minify",
    });
    // Written into `outdir`, which is installed wholesale below, so the map
    // lands at /islands/_runtime.js.map with no extra wiring.
    if (cmd.source_maps) try argv.append(gpa, "--sourcemap");
    try runDriver(io, gpa, bun_path, src_dir, argv.items, env);

    try installBundleDir(io, arena, cmd, outdir, "islands_rt", "islands");
    cmd.islands_slice = manifest;
}

/// The client half of every CLI-built SPA: the code-split bundle (entry chunk +
/// one content-hashed chunk per lazy `import()`) and the per-SPA runtime slice,
/// both installed under `/spa/`, plus the two manifests the prerender reads.
///
/// WHY A DIRECTORY IS THE HARD PART. A `.spa.tsx` client bundle is bun's
/// code-splitting mode: `--outdir` plus a `spa-chunks.json` naming the entry and
/// mapping each lazy route to its chunk. The chunk names are content-hashed and
/// so unknowable in advance — but the bundler has already RUN by the time the
/// outputs are registered here, so the names are simply read off the directory
/// and each file becomes an ordinary `install_always` asset
/// (`installBundleDir`). That is why this needs no "install a directory"
/// concept in `root.zig`.
///
/// The two manifests are attached to the specs afterwards; the prerender pass
/// inside `root.run` then reads them for the per-route `modulepreload`, the
/// manifest's `chunks` map and the shell's import map. Attaching them here,
/// before `root.run`, is what keeps the pass order in `src/root.zig` untouched.
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
        const name = spa_mod.spaName(sp.src);

        // 1. The code-split client bundle. `--external=@z/runtime` keeps the SPA
        // on the page's ONE Preact, exactly as an island bundle does.
        const outdir = try std.fmt.allocPrint(gpa, "{s}/spa-{s}", .{ cache_abs, name });
        const chunks_json = try std.fmt.allocPrint(gpa, "{s}/{s}-chunks.json", .{ cache_abs, name });
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.appendSlice(gpa, &.{
            rt.spa_bundle_driver,
            try std.fmt.allocPrint(gpa, "--entry={s}", .{sp.src}),
            try std.fmt.allocPrint(gpa, "--outdir={s}", .{outdir}),
            try std.fmt.allocPrint(gpa, "--entry-name={s}.js", .{name}),
            try std.fmt.allocPrint(gpa, "--chunks-json={s}", .{chunks_json}),
            try std.fmt.allocPrint(gpa, "--depfile={s}/{s}.d", .{ cache_abs, name }),
            "--external=@z/runtime",
            "--external=@z/runtime/jsx-runtime",
            "--minify",
        });
        // The entry and every code-split chunk get a linked `.map`, written
        // into `outdir` — which `installBundleDir` stages wholesale, so they
        // land at /spa/<name>.js.map (+ per-chunk maps) with no extra wiring.
        if (cmd.source_maps) try argv.append(gpa, "--sourcemap");
        try runDriver(io, gpa, bun_path, src_dir, argv.items, env);
        try installBundleDir(io, arena, cmd, outdir, try std.fmt.allocPrint(gpa, "spa_{s}", .{name}), "spa");
        sp.chunks_json = chunks_json;

        // 2. The per-deployable runtime slice. On the SLICED decision this writes
        // `<name>-runtime.js` into its outdir and a manifest naming it; on the
        // FALLBACK decision it writes an empty directory and a
        // `{"fallback":true}` manifest, so the loop below installs nothing and
        // the SPA's shells point at the shared runtime instead. Both outcomes are
        // normal, which is why the empty directory is not an error here.
        const rt_outdir = try std.fmt.allocPrint(gpa, "{s}/spa-rt-{s}", .{ cache_abs, name });
        const slice_json = try std.fmt.allocPrint(gpa, "{s}/{s}-slice.json", .{ cache_abs, name });
        var rt_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try rt_argv.appendSlice(gpa, &.{
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
        });
        if (cmd.source_maps) try rt_argv.append(gpa, "--sourcemap");
        try runDriver(io, gpa, bun_path, src_dir, rt_argv.items, env);
        try installBundleDir(io, arena, cmd, rt_outdir, try std.fmt.allocPrint(gpa, "spa_rt_{s}", .{name}), "spa");
        sp.slice_json = slice_json;
    }
}

/// Register every FILE a driver wrote into `dir` as an `install_always` build
/// asset under `<prefix>/<basename>` — `spa/` for a SPA's chunks and its sliced
/// runtime, `islands/` for the sliced islands runtime. `key` namespaces the asset
/// names so two SPAs cannot collide in the asset map even if they emit a chunk
/// of the same name (they then also install to the same path — content-hashed
/// names mean equal names imply equal bytes).
///
/// A missing or empty directory is not an error: either runtime slicer's FALLBACK
/// decision deliberately writes no bundle at all.
///
/// Subdirectories are ignored rather than walked, because the drivers emit a flat
/// directory (entry, chunks, `.map`s) — a nested file would be a shape the flat
/// `/spa/` and `/islands/` URL spaces have no place for, and silently flattening
/// it would collide.
///
/// Contract 4 (arena-scoped) — see `bundleClient`.
fn installBundleDir(
    io: Io,
    arena: RenderArena,
    cmd: *Command,
    dir: []const u8,
    key: []const u8,
    prefix: []const u8,
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
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name }),
        );
    }
}

/// Register one built bundle as an `install_always` asset. A name already
/// present means the caller passed BOTH
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

test "parse frees partial release command state on allocation failure" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            var cmd = try Command.parse(gpa, &.{
                "--build-asset=a",                  "a.txt",                            "--install=a.txt",
                "--build-asset=b",                  "b.txt",                            "--install=b.txt",
                "--island=components/A.island.tsx", "--island=components/B.island.tsx", "--spa=apps/A.spa.tsx|/a",
                "--spa=apps/B.spa.tsx|/b",
            });
            defer cmd.deinit(gpa);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
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
    // Single `=` token — the path must NOT be read from a following argv word.
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

test "missingSpaClientAsset requires each SPA entry and the shared runtime" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--spa=app/App.spa.tsx|/app"});
    defer cmd.deinit(gpa);

    var missing = (try missingSpaClientAsset(gpa, &cmd)).?;
    try std.testing.expectEqualStrings("app/App.spa.tsx", missing.spa_src);
    try std.testing.expectEqualStrings("spa/App.js", missing.install_path);
    gpa.free(missing.install_path);

    try cmd.build_assets.put(gpa, "app", .{
        .input_path = "zig-out/App.spa.js",
        .install_path = "/spa/App.js",
        .rc = .{ .raw = 0 },
    });
    missing = (try missingSpaClientAsset(gpa, &cmd)).?;
    try std.testing.expectEqualStrings("zigapagos-runtime.js", missing.install_path);
    gpa.free(missing.install_path);

    try cmd.build_assets.put(gpa, "runtime", .{
        .input_path = "zig-out/zigapagos-runtime.js",
        .install_path = "zigapagos-runtime.js",
        .rc = .{ .raw = 0 },
    });
    try std.testing.expect((try missingSpaClientAsset(gpa, &cmd)) == null);

    validateSpaClientAssets(gpa, &cmd);
    try std.testing.expectEqual(@as(u32, 1), cmd.build_assets.get("app").?.rc.raw);
    try std.testing.expectEqual(@as(u32, 1), cmd.build_assets.get("runtime").?.rc.raw);
}

test "parse tolerates a --spa= value with no '|' (empty declared base)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--spa=app/App.spa.tsx"});
    defer cmd.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cmd.spas.len);
    try std.testing.expectEqualStrings("app/App.spa.tsx", cmd.spas[0].src);
    try std.testing.expectEqualStrings("", cmd.spas[0].base);
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

test "parse leaves chunks_json/slice_json null — only bundleSpas attaches them" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{"--spa=app/App.spa.tsx|/app"});
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.spas[0].chunks_json == null);
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
