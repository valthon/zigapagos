const std = @import("std");
const zigapagos = @import("zigapagos");

pub fn build(b: *std.Build) void {
    const islands: []const zigapagos.Island = &.{
        .{ .root = b.path("components/Counter.island.tsx"), .src = "components/Counter.island.tsx" },
    };

    const site = zigapagos.website(b, .{
        .islands = islands,
        .output_path = "site",
        .force = true,
    });
    b.getInstallStep().dependOn(&site.step);

    const serve_step = b.step("serve", "Start the Zigapagos development server");
    const serve_run = zigapagos.serve(b, .{
        .islands = islands,
    });
    serve_step.dependOn(&serve_run.step);
}
