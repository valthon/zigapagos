const std = @import("std");
const config = @import("config.zig");

pub fn setup(b: *std.Build, cfg: config.Config) void {
    const checker = b.addExecutable(.{
        .name = "check_ziggy_examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check_ziggy_examples.zig"),
            .target = b.graph.host,
            .optimize = cfg.optimize,
        }),
    });
    checker.root_module.addImport("ziggy", @import("deps.zig").ziggyModule(b, b.graph.host, cfg.optimize));
    const run = b.addRunArtifact(checker);
    run.addPassthruArgs();
    run.has_side_effects = true;
    const step = b.step("docs-ziggy-check", "Parse complete documentation configs and frontmatter against shipped schemas");
    step.dependOn(&run.step);
}
