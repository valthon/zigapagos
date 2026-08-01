//! `zigapagos validate [OPTIONS]` -- parses and analyzes the site in the
//! current directory (issue #45). Runs the SAME build orchestrator
//! (`root.run`) as `zigapagos release`, in `.memory` mode with the island
//! sidecar deliberately left unconfigured (see `root.Options.island_sidecar_
//! optional`), so it surfaces every diagnostic a release build would surface
//! BEFORE island SSR -- without bundling islands, spawning Bun, or writing an
//! output tree.
//!
//! This is deliberately NOT "stop at the pre-render gate": `root.run`'s
//! aggregate gate (`any_prerendering_error`) only covers scan/parse/analyze/
//! template-parse diagnostics. Template RENDER errors -- a `$site.page(...)`
//! naming no page, a failing Scripty expression -- are caught by the render
//! pass itself (`worker.zig`'s `any_rendering_error`, set in BOTH modes), so
//! `validate` runs the FULL memory build, not a truncated prefix of it. See
//! the `dx/introspection` plan's §0.2-0.3 for the two ways an earlier design
//! (stopping at the gate) under-covers, verified by hand against this repo.
//!
//! What it does NOT cover, and why: island SSR (no sidecar runs -- a
//! component that throws is invisible), the typed island props check (never
//! enabled here), SPA route enumeration and every SPA spec check (a memory
//! build never prerenders, and neither command passes `--spa=` specs), asset
//! installation and refcount pruning, CSS minification -- all disk/sidecar-
//! only passes a memory build skips entirely (see root.zig's pass-order
//! comment). See `help_message` below for the user-facing version of this.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const fatal = @import("../fatal.zig");
const root = @import("../root.zig");
const worker = @import("../worker.zig");
const Allocator = std.mem.Allocator;
const BuildAsset = root.BuildAsset;

/// NO_SLOP.md §2.2a contract 1 (self-freeing): every allocation this function
/// makes directly is freed before it returns (`cmd.deinit`); `build` is a
/// bigger graph, but it too is torn down here (`build.deinit`), gated on
/// `builtin.mode == .Debug` for the SAME reason `release.zig`/`debug.zig` gate
/// their own teardown that way -- the process exits immediately after `main`
/// returns, so a Release build skips the teardown walk on purpose (it would
/// just be free()s right before `exit`), while Debug keeps it so the leak
/// detector still has something to check.
pub fn validate(
    io: Io,
    gpa: Allocator,
    args: []const []const u8,
) bool {
    var cmd: Command = Command.parse(gpa, args) catch fatal.oom();
    defer cmd.deinit(gpa);

    const cfg, const base_dir_path = root.Config.load(io, gpa);

    worker.start(io);
    defer if (builtin.mode == .Debug) worker.stopWaitAndDeinit(io);

    // DELIBERATELY NOT FACTORED into a shared helper with explain.zig's
    // identical-looking preamble: `Build` stores `cfg: *const root.Config`,
    // and `root.run` is called with `&cfg` where `cfg` is a local in THIS
    // function's frame. A helper returning `{ cfg, build }` by value would
    // hand back a `Build` whose `cfg` pointer dangles into the returned
    // temporary. `release.zig`, `debug.zig` and `serve.zig` all duplicate this
    // same preamble for exactly this reason -- do not "simplify" it away.
    const build = root.run(io, gpa, &cfg, .{
        .base_dir_path = base_dir_path,
        .build_assets = &cmd.build_assets,
        .drafts = cmd.drafts,
        .mode = .memory,
        .allow_missing_pages = cmd.allow_missing_pages,
        .island_sidecar_optional = true,
    }) catch fatal.oom();
    defer if (builtin.mode == .Debug) build.deinit(io, gpa);

    const failed = build.any_prerendering_error or build.any_rendering_error.load(.acquire);

    if (failed) {
        std.debug.print("validate: FAILED — see the diagnostics above\n", .{});
        return true;
    }

    // Print the page count even on success: a gate that checks nothing must
    // not report success silently. A site is structurally guaranteed at least
    // one page (Variant.zig fatals on a content root with no index.smd,
    // AUD-009), but the count is what makes a mis-pointed run (e.g. run from
    // the wrong directory, or against a mostly-draft site) visible.
    var pages: usize = 0;
    var layouts: usize = 0;
    for (build.variants) |*v| {
        for (v.pages.items) |*p| {
            if (!p._parse.active) continue;
            if (p._parse.status != .parsed) continue;
            pages += 1;
        }
    }
    for (build.templates.entries.items(.value)) |t| {
        if (t.layout) layouts += 1;
    }

    // On stdout, unlike every diagnostic above (which `root.run` already sent
    // to stderr via `std.debug.print`): `std.debug.print` itself always
    // targets stderr, so the one-line success summary needs a real stdout
    // writer to land where callers (and the shell tests) expect it.
    var out_buf: [256]u8 = undefined;
    const stdout = Io.File.stdout();
    // `writerStreaming`, not `writer`: `Io.File.writer` defaults to POSITIONAL
    // writes, which track their own offset and ignore the file's shared one.
    // With `cmd >f 2>&1` both descriptors point at ONE open file description,
    // and stderr's `std.debug.print` has already advanced its offset by the
    // time this buffered report flushes -- so a positional flush from offset
    // zero overwrites what stderr committed, silently corrupting anything that
    // parses the merged stream (issue #78). Streaming (positionless, appending)
    // writes advance the shared offset instead. On a pipe or a tty the
    // positional writer already fell back to streaming, so this changes
    // behaviour in exactly the broken case and nowhere else.
    var fw = stdout.writerStreaming(io, &out_buf);
    fw.interface.print("validate: OK — {d} page{s}, {d} layout{s}, 0 errors\n", .{
        pages,   if (pages == 1) "" else "s",
        layouts, if (layouts == 1) "" else "s",
    }) catch |err| fatal.msg("error writing to stdout: {t}\n", .{err});
    fw.interface.flush() catch |err| fatal.msg("error writing to stdout: {t}\n", .{err});
    return false;
}

pub const Command = struct {
    build_assets: std.StringArrayHashMapUnmanaged(BuildAsset),
    drafts: bool,
    allow_missing_pages: bool,

    /// NO_SLOP.md §2.2a contract 2 (owned-result): `build_assets` is a graph
    /// (each value's `.ref`/paths are borrowed from `args`, but the map's own
    /// backing storage is gpa-allocated); the caller `deinit`s.
    pub fn deinit(co: *const Command, gpa: Allocator) void {
        var ba = co.build_assets;
        ba.deinit(gpa);
    }

    pub fn parse(gpa: Allocator, args: []const []const u8) !Command {
        var build_assets: std.StringArrayHashMapUnmanaged(BuildAsset) = .empty;
        var drafts = false;
        var allow_missing_pages = false;

        const eql = std.mem.eql;
        const startsWith = std.mem.startsWith;
        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
                fatal.usage(help_message, .{});
            } else if (startsWith(u8, arg, "--build-asset=")) {
                // Parity with `zigapagos release`'s grammar, not completeness:
                // build-asset membership is checked at ANALYSIS time
                // (worker.zig's `b.build_assets.get(ba.ref) orelse …
                // missing_asset`), so a site whose content has a
                // `$build.asset("x")` code fence false-positives without this.
                const name = arg["--build-asset=".len..];

                idx += 1;
                if (idx >= args.len) fatal.usageError(
                    "error: missing build asset sub-argument for '{s}'\n",
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
                if (gop.found_existing) fatal.usageError(
                    "error: duplicate build asset name '{s}'\n",
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
            } else {
                fatal.usageError("error: unexpected cli argument '{s}'\n", .{arg});
            }
        }

        return .{
            .build_assets = build_assets,
            .drafts = drafts,
            .allow_missing_pages = allow_missing_pages,
        };
    }
};

const help_message =
    \\Usage: zigapagos validate [OPTIONS]
    \\
    \\Parses and analyzes the site in the current directory (or the nearest
    \\parent holding a zigapagos.ziggy) and reports every diagnostic a release
    \\build would report BEFORE island SSR — without bundling islands, spawning
    \\the Bun sidecar, or writing an output tree. Nothing under the output
    \\directory is created, read, or modified.
    \\
    \\WHAT IT COVERS
    \\  frontmatter + Ziggy schema errors, SuperMD parse errors, layout
    \\  resolution and `extends` chains, content-side $link.page and
    \\  $page.asset/$site.asset/$build.asset references, unknown code-fence
    \\  languages (warning), output-URL collisions, SuperHTML/Scripty template
    \\  parse errors, the ':' directive lint, and template RENDER errors (a
    \\  failing Scripty expression, a $site.page(...) that names no page).
    \\
    \\WHAT IT DOES NOT COVER  (validate is a SUBSET of release — a green
    \\                         validate is not a green release)
    \\  island SSR (no sidecar runs, so a component that throws is invisible),
    \\  the typed island props check, SPA route enumeration and every SPA spec
    \\  check (overlapping bases, basename collisions, '..' in a route path,
    \\  --spa-not-found), asset installation and refcount pruning, CSS
    \\  minification, and anything that only fails while writing the output
    \\  tree.
    \\
    \\Options:
    \\  --drafts               Include draft pages
    \\  --allow-missing-pages  Tolerate a dangling $link.page/$site.page
    \\                         reference (same semantics as `zigapagos release`)
    \\  --build-asset=NAME PATH [--install=P | --install-always=P]
    \\                         Declare a build asset, exactly as `zigapagos
    \\                         release` receives it from build.zig. Needed
    \\                         whenever content references $build.asset(...):
    \\                         membership is checked at analysis time, so
    \\                         omitting it reports a false "missing asset".
    \\                         Note a code fence whose `src` is a build asset
    \\                         is READ during analysis, so pointing this at an
    \\                         artifact that has not been built yet is a hard
    \\                         error — same as release.
    \\  --help, -h             Show this help menu
    \\
    \\Exit code: 0 when the site would pass a release build's pre-SSR gates, 1
    \\otherwise. Warnings alone (e.g. an unknown code-fence language) exit 0,
    \\matching release.
    \\
    \\
;

test "validate: parse accepts --drafts and --allow-missing-pages" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{ "--drafts", "--allow-missing-pages" });
    defer cmd.deinit(gpa);
    try std.testing.expect(cmd.drafts);
    try std.testing.expect(cmd.allow_missing_pages);

    var cmd_default = try Command.parse(gpa, &.{});
    defer cmd_default.deinit(gpa);
    try std.testing.expect(!cmd_default.drafts);
    try std.testing.expect(!cmd_default.allow_missing_pages);
}

test "validate: parse recognizes the --build-asset grammar (with and without --install)" {
    const gpa = std.testing.allocator;
    var cmd = try Command.parse(gpa, &.{
        "--build-asset=logo", "assets/logo.svg", "--install=static/logo.svg",
    });
    defer cmd.deinit(gpa);
    const asset = cmd.build_assets.get("logo").?;
    try std.testing.expectEqualStrings("assets/logo.svg", asset.input_path);
    try std.testing.expectEqualStrings("static/logo.svg", asset.install_path.?);
    try std.testing.expect(!asset.install_always);

    var cmd2 = try Command.parse(gpa, &.{
        "--build-asset=logo", "assets/logo.svg", "--install-always=static/logo.svg",
    });
    defer cmd2.deinit(gpa);
    const asset2 = cmd2.build_assets.get("logo").?;
    try std.testing.expect(asset2.install_always);

    // No install sub-arg at all: bare declaration, needed only so
    // `$build.asset(...)` resolves at analysis time.
    var cmd3 = try Command.parse(gpa, &.{ "--build-asset=logo", "assets/logo.svg" });
    defer cmd3.deinit(gpa);
    const asset3 = cmd3.build_assets.get("logo").?;
    try std.testing.expect(asset3.install_path == null);
}
