//! The SELF-CONTAINED sidecar entry: `render.ts` plus a copy of `@z/runtime`
//! served to the site's islands through Bun module overrides.
//!
//! WHY IT EXISTS. `render.ts` imports the runtime through relative paths, so it
//! always has one; the site's islands import it by its BARE name
//! (`import { useState } from "@z/runtime"`), which Bun resolves from the island
//! file upward through `node_modules`. In a repo checkout that lands on the
//! `runtime/` tree the sidecar itself was loaded from — the two are the same
//! files, so there is one Preact and nobody notices the resolution. An
//! npm-installed `zigapagos` has no such package in the consumer's tree, and
//! `@z/runtime` is `private: true`, so the bare specifier would simply not
//! resolve and every island SSR would fail.
//!
//! The table of specifiers, and the `build.module` registration that answers
//! them, live in `./bundled-runtime.ts` — shared with `bundle-standalone.ts`,
//! the client bundler's equivalent entry point, so the two can never answer the
//! same specifier differently. See that file for the full rationale.
//!
//! ORDER. Importing `./render.ts` runs its module body first, which registers
//! the site's own `z-runtime.config.json` `resolve` map. Only then does this
//! file register its defaults, and `registerModuleOnce` skips a specifier that
//! is already claimed — so a site that deliberately maps `react` (or even
//! `@z/runtime`) at something else keeps winning, exactly as under the Zig build
//! integration.

import { runSidecar } from "./render.ts";
import { registerBundledRuntime } from "./bundled-runtime.ts";

export { registerBundledRuntime };

if (import.meta.main) {
  registerBundledRuntime();
  await runSidecar();
}
