//! The SELF-CONTAINED client-bundler entry: `bundle-island.ts` plus the bundled
//! copy of `@z/runtime`, for the same reason `standalone.ts` exists on the SSR
//! side — an npm-installed `zigapagos` ships the runtime inside
//! `@zigapagos/cli`, where the consumer's own `node_modules` cannot see it.
//!
//! WHY THE BUNDLER NEEDS IT AT ALL, when island bundles resolve nothing. Bundling
//! keeps `@z/runtime` external, so `Bun.build` never has to resolve it. But the
//! code-splitting (SPA) mode does one further thing: it IMPORTS the SPA entry in
//! this process to walk its `routes` and map each lazy route to the chunk Bun
//! named after that module (`bundle-island.ts`'s `mapRouteChunks`). That import
//! is a real module load, and a `.spa.tsx` opens with
//! `import { Router, lazy } from "@z/runtime"`.
//!
//! Without the overrides that import throws, and `mapRouteChunks` — best-effort
//! by design, because a failed mapping must never fail a build — returns `{}`.
//! The bundle is still correct and the SPA still works; what is lost is silent:
//! no `modulepreload` for any lazy route and an empty `chunks` map in the
//! routing manifest, i.e. a build that succeeds while quietly shipping the
//! unoptimized shape. That is precisely the failure class this distribution
//! keeps running into, so the fix is to give the bundler the same runtime the
//! sidecar already has.
//!
//! ORDER (load-bearing, and the mirror of `standalone.ts`'s): the site's own
//! `z-runtime.config.json` `resolve` map is registered FIRST, so a site that
//! deliberately maps `react` (or `@z/runtime`) keeps winning —
//! `registerModuleOnce` skips an already-claimed specifier. `process.cwd()` is
//! the discovery root because the CLI spawns this driver with the website root
//! as its cwd, exactly as it does the sidecar.

import { registerSsrModuleOverrides } from "./ssr-resolve.ts";
import { registerBundledRuntime } from "./bundled-runtime.ts";
import { runBundleCli } from "./bundle-island.ts";

if (import.meta.main) {
  registerSsrModuleOverrides(process.cwd());
  registerBundledRuntime();
  await runBundleCli();
}
