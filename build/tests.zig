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
const exe_build = @import("exe.zig");

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
    /// Wires the wuffs shims + compiled libwebp into this suite's root
    /// module, the same way `addZigapagosExe` wires them into the exe, so
    /// the suite cannot drift from production linkage (issue #132).
    image_deps: bool = false,
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
    // Machine-readable diagnostics registry (issue #46 / DX-27): std-only, no
    // ziggy/supermd/host_target/repo_root_cwd needed. Part of `standalone` so
    // `-Dsingle-threaded` covers it automatically via `check`.
    .{
        .step_name = "test-diag",
        .description = "Run diagnostic-code registry tests",
        .root_source_file = "src/diag.zig",
    },
    // `--summary` emitted-artifact inventory (issue #42). Std-only for the same
    // reason `test-diag` is: the collector deliberately knows nothing about the
    // build — it takes paths and prints them — so it needs no deps and belongs
    // in `standalone`, where `-Dsingle-threaded` covers it via `check`.
    .{
        .step_name = "test-summary",
        .description = "Run build-summary inventory tests",
        .root_source_file = "src/summary.zig",
    },
    // Build-time image optimization (issue #132): webp bindings, decode,
    // resample, planning. Needs the wuffs shims + the compiled libwebp
    // (`image_deps`), wired the same way the exe gets them so the suite
    // cannot drift from production linkage.
    .{
        .step_name = "test-images",
        .description = "Run image-optimization (decode/resample/encode/plan) unit tests",
        .root_source_file = "src/image/tests.zig",
        .image_deps = true,
    },
    // Rails source-discovery adapter (issue #166 stage 1): detection,
    // presentation inventory, integration detection, and MIGRATION.md
    // rendering. Std-only by design -- no import escapes `src/cli/rails/` --
    // so it belongs in `standalone` like `test-diag`/`test-summary`.
    .{
        .step_name = "test-rails",
        .description = "Run Rails migration adapter unit tests",
        .root_source_file = "src/cli/rails/rails.zig",
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
///    spa.zig, e2e.zig, dev.zig are all imported from main()'s body), so it is
///    not in the top-level import graph and its `test` blocks are invisible to
///    Zig's lazy analysis. main.zig carries a top-level anchor per suite
///    (`test "parse"`, `test "spa"`, `test "dev"`, …) that forces eager
///    inclusion, and `filters` selects that anchor plus the real tests it
///    pulls in.
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
    // The "parse" filter matches main.zig's anchor AND the actual tests in
    // release.zig ("parse recognizes the island sidecar args").
    //
    // Every filter here is a SUBSTRING of a test name, and a test whose name
    // matches none of them is silently not built — so a new test in this file is
    // not run until its name is covered. That is how a test can pass with the fix
    // AND without it: it never executed either time. `discoverEntries` and
    // `containsComponent` are listed because the toolchain-free island/SPA scan is
    // named for what it does rather than for `parse`.
    .{
        .step_name = "test-release",
        .description = "Run release CLI Command.parse + entry-discovery unit tests",
        .filters = &.{ "parse", "discoverEntries", "containsComponent" },
    },
    // `zigapagos debug` Command.parse allocation-failure coverage. The filter
    // matches both main.zig's anchor and debug.zig's test.
    .{
        .step_name = "test-debug",
        .description = "Run debug CLI Command.parse unit tests",
        .filters = &.{"debug:"},
    },
    // SPA prerender helper unit tests (path/manifest/shell helpers in
    // src/spa.zig: spaName, defaultBase, substituteParams, joinUrl,
    // patternDir, planRoute, diskJoin, renderManifest, renderShell).
    .{
        .step_name = "test-spa",
        .description = "Run SPA prerender helper unit tests",
    },
    // Static-asset unit tests: the CSS-minify gate + the pruned-asset report's
    // suppressions (src/root.zig) and content-hashed filenames
    // (src/fingerprint.zig). The "assets:" filter matches every
    // `test "assets: …"` block.
    //
    // This step NEEDS main.zig's `test "assets: unit-test anchor"`. The comment
    // this replaces claimed root.zig's blocks were "eagerly discovered because
    // main.zig imports it at the top level"; they were not. A top-level `const`
    // is analyzed only when analyzed code references it, and in a FILTERED
    // compile the only analyzed code is the matching tests — of which there
    // were none in main.zig. The step therefore compiled and ran ZERO tests
    // and still exited 0, for as long as it has existed. If you ever add a
    // suite here, make its filter match an anchor.
    .{
        .step_name = "test-assets",
        .description = "Run static-asset (minify/fingerprint/report) unit tests",
        .filters = &.{"assets:"},
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
    // `zigapagos explain` CLI parse + route-normalization unit tests (the
    // `Command.parse` surface and `routeCandidates`). Route resolution BEYOND
    // normalization needs a whole `Build`, so it is covered by
    // `tests/explain/explain.sh` against a real site instead -- do not widen
    // this description to imply otherwise.
    .{
        .step_name = "test-explain",
        .description = "Run explain CLI parse + route-normalization unit tests",
        .filters = &.{"explain:"},
    },
    // `sitemap.xml` emitter unit tests (issue #150): URL composition
    // (host_url + url_path_prefix + page path/pagination tail, and the raw
    // SPA-route form) and XML escaping. The "sitemap:" filter matches
    // main.zig's anchor and every `test "sitemap: …"` block in
    // src/sitemap.zig -- see that anchor's comment for why the anchor has
    // to import sitemap.zig directly rather than relying on root.zig's own
    // top-level import of it.
    .{
        .step_name = "test-sitemap",
        .description = "Run sitemap.xml emitter unit tests",
        .filters = &.{"sitemap:"},
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
        if (suite.image_deps) {
            exe_build.addWuffsImports(b, tests.root_module, target, cfg.optimize);
            exe_build.addWebpLib(b, tests.root_module, target, cfg.optimize);
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
