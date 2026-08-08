> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/react-spa-bridge/> — the site is the canonical reading experience.

# Incremental React → `@z/runtime` bridge (preact/compat)

Port a React SPA (or islands) to zigapagos **import-by-import** instead of a big-bang rewrite.
An opt-in npm package keeps its `import { ... } from "react"` lines and bundles against the
**shared** Preact via `@z/runtime/compat`, so a half-ported app runs on one Preact instance.

There is no de-React codemod and no separate tool to run: you port in place, one package at a
time.

## The allowlist config — `z-runtime.config.json`

Islands/SPAs may import only `@z/runtime` (+ subpaths) and relative paths by default. Add a
`z-runtime.config.json` at your website root to widen that:

```jsonc
{
  "islandImports": {
    "firstParty": ["@myapp/shared"],           // your own workspace scopes (allowed as-is)
    "npmCompat": ["react-router-dom", "some-react-lib"]  // opt-in npm, run under preact/compat
  },
  "resolve": {                                  // optional: module-resolution overrides
    "@legacy/store": "@z/runtime/compat"       // every resolution of the key lands on the value
  }
}
```

- `firstParty` — extra first-party scopes the import lint allows verbatim (exact string or a
  regex fragment). No scope is allowed by default; declare your own here.
- `npmCompat` — npm packages you've vetted to run under `preact/compat`. Listing a package here
  lets the import lint accept it; the package bundles normally, but its `react`/`react-dom`
  imports resolve to the shared runtime (see below).
- `resolve` — module-resolution overrides (see next section).

The lint (`runtime/scripts/lint-island-imports.ts`) reads this file (auto-discovered upward from
the linted file, or `--config <path>`). A bare-CLI lint walks up to the filesystem root to find
it, so avoid a stray `z-runtime.config.json` in an unrelated ancestor dir.

## Module-resolution overrides — `resolve`

Both the **SSR sidecar** and the **island/SPA bundler** apply the `resolve` map as a Bun
resolution override: every resolution of a mapped specifier — from any file, at any package
depth (`firstParty` workspace packages, `npmCompat` deps) — lands on the mapped module. This
enforces the ONE-Preact invariant as one config line: no shim packages, no `file:` redirects,
no per-machine symlinks into each workspace package's `node_modules`.

**Defaults:** whenever `firstParty` or `npmCompat` is non-empty, the framework default-maps

```jsonc
{
  "react": "@z/runtime/compat",
  "react-dom": "@z/runtime/compat",
  "react-dom/client": "@z/runtime/compat/client",
  "react/jsx-runtime": "@z/runtime/jsx-runtime",
  "react/jsx-dev-runtime": "@z/runtime/jsx-dev-runtime"
}
```

so a compat-bridge site needs **no** `resolve` block at all for react. An explicit `resolve`
entry for the same key overrides its default.

Semantics:

- Keys match the **exact** specifier only (no subpaths — map `react/jsx-runtime` separately
  from `react`). Mapped keys are automatically importable (exact match) under the lint.
- Relative targets (`"./vendor/x.ts"`) resolve from the config file's directory.
- Client bundle: a mapped specifier whose target is on the `@z/runtime` surface stays
  **external** (the page import-map resolves it to the shared runtime — never a second inlined
  Preact); custom keys are rewritten through a tiny virtual re-export shim since a plain
  external is never renamed. Any other target is resolved and bundled.
- SSR sidecar: overrides are registered as process-global Bun module mocks before any island or
  SPA module is imported, so they also apply to imports made *inside* `node_modules` packages.

## Optional: tsconfig `paths` for TYPES

Runtime resolution does not need tsconfig `paths` — the `resolve` defaults above cover SSR.
To point `tsc` at the compat **types** for bare `react` imports, keep (or add) the mapping in
your website `tsconfig.json`:

```jsonc
{
  "compilerOptions": {
    "paths": {
      "react": ["./node_modules/@z/runtime/src/compat/index.ts"],
      "react-dom": ["./node_modules/@z/runtime/src/compat/index.ts"],
      "react-dom/client": ["./node_modules/@z/runtime/src/compat/client.ts"],
      "react/jsx-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"],
      "react/jsx-dev-runtime": ["./node_modules/@z/runtime/src/jsx-runtime.ts"]
    }
  }
}
```

(`@z/runtime/compat` re-exports the full `preact/compat` React surface.)

## Workflow

1. Move a component (or a whole npm dep) into the island/SPA tree; keep its `react` imports.
2. Add the package to `npmCompat` (and any workspace scope to `firstParty`).
3. Lint (`zigapagos` runs it in `ssr.sh`/`spa.sh`) — an un-allowlisted npm import fails loudly, so you
   port deliberately, one dependency at a time.
4. Build: `react` stays external → one Preact; SSR resolves via the `resolve` defaults above.

## Caveats

- **No module-scope browser side effects.** A component that touches `window`/`document` at
  module top level breaks build-time SSR — mark the island `client:only` or guard the access.
- **`React.lazy` is not supported through the bridge.** The shared `lazy` is zigapagos's
  route-level `lazy()`. Calling `React.lazy(...)` in an npm component and rendering it throws a
  loud error (rather than silently rendering nothing) — split at the *route* level with
  `lazy()` instead (see `docs/spa.md` → Code Splitting).
- **One Preact is enforced by keeping `react` external** — never let a build inline
  `preact/compat` into an island bundle. `react` is externalized unconditionally, and `resolve`
  targets on the `@z/runtime` surface are likewise always kept external, so an override can't
  accidentally inline a second Preact into the client.
