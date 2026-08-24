//! `rails-schema` / `rails-check` — the JSON Schema drift gate for the Rails
//! discovery manifest (`contract/rails-presentation.v1.schema.json`).
//!
//! Mirrors `codegen.zig`'s `api-check` block exactly: regenerate -> `git
//! add` -> `git diff --cached --exit-code`, with the gate owning its OWN
//! `Run` step (not the one `rails-schema` uses) so `rails-check` always
//! regenerates independently of whether `rails-schema` happened to run
//! first in the same invocation -- see `codegen.zig`'s identical comment on
//! `api-check` for why that duplication is deliberate.
//!
//! The generator itself (`src/cli/rails/schema_gen.zig`) lives INSIDE
//! `src/cli/rails/`, not here: it walks `manifest.zig`'s Zig types via
//! `@typeInfo`, which only needs a same-directory `@import`, so it already
//! satisfies that directory's std-only constraint without this file's help.
//! This file's only job is wiring that generator's compiled executable into
//! the build graph, the same division `docgen.zig` draws between
//! `src/docgen_reference.zig` (the walker) and itself (the wiring).
const std = @import("std");
const config = @import("config.zig");

/// Both compiled executables' steps, so `build.zig` can fold each into
/// `check` (`docgen.setup`'s `docgen_reference_exe` return is the
/// precedent) -- a `manifest.zig` type change that either generator's
/// `@typeInfo` walk cannot handle should fail the ordinary `check` gate,
/// not wait for the next `rails-schema`/`rails-check`/`rails-manifest-
/// validate` invocation.
pub const Exes = struct {
    schema_gen: *std.Build.Step.Compile,
    manifest_validate: *std.Build.Step.Compile,
};

pub fn setup(b: *std.Build, cfg: config.Config) Exes {
    const exe = b.addExecutable(.{
        .name = "rails_schema_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/rails/schema_gen.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
        }),
    });

    // `rails_manifest_validate` (Stage 4 Phase 2 fix round, item 1): the
    // instance validator `tests/migrate/rails.sh` runs against the
    // COMMITTED schema and its own real fixture manifest -- see
    // `schema_validate.zig`'s module doc for why this is a real,
    // dependency-free CLI rather than a `pip install jsonschema` step this
    // repo's toolchain does not otherwise have. Installed under its own
    // step name (not folded into the default `zig build` install, which
    // CLAUDE.md documents as building exactly one binary, ZIGAPAGOS) so
    // `tests/migrate/rails.sh` can build it on demand the same way it
    // already builds `zig-out/bin/zigapagos` on demand.
    const validate_exe = b.addExecutable(.{
        .name = "rails_manifest_validate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/rails/schema_validate.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
        }),
    });
    {
        const install = b.addInstallArtifact(validate_exe, .{});
        b.step(
            "rails-manifest-validate",
            "Build zig-out/bin/rails_manifest_validate (a real JSON Schema instance validator, scoped to this schema's own keyword subset)",
        ).dependOn(&install.step);
    }

    // `rails-schema` — regenerate contract/rails-presentation.v1.schema.json.
    {
        const run = addSchemaGenRun(b, exe);
        b.step(
            "rails-schema",
            "Regenerate contract/rails-presentation.v1.schema.json from the manifest Zig types",
        ).dependOn(&run.step);
    }

    // `rails-check` — drift gate: regen then git add + git diff --cached --exit-code.
    // Its own Run step (not the one above): the gate must regenerate on
    // every `rails-check`, independently of `rails-schema`.
    {
        const run = addSchemaGenRun(b, exe);

        const git_add = b.addSystemCommand(&.{ "git", "add" });
        git_add.addFileArg(b.path("contract/rails-presentation.v1.schema.json"));
        git_add.setName("git add contract/rails-presentation.v1.schema.json");
        git_add.step.dependOn(&run.step);

        const diff = b.addSystemCommand(&.{
            "git",
            "diff",
            "--cached",
            "--exit-code",
        });
        diff.addFileArg(b.path("contract/rails-presentation.v1.schema.json"));
        diff.setName("git diff contract/rails-presentation.v1.schema.json");
        diff.step.dependOn(&git_add.step);

        const rails_check = b.step(
            "rails-check",
            "Fail if contract/rails-presentation.v1.schema.json is stale vs a fresh rails-schema",
        );
        rails_check.dependOn(&diff.step);
    }

    return .{ .schema_gen = exe, .manifest_validate = validate_exe };
}

fn addSchemaGenRun(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.addFileArg(b.path("contract/rails-presentation.v1.schema.json"));
    // Writes into the source tree every time — the whole point is to
    // overwrite what is there, so the Run cache must never treat this as a
    // no-op (mirrors docgen.zig's docgen_reference Run and codegen.zig's
    // apigen Run, both of which set this for the identical reason).
    run.has_side_effects = true;
    run.setName("rails_schema_gen contract/rails-presentation.v1.schema.json");
    return run;
}
