### Changed

- Concrete `staticPaths` pages render actual route content and params. Generic dynamic routes can use a neutral shell without a custom skeleton; lazy routes still require one and guards remain fail-closed.

### Fixed

- SPA client bundles exclude `staticPaths` and its exclusively used module bindings. Unsupported spread route definitions fail with an actionable error.
- Generic shell hydration synchronizes the requested URL before running redirects, guards, or route chunk loads.
- Pruning preserves exported helpers and dependencies of retained client initializers. Aliases sharing a destination still trigger authorization and lazy loading once after synchronization; reusable fallback shells do not preload an unrelated root chunk.
- Client bundling enforces the configured import policy for islands, SPAs, and local transitive application modules. Rails migration targets declare their generated SDK imports.
- Unchanged application sources keep Bun's native loader, including JSX in `.js` files. Build-only source transforms persist across bundler processes and invalidate when their source or toolchain changes.
- Shell path snapshots are consumed after initial hydration so later Router mounts use the live URL.
- Source-transform cache writes evict oldest entries above 128 entries or 32 MiB without adding work to cache hits. Missing compiler metadata bypasses caching, preserving the actionable runtime dependency diagnostic.
- Cache read, write and cleanup failures preserve successfully transformed code; actual compiler and route errors still fail the build.
