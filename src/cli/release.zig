const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const tracy = @import("tracy");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const diag = @import("../diag.zig");
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;

pub fn release(
    io: Io,
    gpa: Allocator,
    args: []const []const u8,
    environ_map: *const std.process.Environ.Map,
) bool {
    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    const cmd: Command = try .parse(gpa, args);
    // Authoritative assignment: main.zig's scanArgv already set diag.format
    // as a stderr-suppression optimisation (before std.Progress/the banners),
    // but Command.parse -- which validates the value and reports a proper
    // usage error on garbage -- is what this build actually honors.
    diag.format = cmd.format;
    const cfg, const base_dir_path = root.Config.load(io, gpa);

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
    spas: []const root.SpaSpec,
    /// `--spa-not-found=<name>`: the SPA whose "/" shell backs the
    /// universal 404.html, named by its `spaName(src)` basename. Null (the
    /// default) keeps the historical behavior: the FIRST declared SPA.
    spa_not_found: ?[]const u8 = null,
    /// `--allow-missing-pages`: see `root.Options.allow_missing_pages`.
    /// Same tolerance the live server applies -- see that field's doc comment
    /// for why it is not mode-dependent, and why `dev` takes it from the
    /// project's `build.zig` rather than its own argv.
    allow_missing_pages: bool = false,
    /// `--format=text|json` (issue #46 / DX-27): text (default) is the
    /// historical multi-line prose; json emits one NDJSON diagnostic per line
    /// on stderr with a stable `code`. See `src/diag.zig`.
    format: diag.Format = .text,

    pub fn deinit(co: *const Command, gpa: Allocator) void {
        gpa.free(co.spas);
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
        var css_minify_driver: ?[]const u8 = null;
        var island_props_check: @import("../islands/props_check.zig").Mode = .off;
        var islands_slice: ?[]const u8 = null;
        var spas: std.ArrayListUnmanaged(root.SpaSpec) = .empty;
        var spa_not_found: ?[]const u8 = null;
        var allow_missing_pages = false;
        var format: diag.Format = .text;
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
            .css_minify_driver = css_minify_driver,
            .island_props_check = island_props_check,
            .islands_slice = islands_slice,
            .spas = try spas.toOwnedSlice(gpa),
            .spa_not_found = spa_not_found,
            .allow_missing_pages = allow_missing_pages,
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
    // \\  --build-assets FILE    Path to a file containing a list of build assets
    \\  --help, -h            Show this help menu
    \\
    \\
;

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
