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
    addWebpLib(zb, zigapagos_exe.root_module, target, optimize);

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
                else => noWuffsShim(target),
            },
            .x86 => switch (target.result.os.tag) {
                .macos => zb.path("src/hacks/wuffs-temp-x86-macos.h.zig"),
                .linux => zb.path("src/hacks/wuffs-temp-x86-linux.h.zig"),
                .windows => zb.path("src/hacks/wuffs-temp-x86-windows.h.zig"),
                else => noWuffsShim(target),
            },
            else => noWuffsShim(target),
        },

        .target = target,
        .optimize = optimize,
    }));
}

fn noWuffsShim(target: std.Build.ResolvedTarget) noreturn {
    std.debug.panic(
        "no checked-in wuffs shim for {s}-{s}; add one under src/hacks/",
        .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
    );
}

// Generated from the vendored libwebp tarball (issue #132):
//   d=zig-pkg/<libwebp hash dir>/
//   (cd "$d" && ls src/enc/*.c src/dec/*.c src/dsp/*.c src/utils/*.c sharpyuv/*.c) | sort
// All four dirs + sharpyuv compile as one lib (the cmake/Bazel upstream
// grouping); dec is included because dsp's decode half references it, and
// the encode-only entry points mean the decode surface is simply unused,
// not stripped. Per-arch dsp/enc variants (mips/neon/sse/avx) are guarded
// internally by the same `WEBP_USE_*` macros upstream's own CMakeLists
// relies on, so they compile to empty translation units on targets that
// don't match — no per-target exclusion needed.
const webp_sources = [_][]const u8{
    "sharpyuv/sharpyuv.c",
    "sharpyuv/sharpyuv_cpu.c",
    "sharpyuv/sharpyuv_csp.c",
    "sharpyuv/sharpyuv_dsp.c",
    "sharpyuv/sharpyuv_gamma.c",
    "sharpyuv/sharpyuv_neon.c",
    "sharpyuv/sharpyuv_sse2.c",
    "src/dec/alpha_dec.c",
    "src/dec/buffer_dec.c",
    "src/dec/frame_dec.c",
    "src/dec/idec_dec.c",
    "src/dec/io_dec.c",
    "src/dec/quant_dec.c",
    "src/dec/tree_dec.c",
    "src/dec/vp8_dec.c",
    "src/dec/vp8l_dec.c",
    "src/dec/webp_dec.c",
    "src/dsp/alpha_processing.c",
    "src/dsp/alpha_processing_mips_dsp_r2.c",
    "src/dsp/alpha_processing_neon.c",
    "src/dsp/alpha_processing_sse2.c",
    "src/dsp/alpha_processing_sse41.c",
    "src/dsp/cost.c",
    "src/dsp/cost_mips32.c",
    "src/dsp/cost_mips_dsp_r2.c",
    "src/dsp/cost_neon.c",
    "src/dsp/cost_sse2.c",
    "src/dsp/cpu.c",
    "src/dsp/dec.c",
    "src/dsp/dec_clip_tables.c",
    "src/dsp/dec_mips32.c",
    "src/dsp/dec_mips_dsp_r2.c",
    "src/dsp/dec_msa.c",
    "src/dsp/dec_neon.c",
    "src/dsp/dec_sse2.c",
    "src/dsp/dec_sse41.c",
    "src/dsp/enc.c",
    "src/dsp/enc_mips32.c",
    "src/dsp/enc_mips_dsp_r2.c",
    "src/dsp/enc_msa.c",
    "src/dsp/enc_neon.c",
    "src/dsp/enc_sse2.c",
    "src/dsp/enc_sse41.c",
    "src/dsp/filters.c",
    "src/dsp/filters_mips_dsp_r2.c",
    "src/dsp/filters_msa.c",
    "src/dsp/filters_neon.c",
    "src/dsp/filters_sse2.c",
    "src/dsp/lossless.c",
    "src/dsp/lossless_avx2.c",
    "src/dsp/lossless_enc.c",
    "src/dsp/lossless_enc_avx2.c",
    "src/dsp/lossless_enc_mips32.c",
    "src/dsp/lossless_enc_mips_dsp_r2.c",
    "src/dsp/lossless_enc_msa.c",
    "src/dsp/lossless_enc_neon.c",
    "src/dsp/lossless_enc_sse2.c",
    "src/dsp/lossless_enc_sse41.c",
    "src/dsp/lossless_mips_dsp_r2.c",
    "src/dsp/lossless_msa.c",
    "src/dsp/lossless_neon.c",
    "src/dsp/lossless_sse2.c",
    "src/dsp/lossless_sse41.c",
    "src/dsp/rescaler.c",
    "src/dsp/rescaler_mips32.c",
    "src/dsp/rescaler_mips_dsp_r2.c",
    "src/dsp/rescaler_msa.c",
    "src/dsp/rescaler_neon.c",
    "src/dsp/rescaler_sse2.c",
    "src/dsp/ssim.c",
    "src/dsp/ssim_sse2.c",
    "src/dsp/upsampling.c",
    "src/dsp/upsampling_mips_dsp_r2.c",
    "src/dsp/upsampling_msa.c",
    "src/dsp/upsampling_neon.c",
    "src/dsp/upsampling_sse2.c",
    "src/dsp/upsampling_sse41.c",
    "src/dsp/yuv.c",
    "src/dsp/yuv_mips32.c",
    "src/dsp/yuv_mips_dsp_r2.c",
    "src/dsp/yuv_neon.c",
    "src/dsp/yuv_sse2.c",
    "src/dsp/yuv_sse41.c",
    "src/enc/alpha_enc.c",
    "src/enc/analysis_enc.c",
    "src/enc/backward_references_cost_enc.c",
    "src/enc/backward_references_enc.c",
    "src/enc/config_enc.c",
    "src/enc/cost_enc.c",
    "src/enc/filter_enc.c",
    "src/enc/frame_enc.c",
    "src/enc/histogram_enc.c",
    "src/enc/iterator_enc.c",
    "src/enc/near_lossless_enc.c",
    "src/enc/picture_csp_enc.c",
    "src/enc/picture_enc.c",
    "src/enc/picture_psnr_enc.c",
    "src/enc/picture_rescale_enc.c",
    "src/enc/picture_tools_enc.c",
    "src/enc/predictor_enc.c",
    "src/enc/quant_enc.c",
    "src/enc/syntax_enc.c",
    "src/enc/token_enc.c",
    "src/enc/tree_enc.c",
    "src/enc/vp8l_enc.c",
    "src/enc/webp_enc.c",
    "src/utils/bit_reader_utils.c",
    "src/utils/bit_writer_utils.c",
    "src/utils/color_cache_utils.c",
    "src/utils/filters_utils.c",
    "src/utils/huffman_encode_utils.c",
    "src/utils/huffman_utils.c",
    "src/utils/palette.c",
    "src/utils/quant_levels_dec_utils.c",
    "src/utils/quant_levels_utils.c",
    "src/utils/random_utils.c",
    "src/utils/rescaler_utils.c",
    "src/utils/thread_utils.c",
    "src/utils/utils.c",
};

/// Compile libwebp's encoder from the vendored source tarball and link it
/// into `module`. Compiled (not prebuilt) so `zig cc` cross-compiles it for
/// every release target exactly like the wuffs impl. Paired with
/// `addWuffsImports` at every call site — decode and encode travel together.
pub fn addWebpLib(
    zb: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dep = zb.dependency("libwebp", .{});
    const lib = zb.addLibrary(.{
        .name = "webp",
        .linkage = .static,
        .root_module = zb.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(dep.path(""));
    lib.root_module.addIncludePath(dep.path("src"));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &webp_sources,
        .flags = &.{ "-DWEBP_DISABLE_STATS", "-fno-sanitize=undefined" },
    });
    module.linkLibrary(lib);
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
