//! The `release` step: cross-compiled `zigapagos` binaries for the published
//! target matrix, archived into `<prefix>/releases/`.

const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const deps = @import("deps.zig");
const exe = @import("exe.zig");

/// Registers the `release` step. A release is only buildable from a tagged
/// checkout whose tag matches the zon package version; every other case
/// registers a failing step so the error surfaces when `release` is asked for
/// rather than on every unrelated `zig build`.
pub fn setup(b: *std.Build, version: config.Version) void {
    // Declared here rather than in config.zig because it configures nothing but
    // this step, and config.Config is threaded into the exe/test wiring where a
    // release-only knob would be noise. It must be declared unconditionally —
    // outside the `version == .tag` branch — or passing it on an untagged
    // checkout would be rejected as an unknown option before the (more useful)
    // "git tag missing" failure could be reported.
    const only = b.option(
        []const u8,
        "release-target",
        "Build only this target of the release matrix (zig triple, e.g. x86_64-macos); default: all",
    );

    const release = b.step("release", "Create release builds of Zigapagos");
    if (version == .tag) {
        const zon = @import("../build.zig.zon");
        if (std.mem.eql(u8, zon.version, version.tag[1..])) {
            addTargets(b, release, version.string(), only);
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
    /// `-Drelease-target`: build a single triple instead of the whole matrix,
    /// so the release workflow can give each target its own runner.
    only: ?[]const u8,
) void {
    // The shipped matrix is the four Unix targets backed by checked-in Wuffs
    // translation shims. Building the historical eight-target matrix at v0.1.0
    // exposed the remaining platform blockers:
    //
    //   - x86_64-windows: `os.windows` has no `OVERLAPPED` (WindowsWatcher.zig)
    //     or `PAGE_READONLY` (src/wuffs.zig). Same stable-0.16.0 breakage that
    //     already keeps Windows out of CI, so it returns with that port too.
    //   - x86_64-freebsd: links LinuxWatcher's `inotify_init1`/`inotify_add_watch`/
    //     `inotify_rm_watch`, which do not exist there, and has no checked-in
    //     Wuffs shim under src/hacks/. Note this is a watcher
    //     *selection* bug — FreeBSD must not compile LinuxWatcher at all —
    //     so the commented-out `linkSystemLibrary("inotify")` below would not
    //     have fixed it.
    //
    // Re-add a target here only together with its fix; a target that cannot be
    // built is worse than an absent one, because `release` is all-or-nothing.
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

    Io.Dir.cwd().createDirPath(b.graph.io, b.pathJoin(&.{
        b.install_prefix,
        "releases",
    })) catch unreachable;

    // Release needs different options and archive steps, so it constructs its
    // own executable. Keep the non-Wuffs imports in sync with addZigapagosExe;
    // Wuffs itself shares addWuffsImports so release and local builds cannot
    // accidentally take different translation paths.
    for (targets) |t| {
        if (only) |triple| {
            if (!std.mem.eql(u8, triple, t.zigTriple(b.allocator) catch unreachable)) continue;
        }

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
