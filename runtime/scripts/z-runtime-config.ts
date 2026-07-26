// Shared loader for the optional `z-runtime.config.json` at a website root.
// Consumed by the import linter (lint-island-imports.ts), the client bundler
// (bundle-island.ts), and the build-time SSR sidecar (render.ts). Absent config
// => base behavior (allow @z/runtime(/*) + relative only, no npm bridge).
//
// Shape (all fields optional):
//   { "islandImports": {
//       "firstParty": ["@myapp/shared"],   // extra allowed import scopes (a pkg
//                                           //   name; its subpaths are allowed too)
//       "npmCompat":  ["react-router-dom"]  // opt-in npm packages bundled with
//                                           //   react -> @z/runtime/compat (one Preact)
//     },
//     "resolve": {                          // module-resolution overrides:
//       "react": "@z/runtime/compat"       //   EVERY resolution of the key — from
//     },                                    //   any file, any package depth — lands
//                                           //   on the value (exact-match keys)
//     "data": {                             // @z/site-data content selection:
//       "services": "content/services/*.smd"  // key -> file or glob, relative to
//     }                                     //   this config file's directory
//   }
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export interface IslandImportsConfig {
  /** Extra allowed import scopes (package name; subpaths allowed too). */
  firstParty: string[];
  /** Opt-in npm packages bundled with react/react-dom aliased to the shared runtime. */
  npmCompat: string[];
}

export interface ZRuntimeConfig {
  islandImports: IslandImportsConfig;
  /**
   * Module-resolution overrides: every resolution of a key
   * specifier — from any file, at any package depth (firstParty workspace
   * packages, npmCompat deps) — lands on the value module. Keys match the
   * exact specifier only (no subpaths). Relative values resolve from the
   * config file's directory. Applied by BOTH the SSR sidecar and the
   * island/SPA bundler.
   */
  resolve?: Record<string, string>;
  /**
   * `@z/site-data` content selection: each key names a member of
   * the virtual module's default export; each value is a content file path or
   * glob, relative to the config file's directory. See scripts/site-data.ts.
   */
  data?: Record<string, string>;
}

export const EMPTY_CONFIG: ZRuntimeConfig = {
  islandImports: { firstParty: [], npmCompat: [] },
};

/**
 * The default `resolve` map for compat-bridge sites: whenever `firstParty` or
 * `npmCompat` is non-empty, bare react/react-dom/jsx-runtime imports resolve to
 * the shared `@z/runtime` compat surface (the ONE-Preact invariant is
 * unconditional for bridge sites). A user `resolve` entry for the same key
 * overrides its default. Pinned to react-alias.ts's REACT_ALIAS by a test —
 * the two sides (SSR override / client external+import-map) must not drift.
 */
export const RESOLVE_DEFAULTS: Readonly<Record<string, string>> = {
  "react": "@z/runtime/compat",
  "react-dom": "@z/runtime/compat",
  "react-dom/client": "@z/runtime/compat/client",
  "react/jsx-runtime": "@z/runtime/jsx-runtime",
  "react/jsx-dev-runtime": "@z/runtime/jsx-dev-runtime",
};

/**
 * Identity entries that make `@z/runtime` (+ its import-map subpaths) resolve
 * from ANY file. An out-of-tree bridged package (a `firstParty` workspace dir,
 * an `npmCompat` dep hoisted elsewhere) has no `@z/runtime` in its own
 * node_modules chain, yet its transpiled JSX (a site tsconfig with
 * `jsxImportSource: "@z/runtime"`) and the mapped react targets both name
 * these specifiers. Self-mapping routes them through the override machinery,
 * whose targets resolve from the config dir/runtime tree — position-
 * independent, no per-package symlinks. On the client-bundler side these are
 * import-map specifiers mapped to themselves, so they stay EXTERNAL
 * (react-alias.ts) — never inlined.
 */
export const RUNTIME_SELF_ENTRIES: Readonly<Record<string, string>> = {
  "@z/runtime": "@z/runtime",
  "@z/runtime/jsx-runtime": "@z/runtime/jsx-runtime",
  "@z/runtime/jsx-dev-runtime": "@z/runtime/jsx-dev-runtime",
  "@z/runtime/compat": "@z/runtime/compat",
  "@z/runtime/compat/client": "@z/runtime/compat/client",
};

/**
 * The effective resolution-override map for a config: the react->compat
 * defaults + the runtime self-entries (iff the site bridges any
 * firstParty/npmCompat package) overlaid with the user's explicit `resolve`
 * entries (which win per key).
 */
export function effectiveResolveMap(config: ZRuntimeConfig): Record<string, string> {
  const bridged =
    config.islandImports.firstParty.length > 0 || config.islandImports.npmCompat.length > 0;
  return {
    ...(bridged ? { ...RESOLVE_DEFAULTS, ...RUNTIME_SELF_ENTRIES } : {}),
    ...(config.resolve ?? {}),
  };
}

const CONFIG_NAME = "z-runtime.config.json";

/**
 * Resolve a `resolve`-map TARGET to an importable path — shared by the SSR
 * override registration (ssr-resolve.ts) and the client bundler plugin
 * (react-alias.ts), so both sides fail a bad target with the same actionable
 * message. Relative targets (and bare package targets) resolve from `baseDir`
 * — the config file's directory, i.e. the website root, mirroring how the
 * documented tsconfig `paths` resolved the compat surface
 * (`./node_modules/@z/runtime/src/...`). Falls back to the framework's own
 * runtime tree so `@z/runtime/*` targets work where the site has no
 * node_modules (e.g. the built-in test fixtures).
 */
export function resolveConfigTarget(target: string, baseDir: string): string {
  try {
    return Bun.resolveSync(target, baseDir);
  } catch (primary) {
    try {
      return Bun.resolveSync(target, resolve(import.meta.dir, "..")); // runtime/ (self-references @z/runtime)
    } catch {
      throw new Error(
        `${CONFIG_NAME}: resolve target "${target}" is not importable from ${baseDir}: ` +
          `${primary instanceof Error ? primary.message : String(primary)}`,
      );
    }
  }
}

/** Walk up from `startDir` looking for z-runtime.config.json. Returns the abs path or null. */
export function findConfigPath(startDir: string): string | null {
  let dir = resolve(startDir);
  for (;;) {
    const p = join(dir, CONFIG_NAME);
    if (existsSync(p)) return p;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function asStringArray(v: unknown, where: string): string[] {
  if (v === undefined) return [];
  if (!Array.isArray(v)) throw new Error(`${CONFIG_NAME}: ${where} must be an array of strings`);
  for (const e of v) {
    if (typeof e !== "string") throw new Error(`${CONFIG_NAME}: ${where} entries must be strings`);
  }
  return v as string[];
}

function asStringMap(v: unknown, where: string): Record<string, string> {
  if (v === undefined) return {};
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    throw new Error(`${CONFIG_NAME}: ${where} must be an object of string -> string`);
  }
  for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
    if (typeof val !== "string" || val.length === 0 || k.length === 0) {
      throw new Error(`${CONFIG_NAME}: ${where} entries must map a specifier to a non-empty string ("${k}")`);
    }
  }
  return v as Record<string, string>;
}

/** Validate an already-JSON-parsed config value into the normalized shape. Loud-fail on bad shape. */
export function validateConfig(raw: unknown): ZRuntimeConfig {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`${CONFIG_NAME}: top level must be an object`);
  }
  const ii = (raw as Record<string, unknown>).islandImports;
  if (ii !== undefined && (ii === null || typeof ii !== "object" || Array.isArray(ii))) {
    throw new Error(`${CONFIG_NAME}: islandImports must be an object`);
  }
  const io = (ii ?? {}) as Record<string, unknown>;
  return {
    islandImports: {
      firstParty: asStringArray(io.firstParty, "islandImports.firstParty"),
      npmCompat: asStringArray(io.npmCompat, "islandImports.npmCompat"),
    },
    resolve: asStringMap((raw as Record<string, unknown>).resolve, "resolve"),
    data: asStringMap((raw as Record<string, unknown>).data, "data"),
  };
}

/**
 * Load the config from an explicit `configPath` (if it exists) else by searching
 * upward from `startDir`. Returns the normalized config and the resolved path
 * (null when no config file was found — callers add the path to a depfile so a
 * config edit invalidates the affected bundles).
 */
export function loadConfig(opts: { configPath?: string; startDir?: string }): {
  config: ZRuntimeConfig;
  path: string | null;
} {
  let p: string | null = null;
  if (opts.configPath) {
    const abs = resolve(opts.configPath);
    if (existsSync(abs)) p = abs;
  }
  if (!p && opts.startDir) p = findConfigPath(opts.startDir);
  if (!p) return { config: EMPTY_CONFIG, path: null };
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(p, "utf8"));
  } catch (e) {
    throw new Error(`${CONFIG_NAME}: failed to read/parse ${p}: ${e instanceof Error ? e.message : String(e)}`);
  }
  return { config: validateConfig(raw), path: p };
}
