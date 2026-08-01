const std = @import("std");
const zigapagos = @import("zigapagos");

pub fn build(b: *std.Build) void {
    const islands: []const zigapagos.Island = &.{
        .{ .root = b.path("components/Hero.island.tsx"), .src = "components/Hero.island.tsx" },
        .{ .root = b.path("components/Flagged.island.tsx"), .src = "components/Flagged.island.tsx" },
        .{ .root = b.path("components/Panel.island.tsx"), .src = "components/Panel.island.tsx" },
        // npm-compat bridge: renders a component from the opt-in @demo/widget
        // package, whose `react` import is aliased to the shared runtime.
        .{ .root = b.path("components/Widget.island.tsx"), .src = "components/Widget.island.tsx" },
    };

    const spas: []const zigapagos.Spa = &.{
        // The universal 404.html is explicitly backed by `app`'s "/" shell via
        // `.not_found = "app"` below, so declaration order no longer decides
        // it. The three `slices/*` SPAs exercise per-deployable runtime
        // slicing: `public` (non-privileged bindings only) and
        // `admin` (uses the admin-only host.loadScript) get their own sliced
        // /spa/<name>-runtime.js; `fallback` (a computed host access) bails to
        // the shared runtime.
        .{ .root = b.path("app/app.spa.tsx"), .src = "app/app.spa.tsx", .base = "/app" },
        .{ .root = b.path("slices/public.spa.tsx"), .src = "slices/public.spa.tsx", .base = "/public" },
        .{ .root = b.path("slices/admin.spa.tsx"), .src = "slices/admin.spa.tsx", .base = "/admin" },
        .{ .root = b.path("slices/fallback.spa.tsx"), .src = "slices/fallback.spa.tsx", .base = "/fallback" },
        // `compat` imports @z/runtime/compat — the slicer must fall back to the
        // shared runtime (which has the compat surface) rather than slice + crash.
        .{ .root = b.path("slices/compat.spa.tsx"), .src = "slices/compat.spa.tsx", .base = "/compat" },
    };

    const site = zigapagos.website(b, .{
        // Debug rather than the .ReleaseFast default. This is a build-time tool
        // that runs for well under a second on this site; ReleaseFast costs 58s
        // to link and 96s for a cold build, against 29s for Debug — measured
        // with `zig build --summary all`. Debug also turns on the safety checks
        // (bounds, overflow, UB), which is what you want from the binary your
        // tests exercise. Published release artifacts are unaffected: release.zig
        // hardcodes .ReleaseFast for `zig build release`.
        .debug = .{ .optimize = .Debug },
        .islands = islands,
        .spas = spas,
        // Explicit 404 owner: the universal 404.html reuses the
        // `app` SPA's "/" shell regardless of `spas` declaration order.
        .not_found = "app",
        .output_path = "site",
        .force = true,
    });
    b.getInstallStep().dependOn(&site.step);

    // Dev loop: `zig build dev` builds the release output (same tree as
    // `zig build`, so output_path must match website()'s), serves it with the
    // STOCK ZigBase binary (real same-origin /api + admin UI), watches
    // content/layouts/assets + the island/SPA source dirs, and re-runs
    // `zig build` on change. The ZigBase data dir defaults to `.zigbase/`
    // (gitignored) and PERSISTS across dev sessions. No live reload —
    // refresh the browser after a rebuild.
    const dev_step = b.step("dev", "Serve the site with ZigBase, rebuilding on change");
    const dev_run = zigapagos.dev(b, .{
        // Debug rather than the .ReleaseFast default. This is a build-time tool
        // that runs for well under a second on this site; ReleaseFast costs 58s
        // to link and 96s for a cold build, against 29s for Debug — measured
        // with `zig build --summary all`. Debug also turns on the safety checks
        // (bounds, overflow, UB), which is what you want from the binary your
        // tests exercise. Published release artifacts are unaffected: release.zig
        // hardcodes .ReleaseFast for `zig build release`.
        .debug = .{ .optimize = .Debug },
        .islands = islands,
        .spas = spas,
        .output_path = "site",
        .force = true,
    }, .{});
    dev_step.dependOn(&dev_run.step);

    // The bundled preview server: in-memory build, live reload, no backend.
    // `zig build dev` is the loop to use once /api is real.
    const serve_step = b.step("serve", "Start the Zigapagos preview server (in-memory; see 'zig build dev' for a backend)");
    const serve_run = zigapagos.serve(b, .{
        // Debug rather than the .ReleaseFast default. This is a build-time tool
        // that runs for well under a second on this site; ReleaseFast costs 58s
        // to link and 96s for a cold build, against 29s for Debug — measured
        // with `zig build --summary all`. Debug also turns on the safety checks
        // (bounds, overflow, UB), which is what you want from the binary your
        // tests exercise. Published release artifacts are unaffected: release.zig
        // hardcodes .ReleaseFast for `zig build release`.
        .debug = .{ .optimize = .Debug },
        .islands = islands,
        .spas = spas,
    });
    serve_step.dependOn(&serve_run.step);

    // e2e harness: `zig build e2e -- <cmd>` builds + installs the full
    // release output (same tree as `zig build`), serves it with the STOCK
    // ZigBase binary (production-faithful: real same-origin API + `.spa`-marker
    // SPA fallback) on a free port, waits for readiness (GET / -> 200), runs
    // <cmd> with ZIGAPAGOS_ORIGIN exported, tears zigbase down, and propagates
    // the command's exit code as the step result. Any driver that reads
    // ZIGAPAGOS_ORIGIN works, e.g. `zig build e2e -- npx playwright test`.
    // See docs/spa.md § "End-to-End Testing".
    //
    // `output_path` must match the website() call above — the harness serves
    // that installed tree (zig-out/site).
    const e2e_step = b.step("e2e", "Serve the built site with ZigBase, then run a command with ZIGAPAGOS_ORIGIN set");
    const e2e_run = zigapagos.e2e(b, .{ .output_path = "site" }, .{});
    e2e_step.dependOn(&e2e_run.step);
}
