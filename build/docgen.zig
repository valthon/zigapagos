//! The SuperHTML docgen tool. Always wired into the graph (so lazy deps don't
//! hide it), installed only under `-Ddocgen`.

const std = @import("std");

const config = @import("config.zig");
const deps = @import("deps.zig");

pub fn setup(b: *std.Build, cfg: config.Config) void {
    const shtml_docgen = b.addExecutable(.{
        .name = "shtml_docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docgen.zig"),
            .target = cfg.target,
            .optimize = .Debug,
        }),
    });
    {
        const up = deps.upstream(b, cfg.target, cfg.optimize, cfg.enable_tracy);
        shtml_docgen.root_module.addImport("zeit", up.zeit);
        shtml_docgen.root_module.addImport("ziggy", up.ziggy);
        shtml_docgen.root_module.addImport("supermd", up.supermd);
        shtml_docgen.root_module.addImport("superhtml", up.superhtml);
    }

    if (b.option(
        bool,
        "docgen",
        "enable building the SuperHTML docgen tool",
    ) orelse false) {
        b.installArtifact(shtml_docgen);
    }
}
