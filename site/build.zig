const std = @import("std");
const zigapagos = @import("zigapagos");

pub fn build(b: *std.Build) void {
    const islands: []const zigapagos.Island = &.{
        .{ .root = b.path("components/Counter.island.tsx"), .src = "components/Counter.island.tsx" },
        .{ .root = b.path("components/CodeTabs.island.tsx"), .src = "components/CodeTabs.island.tsx" },
        .{ .root = b.path("components/DirectiveDemo.island.tsx"), .src = "components/DirectiveDemo.island.tsx" },
        .{ .root = b.path("components/MigrateDiff.island.tsx"), .src = "components/MigrateDiff.island.tsx" },
    };

    const spas: []const zigapagos.Spa = &.{
        .{ .root = b.path("demo/app.spa.tsx"), .src = "demo/app.spa.tsx", .base = "/demos/app" },
    };

    const site = zigapagos.website(b, .{
        .islands = islands,
        .spas = spas,
        .not_found = "app",
        .output_path = "site",
        .force = true,
    });
    b.getInstallStep().dependOn(&site.step);

    const serve_step = b.step("serve", "Start the Zigapagos development server");
    const serve_run = zigapagos.serve(b, .{
        .islands = islands,
        .spas = spas,
    });
    serve_step.dependOn(&serve_run.step);
}
