//! Zigapagos's build script. It builds ZIGAPAGOS — the executable, its tests
//! and its release artifacts. It does not build websites: a zigapagos site is
//! built by running the `zigapagos` binary, which needs no Zig toolchain at all.
//!
//! A table of contents over `build/`:
//!
//!   config.zig    `-D` user options + the git-derived version
//!   exe.zig       the `zigapagos` executable, `check` and `run`
//!   deps.zig      upstream modules shared by every compilation
//!   release.zig   `release` — the cross-compiled target matrix
//!   docgen.zig    the SuperHTML docgen tool (`-Ddocgen`)
//!   tests.zig     the `test-*` unit-test suites
//!   codegen.zig   `apigen` / `api-gen` / `api-check`
//!   rails_schema.zig `rails-schema` / `rails-check`
//!   snapshot.zig  `test` — snapshot rendering + diff
//!   camera.zig    helper exe used by the content-scanning snapshots
//!
//! Step registration order below is the order steps appear in
//! `zig build --help`; keep it stable.

const std = @import("std");

const codegen = @import("build/codegen.zig");
const config = @import("build/config.zig");
const docgen = @import("build/docgen.zig");
const exe = @import("build/exe.zig");
const rails_schema = @import("build/rails_schema.zig");
const release = @import("build/release.zig");
const snapshot = @import("build/snapshot.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) !void {
    const cfg = config.parse(b);

    // Set up before anything lazy, as lazy deps would otherwise hide the
    // existence of this artifact.
    const zigapagos_exe = exe.addZigapagosExe(b, cfg.exeConfig());

    release.setup(b, cfg.version);
    const docgen_reference_exe = docgen.setup(b, cfg);

    const check = exe.addCheckStep(b, zigapagos_exe);
    // The Scripty reference generator walks src/context/* with @typeInfo, so a
    // context-type change can break it. Folding it into `check` means that
    // breaks at the usual gate rather than the next time someone regenerates
    // docs/scripty.md. (docgen.setup runs above, before `check` exists.)
    check.dependOn(&docgen_reference_exe.step);
    exe.addRunStep(b, zigapagos_exe);

    tests.setup(b, cfg, zigapagos_exe, check);
    codegen.setup(b);

    const rails_schema_exes = rails_schema.setup(b, cfg);
    // Same reasoning as the docgen_reference fold-in above: the schema
    // generator walks manifest.zig's types with @typeInfo, so a type change
    // that breaks the walk should fail `check`, not wait for `rails-check`.
    check.dependOn(&rails_schema_exes.schema_gen.step);
    // The manifest instance validator has no such reflective walk, but it
    // shares this directory's std-only constraint and `tests/migrate/
    // rails.sh` depends on it compiling -- `check` should catch a break
    // there too, not the next e2e run.
    check.dependOn(&rails_schema_exes.manifest_validate.step);

    try snapshot.setup(b, cfg.target, zigapagos_exe);
}
