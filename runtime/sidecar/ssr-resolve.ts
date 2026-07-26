// SSR-side resolution overrides.
//
// Bun RUNTIME plugins can't intercept bare specifiers via onResolve (only
// Bun.build can), but `build.module(specifier, cb)` registers a process-global
// module override that wins over node_modules resolution for EVERY import of
// that exact specifier — from any file, at any package depth. That is exactly
// the ONE-Preact guarantee the compat bridge needs at SSR time: with
// z-runtime.config.json's `resolve` map (+ the react->compat DEFAULTS when
// firstParty/npmCompat is non-empty), a bridged npm component's
// `import { useState } from "react"` lands on the shared @z/runtime/compat with
// NO tsconfig `paths` and NO per-machine shim packages/symlinks.
//
// Used by render.ts (the NDJSON sidecar), render-once.ts, bundle-island.ts
// (whose route-chunk mapping imports the SPA entry at runtime), and the
// bun-test preload (src/testing/preload.ts), which applies the same
// resolve-map overrides so out-of-tree workspace views resolve identically
// under `bun test` — with its own mockable @z/site-data.
import { dirname } from "node:path";
import { createRequire } from "node:module";
import {
  loadConfig,
  effectiveResolveMap,
  resolveConfigTarget,
  type ZRuntimeConfig,
} from "../scripts/z-runtime-config.ts";
import { buildSiteData } from "../scripts/site-data.ts";

/**
 * Resolve an override TARGET to an importable path — the shared
 * `resolveConfigTarget` (z-runtime-config.ts): the config's dir first, the
 * framework runtime/ tree as fallback, an actionable error otherwise. The
 * client bundler plugin (react-alias.ts) uses the same resolver, so a bad
 * target fails identically on both sides.
 */
export const resolveSsrTarget = resolveConfigTarget;

// Specs already overridden in this process — Bun module overrides are
// process-global, so re-registration (e.g. two bundleSpa calls in one test
// process) is skipped rather than stacked.
const registered = new Set<string>();

// Loads override targets SYNCHRONOUSLY. An async `build.module` callback
// would make the overridden module itself async, and a CJS consumer in the
// bridged graph (e.g. use-sync-external-store's shim doing `require("react")`)
// then dies with `require() async module is unsupported`. Bun's require()
// loads the (TLA-free) runtime modules fine and returns their namespace.
const requireTarget = createRequire(import.meta.url);

/**
 * Register a caller-supplied `build.module` factory for `spec` through the same
 * process-global once-guard the sidecar overrides use. Returns false (and does
 * nothing) when `spec` is already overridden in this process. Used by the
 * testing preload (src/testing/site-data.ts) so its @z/site-data registration
 * and the sidecar's never stack.
 */
export function registerModuleOnce(
  spec: string,
  factory: () => { exports: Record<string, unknown>; loader: "object" },
): boolean {
  if (registered.has(spec)) return false;
  registered.add(spec);
  Bun.plugin({
    name: `z-resolve-override:${spec}`,
    setup(build) {
      build.module(spec, factory);
    },
  });
  return true;
}

/** Register one module override: every import of `spec` yields `target`'s namespace. */
function registerOverride(spec: string, target: string, baseDir: string): void {
  if (registered.has(spec)) return;
  registered.add(spec);
  Bun.plugin({
    name: `z-resolve-override:${spec}`,
    setup(build) {
      build.module(spec, () => {
        const ns = requireTarget(resolveSsrTarget(target, baseDir));
        // require() returns raw `module.exports` for CJS targets, not an ESM
        // namespace. Interop shape (the esModuleInterop rules):
        //   - object WITH `default` (an ESM namespace) → spread as-is;
        //   - object/function WITHOUT `default` (plain CJS exports, or
        //     `module.exports = fn/class` — a bare spread of a function would
        //     yield `{}` and lose the export) → synthesize `default: ns` and
        //     spread own enumerable props as named exports;
        //   - primitive → default-only.
        const exports =
          ns && typeof ns === "object" && "default" in ns
            ? { ...ns }
            : ns && (typeof ns === "object" || typeof ns === "function")
              ? { default: ns, ...ns }
              : { default: ns };
        return { exports, loader: "object" };
      });
    },
  });
  // Pre-warm through the REQUIRE loader. Bun serves a module override to both
  // loaders only when its first fetch is a require(); an ESM-import-first
  // fetch leaves a later require() of the same spec dying with "Requested
  // module is already fetched" — and mixed graphs are the norm (a bridged
  // component imports "react" while use-sync-external-store's CJS shim
  // require()s it). A broken target is NOT a registration error: it still
  // fails at first real use with resolveSsrTarget's actionable message.
  try {
    requireTarget(spec);
  } catch {
    /* surfaces at first actual import */
  }
}

export interface SsrOverridesResult {
  config: ZRuntimeConfig;
  /** Abs path of the discovered z-runtime.config.json, or null. */
  configPath: string | null;
  /** Dir the config was found in (target resolution base), else `startDir`. */
  baseDir: string;
}

/**
 * Register ONLY the effective `resolve`-map overrides (no @z/site-data) —
 * shared by registerSsrModuleOverrides and the bun-test preload
 * (src/testing/preload.ts), which supplies its own mockable @z/site-data.
 * Discovers z-runtime.config.json upward from `startDir`.
 */
export function registerResolveOverrides(startDir: string): SsrOverridesResult {
  const { config, path } = loadConfig({ startDir });
  const baseDir = path ? dirname(path) : startDir;
  for (const [spec, target] of Object.entries(effectiveResolveMap(config))) {
    registerOverride(spec, target, baseDir);
  }
  return { config, configPath: path, baseDir };
}

/**
 * Discover z-runtime.config.json upward from `startDir` (the website root —
 * the sidecar's cwd, exactly where the Zig build spawns it) and register the
 * effective `resolve` map + @z/site-data as process-global module overrides.
 * Idempotent per process in practice (call once at startup, before any
 * island/SPA import).
 */
export function registerSsrModuleOverrides(startDir: string): SsrOverridesResult {
  const r = registerResolveOverrides(startDir);
  registerSiteData(r.config.data ?? {}, r.baseDir);
  return r;
}

/**
 * `@z/site-data` at SSR: the virtual module built from the config's
 * `data` map (see scripts/site-data.ts). Built lazily on first import, once
 * per sidecar process — the sidecar is respawned every build/dev rebuild, so
 * prerendered output always sees fresh content. With no `data` map the import
 * fails loudly with a pointer to the config.
 */
function registerSiteData(dataMap: Record<string, string>, baseDir: string): void {
  registerModuleOnce("@z/site-data", () => {
    if (Object.keys(dataMap).length === 0) {
      throw new Error(
        `@z/site-data imported, but z-runtime.config.json declares no "data" map ` +
          `(add e.g. { "data": { "services": "content/services/*.smd" } } at the website root)`,
      );
    }
    const { data } = buildSiteData(dataMap, baseDir);
    return { exports: { default: data }, loader: "object" };
  });
}
