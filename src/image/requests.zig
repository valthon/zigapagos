//! Mutex-guarded collection point for image-derivation requests (#132).
//!
//! Registration happens inside `page_analyze` worker jobs, which hold
//! `*const Build` — analysis mutates nothing on Build except atomics, and
//! widening that to `*Build` for one feature would surrender the guarantee
//! for every field. Module-level state instead (the worker.zig pattern):
//! one process = one build (dev re-execs per rebuild), and `take` drains.
//!
//! Registration is gated `build.mode == .disk` at both call sites
//! (`worker.zig`'s page-asset and site-asset analyze arms), matching the
//! sole `take()` call site (`root.zig`'s `planImageVariants`, itself gated
//! the same way). A `.memory` build (`zigapagos validate`/`explain-code`)
//! must never populate this collector: `take` runs only for `.disk`, so an
//! entry registered under `.memory` would sit here undrained until the next
//! `.disk` build in the same process — read (falsely) as belonging to that
//! later build's page set.
const std = @import("std");
const Io = std.Io;
const plan = @import("plan.zig");

// std.Thread.Mutex does not exist on this toolchain (zig 0.16): locking here
// follows the established repo pattern for a mutex guarding worker-job shared
// state (`Build.island_props_checks_mutex`, used from `worker.zig`'s
// `page_analyze` jobs) — `std.Io.Mutex` + `lockUncancelable`/`unlock`, both
// threaded through the caller's `io` rather than a bare `.lock()`. It is
// a no-op spin/futex either way under `-Dsingle-threaded`.
var mu: Io.Mutex = .init;
var requests: std.AutoArrayHashMapUnmanaged(plan.SourceRef, void) = .empty;
// Recorded from the first `register()` of a build cycle and never
// overwritten thereafter — purely a witness for the same-allocator
// contract's assert below, not a value either function actually needs to
// operate (register uses its own `gpa` parameter; take uses its own). Reset
// to null once `take()` drains the collector so the next build cycle starts
// clean.
var first_gpa: ?std.mem.Allocator = null;

/// Idempotent per ref (a hundred pages referencing one image is one entry).
/// Thread-safe. Allocator contract: owned-result (NO_SLOP §2.2a contract 2) —
/// the collector owns the accumulated map until take() deinits it.
///
/// MODULE CONTRACT: every `register()`/`take()` call in a build cycle must
/// receive the *same* allocator — the collector is module-level state with
/// no per-caller identity, so a mismatched allocator would have `take()`
/// free memory the registering allocator owns. Both call sites (the
/// page-asset and site-asset analyze arms in `worker.zig`) and the sole
/// `take()` call site (`root.zig`'s `planImageVariants`) pass the build's
/// gpa, so this holds today; the assert below catches a future caller that
/// doesn't.
pub fn register(io: Io, gpa: std.mem.Allocator, ref: plan.SourceRef) error{OutOfMemory}!void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (first_gpa) |fg| {
        std.debug.assert(fg.ptr == gpa.ptr and fg.vtable == gpa.vtable);
    } else {
        first_gpa = gpa;
    }
    _ = try requests.getOrPut(gpa, ref);
}

/// Drain: returns the deduped refs (caller frees with the same gpa) and
/// resets the collector. Called exactly once per build, single-threaded,
/// after the analyze pass's worker.wait().
/// Allocator contract: self-freeing (NO_SLOP §2.2a contract 1) — the
/// duped keys escape as the return; the map is freed within.
///
/// MODULE CONTRACT: see `register()` — `gpa` here must be the same
/// allocator every `register()` call in this cycle used.
pub fn take(io: Io, gpa: std.mem.Allocator) error{OutOfMemory}![]plan.SourceRef {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (first_gpa) |fg| {
        std.debug.assert(fg.ptr == gpa.ptr and fg.vtable == gpa.vtable);
    }
    const out = try gpa.dupe(plan.SourceRef, requests.keys());
    requests.deinit(gpa);
    requests = .empty;
    first_gpa = null;
    return out;
}
