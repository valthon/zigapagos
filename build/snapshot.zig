//! The `test` step: snapshot testing. Each fixture directory under `tests/` is
//! rendered, its stderr captured into `snapshot.txt` (and, for the rendering
//! suites, its output tree into `snapshot/`), then the whole of `tests/` is
//! staged and diffed — a non-empty diff fails the step.

const std = @import("std");

pub fn setup(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zigapagos_exe: *std.Build.Step.Compile,
) !void {
    const test_step = b.step("test", "build snapshot tests and diff the results");

    const camera = b.addExecutable(.{
        .name = "camera",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/camera.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });

    const diff = b.addSystemCommand(&.{
        "git",
        "diff",
        "--cached",
        "--exit-code",
    });
    diff.addDirectoryArg(b.path("tests"));
    diff.setName("git diff tests/");
    test_step.dependOn(&diff.step);

    // We need to stage all of tests/ in order for untracked files to show up in
    // the diff. It's also not a bad automatism since it avoids the problem of
    // forgetting to stage new snapshot files.
    const git_add = b.addSystemCommand(&.{ "git", "add" });
    git_add.addDirectoryArg(b.path("tests/"));
    git_add.setName("git add tests/");
    diff.step.dependOn(&git_add.step);

    // content scanning
    {
        const tests_dir = try b.build_root.handle.openDir(b.graph.io, "tests/content-scanning", .{
            .iterate = true,
        });

        var it = tests_dir.iterateAssumeFirstIteration();
        while (try it.next(b.graph.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name[0] == '.') continue;

            const path = b.pathJoin(&.{
                "tests/content-scanning",
                entry.name,
            });

            const run_camera = b.addRunArtifact(camera);
            run_camera.addArtifactArg(zigapagos_exe);
            run_camera.addArg("debug");
            run_camera.setCwd(b.path(path));
            run_camera.has_side_effects = true;

            const out = run_camera.captureStdErr(.{});

            const update_snap = b.addUpdateSourceFiles();
            update_snap.addCopyFileToSource(out, b.pathJoin(&.{ path, "snapshot.txt" }));

            update_snap.step.dependOn(&run_camera.step);
            git_add.step.dependOn(&update_snap.step);
        }
    }

    // rendering
    try addRenderSuites(b, zigapagos_exe, git_add, "tests/rendering", &.{});
    // drafts on
    try addRenderSuites(b, zigapagos_exe, git_add, "tests/drafts", &.{"--drafts"});
}

/// One `zigapagos release --output=snapshot` per fixture directory under
/// `dir`, with `extra_args` inserted right after the subcommand.
fn addRenderSuites(
    b: *std.Build,
    zigapagos_exe: *std.Build.Step.Compile,
    git_add: *std.Build.Step.Run,
    dir: []const u8,
    extra_args: []const []const u8,
) !void {
    const tests_dir = try b.build_root.handle.openDir(b.graph.io, dir, .{
        .iterate = true,
    });

    var it = tests_dir.iterateAssumeFirstIteration();
    while (try it.next(b.graph.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;

        const src_path = b.pathJoin(&.{
            dir,
            entry.name,
        });

        const snapshot_path = b.pathJoin(&.{
            src_path,
            "snapshot",
        });

        // Deleting the old snapshot dir must only happen as part of the
        // `test` pipeline, never at configure time (i.e. not on every
        // plain `zig build`). Wiring it as a step that the render run
        // depends on -- rather than calling b.run(...) directly here --
        // means it only executes when something reachable from
        // `test_step` pulls it in.
        const rm_snapshot = b.addSystemCommand(&.{ "rm", "-rf", snapshot_path });
        rm_snapshot.setName(b.fmt("rm -rf {s}", .{snapshot_path}));
        rm_snapshot.has_side_effects = true;

        const run_zigapagos = b.addRunArtifact(zigapagos_exe);
        run_zigapagos.step.dependOn(&rm_snapshot.step);
        run_zigapagos.addArg("release");
        for (extra_args) |a| run_zigapagos.addArg(a);
        run_zigapagos.addArg("--force");
        run_zigapagos.addArg("--output=snapshot");
        run_zigapagos.setCwd(b.path(src_path));
        run_zigapagos.has_side_effects = true;

        const stderr_out = run_zigapagos.captureStdErr(.{});
        const update_snap = b.addUpdateSourceFiles();
        update_snap.addCopyFileToSource(stderr_out, b.pathJoin(
            &.{ src_path, "snapshot.txt" },
        ));

        update_snap.step.dependOn(&run_zigapagos.step);
        git_add.step.dependOn(&update_snap.step);
    }
}
