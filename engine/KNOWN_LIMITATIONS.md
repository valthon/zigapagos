# Known Limitations

Deferred items surfaced during final code review. These are documented here
as guidance for the next implementation plan (hydration / LiveBackend work).

---

## 1. Unbounded `persistent`-arena growth under node churn

**Location:** `engine/src/component.zig` — the `persistent` field of `Component`.

**Summary:** `component.zig` allocates the retained `Mounted` tree (and child
`ArrayList`s) into a `persistent` arena that is never reset until `deinit`.
`reconciler.reconcile` creates a new `Mounted` on every fresh mount,
type/tag-mismatch replace, and newly-keyed child, but dropped/removed `Mounted`
structs are never reclaimed — an arena cannot free individual allocations.

Therefore a component whose tree **churns** across updates (conditional
rendering, growing/shrinking lists, text↔element swaps) accumulates dead
`Mounted` structs for the component's lifetime — unbounded growth. Steady-state
same-shape reuse does **not** grow. This does not affect the public `Component`
API and can be retrofitted without breaking consumers.

**Planned fix:** Give the reconciler an explicit recursive unmount/free path for
dropped subtrees (free child `ArrayList`s) backed by a
`std.heap.MemoryPool(Mounted)` or a freelist instead of an arena, OR
periodically rebuild the tree.

**Suggested validation:** Add a churn test (toggle element type N times, assert
bounded allocation) alongside the fix.

---

## 2. Keyed reorder is not minimal

**Location:** `engine/src/reconciler.zig` — `reconcileKeyed`, the
`b.appendChild` call inside the reuse branch.

**Summary:** `reconcileKeyed` calls `appendChild` for every reused keyed child
on every update (to enforce order), so a no-op update on a stable N-item keyed
list emits N `append_child` DOM ops instead of zero. The current test only
asserts "no `create_element`", so it passes while the patch is non-minimal.

This is acceptable for the build-time `StringBackend` (which ignores order ops)
but will cause real DOM thrash under a future `LiveBackend`: moving a node in
the DOM forces layout/paint for affected siblings.

**Planned fix:** Compute a longest-increasing-subsequence (or last-placed-index
high-water mark) and only `insertBefore` nodes that actually moved. Nodes
already in their correct relative position need no DOM op.
