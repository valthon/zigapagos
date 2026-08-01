//! The SuperHTML docgen tool. Always wired into the graph (so lazy deps don't
//! hide it), installed only under `-Ddocgen`.

const std = @import("std");

const config = @import("config.zig");
const deps = @import("deps.zig");

/// Returns the fork-added reference generator's compile step so `build.zig`
/// can fold it into `check` — this runs before `check` exists, so it cannot
/// wire that dependency itself.
pub fn setup(b: *std.Build, cfg: config.Config) *std.Build.Step.Compile {
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

    return setupReference(b, cfg);
}

/// `docs-reference` — the fork-added Scripty reference generator (issue #37).
///
/// Deliberately NOT the tool above. `src/docgen.zig` is inherited, is kept
/// clean for release-tag syncs, and does not currently compile on this tree
/// (`std.process.argsAlloc` is gone in Zig 0.16, and it reads a
/// `context.Template` that has since been renamed to `context.Root`) — which is
/// also why `-Ddocgen` is opt-in and nothing depends on it. `src/docgen_reference.zig`
/// is a separate root file with its own output format.
///
/// This one is NOT gated behind an option: `docs/scripty.md` is a committed,
/// drift-gated artifact, so the generator has to build on every configure or
/// `tests/meta/scripty-reference.sh` would be reporting on a tool nobody
/// compiles. The step has side effects (it writes into the source tree) and so
/// runs only when named.
fn setupReference(b: *std.Build, cfg: config.Config) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "docgen_reference",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docgen_reference.zig"),
            .target = cfg.target,
            .optimize = .Debug,
        }),
    });
    {
        const up = deps.upstream(b, cfg.target, cfg.optimize, cfg.enable_tracy);
        exe.root_module.addImport("zeit", up.zeit);
        exe.root_module.addImport("ziggy", up.ziggy);
        exe.root_module.addImport("supermd", up.supermd);
        exe.root_module.addImport("superhtml", up.superhtml);
    }

    const run = b.addRunArtifact(exe);
    run.addFileArg(b.path("docs/scripty.md"));
    // The output path is a tracked source file, so the Run cache must never
    // decide this is a no-op: the whole point is to overwrite what is there.
    run.has_side_effects = true;
    run.setName("docgen_reference docs/scripty.md");

    const step = b.step("docs-reference", "Regenerate docs/scripty.md from the Scripty context types");
    step.dependOn(&run.step);

    return exe;
}
