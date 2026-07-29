//! The `test-*` unit-test steps.
//!
//! Two families, each declared as a table so the wiring is written once:
//!
//!  * `standalone` — suites compiled as their own root module.
//!  * `exe_module` — suites compiled from the exe's fully-wired root module,
//!    needed whenever the file under test @imports across `src/` boundaries or
//!    is only reachable from inside a function body (see the anchor note on
//!    `exe_module`).
//!
//! Table ORDER is the order the steps appear in `zig build --help`.

const std = @import("std");
const config = @import("config.zig");
const deps = @import("deps.zig");

/// A suite compiled as its own root module (std-only, or std + ziggy).
const Standalone = struct {
    step_name: []const u8,
    description: []const u8,
    root_source_file: []const u8,
    /// Some suites pin the HOST target: they spawn/exec host programs (bun) or
    /// only make sense natively, so cross-compiling them would be pointless.
    host_target: bool = false,
    ziggy: bool = false,
    /// Wires the full `supermd` module (already carrying its own scripty/
    /// superhtml/ziggy imports and libcmark-gfm linkage, see `build/deps.zig`)
    /// into this suite's root module.
    supermd: bool = false,
    /// Run the test binary from the repo root (it reads repo-relative fixtures
    /// or spawns repo-relative scripts).
    repo_root_cwd: bool = false,
};

const standalone: []const Standalone = &.{
    .{
        .step_name = "test-islands",
        .description = "Run islands unit tests",
        .root_source_file = "src/islands/tests.zig",
        .ziggy = true,
    },
    .{
        .step_name = "test-props",
        .description = "Run type-erased island props tests",
        .root_source_file = "src/islands/props.zig",
        .host_target = true,
        .ziggy = true,
    },
    // `zigapagos migrate` detection/inference unit tests (std-only, no deps).
    .{
        .step_name = "test-migrate",
        .description = "Run zigapagos-migrate detection/inference unit tests",
        .root_source_file = "src/cli/migrate_detect.zig",
    },
    // Bun sidecar client integration test (spawns the NDJSON render sidecar).
    // The test spawns `bun runtime/sidecar/render.ts` relative to the repo
    // root, so run the test binary from the repo root.
    .{
        .step_name = "test-sidecar",
        .description = "Run the Bun island-sidecar client integration test",
        .root_source_file = "src/islands/sidecar.zig",
        .host_target = true,
        .repo_root_cwd = true,
    },
    // GitHub-compatible heading-id slugifier + injection pass unit tests
    // (issue #29). Needs `supermd` for the `Ast`/`Node`/`Directive` types the
    // injection pass (`apply`) operates on.
    .{
        .step_name = "test-slugs",
        .description = "Run heading-id slugifier unit tests",
        .root_source_file = "src/heading_slugs.zig",
        .supermd = true,
    },
};

/// A suite compiled from `zigapagos_exe.root_module`.
///
/// Two reasons a suite lands here rather than in `standalone`:
///
///  * The file under test @imports across a `src/` subdirectory boundary (e.g.
///    init_from_astro.zig's `@import("../fatal.zig")`), which Zig 0.16's module
///    system rejects for a standalone root module — the file-ownership check
///    fires before lazy analysis. Reusing the exe module (already wired with
///    every dep) sidesteps that.
///  * The file is only @import-ed from inside a function body (release.zig,
///    spa.zig, serve.zig, e2e.zig, dev.zig are all imported from main()'s
///    body), so it is not in the top-level import graph and its `test` blocks
///    are invisible to Zig's lazy analysis. main.zig carries a top-level
///    anchor per suite (`test "parse"`, `test "spa"`, `test "serve"`, …) that
///    forces eager inclusion, and `filters` selects that anchor plus the real
///    tests it pulls in.
///
/// In Zig 0.16, `filters` is a compile-time option — passed to the compiler as
/// --test-filter, not to the test binary at runtime.
const ExeModule = struct {
    step_name: []const u8,
    description: []const u8,
    filters: []const []const u8 = &.{},
    /// Add the test binary to `check` (compile-only). Set on exactly ONE
    /// suite: the UNFILTERED exe-module compile analyzes every test decl
    /// reachable from main.zig — including the filtered suites' blocks — so
    /// `check` catches compile rot (e.g. under -Dsingle-threaded)
    /// in ALL exe-graph test code from that single binary. The filtered
    /// compiles below would only analyze their own matches.
    checked: bool = false,
    /// Run from the repo root (reads repo-relative fixtures such as
    /// tests/migrate/astro-sample/).
    repo_root_cwd: bool = false,
};

const exe_module: []const ExeModule = &.{
    .{
        .step_name = "test-init",
        .description = "Run zigapagos init --from-astro unit tests",
        .checked = true,
        .repo_root_cwd = true,
    },
    // The "parse" filter matches main.zig's anchor AND the actual test in
    // release.zig ("parse recognizes the island sidecar args").
    .{
        .step_name = "test-release",
        .description = "Run release CLI Command.parse unit tests",
        .filters = &.{"parse"},
    },
    // SPA prerender helper unit tests (path/manifest/shell helpers in
    // src/spa.zig: spaName, defaultBase, substituteParams, joinUrl,
    // patternDir, planRoute, diskJoin, renderManifest, renderShell).
    .{
        .step_name = "test-spa",
        .description = "Run SPA prerender helper unit tests",
    },
    // CSS-minify gating unit tests. `shouldMinifyCss` lives in
    // src/root.zig, which main.zig imports at the top level, so its test blocks
    // are eagerly discovered under the exe root_module. The "assets:" filter
    // matches every `test "assets: …"` block.
    .{
        .step_name = "test-assets",
        .description = "Run static-asset (CSS minify) gating unit tests",
        .filters = &.{"assets:"},
    },
    // `serve` CLI parse tests — Command.parse must recognise the --proxy flag
    // (+ helper unit tests for matchProxy / parseStatusLine). The "serve"
    // filter matches main.zig's anchor and every `test "serve …"` block.
    .{
        .step_name = "test-serve",
        .description = "Run serve CLI Command.parse + proxy unit tests",
        .filters = &.{"serve"},
    },
    // `zigapagos e2e` CLI parse + zigbase-locator unit tests. The "e2e" filter
    // matches main.zig's anchor and every `test "e2e …"` block in e2e.zig and
    // zigbase.zig.
    .{
        .step_name = "test-e2e",
        .description = "Run zigapagos-e2e CLI parse + zigbase locator unit tests",
        .filters = &.{"e2e"},
    },
    // `zigapagos dev` CLI parse + helper unit tests. The "dev" filter matches
    // main.zig's anchor and every `test "dev …"` block.
    .{
        .step_name = "test-dev",
        .description = "Run zigapagos-dev CLI parse + helper unit tests",
        .filters = &.{"dev"},
    },
    // `zigapagos doctor` CLI parse + check-helper unit tests (built-output-tree
    // audit). The "doctor" filter matches main.zig's anchor and every
    // `test "doctor: …"` block in doctor.zig.
    .{
        .step_name = "test-doctor",
        .description = "Run zigapagos-doctor CLI parse + check-helper unit tests",
        .filters = &.{"doctor"},
    },
    // `zigapagos validate` CLI parse unit tests. The "validate:" filter matches
    // main.zig's anchor and every `test "validate: …"` block. The COLON is
    // load-bearing: a bare "validate" filter also matches the unrelated
    // validateClientDirective / validateConcretePath / validateRoutePath /
    // validateSpaBase tests in pass.zig and spa.zig.
    .{
        .step_name = "test-validate",
        .description = "Run validate CLI Command.parse unit tests",
        .filters = &.{"validate:"},
    },
};

/// Registers every `test-*` step and hangs the test binaries off `check`.
pub fn setup(
    b: *std.Build,
    cfg: config.Config,
    zigapagos_exe: *std.Build.Step.Compile,
    check: *std.Build.Step,
) void {
    const ziggy = b.dependency("ziggy", .{
        .target = cfg.target,
        .optimize = cfg.optimize,
    }).module("ziggy");

    // NOTE: every standalone test module below threads `single_threaded`
    // through, so `-Dsingle-threaded` genuinely applies to it and
    // `check` (which compiles all of these) catches single-threaded rot in
    // test-only code, not just in the exe.
    for (standalone) |suite| {
        const target = if (suite.host_target) b.graph.host else cfg.target;
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.root_source_file),
                .target = target,
                .optimize = cfg.optimize,
                .single_threaded = cfg.single_threaded,
            }),
        });
        if (suite.ziggy) tests.root_module.addImport("ziggy", ziggy);
        if (suite.supermd) {
            const up = deps.upstream(b, target, cfg.optimize, cfg.enable_tracy);
            tests.root_module.addImport("supermd", up.supermd);
        }
        check.dependOn(&tests.step);
        const run_tests = b.addRunArtifact(tests);
        if (suite.repo_root_cwd) run_tests.setCwd(b.path("."));
        b.step(suite.step_name, suite.description).dependOn(&run_tests.step);
    }

    for (exe_module) |suite| {
        const tests = b.addTest(.{
            .root_module = zigapagos_exe.root_module,
            .filters = suite.filters,
        });
        if (suite.checked) check.dependOn(&tests.step);
        const run_tests = b.addRunArtifact(tests);
        if (suite.repo_root_cwd) run_tests.setCwd(b.path("."));
        b.step(suite.step_name, suite.description).dependOn(&run_tests.step);
    }
}
