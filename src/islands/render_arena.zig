//! The marker type NO_SLOP.md §2.2a's contract 4 (arena-scoped) asks for.
//!
//! Lineage: zigbase's `src/request_arena.zig` (`RequestArena`), from its
//! allocator-ownership design — same shape, same three-part bar, same `.a`
//! escape hatch. The name differs on purpose: in zigapagos the arena-scoped
//! lifetime is a *page render / SPA prerender pass* (one entry in
//! `spa.prerenderAll`'s per-SPA loop, one `worker.renderPage`, one dev
//! re-render), not an HTTP request — so the type is named for the boundary it
//! actually has here.
//!
//! Why it lives under `src/islands/` rather than `src/`: `src/islands/props.zig`
//! and `src/islands/sidecar.zig` are the ROOT source files of their own test
//! modules (`zig build test-props` / `test-sidecar`), and Zig 0.16 rejects an
//! import that escapes a module's own directory ("import of file outside module
//! path" — the same rule that forces `cli/init_from_astro.zig`'s tests to reuse
//! the exe module instead of being their own root, and that keeps
//! `cli/migrate_detect.zig` from adopting this type at all). A type those roots
//! must import therefore has to sit beside them. Consumers outside
//! this directory (`src/spa.zig`, `src/root.zig`, `src/worker.zig`,
//! `src/cli/dev.zig`) are all part of the `src/main.zig` module and import it by
//! path without trouble.
const std = @import("std");

/// An arena scoped to one render pass. Deliberately NOT `std.mem.Allocator`:
///
///   * a GPA cannot flow in ACCIDENTALLY through the signature — the production
///     constructor `from` takes a concrete `*std.heap.ArenaAllocator`, so there
///     is no implicit conversion in either direction;
///   * the **compiler** checks it, instead of a parameter merely *named* `arena`
///     (what this repo relied on before this type existed) which checks nothing;
///   * the dependency is visible in every signature that has it, so "who needs
///     an arena" is a grep, not an audit.
///
/// Zig has no private fields, so a deliberate `RenderArena{ .a = some_gpa }`
/// literal still compiles: the guarantee is against *accidental* misuse — the
/// path the defect class actually travels — and any bypass is greppable and
/// high-friction rather than the default. Same for stashing `.a` past the end of
/// the pass; the type cannot stop that, review and `.a`'s greppability do.
///
/// A function taking a `RenderArena` is contract 4 and REQUIRES a written
/// justification meeting all three of:
///   1. the result is a graph of interlinked allocations, not a single buffer; and
///   2. freeing them individually would be pointer-chasing for no benefit; and
///   3. the lifetime is genuinely pass-scoped — it dies at a known boundary.
/// "It is currently written that way" and "adding `defer`s is tedious" are not
/// justifications. Anything that cannot clear the bar becomes contract 1/2/3.
pub const RenderArena = struct {
    /// The deliberate escape hatch: contract-1 helpers take a plain `Allocator`
    /// and are correct under any allocator, including this arena, so
    /// arena-scoped code reaches them through `.a`. Greppable on purpose.
    a: std.mem.Allocator,

    /// The production constructor: build from the real arena, at the boundary
    /// that owns and `deinit`s it (e.g. `spa.prerenderAll`'s per-SPA
    /// `arena_state`). Taking the concrete `*ArenaAllocator` rather than an
    /// `Allocator` is what makes a GPA unable to reach an arena-scoped API by
    /// accident. The one sanctioned non-arena construction is `forTest` below.
    pub fn from(arena: *std.heap.ArenaAllocator) RenderArena {
        return .{ .a = arena.allocator() };
    }

    /// Install a NON-arena allocator for a test. This exists so a test can keep
    /// using `std.testing.allocator`, whose leak detection is STRICTLY STRONGER
    /// than an arena's: an arena frees everything at `deinit`, so code that
    /// leaks looks identical to code that does not, and wrapping a test in a
    /// real arena just to satisfy this type would delete the detection §2.2a
    /// exists to restore (see `scripts/allocator-allowlist.txt`).
    ///
    /// Correctness note: code under a `RenderArena` must be correct under ANY
    /// allocator, because the contract-1 helpers it reaches via `.a` are. So
    /// running it on a GPA is a valid — and harsher — execution: it additionally
    /// requires the code not to leak. Where that genuinely cannot hold (the
    /// result is a `*Leaky`-parsed graph with no `deinit`, e.g.
    /// `islands/manifest.zig`'s `parse`), the test keeps a real arena and an
    /// allowlist row saying so.
    ///
    /// Test-only by CONVENTION, not by compiler enforcement: `forTest` in
    /// production code is a review defect, and greppable as one.
    pub fn forTest(gpa: std.mem.Allocator) RenderArena {
        return .{ .a = gpa };
    }
};

test "RenderArena.from builds from a real arena and exposes .a" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = RenderArena.from(&arena_state);
    const buf = try arena.a.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), buf.len);

    // Contract-1 helpers take a plain Allocator; `.a` is the deliberate bridge.
    try std.testing.expect(@TypeOf(arena.a) == std.mem.Allocator);
}

test "RenderArena.forTest keeps the testing allocator's leak detection on" {
    const arena = RenderArena.forTest(std.testing.allocator);
    // Nothing arena-ish about it: this allocation must be freed, and the test
    // fails if it is not — which is the entire point of `forTest`.
    const buf = try arena.a.alloc(u8, 8);
    defer arena.a.free(buf);
    try std.testing.expectEqual(@as(usize, 8), buf.len);
}
