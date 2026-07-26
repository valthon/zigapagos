//! The Bun bundling plumbing shared by `website()`: build assets, the ONE
//! shared client runtime, per-island ESM bundles and per-SPA code-split
//! bundles. Every entry point here appends flags to the `zigapagos release`
//! Run step (`run_zigapagos`) and/or registers install steps.

const std = @import("std");
const api = @import("api.zig");
const validate = @import("validate.zig");

const BuildAsset = api.BuildAsset;
const Island = api.Island;
const Spa = api.Spa;

pub fn addBuildAssets(
    project: *std.Build,
    run_zigapagos: *std.Build.Step.Run,
    build_assets: []const BuildAsset,
) void {
    for (build_assets) |a| {
        run_zigapagos.addArg(project.fmt("--build-asset={s}", .{a.name}));
        run_zigapagos.addFileArg(a.lp);
        if (a.install_always) {
            const install_path = a.install_path orelse std.debug.panic(
                "Build assets '{s}' specifies install_always = true  " ++
                    "but defines no install path.",
                .{a.name},
            );
            run_zigapagos.addArg(project.fmt("--install-always={s}", .{
                install_path,
            }));
        } else if (a.install_path) |ip| {
            run_zigapagos.addArg(project.fmt("--install={s}", .{ip}));
        }
    }
}

/// Bundle the ONE shared runtime via the bundle-island.ts driver and stage it as
/// a build asset at `/zigapagos-runtime.js` — exactly the URL the SSR pass (and
/// every SPA shell) injects. No `--external`: Preact is bundled in. A makefile
/// depfile is produced so Zig's Run cache tracks browser-entry.ts's full
/// transitive closure of TS imports automatically.
///
/// Called once whenever islands OR SPAs are declared: the shared
/// runtime is every SPA's fallback (any SPA whose slice manifest bails to
/// `fallback: true` loads it), and that slice decision is only known at BUILD
/// time (`runtime/scripts/build-spa-runtime.ts`) — configure time can't tell
/// whether an SPA-only site (no islands) will need it, so it's always emitted
/// alongside islands/SPAs rather than gated on `opts.islands.len > 0`.
pub fn addSharedRuntimeAsset(
    project: *std.Build,
    zb: *std.Build,
    run_zigapagos: *std.Build.Step.Run,
    source_maps: bool,
) void {
    // A version stamp listed in the bundle's depfile so a deliberate runtime/bun
    // bump invalidates it (no manual edit needed). Bump the string when the
    // @z/runtime external ABI changes. Same string as `addIslandAssets`'s own
    // stamp (kept separate: each `addWriteFiles()` call is an independent
    // build-graph artifact, and per-island bundles don't need the runtime's).
    const stamp = project.addWriteFiles().add(".version-stamp", "@z/runtime 0.0.0\n");

    const driver = zb.path("runtime/sidecar/bundle-island.ts");

    const bun_rt = project.addSystemCommand(&.{"bun"});
    bun_rt.addFileArg(driver);
    bun_rt.addPrefixedFileArg("--entry=", zb.path("runtime/src/browser-entry.ts"));
    const rt_js = bun_rt.addPrefixedOutputFileArg("--outfile=", "zigapagos-runtime.js");
    _ = bun_rt.addPrefixedDepFileOutputArg("--depfile=", "zigapagos-runtime.d");
    bun_rt.addPrefixedFileArg("--runtime-stamp=", stamp);
    bun_rt.addArgs(&.{"--minify"});
    run_zigapagos.addArg("--build-asset=zigapagos-runtime");
    run_zigapagos.addFileArg(rt_js);
    run_zigapagos.addArg("--install-always=zigapagos-runtime.js");
    // Source map: the driver writes `<mapfile>` and retargets the bundle's
    // `sourceMappingURL` to its basename; stage it next to the runtime so the
    // browser fetches /zigapagos-runtime.js.map.
    if (source_maps) {
        const rt_map = bun_rt.addPrefixedOutputFileArg("--mapfile=", "zigapagos-runtime.js.map");
        bun_rt.addArg("--sourcemap");
        run_zigapagos.addArg("--build-asset=zigapagos-runtime-map");
        run_zigapagos.addFileArg(rt_map);
        run_zigapagos.addArg("--install-always=zigapagos-runtime.js.map");
    }
}

/// Bundle each island via the bundle-island.ts driver and stage it as a build
/// asset at `/islands/<Name>.js` — exactly the URL the SSR pass injects. A
/// makefile depfile is produced alongside each bundle so Zig's Run cache
/// tracks the full transitive closure of TS imports automatically.
/// `website_root` is passed as the cwd for per-island builds so the consumer
/// tsconfig's jsxImportSource drives the JSX transform.
pub fn addIslandAssets(
    project: *std.Build,
    zb: *std.Build,
    run_zigapagos: *std.Build.Step.Run,
    islands: []const Island,
    website_root: std.Build.LazyPath,
    source_maps: bool,
) void {
    // A version stamp listed in every bundle's depfile so a deliberate runtime/bun
    // bump invalidates all bundles in one stroke (no per-island edit). Bump the string
    // when the @z/runtime external ABI changes.
    const stamp = project.addWriteFiles().add(".version-stamp", "@z/runtime 0.0.0\n");

    const driver = zb.path("runtime/sidecar/bundle-island.ts");

    // Dev-only fast refresh: `zigapagos dev` sets
    // ZIGAPAGOS_HOT_ISLANDS=1 in the rebuild command's environment
    // (src/cli/dev.zig's `hot_islands_env` — keep the names in sync; this file
    // cannot import that one), so a dev-loop `zig build` bundles each island
    // with the fast-refresh transform (`--hot`) and an island hot-swap
    // preserves plain useState/useReducer state. Read at CONFIGURE time so the
    // flag lands in the Run step's argv — the zig build cache hashes argv, not
    // the environment, so hot (dev) and plain (release) bundles cache
    // independently and a plain `zig build` stays byte-identical.
    const hot = if (project.graph.environ_map.get("ZIGAPAGOS_HOT_ISLANDS")) |v|
        v.len > 0 and !std.mem.eql(u8, v, "0")
    else
        false;

    // Each island: driver with @z/runtime external (one shared Preact via the
    // import map), cwd = the website root so the consumer tsconfig's
    // jsxImportSource drives the JSX transform. One file per island.
    for (islands) |isl| {
        const name = validate.islandName(isl.src); // basename, final extension stripped
        const bun_isl = project.addSystemCommand(&.{"bun"});
        bun_isl.addFileArg(driver);
        bun_isl.setCwd(website_root);
        // Force production JSX runtime (jsx/jsxs, not jsxDEV): Bun selects the
        // jsx-dev-runtime vs jsx-runtime based on its own NODE_ENV environment
        // variable at build time, not via --define (which only rewrites code).
        bun_isl.setEnvironmentVariable("NODE_ENV", "production");
        if (hot) bun_isl.addArg("--hot");
        bun_isl.addPrefixedFileArg("--entry=", isl.root);
        const isl_js = bun_isl.addPrefixedOutputFileArg("--outfile=", project.fmt("{s}.js", .{name}));
        _ = bun_isl.addPrefixedDepFileOutputArg("--depfile=", project.fmt("{s}.d", .{name}));
        bun_isl.addPrefixedFileArg("--runtime-stamp=", stamp);
        bun_isl.addArgs(&.{ "--external=@z/runtime", "--external=@z/runtime/jsx-runtime" });
        run_zigapagos.addArg(project.fmt("--build-asset=island_{s}", .{name}));
        run_zigapagos.addFileArg(isl_js);
        run_zigapagos.addArg(project.fmt("--install-always=islands/{s}.js", .{name}));
        // Source map: staged at /islands/<name>.js.map next to the bundle.
        if (source_maps) {
            const isl_map = bun_isl.addPrefixedOutputFileArg("--mapfile=", project.fmt("{s}.js.map", .{name}));
            bun_isl.addArg("--sourcemap");
            run_zigapagos.addArg(project.fmt("--build-asset=island_{s}_map", .{name}));
            run_zigapagos.addFileArg(isl_map);
            run_zigapagos.addArg(project.fmt("--install-always=islands/{s}.js.map", .{name}));
        }
    }
}

/// Bundle each SPA entry via the bundle-island.ts driver in CODE-SPLITTING mode
/// (`@z/runtime` kept external so the SPA shares the one Preact instance with any
/// islands on the page). The driver emits the entry chunk (`<name>.js`) plus one
/// content-hashed chunk per lazy `import()` into an output DIRECTORY, and a
/// sidecar `spa-chunks.json` (entry name + lazy-route→chunk map).
///
/// Because a no-lazy SPA's entry is byte-identical to the old single-outfile
/// build, splitting mode is used for every SPA (no configure-time hasLazy check).
///
/// Install: the chunk names are content-hashed and unknown at configure time, so
/// instead of zigapagos's single-file `--build-asset`/`--install-always` path, the
/// whole output directory is installed into `<output_path>/spa` via a native
/// `addInstallDirectory` ordered AFTER `run_zigapagos` (which writes the site;
/// `--force` only skips the empty-output check, it never prunes, so the chunks
/// are not wiped either way — the ordering just avoids racing the writes). Note
/// that because nothing prunes the output tree and chunk names are content-hashed,
/// stale `<name>-<oldhash>.js` chunks from prior rebuilds accumulate under
/// `<output_path>/spa`. `spa-chunks.json` is threaded to the
/// prerender (`--spa-chunks`) for the per-route manifest chunk + modulepreload.
pub fn addSpaAssets(
    project: *std.Build,
    zb: *std.Build,
    run_zigapagos: *std.Build.Step.Run,
    spas: []const Spa,
    website_root: std.Build.LazyPath,
    output_path: []const u8,
    source_maps: bool,
) void {
    const stamp = project.addWriteFiles().add(".spa-version-stamp", "@z/runtime 0.0.0\n");
    const driver = zb.path("runtime/sidecar/bundle-island.ts");
    const rt_driver = zb.path("runtime/scripts/build-spa-runtime.ts");
    for (spas) |s| {
        const name = validate.spaName(s.src);
        const bun = project.addSystemCommand(&.{"bun"});
        bun.setCwd(website_root);
        bun.setEnvironmentVariable("NODE_ENV", "production");
        bun.addFileArg(driver);
        bun.addPrefixedFileArg("--entry=", s.root);
        const outdir = bun.addPrefixedOutputDirectoryArg("--outdir=", project.fmt("spa-{s}", .{name}));
        bun.addArg(project.fmt("--entry-name={s}.js", .{name}));
        const chunks_json = bun.addPrefixedOutputFileArg("--chunks-json=", project.fmt("{s}-chunks.json", .{name}));
        _ = bun.addPrefixedDepFileOutputArg("--depfile=", project.fmt("{s}.d", .{name}));
        bun.addPrefixedFileArg("--runtime-stamp=", stamp);
        bun.addArgs(&.{ "--external=@z/runtime", "--external=@z/runtime/jsx-runtime", "--minify" });
        // Source map: the entry + every code-split chunk get a linked
        // `.map`. They're written into `outdir`, which is installed wholesale
        // below, so they land at /spa/<name>.js.map (+ per-chunk maps) with no
        // extra wiring.
        if (source_maps) bun.addArg("--sourcemap");

        const install = project.addInstallDirectory(.{
            .source_dir = outdir,
            .install_dir = .prefix,
            .install_subdir = project.fmt("{s}/spa", .{output_path}),
        });
        install.step.dependOn(&run_zigapagos.step);
        project.getInstallStep().dependOn(&install.step);

        run_zigapagos.addArg(project.fmt("--spa-chunks={s}", .{s.src}));
        run_zigapagos.addFileArg(chunks_json);

        // Per-deployable runtime slice: a separate driver builds a per-SPA
        // runtime bundle containing ONLY that SPA's used host.* members (or, on
        // any uncertain host usage, emits a fallback manifest ⇒ the SPA uses the
        // shared /zigapagos-runtime.js). The sliced runtime (if any) is installed
        // to /spa/<name>-runtime.js next to the SPA bundle; the slice manifest is
        // threaded to the prerender so spa.zig points this SPA's shell import-map
        // at the per-SPA runtime (sliced) or the shared one (fallback).
        const rt_bun = project.addSystemCommand(&.{"bun"});
        rt_bun.setCwd(website_root);
        rt_bun.setEnvironmentVariable("NODE_ENV", "production");
        rt_bun.addFileArg(rt_driver);
        rt_bun.addPrefixedFileArg("--entry=", s.root);
        rt_bun.addPrefixedFileArg("--spa-entry=", zb.path("runtime/src/spa-entry.ts"));
        rt_bun.addPrefixedFileArg("--host-module=", zb.path("runtime/src/host.ts"));
        rt_bun.addPrefixedFileArg("--ssr-env-module=", zb.path("runtime/src/ssr-env.ts"));
        const rt_outdir = rt_bun.addPrefixedOutputDirectoryArg("--outdir=", project.fmt("spa-rt-{s}", .{name}));
        rt_bun.addArg(project.fmt("--name={s}", .{name}));
        const slice_json = rt_bun.addPrefixedOutputFileArg("--manifest=", project.fmt("{s}-slice.json", .{name}));
        _ = rt_bun.addPrefixedDepFileOutputArg("--depfile=", project.fmt("{s}-rt.d", .{name}));
        rt_bun.addPrefixedFileArg("--runtime-stamp=", stamp);
        rt_bun.addArg("--minify");
        // Source map: a linked map for the sliced per-SPA runtime, written
        // into rt_outdir (installed wholesale below) → /spa/<name>-runtime.js.map.
        if (source_maps) rt_bun.addArg("--sourcemap");

        const rt_install = project.addInstallDirectory(.{
            .source_dir = rt_outdir,
            .install_dir = .prefix,
            .install_subdir = project.fmt("{s}/spa", .{output_path}),
        });
        rt_install.step.dependOn(&run_zigapagos.step);
        project.getInstallStep().dependOn(&rt_install.step);

        run_zigapagos.addArg(project.fmt("--spa-slice={s}", .{s.src}));
        run_zigapagos.addFileArg(slice_json);
    }
}
