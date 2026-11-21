//! Type/schema agreement, independent of the sample-document checks.
const std = @import("std");

pub fn setup(b: *std.Build, check: *std.Build.Step) *std.Build.Step {
    const step = b.step("schema-check", "Check real config and page types against shipped Ziggy schemas");
    var real_checkers: [2]*std.Build.Step.Compile = undefined;
    inline for (.{ "config", "page" }, .{ "src/schemas/zigapagos.ziggy-schema", "src/schemas/page.ziggy-schema" }, 0..) |kind, path, idx| {
        const types = b.createModule(.{ .root_source_file = b.path("src/schema_" ++ kind ++ ".zig") });
        // Resolve for the host: a Windows cross-check must still RUN the
        // schema checker locally, with native dependencies and libraries.
        const up = @import("deps.zig").upstream(b, b.graph.host, .debug, false);
        types.addImport("ziggy", up.ziggy);
        types.addImport("scripty", up.scripty);
        types.addImport("supermd", up.supermd);
        types.addImport("superhtml", up.superhtml);
        types.addImport("zeit", up.zeit);
        const checker = b.addExecutable(.{
            .name = "check-schema-" ++ kind,
            .root_module = b.createModule(.{
                .root_source_file = b.path("build/schema_checker.zig"),
                .target = b.graph.host,
                .optimize = .debug,
            }),
        });
        checker.root_module.addImport("ziggy", up.ziggy);
        checker.root_module.addImport("types", types);
        real_checkers[idx] = checker;
        const run = b.addRunArtifact(checker);
        run.addFileArg(b.path(path));
        step.dependOn(&run.step);
    }
    const regression = b.step("test-schema", "Reject structural mismatches between Zig types and Ziggy schemas");
    const run_tests = b.addSystemCommand(&.{"python3"});
    run_tests.addFileArg(b.path("tests/schema/structural_agreement.py"));
    run_tests.has_side_effects = true;
    inline for (.{ "types", "optional_types", "dynamic_root", "bytes_root", "optional_root", "dictionary_root" }) |name| {
        const up = @import("deps.zig").upstream(b, b.graph.host, .debug, false);
        const types = b.createModule(.{ .root_source_file = b.path("tests/schema/" ++ name ++ ".zig") });
        types.addImport("ziggy", up.ziggy);
        const checker = b.addExecutable(.{
            .name = "check-schema-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("build/schema_checker.zig"),
                .target = b.graph.host,
                .optimize = .debug,
            }),
        });
        checker.root_module.addImport("ziggy", up.ziggy);
        checker.root_module.addImport("types", types);
        run_tests.addArtifactArg(checker);
        run_tests.addFileArg(b.path("tests/schema/" ++ name ++ ".ziggy-schema"));
        check.dependOn(&checker.step);
    }
    inline for (real_checkers, .{ "src/schemas/zigapagos.ziggy-schema", "src/schemas/page.ziggy-schema" }) |checker, path| {
        run_tests.addArtifactArg(checker);
        run_tests.addFileArg(b.path(path));
    }
    regression.dependOn(&run_tests.step);
    check.dependOn(step);
    b.getInstallStep().dependOn(step);
    return step;
}
