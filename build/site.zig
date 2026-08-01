//! The two site-building entry points a consumer's `build.zig` calls:
//! `website()` (the release/SSG pass) and `serve()` (the bundled preview
//! server). Both are re-exported from the root `build.zig`, which passes
//! its own `@This()` as `Zigapagos` so `dependencyFromBuildZig` can find the
//! zigapagos dependency in the consumer's package graph.

const std = @import("std");
const api = @import("api.zig");
const bundles = @import("bundles.zig");
const exe = @import("exe.zig");
const validate = @import("validate.zig");

const Options = api.Options;

/// Builds a Zigapagos website.
pub fn website(comptime Zigapagos: type, project: *std.Build, opts: Options) *std.Build.Step.Run {
    const zigapagos_dep = project.dependencyFromBuildZig(Zigapagos, .{
        .optimize = opts.debug.optimize,
        .scope = opts.debug.scopes,
    });

    const zb = zigapagos_dep.builder;
    const website_root = opts.website_root orelse project.path(".");

    // `.not_found` must name a declared SPA — checked up front,
    // even for a site that declares no SPAs at all (a dangling `.not_found`
    // is a config error either way).
    validate.validateNotFound(opts.spas, opts.not_found);

    // Islands and SPAs need build-time SSR — islands for their hydration markers,
    // SPAs for their prerendered skeletons — but that SSR runs in the Bun sidecar,
    // which this step is handed as `--island-sidecar=` below. Nothing about a
    // site's components is compiled into `zigapagos`: every input is a CLI
    // argument or a bundled asset, and the comptime registry that once had to be
    // linked in retired with the Zig-island path.
    //
    // So a prebuilt binary serves an island site exactly as well as a from-source
    // one, and `zigapagos = .path` is honoured here rather than rejected. It used
    // to panic — the justification outlived the mechanism, and the cost was real:
    // a consumer with a single island had to compile the generator and its whole
    // dependency tree (653 compile steps, 632 of them tree-sitter grammars) to
    // produce a site whose own build work is under a second.
    if (opts.islands.len > 0 or opts.spas.len > 0) {
        validate.validateIslands(opts.islands);
        validate.validateSpas(opts.spas);
    }

    const run_zigapagos = switch (api.resolveZigapagos(project, opts)) {
        .source => if (opts.islands.len > 0 or opts.spas.len > 0)
            // A dedicated exe rather than `zigapagos_dep.artifact(...)` only so the
            // build carries `version_string = "website"`; optimize and scopes already
            // reach the dependency through `dependencyFromBuildZig` above.
            project.addRunArtifact(exe.addZigapagosExe(zb, .{
                .target = zb.graph.host,
                .optimize = opts.debug.optimize,
                .version_string = "website",
                .scopes = opts.debug.scopes,
            }))
        else
            project.addRunArtifact(zigapagos_dep.artifact("zigapagos")),
        .path => |path| project.addSystemCommand(&.{path orelse "zigapagos"}),
    };
    run_zigapagos.setCwd(website_root);
    run_zigapagos.addArg("release");

    const full_output_path = project.pathJoin(&.{
        project.install_prefix,
        opts.output_path,
    });

    if (opts.force) run_zigapagos.addArg("--force");
    if (opts.allow_missing_pages) run_zigapagos.addArg("--allow-missing-pages");
    run_zigapagos.addArg(project.fmt("--output={s}", .{full_output_path}));

    // Minify `.css` site assets during release staging, matching the
    // island/SPA JS minify pass so a zigapagos site ships CSS at the same gzip
    // size a Vite/esbuild build would. Bun is a hard toolchain dependency; the
    // SSG only shells out to the driver when a `.css` site asset is actually
    // staged, and only in this release (disk-mode) path — the in-memory live
    // server (`serve()`) never threads these, so its dev CSS stays verbatim.
    run_zigapagos.addArg("--bun=bun");
    run_zigapagos.addPrefixedFileArg("--css-minify-driver=", zb.path("runtime/sidecar/minify-css.ts"));

    if (opts.islands.len > 0 or opts.spas.len > 0) {
        // The sidecar script lives in the zigapagos dependency's runtime/.
        run_zigapagos.addPrefixedFileArg("--island-sidecar=", zb.path("runtime/sidecar/render.ts"));
        // The zigapagos process runs with cwd = website root (see setCwd above);
        // "." resolves to that root where package.json/node_modules live.
        run_zigapagos.addArg("--island-src-dir=.");
        // The ONE shared runtime: emitted whenever islands OR SPAs
        // are declared, not just islands — see `addSharedRuntimeAsset`.
        bundles.addSharedRuntimeAsset(project, zb, run_zigapagos, opts.source_maps);
        if (opts.islands.len > 0) {
            // Release builds enforce the typed-props contract (fail loudly on mismatch).
            run_zigapagos.addArg("--island-props-check=error");
            // Bundle each island JS file as a build asset.
            bundles.addIslandAssets(project, zb, run_zigapagos, opts.islands, website_root, opts.output_path, opts.source_maps);
        }
        if (opts.spas.len > 0) {
            bundles.addSpaAssets(project, zb, run_zigapagos, opts.spas, website_root, opts.output_path, opts.source_maps);
            for (opts.spas) |s| {
                // `src` never contains '|' (validateSpas already rejects
                // quotes/backslashes in src; '|' is similarly not a valid
                // path character site authors would use) and `base` always
                // starts with '/' (validateSpas asserts this), so
                // `release.zig` can split on the FIRST '|' unambiguously.
                run_zigapagos.addArg(project.fmt("--spa={s}|{s}", .{ s.src, s.base }));
            }
            // Explicit 404 owner: which SPA's "/" shell backs the
            // universal 404.html. Validated above (validateNotFound); the
            // release-time prerender re-checks and picks the shell.
            if (opts.not_found) |nf| {
                run_zigapagos.addArg(project.fmt("--spa-not-found={s}", .{nf}));
            }
        }
    }

    bundles.addBuildAssets(project, run_zigapagos, opts.build_assets);

    if (opts.spas.len > 0 or opts.islands.len > 0) {
        // Translate each namespace's routing-manifest.json (written by the
        // release-time SPA prerender pass) into host-specific server config
        // (nginx/apache/zigbase), keyed by each site's `deploy_target`, AND
        // emit the site-wide strict-CSP artifacts (inline-script sha256 hashes).
        // Islands-only sites have no manifest but still carry an inline
        // importmap, so they need the CSP scan too.
        const emit = project.addSystemCommand(&.{"bun"});
        emit.addFileArg(zb.path("runtime/scripts/emit-host-config.ts"));
        emit.addArg("--site");
        emit.addArg(full_output_path);
        emit.has_side_effects = true;
        emit.setName("emit-host-config");
        emit.step.dependOn(&run_zigapagos.step);
        project.getInstallStep().dependOn(&emit.step);
    }

    return run_zigapagos;
}

/// The bundled preview server: an in-memory build on its own HTTP server,
/// needing no backend, no zigbase binary and no rebuild command. That is what
/// makes it the first thing a new site runs. It cannot serve a real backend
/// (only `--proxy` shims), so prefer `dev()` — the zigbase-backed loop over the
/// real release tree — once the site has one.
///
/// Serves a Zigapagos website via the Zigapagos preview server, allowing you to edit
/// the input files and obtaining instant rebuild and page reload.
/// Currently does not support `--watch` but will in the future.
///
/// Ignores `opts.output_path` as it keeps all generated files in memory.
pub fn serve(comptime Zigapagos: type, project: *std.Build, opts: Options) *std.Build.Step.Run {
    const zigapagos_dep = project.dependencyFromBuildZig(Zigapagos, .{
        .optimize = opts.debug.optimize,
        .scope = opts.debug.scopes,
    });

    const run_zigapagos = switch (api.resolveZigapagos(project, opts)) {
        .source => project.addRunArtifact(zigapagos_dep.artifact("zigapagos")),
        .path => |path| project.addSystemCommand(&.{path orelse "zigapagos"}),
    };

    run_zigapagos.setCwd(opts.website_root orelse project.path("."));

    if (opts.allow_missing_pages) run_zigapagos.addArg("--allow-missing-pages");

    // Same configure-time `.not_found` check as `website()`: the
    // dev server has no universal 404.html to own, but a dangling name is a
    // config error worth failing fast on regardless of which step runs.
    validate.validateNotFound(opts.spas, opts.not_found);

    // Islands AND SPAs both need the render sidecar + shared runtime bundled at
    // dev-server startup, so the sidecar/src-dir/runtime-entry flags are emitted
    // ONCE whenever either is declared (deduped — see serve.zig's startup cache,
    // which builds the shared runtime for an SPA-only site too).
    if (opts.islands.len > 0 or opts.spas.len > 0) {
        // No `.path` rejection here either, for the reason given in `website()`:
        // the sidecar does the SSR and reaches the binary as a flag. This one was
        // the plainer contradiction of the two — the runner above is already
        // obtained through `switch (opts.zigapagos)`, so the code built a
        // prebuilt-binary run step and then refused to let it run.
        run_zigapagos.addArg("--bun=bun");
        run_zigapagos.addPrefixedFileArg("--island-sidecar=", zigapagos_dep.builder.path("runtime/sidecar/render.ts"));
        run_zigapagos.addArg("--island-src-dir=.");
        // Dev/HMR loop stays lenient: --island-props-check defaults to off here.
        run_zigapagos.addPrefixedFileArg("--island-runtime-entry=", zigapagos_dep.builder.path("runtime/src/browser-entry.ts"));
    }
    if (opts.islands.len > 0) {
        for (opts.islands) |isl| run_zigapagos.addArg(project.fmt("--island={s}", .{isl.src}));
    }
    if (opts.spas.len > 0) {
        validate.validateSpas(opts.spas);
        // The dev server bundles SPA entries itself at startup with the SAME
        // code-splitting driver release uses (entry naming + chunks json +
        // splitting), so the LazyPath is threaded in as a flag.
        run_zigapagos.addPrefixedFileArg("--spa-bundle-driver=", zigapagos_dep.builder.path("runtime/sidecar/bundle-island.ts"));
        // `--spa=<src>|<base>`: same encoding release uses (release.zig splits
        // on the first '|'); `src` never contains '|' (validateSpas asserts).
        for (opts.spas) |s| run_zigapagos.addArg(project.fmt("--spa={s}|{s}", .{ s.src, s.base }));
    }

    // Dev-server reverse-proxy rules. `prefix` never contains '=' (it is a URL
    // path) so `serve.zig` splits each value on the FIRST '=' to recover the
    // upstream URL unambiguously (which may itself contain '=' in a query).
    for (opts.proxies) |p| run_zigapagos.addArg(project.fmt("--proxy={s}={s}", .{ p.prefix, p.upstream }));

    bundles.addBuildAssets(project, run_zigapagos, opts.build_assets);

    return run_zigapagos;
}
