// @z/site-data under `bun test`. The build/SSR sides materialize
// the virtual module from z-runtime.config.json's `data` map
// (scripts/site-data.ts / sidecar/ssr-resolve.ts); under plain `bun test` it
// doesn't exist. The testing preload (preload.ts) registers THIS module
// override instead: config-fed like the sidecar (lazily, at first read — a
// broken data map fails only the tests that read site data), and swappable per
// test via mockSiteData(). Reads before any seed loud-fail with an actionable
// pointer, never silently yield undefined.
import { buildSiteData } from "../../scripts/site-data.ts";
import { registerModuleOnce } from "../../sidecar/ssr-resolve.ts";

const holder: Record<string, unknown> = {};
let seeded = false;
// Re-runnable config seed (set by registerTestSiteData when the config has a
// `data` map): clears + refills the holder. Re-runs after mockSiteData's
// restore() so restore always returns to the preset baseline.
let configSeed: (() => void) | null = null;

function clearHolder(): void {
  for (const k of Object.keys(holder)) delete holder[k];
}

// Lazy config seed, shared by every trap below: the FIRST observation of the
// proxy — whether a property get, Object.keys()/spread (ownKeys), an `in`
// check (has), or a descriptor lookup — must fill the holder from the config's
// `data` map, or a view whose first access enumerates keys would silently
// render from {} while the real build (sidecar/bundler) sees the data.
function seedFromConfig(): void {
  if (!seeded && configSeed) configSeed(); // loud-fails to the reader on a broken data map
}

// The module's default export: a Proxy over the mutable holder, so views that
// already hold `import site from "@z/site-data"` observe mockSiteData swaps on
// their next render. Only string-key gets loud-fail when unseeded — symbol
// probes (e.g. thenable checks during import interop) must return undefined,
// and Object.keys()/spread/`in` of an unseeded NO-CONFIG module yields {}/false
// silently (the documented unseeded state; a config-fed module always seeds
// first, whichever trap fires first).
const proxy = new Proxy(holder, {
  get(t, prop, recv) {
    seedFromConfig();
    if (!seeded && typeof prop === "string") {
      throw new Error(
        `@z/site-data has no data under bun test: add a "data" map to z-runtime.config.json ` +
          `at the website root, or call mockSiteData(...) from "@z/runtime/testing" first`,
      );
    }
    return Reflect.get(t, prop, recv);
  },
  ownKeys(t) {
    seedFromConfig();
    return Reflect.ownKeys(t);
  },
  has(t, prop) {
    seedFromConfig();
    return Reflect.has(t, prop);
  },
  getOwnPropertyDescriptor(t, prop) {
    seedFromConfig();
    return Reflect.getOwnPropertyDescriptor(t, prop);
  },
});

/**
 * Supply @z/site-data's contents for tests. Replaces the whole default
 * export's contents in place, so views that already hold
 * `import site from "@z/site-data"` see the new data on their next render.
 * Returns a restore function that reverts to the preset baseline (the config's
 * `data` map when one exists, else the unseeded loud-fail state). NOTE: a view
 * that destructures site data at MODULE scope captures values at import time —
 * mock before importing such a view.
 */
export function mockSiteData(data: Record<string, unknown>): () => void {
  clearHolder();
  Object.assign(holder, data);
  seeded = true;
  return () => {
    clearHolder();
    seeded = false; // next read re-seeds from config (if any) or loud-fails
  };
}

/**
 * Called by the testing preload (preload.ts). Registers the @z/site-data
 * module override through the sidecar's shared once-guard — idempotent per
 * process, and never stacks with the sidecar's own registration (e.g. a test
 * that also calls bundleSpa in-process).
 */
export function registerTestSiteData(dataMap: Record<string, string>, baseDir: string): void {
  if (Object.keys(dataMap).length > 0) {
    configSeed = () => {
      clearHolder();
      Object.assign(holder, buildSiteData(dataMap, baseDir).data);
      seeded = true;
    };
  }
  registerModuleOnce("@z/site-data", () => ({ exports: { default: proxy }, loader: "object" }));
}
