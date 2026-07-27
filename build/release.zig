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
    // The shipped matrix is deliberately the two targets that actually build on
    // released Zig 0.16.0. Building the historical eight-target matrix at
    // `v0.1.0` produced exactly one archive; the other seven failed for four
    // independent reasons, each of which has to be fixed before its targets can
    // come back:
    //
    //   - all four aarch64 targets: `zig translate-c` dies with SIGSEGV on
    //     wuffs-v0.4.c. A compiler crash, not a defect here — it is expected to
    //     go with the Zig 0.17 port (see docs/ROADMAP.md fork policy).
    //   - x86_64-windows: `os.windows` has no `OVERLAPPED` (WindowsWatcher.zig)
    //     or `PAGE_READONLY` (src/wuffs.zig). Same stable-0.16.0 breakage that
    //     already keeps Windows out of CI, so it returns with that port too.
    //   - x86_64-freebsd: links LinuxWatcher's `inotify_init1`/`inotify_add_watch`/
    //     `inotify_rm_watch`, which do not exist there. Note this is a watcher
    //     *selection* bug — FreeBSD must not compile LinuxWatcher at all —
    //     so the commented-out `linkSystemLibrary("inotify")` below would not
    //     have fixed it.
    //
    // Re-add a target here only together with its fix; a target that cannot be
    // built is worse than an absent one, because `release` is all-or-nothing.
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    };

    Io.Dir.cwd().createDirPath(b.graph.io, b.pathJoin(&.{
        b.install_prefix,
        "releases",
    })) catch unreachable;

    // NOTE: this intentionally does NOT call `addZigapagosExe`. Release links the
    // upstream `wuffs.module("wuffs")` directly rather than the dev
    // `_wuffs`(impl)+shim wiring, because the full matrix above is meant to grow
    // back to targets (freebsd, aarch64-windows) that `addZigapagosExe`'s local
    // wuffs shim switch doesn't cover — it would @panic on them. Keep the split
    // even while the matrix is reduced, so restoring a target stays a one-line
    // change here. The non-wuffs imports below mirror `addZigapagosExe`; keep
    // them in sync.
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
