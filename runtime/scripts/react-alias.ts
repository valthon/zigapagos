// The CLIENT-side react/react-dom bridge for the island/SPA bundler
// (bundle-island.ts).
//
// THE ONE-PREACT INVARIANT (client): an npm React component's
// `import { useState } from "react"` is kept EXTERNAL in the island/SPA bundle
// (the bare `react` specifier survives). The page import-map (pass.zig) maps
// `react` (and friends) to the shared /zigapagos-runtime.js, which re-exports the
// full preact/compat surface => ONE shared Preact. Bun.build does NOT rewrite an
// external specifier, so we do not rename — the import-map does the mapping. Never
// inline preact/compat into an island bundle (a 2nd Preact).
//
// The externalization is UNCONDITIONAL: react is never legitimately bundled into
// an island, so it is always kept external — this closes a footgun where a
// consumer's tsconfig `paths` (needed for SSR, below) would otherwise cause
// Bun.build to resolve `react` -> preact/compat and INLINE a silent 2nd Preact.
// The lint (z-runtime.config.json `npmCompat`) remains the POLICY gate: an
// un-allowlisted react import still fails the lint.
//
// SSR is handled separately by runtime module overrides (sidecar/ssr-resolve.ts —
// Bun runtime plugins cannot intercept bare specifiers via onResolve). REACT_ALIAS
// documents that mapping (pinned to z-runtime-config.ts's RESOLVE_DEFAULTS by
// test); the client keys below map to the shared runtime via the import-map.
import type { BunPlugin } from "bun";
import { resolveConfigTarget } from "./z-runtime-config.ts";

/** The bare specifiers an npm React component may import, and their compat target. */
export const REACT_ALIAS: Readonly<Record<string, string>> = {
  "react": "@z/runtime/compat",
  "react-dom": "@z/runtime/compat",
  "react-dom/client": "@z/runtime/compat/client",
  "react/jsx-runtime": "@z/runtime/jsx-runtime",
  "react/jsx-dev-runtime": "@z/runtime/jsx-dev-runtime",
};

// onResolve filter matching exactly the bridged specifiers (nothing else — e.g.
// `react-router-dom` must pass through to be bundled normally).
const FILTER = /^(react|react-dom|react-dom\/client|react\/jsx-runtime|react\/jsx-dev-runtime)$/;

/**
 * Bun.build plugin for the CLIENT bundle: keep react* EXTERNAL (the import-map
 * resolves the bare specifier to the shared runtime at load time => one Preact).
 * Always active — react is never legitimately bundled into an island.
 */
export function reactAliasBuildPlugin(): BunPlugin {
  return {
    name: "z-react-external",
    setup(build) {
      build.onResolve({ filter: FILTER }, (args) => {
        // Keep the original specifier and mark it external — the page import-map
        // maps it to /zigapagos-runtime.js (Bun.build does not rename externals).
        return { path: args.path, external: true };
      });
    },
  };
}

/**
 * Every specifier present in the page import map (pass.zig `import_map` /
 * `importMapFor`): the browser resolves these to the shared (or per-SPA sliced)
 * runtime bundle, so the CLIENT build may keep them external.
 */
export const IMPORT_MAP_SPECIFIERS: ReadonlySet<string> = new Set([
  "@z/runtime",
  "@z/runtime/jsx-runtime",
  "@z/runtime/jsx-dev-runtime",
  "@z/runtime/compat",
  "@z/runtime/compat/client",
  ...Object.keys(REACT_ALIAS),
]);

const SHIM_NS = "z-resolve-shim";

/**
 * Bun.build plugin applying the z-runtime.config.json `resolve` override map
 * to the CLIENT bundle. For each mapped specifier (EXACT match, any
 * importer at any package depth):
 *
 * - key AND target both in the page import map (e.g. the react->compat
 *   DEFAULTS): keep the ORIGINAL specifier external — byte-identical to
 *   reactAliasBuildPlugin, the import map does the mapping in the browser.
 * - target on the `@z/runtime` surface but the KEY not in the import map
 *   (a custom alias): Bun.build never rewrites an external specifier, so the
 *   key resolves to a virtual re-export shim whose own `@z/runtime/*` import
 *   is kept external => the import map resolves it (one Preact, never inlined).
 * - anything else: resolve the target from `baseDir` (the config file's dir)
 *   and bundle it.
 *
 * Register this BEFORE reactAliasBuildPlugin so an explicit user override of a
 * react* key wins over the unconditional externalization.
 */
export function resolveOverridePlugin(map: Record<string, string>, baseDir: string): BunPlugin {
  const entries = Object.entries(map);
  return {
    name: "z-resolve-overrides",
    setup(build) {
      if (entries.length === 0) return;
      const bySpec = new Map(entries);
      // `RegExp.escape`: the alias keys are user-supplied specifiers that may
      // carry metacharacters, and this pattern is consumed only by Bun's
      // onResolve filter — never read by a human, so the stdlib escaper's
      // `\x`-heavy spelling is free here.
      const filter = new RegExp(`^(${entries.map(([s]) => RegExp.escape(s)).join("|")})$`);
      build.onResolve({ filter }, (args) => {
        const target = bySpec.get(args.path);
        if (target === undefined) return undefined;
        if (IMPORT_MAP_SPECIFIERS.has(args.path) && IMPORT_MAP_SPECIFIERS.has(target)) {
          return { path: args.path, external: true };
        }
        if (target.startsWith("@z/runtime")) {
          return { path: args.path, namespace: SHIM_NS };
        }
        // Shared resolver (z-runtime-config.ts): config-dir first, runtime/-tree
        // fallback, and an actionable `resolve target "…" is not importable`
        // error otherwise — same failure mode as the SSR side.
        return { path: resolveConfigTarget(target, baseDir) };
      });
      // The shim's own `@z/runtime/*` import: ALWAYS external (the runtime is
      // never legitimately inlined — same footgun-closer as react above), even
      // if the caller's --external list were to omit it.
      build.onResolve({ filter: /^@z\/runtime(\/|$)/ }, (args) => {
        if (args.namespace !== SHIM_NS) return undefined;
        return { path: args.path, external: true };
      });
      build.onLoad({ filter: /.*/, namespace: SHIM_NS }, (args) => {
        const target = bySpec.get(args.path)!;
        // The shared runtime bundle (browser-entry.ts) exports a default (the
        // React compat object), so the default re-export always links.
        const t = JSON.stringify(target);
        return {
          contents: `export * from ${t};\nexport { default } from ${t};\n`,
          loader: "js",
          resolveDir: baseDir,
        };
      });
    },
  };
}
