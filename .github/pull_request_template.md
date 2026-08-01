<!--
Thanks for contributing to Zigapagos! Keep this PR's docs and examples in sync —
stale docs ship wrong guidance to users.
-->

## Summary

<!-- What does this PR change, and why? -->

## Documentation & examples sync (required)

Docs and the examples must stay current with every change. Check each item
that applies, or strike it through / mark `N/A`:

- [ ] **`README.md`** and other top-level docs reflect this change.
- [ ] **`docs/*.md`** (source-of-truth docs: `islands.md`, `spa.md`, `observability.md`, …) updated.
- [ ] **`examples/tsx-site`** — code *and* README — updated if behavior, defaults, fields, or APIs changed.
- [ ] **`site/`** (the dogfooded project site) updated if it exercises the changed surface.
- [ ] New/changed **CLI flags & env vars** documented in the relevant `docs/*.md`.
- [ ] **`runtime/src/testing/README.md`** and `runtime/package.json` exports updated for any new runtime entry points.


## Code-quality standard (Zig changes)

[`NO_SLOP.md`](../NO_SLOP.md) is the bar every Zig change is reviewed against —
read it before requesting review, not after.

- [ ] Every allocating fn takes an `Allocator`; every acquisition has a local `defer`/`errdefer` (§2.1, §2.2).
- [ ] Each allocator-taking fn matches one of the four **ownership contracts** and says which (§2.2a).
- [ ] No swallowed errors, no `catch {}` / `catch unreachable` over genuinely-fallible calls; error sets are precise (§2.3).
- [ ] New tests use raw `std.testing.allocator` — **not** an `ArenaAllocator` wrapped around it, which turns leak detection off. If a new site is unavoidable, `scripts/check-allocator-contracts.sh` will fail until it is listed in `scripts/allocator-allowlist.txt` **with a written justification** (§2.2a).

## Verification

- [ ] `zig build` and `zig build test` pass (and `zig build -Dsingle-threaded` still compiles).
- [ ] `scripts/check-allocator-contracts.sh` passes.
- [ ] `zig build api-check` passes if `contract/` or `runtime/scripts/apigen.ts` changed.
- [ ] The targeted unit-test steps for the touched areas pass (`zig build test-islands | test-dev | test-release | …`).
- [ ] `cd runtime && bun test` passes for any `runtime/` change.
- [ ] The relevant `tests/dev/*.sh` e2e scripts pass for dev-loop behavior changes.
