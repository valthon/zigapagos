//! Zigapagos's build script, in two halves.
//!
//! 1. The PUBLIC API a consumer's `build.zig` uses to build a site: the option
//!    types (`build/api.zig`) plus `website` (`build/site.zig`) and
//!    `e2e`/`dev` (`build/harness.zig`). The three entry points are thin
//!    wrappers here because `dependencyFromBuildZig` needs THIS file's type to
//!    locate the zigapagos dependency in the consumer's package graph; the
//!    implementations (and their full doc comments) live in those modules.
//!
//! 2. The IN-REPO build (`build` below), a table of contents over `build/`:
//!
//!      config.zig    `-D` user options + the git-derived version
//!      exe.zig       the `zigapagos` executable, `check` and `run`
//!      deps.zig      upstream modules shared by every compilation
//!      release.zig   `release` — the cross-compiled target matrix
//!      docgen.zig    the SuperHTML docgen tool (`-Ddocgen`)
//!      tests.zig     the `test-*` unit-test suites
//!      codegen.zig   `apigen` / `api-gen` / `api-check`
//!      snapshot.zig  `test` — snapshot rendering + diff
//!      camera.zig    helper exe used by the content-scanning snapshots
//!
//!    Step registration order below is the order steps appear in
//!    `zig build --help`; keep it stable.

const std = @import("std");

const api = @import("build/api.zig");
const codegen = @import("build/codegen.zig");
const config = @import("build/config.zig");
const docgen = @import("build/docgen.zig");
const exe = @import("build/exe.zig");
const harness = @import("build/harness.zig");
const release = @import("build/release.zig");
const site = @import("build/site.zig");
const snapshot = @import("build/snapshot.zig");
const tests = @import("build/tests.zig");

pub const BuildAsset = api.BuildAsset;
pub const Island = api.Island;
pub const Spa = api.Spa;
pub const Options = api.Options;
pub const E2eOptions = harness.E2eOptions;
pub const DevOptions = harness.DevOptions;

/// Builds a Zigapagos website. See `build/site.zig` for the full docs.
pub fn website(project: *std.Build, opts: Options) *std.Build.Step.Run {
    return site.website(@This(), project, opts);
}

/// The supported SPA e2e workflow: serve the release tree with the stock
/// ZigBase binary and run a browser driver against it. See `build/harness.zig`
/// for the full docs.
pub fn e2e(project: *std.Build, opts: Options, e2e_opts: E2eOptions) *std.Build.Step.Run {
    return harness.e2e(@This(), project, opts, e2e_opts);
}

/// The zigbase-backed local dev loop (`zig build dev`). See
/// `build/harness.zig` for the full docs.
pub fn dev(project: *std.Build, opts: Options, dev_opts: DevOptions) *std.Build.Step.Run {
    return harness.dev(@This(), project, opts, dev_opts);
}

pub fn build(b: *std.Build) !void {
    const cfg = config.parse(b);

    // Set up before anything lazy, as lazy deps would otherwise hide the
    // existence of this artifact.
    const zigapagos_exe = exe.addZigapagosExe(b, cfg.exeConfig());

    release.setup(b, cfg.version);
    docgen.setup(b, cfg);

    const check = exe.addCheckStep(b, zigapagos_exe);
    exe.addRunStep(b, zigapagos_exe);

    tests.setup(b, cfg, zigapagos_exe, check);
    codegen.setup(b);

    try snapshot.setup(b, cfg.target, zigapagos_exe);
}
