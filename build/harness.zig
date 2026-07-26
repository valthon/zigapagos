//! The two zigbase-backed harness steps a consumer's `build.zig` calls —
//! `e2e()` (serve the release tree with the stock ZigBase binary and run a
//! browser driver against it) and `dev()` (the same, plus a watch/rebuild
//! loop) — together with their option structs. Both are re-exported from the
//! root `build.zig`, which passes its own `@This()` as `Zigapagos` so
//! `dependencyFromBuildZig` can find the zigapagos dependency.

const std = @import("std");
const api = @import("api.zig");

const Options = api.Options;

/// Options for the `e2e()` harness step.
pub const E2eOptions = struct {
    /// Fallback command when `zig build e2e` is invoked without trailing args.
    /// `zig build e2e -- <cmd> [args…]` always takes precedence. When both are
    /// empty the step fails at run time with usage guidance.
    default_cmd: []const []const u8 = &.{},
    /// Path polled for readiness; the server is "ready" at the FIRST 200, so
    /// drivers never hand-roll polling. Point it at a page the site actually
    /// serves — e.g. "/app/" for a site whose only content is an SPA at /app.
    ready_path: []const u8 = "/",
    /// How long the readiness poll may take before the step fails.
    timeout_ms: u32 = 120_000,
    /// ZigBase data directory. null (the default) = a fresh temp dir per run,
    /// deleted on teardown, so e2e runs are hermetic. Point it at a seeded
    /// directory to run against fixtures.
    data_dir: ?[]const u8 = null,
    /// Explicit zigbase binary. null (the default) = `zigbase` on PATH, then
    /// the pinned release in the zigapagos cache (`src/cli/zigbase.zig`,
    /// `pinned_version`). Never downloaded implicitly; when nothing is found
    /// the step fails with instructions (or downloads iff `download_zigbase`).
    zigbase_path: ?[]const u8 = null,
    /// Opt-in: when the locator finds no zigbase anywhere, download the
    /// pinned GitHub release into the zigapagos cache (SHA256-verified
    /// against the release's published SHA256SUMS) and use it. Off by
    /// default — nothing is ever fetched without this explicit opt-in.
    download_zigbase: bool = false,
    /// Overrides the `zigbase serve` invocation template. The default is the
    /// VERIFIED stock CLI (zigbase src/cli.zig; values are space-separated
    /// tokens — the real parser does no '=' splitting):
    ///   serve --http-host {host} --http-port {port} --data-dir {data} --serve-static {site}
    /// with `{host}`/`{port}`/`{site}`/`{data}` substituted at run time
    /// (e2e always substitutes `127.0.0.1` for `{host}`). Override the
    /// FULL argv (subcommand included) only for custom ZigBase embedder
    /// builds (e.g. ones that compile static serving out).
    zigbase_args: []const []const u8 = &.{},
};

/// The supported SPA e2e workflow (one step instead of hand-rolled
/// orchestration), production-faithful: the RELEASE output tree is served by
/// the STOCK ZigBase binary — real same-origin API, `.spa`-marker SPA
/// fallback — not the dev server.
///
/// ```zig
/// // opts must carry the SAME output_path as your website() call: the
/// // harness serves that installed tree.
/// const e2e_step = b.step("e2e", "Run e2e tests against the served site");
/// e2e_step.dependOn(&zigapagos.e2e(b, .{ .output_path = "site" }, .{}).step);
/// ```
///
/// `zig build e2e -- npx playwright test` then:
///  1. builds + installs the full release output (the step depends on the
///     project's install step, so SPA chunks and host-config artifacts like
///     the `.spa` marker are on disk),
///  2. locates zigbase (PATH → pinned cache; see E2eOptions.zigbase_path) and
///     boots `zigbase serve` over the tree on a FREE port,
///  3. waits for readiness = the first successful shell fetch
///     (`GET ready_path` polled until 200),
///  4. runs the user command with the origin exported as `ZIGAPAGOS_ORIGIN`
///     (e.g. `http://127.0.0.1:49213`) and its output streaming through,
///  5. tears zigbase down (on success, failure, or signal) and propagates the
///     command's exit code as the step result.
///
/// Any browser driver works by reading `ZIGAPAGOS_ORIGIN`; see
/// `docs/spa.md` § "End-to-End Testing".
pub fn e2e(
    comptime Zigapagos: type,
    project: *std.Build,
    opts: Options,
    e2e_opts: E2eOptions,
) *std.Build.Step.Run {
    const zigapagos_dep = project.dependencyFromBuildZig(Zigapagos, .{
        .optimize = opts.debug.optimize,
        .scope = opts.debug.scopes,
    });

    // The plain zigapagos binary suffices: `zigapagos e2e` only orchestrates
    // (no SSR), so unlike website()/serve() no from-source island registry is
    // needed even for island/SPA sites.
    const run_zigapagos = switch (opts.zigapagos) {
        .source => project.addRunArtifact(zigapagos_dep.artifact("zigapagos")),
        .path => |path| project.addSystemCommand(&.{path orelse "zigapagos"}),
    };
    run_zigapagos.setName("zigapagos e2e");
    // The command (playwright etc.) runs with this cwd, where its config lives.
    run_zigapagos.setCwd(opts.website_root orelse project.path("."));
    // Always execute (never cached), stream zigbase's and the driver's output
    // live, and fail the step when the child (and thus zigapagos) exits
    // non-zero.
    run_zigapagos.stdio = .inherit;
    // Production-faithful: serve the installed release tree, so the FULL
    // install must have happened (website()'s run step alone doesn't cover
    // the SPA chunk dirs or the emit-host-config artifacts — notably the
    // `.spa` marker zigbase reads).
    run_zigapagos.step.dependOn(project.getInstallStep());

    const full_output_path = project.pathJoin(&.{
        project.install_prefix,
        opts.output_path,
    });

    run_zigapagos.addArg("e2e");
    run_zigapagos.addArg(project.fmt("--site={s}", .{full_output_path}));
    if (e2e_opts.data_dir) |d| run_zigapagos.addArg(project.fmt("--data-dir={s}", .{d}));
    if (e2e_opts.zigbase_path) |p| run_zigapagos.addArg(project.fmt("--zigbase={s}", .{p}));
    if (e2e_opts.download_zigbase) run_zigapagos.addArg("--download-zigbase");
    for (e2e_opts.zigbase_args) |a| run_zigapagos.addArg(project.fmt("--zigbase-arg={s}", .{a}));
    run_zigapagos.addArg(project.fmt("--ready-path={s}", .{e2e_opts.ready_path}));
    run_zigapagos.addArg(project.fmt("--timeout-ms={d}", .{e2e_opts.timeout_ms}));

    // Everything after `--` is the user command, verbatim. An empty command is
    // rejected by zigapagos AT RUN TIME with usage guidance — a configure-time
    // panic here would break every unrelated `zig build` invocation.
    run_zigapagos.addArg("--");
    const argv = if (project.args) |args| args else e2e_opts.default_cmd;
    for (argv) |a| run_zigapagos.addArg(a);

    return run_zigapagos;
}

/// Options for the `dev()` zigbase-backed dev-loop step.
pub const DevOptions = struct {
    /// ZigBase data directory. null (the default) = `.zigbase/` under the
    /// website root. PERSISTENT: collections/auth state survive across dev
    /// sessions (delete the directory for a fresh backend), so gitignore it.
    data_dir: ?[]const u8 = null,
    /// Explicit zigbase binary. null (the default) = `zigbase` on PATH, then
    /// the pinned release in the zigapagos cache (`src/cli/zigbase.zig`).
    /// Never downloaded behind your back; when nothing is found the step
    /// fails with instructions (or downloads iff `download_zigbase`).
    zigbase_path: ?[]const u8 = null,
    /// Opt-in: when the locator finds no zigbase anywhere, download the
    /// pinned GitHub release into the zigapagos cache (SHA256-verified
    /// against the release's published SHA256SUMS) and use it. Off by
    /// default — nothing is ever fetched without this explicit opt-in.
    download_zigbase: bool = false,
    /// Overrides the `zigbase serve` invocation template (the FULL argv,
    /// subcommand included; `{host}`/`{port}`/`{site}`/`{data}` substituted).
    /// The default is the shared e2e template plus `--insecure-cookies`
    /// (plain-HTTP local dev — Secure auth cookies would never round-trip).
    zigbase_args: []const []const u8 = &.{},
    /// Path polled for readiness (first 200 = ready).
    ready_path: []const u8 = "/",
    /// How long the readiness poll may take before the step fails.
    timeout_ms: u32 = 120_000,
    /// Listening address; must be an IP literal (the probe connects to it).
    host: []const u8 = "127.0.0.1",
    /// Listening port. 0 = pick a free port at boot (printed to the console).
    port: u16 = 1990,
    /// Quiet window after a file change before the rebuild fires.
    debounce_ms: u16 = 25,
    /// Browser live reload: after each rebuild, a dev-only SSE
    /// side channel tells connected browsers to reload (and a small snippet is
    /// injected into the served — never the release — HTML). On by default;
    /// set false for release-fidelity testing.
    live_reload: bool = true,
    /// SSE reload-server port. 0 (the default) = pick a free port at boot
    /// (printed to the console). Ignored when `live_reload` is false.
    reload_port: u16 = 0,
    /// Overrides the rebuild command. Empty (the default) = `<zig> build`
    /// (the project's install step: site render + island/SPA bundles +
    /// host-config emit; already-cached steps are skipped, so unrelated
    /// edits rebuild incrementally). NOTE: rebuilding into the same output
    /// tree requires `Options.force = true` on your `website()` call.
    rebuild_cmd: []const []const u8 = &.{},
    /// Extra directories to watch, relative to the website root. Island/SPA
    /// source dirs are derived automatically from `Options.islands`/`spas`;
    /// list anything else the build reads here (e.g. a vendored assets dir).
    extra_watch_dirs: []const []const u8 = &.{},
};

/// The zigbase-backed local dev loop: `zig build dev` builds the site's
/// RELEASE output, serves it with the STOCK ZigBase binary (real same-origin
/// `/api`, admin UI, `.spa`-marker fallback — production-faithful, no
/// `--proxy` shims), watches the site's inputs (content/layouts/assets +
/// island/SPA sources), and re-runs the build on change. Supersedes the
/// deprecated `serve()` live server.
///
/// ```zig
/// // opts must carry the SAME output_path as your website() call: the dev
/// // loop rebuilds + serves that installed tree (which is why website()
/// // needs .force = true).
/// const dev_step = b.step("dev", "Serve the site with ZigBase, rebuilding on change");
/// dev_step.dependOn(&zigapagos.dev(b, .{ .output_path = "site" }, .{}).step);
/// ```
///
/// Live reload (DEV-ONLY): after each rebuild, connected browsers
/// auto-reload via a dev-only SSE side channel + a snippet injected into the
/// served HTML (release output is never touched); disable with
/// `DevOptions.live_reload = false`. The ZigBase data dir is PERSISTENT (see
/// `DevOptions.data_dir`): collections/auth state survive across sessions.
pub fn dev(
    comptime Zigapagos: type,
    project: *std.Build,
    opts: Options,
    dev_opts: DevOptions,
) *std.Build.Step.Run {
    const zigapagos_dep = project.dependencyFromBuildZig(Zigapagos, .{
        .optimize = opts.debug.optimize,
        .scope = opts.debug.scopes,
    });

    // The plain zigapagos binary suffices: `zigapagos dev` only orchestrates
    // (watch + spawn the rebuild command + boot zigbase); the rebuild command
    // is the project's own `zig build`, which compiles the from-source
    // island/SPA registry itself when needed.
    const run_zigapagos = switch (opts.zigapagos) {
        .source => project.addRunArtifact(zigapagos_dep.artifact("zigapagos")),
        .path => |path| project.addSystemCommand(&.{path orelse "zigapagos"}),
    };
    run_zigapagos.setName("zigapagos dev");
    run_zigapagos.setCwd(opts.website_root orelse project.path("."));
    // Always execute, stream zigbase's + the rebuild command's output live.
    run_zigapagos.stdio = .inherit;

    const full_output_path = project.pathJoin(&.{
        project.install_prefix,
        opts.output_path,
    });

    run_zigapagos.addArg("dev");
    run_zigapagos.addArg(project.fmt("--site={s}", .{full_output_path}));
    if (dev_opts.data_dir) |d| run_zigapagos.addArg(project.fmt("--data-dir={s}", .{d}));
    if (dev_opts.zigbase_path) |p| run_zigapagos.addArg(project.fmt("--zigbase={s}", .{p}));
    if (dev_opts.download_zigbase) run_zigapagos.addArg("--download-zigbase");
    for (dev_opts.zigbase_args) |a| run_zigapagos.addArg(project.fmt("--zigbase-arg={s}", .{a}));
    run_zigapagos.addArg(project.fmt("--ready-path={s}", .{dev_opts.ready_path}));
    run_zigapagos.addArg(project.fmt("--timeout-ms={d}", .{dev_opts.timeout_ms}));
    run_zigapagos.addArg(project.fmt("--host={s}", .{dev_opts.host}));
    run_zigapagos.addArg(project.fmt("--port={d}", .{dev_opts.port}));
    run_zigapagos.addArg(project.fmt("--debounce={d}", .{dev_opts.debounce_ms}));
    if (!dev_opts.live_reload) run_zigapagos.addArg("--no-live-reload");
    if (dev_opts.reload_port != 0) run_zigapagos.addArg(project.fmt("--reload-port={d}", .{dev_opts.reload_port}));

    // Watch the island/SPA source directories (the config-derived content/
    // layouts/assets dirs are discovered by `zigapagos dev` itself). A source
    // at the website root would make the watch dir "." — which contains
    // zig-out and would retrigger every rebuild — so it is skipped here; use
    // `extra_watch_dirs` with a narrower directory instead.
    var watch_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (opts.islands) |isl| if (std.fs.path.dirname(isl.src)) |d| appendUniqueWatchDir(project, &watch_dirs, d);
    for (opts.spas) |s| if (std.fs.path.dirname(s.src)) |d| appendUniqueWatchDir(project, &watch_dirs, d);
    for (dev_opts.extra_watch_dirs) |d| appendUniqueWatchDir(project, &watch_dirs, d);
    for (watch_dirs.items) |d| run_zigapagos.addArg(project.fmt("--watch-dir={s}", .{d}));

    // Everything after `--` is the rebuild command, verbatim.
    run_zigapagos.addArg("--");
    if (dev_opts.rebuild_cmd.len > 0) {
        for (dev_opts.rebuild_cmd) |a| run_zigapagos.addArg(a);
    } else {
        // The project's own build, via the exact zig that configured it (no
        // PATH dependence). Rebuilds are incremental: cached steps (island/
        // runtime/SPA bundles with unchanged inputs) are skipped.
        run_zigapagos.addArgs(&.{ project.graph.zig_exe, "build" });
    }

    return run_zigapagos;
}

/// Appends one watch dir, skipping duplicates.
fn appendUniqueWatchDir(
    project: *std.Build,
    watch_dirs: *std.ArrayListUnmanaged([]const u8),
    dir: []const u8,
) void {
    for (watch_dirs.items) |d| if (std.mem.eql(u8, d, dir)) return;
    watch_dirs.append(project.allocator, dir) catch @panic("OOM");
}
