//! The `release` step: cross-compiled `zigapagos` binaries for the published
//! target matrix, archived into `<prefix>/releases/`.

const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const deps = @import("deps.zig");
const exe = @import("exe.zig");

/// Tag-versus-manifest validation lives in release.yml's assert-version step.
/// Configure reads only declared Git files for commit provenance, never tags.
pub fn setup(b: *std.Build, cfg: config.Config) void {
    const only = b.option(
        []const u8,
        "release-target",
        "Build only this target of the release matrix (zig triple, e.g. x86_64-macos); default: all",
    );

    const release = b.step("release", "Create release builds of Zigapagos");
    addTargets(b, release, cfg.commit, only);
}

fn addTargets(
    b: *std.Build,
    release_step: *std.Build.Step,
    commit: []const u8,
    /// `-Drelease-target`: build a single triple instead of the whole matrix,
    /// so the release workflow can give each target its own runner.
    only: ?[]const u8,
) void {
    // Ship the four validated Unix targets. Windows now cross-compiles, but
    // native validation and release archives remain separate work. FreeBSD's
    // watcher selection and release coverage also need separate validation.
    //
    // This list stays the single source of truth for WHAT is shipped. WHERE each
    // one is built is the release workflow's matrix, which selects a row with
    // `-Drelease-target=<triple>`; an unknown triple fails here rather than
    // silently building nothing, so the two lists cannot drift apart unnoticed.
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    };

    if (only) |triple| {
        for (targets) |t| {
            if (std.mem.eql(u8, triple, t.zigTriple(b.allocator) catch unreachable)) break;
        } else {
            var known: std.ArrayList(u8) = .empty;
            for (targets, 0..) |t, i| {
                if (i != 0) known.appendSlice(b.allocator, ", ") catch unreachable;
                known.appendSlice(
                    b.allocator,
                    t.zigTriple(b.allocator) catch unreachable,
                ) catch unreachable;
            }
            release_step.dependOn(&b.addFail(b.fmt(
                "error: -Drelease-target='{s}' is not in the release matrix (have: {s})",
                .{ triple, known.items },
            )).step);
            return;
        }
    }

    // Release needs different options and archive steps, so it constructs its
    // own executable. Keep the non-Wuffs imports in sync with addZigapagosExe;
    // Wuffs itself shares addWuffsImports so release and local builds cannot
    // accidentally take different translation paths.
    for (targets) |t| {
        if (only) |triple| {
            if (!std.mem.eql(u8, triple, t.zigTriple(b.allocator) catch unreachable)) continue;
        }

        const target = b.resolveTargetQuery(t);
        const optimize: std.lang.Optimize = .fast;

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

        const treez = ts.module("treez");

        const mime = b.dependency("mime", .{
            .target = target,
            .optimize = optimize,
        });

        const options = blk: {
            const options = b.addOptions();
            options.addOption(bool, "tsan", false);
            options.addOption(bool, "enable_treesitter", true);
            options.addOption([]const u8, "version", @import("../build.zig.zon").version);
            options.addOption([]const u8, "commit", commit);
            options.contents.appendSlice(b.allocator, "pub const log_scope_levels: []const @import(\"std\").log.ScopeLevel = &.{};\n") catch @panic("OOM");
            break :blk options.createModule();
        };

        const zigapagos_exe_release = b.addExecutable(.{
            .name = "zigapagos",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = .fast,
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
        exe.addWuffsImports(b, zigapagos_exe_release.root_module, target, optimize);
        exe.addWebpLib(b, zigapagos_exe_release.root_module, target, optimize);

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
                    deps.macos(b, zigapagos_exe_release.root_module, target, optimize, frameworks);
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
                const archive = zip.addOutputFileArg2(archive_name, .{});
                zip.addFileArg2(zigapagos_exe_release.getEmittedBin(), .{});
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

                // `tar`, not `gtar`: the Homebrew-GNU name does not exist on a
                // stock Linux box or a GitHub `ubuntu-latest` runner, so every
                // tar.xz target failed at the archive step with
                // `failed to spawn and capture stdio from gtar: FileNotFound`
                // *after* linking its binary successfully. Both GNU tar and the
                // bsdtar shipped as `tar` on macOS accept these flags.
                const tar = b.addSystemCommand(&.{
                    "tar",
                    "-cJf",
                });

                const archive = tar.addOutputFileArg2(archive_name, .{});
                tar.addArg("-C");

                tar.addDirectoryArg2(zigapagos_exe_release.getEmittedBinDirectory(), .{});
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
