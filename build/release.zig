//! The `release` step: cross-compiled `zigapagos` binaries for the published
//! target matrix, archived into `<prefix>/releases/`.

const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const deps = @import("deps.zig");

/// Registers the `release` step. A release is only buildable from a tagged
/// checkout whose tag matches the zon package version; every other case
/// registers a failing step so the error surfaces when `release` is asked for
/// rather than on every unrelated `zig build`.
pub fn setup(b: *std.Build, version: config.Version) void {
    const release = b.step("release", "Create release builds of Zigapagos");
    if (version == .tag) {
        const zon = @import("../build.zig.zon");
        if (std.mem.eql(u8, zon.version, version.tag[1..])) {
            addTargets(b, release, version.string());
        } else {
            release.dependOn(&b.addFail(b.fmt(
                "error: git tag does not match zon package version (zon: '{s}', git: '{s}')",
                .{ zon.version, version.tag[1..] },
            )).step);
        }
    } else {
        release.dependOn(&b.addFail(
            "error: git tag missing, cannot make release builds",
        ).step);
    }
}

fn addTargets(
    b: *std.Build,
    release_step: *std.Build.Step,
    version: []const u8,
) void {
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    Io.Dir.cwd().createDirPath(b.graph.io, b.pathJoin(&.{
        b.install_prefix,
        "releases",
    })) catch unreachable;

    // NOTE: this intentionally does NOT call `addZigapagosExe`. The release matrix
    // includes targets (freebsd, aarch64-windows) that `addZigapagosExe`'s local wuffs
    // shim switch doesn't cover (it would @panic), and release links the upstream
    // `wuffs.module("wuffs")` directly rather than the dev `_wuffs`(impl)+shim
    // wiring. The non-wuffs imports below mirror `addZigapagosExe`; keep them in sync.
    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;

        const tracy = b.dependency("tracy", .{ .enable = false });
        const up = deps.upstream(b, target, optimize, false);

        const syntax = b.dependency("flow_syntax", .{
            .target = target,
            .optimize = optimize,
        });

        const ts = syntax.builder.dependency("tree_sitter", .{
            .target = target,
            .optimize = optimize,
        });

        const wuffs = b.dependency("wuffs", .{
            .target = target,
            .optimize = optimize,
        });

        const treez = ts.module("treez");

        const mime = b.dependency("mime", .{
            .target = target,
            .optimize = optimize,
        });

        const options = blk: {
            const options = b.addOptions();
            options.contents.print(b.allocator,
                \\// module = zigapagos
                \\const std = @import("std");
                \\pub const tsan = false;
                \\pub const enable_treesitter = true;
                \\pub const version = "{s}";
                \\pub const log_scope_levels: []const std.log.ScopeLevel = &.{{}};
                \\
            , .{version}) catch unreachable;
            break :blk options.createModule();
        };

        const zigapagos_exe_release = b.addExecutable(.{
            .name = "zigapagos",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        });

        zigapagos_exe_release.root_module.addImport("options", options);
        zigapagos_exe_release.root_module.addImport("ziggy", up.ziggy);
        zigapagos_exe_release.root_module.addImport("scripty", up.scripty);
        zigapagos_exe_release.root_module.addImport("supermd", up.supermd);
        zigapagos_exe_release.root_module.addImport("superhtml", up.superhtml);
        zigapagos_exe_release.root_module.addImport("zeit", up.zeit);
        zigapagos_exe_release.root_module.addImport("syntax", syntax.module("syntax"));
        zigapagos_exe_release.root_module.addImport("treez", treez);
        zigapagos_exe_release.root_module.addImport("tracy", tracy.module("tracy"));
        zigapagos_exe_release.root_module.addImport("mime", mime.module("mime"));
        zigapagos_exe_release.root_module.addImport("wuffs", wuffs.module("wuffs"));

        switch (target.result.os.tag) {
            else => @panic("target must be added to build.zig"),
            .linux => {},
            .freebsd => {
                // only required for FreeBSD < 15
                // zigapagos_exe_release.linkSystemLibrary("inotify");
            },
            .windows => {},
            .macos => {
                if (b.lazyDependency("frameworks", .{
                    .target = target,
                    .optimize = optimize,
                })) |frameworks| {
                    zigapagos_exe_release.root_module.addIncludePath(frameworks.path("include"));
                    zigapagos_exe_release.root_module.addFrameworkPath(frameworks.path("Frameworks"));
                    zigapagos_exe_release.root_module.addLibraryPath(frameworks.path("lib"));
                    zigapagos_exe_release.root_module.linkFramework("CoreServices", .{});
                }
            },
        }

        switch (t.os_tag.?) {
            .macos, .windows => {
                const archive_name = b.fmt("{s}.zip", .{
                    t.zigTriple(b.allocator) catch unreachable,
                });

                const zip = b.addSystemCommand(&.{
                    "zip",
                    "-9",
                    // "-dd",
                    "-q",
                    "-j",
                });
                const archive = zip.addOutputFileArg(archive_name);
                zip.addDirectoryArg(zigapagos_exe_release.getEmittedBin());
                _ = zip.captureStdOut(.{});

                release_step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
            else => {
                const archive_name = b.fmt("{s}.tar.xz", .{
                    t.zigTriple(b.allocator) catch unreachable,
                });

                const tar = b.addSystemCommand(&.{
                    "gtar",
                    "-cJf",
                });

                const archive = tar.addOutputFileArg(archive_name);
                tar.addArg("-C");

                tar.addDirectoryArg(zigapagos_exe_release.getEmittedBinDirectory());
                tar.addArg("zigapagos");
                _ = tar.captureStdOut(.{});

                release_step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
        }
    }
}
