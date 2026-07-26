//! The upstream Zig dependencies shared by every zigapagos compilation: the
//! dev exe (`build/exe.zig`), the SuperHTML docgen tool (`build/docgen.zig`)
//! and each target of the release matrix (`build/release.zig`) all need the
//! same five modules wired the same way, including supermd's own imports.
//!
//! `b.dependency` is memoized per (name, args), so two call sites passing
//! identical arguments get the identical `*Module` objects back — this helper
//! only removes the copy-paste, it changes nothing about the build graph.
//!
//! Deliberately NOT included: `wuffs`, `mime`, `flow_syntax`/`tree_sitter`,
//! `tracy` and the generated `options` module. Those differ per call site (see
//! the wuffs note in `exe.zig`) and stay explicit there.

const std = @import("std");

pub const Upstream = struct {
    scripty: *std.Build.Module,
    superhtml: *std.Build.Module,
    ziggy: *std.Build.Module,
    /// Already carries its `scripty`/`superhtml`/`ziggy` imports.
    supermd: *std.Build.Module,
    zeit: *std.Build.Module,
};

pub fn upstream(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracy: bool,
) Upstream {
    const scripty = b.dependency("scripty", .{
        .target = target,
        .optimize = optimize,
        .tracy = tracy,
    }).module("scripty");

    const superhtml = b.dependency("superhtml", .{
        .target = target,
        .optimize = optimize,
        .tracy = tracy,
    }).module("superhtml");

    const ziggy = b.dependency("ziggy", .{
        .target = target,
        .optimize = optimize,
    }).module("ziggy");

    const supermd = b.dependency("supermd", .{
        .target = target,
        .optimize = optimize,
        .tracy = tracy,
    }).module("supermd");
    supermd.addImport("scripty", scripty);
    supermd.addImport("superhtml", superhtml);
    supermd.addImport("ziggy", ziggy);

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");

    return .{
        .scripty = scripty,
        .superhtml = superhtml,
        .ziggy = ziggy,
        .supermd = supermd,
        .zeit = zeit,
    };
}
