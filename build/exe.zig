//! The `zigapagos` executable itself: module/dependency wiring plus the two
//! top-level steps that hang directly off it (`check` and `run`).

const std = @import("std");
const deps = @import("deps.zig");

pub const ZigapagosExeConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version_string: []const u8,
    tsan: bool = false,
    enable_tracy: bool = false,
    highlight: bool = true,
    scopes: []const []const u8 = &.{},
    single_threaded: ?bool = null,
};

/// Construct the `zigapagos` executable in builder `zb`, wiring all dependencies.
/// The in-repo `build()` is the only caller — `build/release.zig` cross-compiles
/// its own, deliberately (see the wuffs note below).
pub fn addZigapagosExe(zb: *std.Build, cfg: ZigapagosExeConfig) *std.Build.Step.Compile {
    const target = cfg.target;
    const optimize = cfg.optimize;
    const mode = .{ .target = target, .optimize = optimize };

    const zigapagos_exe = zb.addExecutable(.{
        .name = "zigapagos",
        .root_module = zb.createModule(.{
            .root_source_file = zb.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = cfg.single_threaded,
            .sanitize_thread = cfg.tsan,
        }),
    });

    const tracy = zb.dependency("tracy", .{ .enable = cfg.enable_tracy });

    const options = blk: {
        const options = zb.addOptions();
        options.contents.print(zb.allocator,
            \\// module = zigapagos
            \\const std = @import("std");
            \\pub const tsan = {};
            \\pub const enable_treesitter = {};
            \\pub const version = "{s}";
            \\pub const log_scope_levels: []const std.log.ScopeLevel = &.{{
            \\
        , .{ cfg.tsan, cfg.highlight, cfg.version_string }) catch @panic("OOM");

        for (cfg.scopes) |l| options.contents.print(zb.allocator,
            \\.{{.scope = .{f}, .level = .debug}},
        , .{std.zig.fmtId(l)}) catch @panic("OOM");
        options.contents.print(zb.allocator, "}};", .{}) catch @panic("OOM");
        break :blk options.createModule();
    };

    const up = deps.upstream(zb, target, optimize, cfg.enable_tracy);

    const syntax = zb.dependency("flow_syntax", .{
        .target = target,
        .optimize = optimize,
    });
    const ts = syntax.builder.dependency("tree_sitter", mode);
    const treez = ts.module("treez");

    const mime = zb.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    });

    switch (target.result.os.tag) {
        else => @panic("target must be added to build.zig"),
        .linux => {},
        .freebsd => {},
        .windows => {},
        .macos => {
            const frameworks = zb.lazyDependency("frameworks", .{}) orelse return zigapagos_exe;
            zigapagos_exe.root_module.addIncludePath(frameworks.path("include"));
            zigapagos_exe.root_module.addFrameworkPath(frameworks.path("Frameworks"));
            zigapagos_exe.root_module.addLibraryPath(frameworks.path("lib"));
            zigapagos_exe.root_module.linkFramework("CoreServices", .{});
        },
    }

    zigapagos_exe.root_module.addImport("ziggy", up.ziggy);
    zigapagos_exe.root_module.addImport("scripty", up.scripty);
    zigapagos_exe.root_module.addImport("supermd", up.supermd);
    zigapagos_exe.root_module.addImport("superhtml", up.superhtml);
    zigapagos_exe.root_module.addImport("zeit", up.zeit);
    zigapagos_exe.root_module.addImport("syntax", syntax.module("syntax"));
    zigapagos_exe.root_module.addImport("treez", treez);
    zigapagos_exe.root_module.addImport("options", options);
    zigapagos_exe.root_module.addImport("tracy", tracy.module("tracy"));
    zigapagos_exe.root_module.addImport("mime", mime.module("mime"));

    addWuffsImports(zb, zigapagos_exe.root_module, target, optimize);

    return zigapagos_exe;
}

/// Wire the Wuffs C implementation together with the checked-in translated
/// header for `target`. Released Zig 0.16.0 crashes while translating Wuffs for
/// aarch64, so local and release builds must share these pretranslated modules
/// rather than letting either path invoke translate-c implicitly.
pub fn addWuffsImports(
    zb: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const wuffs = zb.dependency("wuffs", .{ .target = target, .optimize = optimize });

    module.addImport("_wuffs", wuffs.module("impl"));
    module.addImport("wuffs", zb.createModule(.{
        .root_source_file = switch (target.result.cpu.arch.family()) {
            .aarch64 => switch (target.result.os.tag) {
                .macos => zb.path("src/hacks/wuffs-temp-aarch64-macos.h.zig"),
                .linux => zb.path("src/hacks/wuffs-temp-aarch64-linux.h.zig"),
                else => @panic("unsupported"),
            },
            .x86 => switch (target.result.os.tag) {
                .macos => zb.path("src/hacks/wuffs-temp-x86-macos.h.zig"),
                .linux => zb.path("src/hacks/wuffs-temp-x86-linux.h.zig"),
                .windows => zb.path("src/hacks/wuffs-temp-x86-windows.h.zig"),
                else => @panic("unsupported"),
            },
            else => @panic("unsupported"),
        },

        .target = target,
        .optimize = optimize,
    }));
}

/// Registers the `check` step and installs the executable.
///
/// `check` compiles the exe AND every unit-test binary WITHOUT running
/// anything. Test decls are only analyzed in a test compilation, so the exe
/// alone is not enough: CI's `zig build check -Dsingle-threaded`
/// must also cover test-only code — the sidecar mutex test's
/// std.Thread.spawn once rotted exactly there, invisible to a compile-only
/// exe check and to the (multi-threaded) test runs. The test binaries are
/// added by `build/tests.zig`, which takes the returned step.
pub fn addCheckStep(b: *std.Build, zigapagos_exe: *std.Build.Step.Compile) *std.Build.Step {
    const check = b.step("check", "compile the zigapagos executable and all unit-test binaries (no run)");
    check.dependOn(&zigapagos_exe.step);
    b.installArtifact(zigapagos_exe);
    return check;
}

/// Registers the `run` step: the standalone exe against `standalone-test/`.
pub fn addRunStep(b: *std.Build, zigapagos_exe: *std.Build.Step.Compile) void {
    const run_step = b.step("run", "run the standalone zigapagos executable");
    const zigapagos_run = b.addRunArtifact(zigapagos_exe);
    zigapagos_run.setCwd(b.path("standalone-test"));
    if (b.args) |args| zigapagos_run.addArgs(args);
    run_step.dependOn(&zigapagos_run.step);
}
