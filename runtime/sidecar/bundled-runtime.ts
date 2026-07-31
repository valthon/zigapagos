//! The copy of `@z/runtime` a build-time Bun process serves to the site's own
//! sources through process-global module overrides.
//!
//! WHY IT EXISTS. A site's island (`import { useState } from "@z/runtime"`) and
//! its SPA entry (`import { lazy, Router } from "@z/runtime"`) name the runtime
//! by its BARE specifier, which Bun resolves from the importing file upward
//! through `node_modules`. In a repo checkout that lands on the `runtime/` tree
//! the build tools were themselves loaded from — same files, one Preact, nobody
//! notices the resolution. An npm-installed `zigapagos` has no such package in
//! the consumer's tree, and `@z/runtime` is `private: true`, so the bare
//! specifier would simply not resolve.
//!
//! Rather than publish a second package the consumer has to install and keep in
//! version lockstep with the binary, this module hands the runtime the CLI
//! already ships to every importer under the names the exports map declares —
//! `build.module`, the same process-global override mechanism `ssr-resolve.ts`
//! already uses for the react-compat bridge. One copy, one Preact instance, no
//! consumer install step, and nothing to drift.
//!
//! TWO CALLERS, ONE TABLE. `standalone.ts` (the SSR sidecar) needs it so island
//! and SPA-skeleton rendering can import the runtime; `bundle-standalone.ts`
//! (the client bundler) needs it because `bundleSpa` IMPORTS the SPA entry at
//! runtime to map each lazy route to its chunk. Without it that import throws,
//! the mapping is silently skipped (it is best-effort by design), and the SPA
//! ships with no per-route `modulepreload` and an empty `chunks` map — a
//! degradation with no error anywhere. It lives here, rather than in either
//! caller, so the two can never answer the same specifier differently.
//!
//! WHAT IT IS NOT: a way to import `@z/runtime` outside a build. The overrides
//! live in the registering process only. The CLIENT side never resolves the bare
//! name either — island and SPA bundles keep it external and the page's import
//! map points it at `/zigapagos-runtime.js` — so both sides still converge on
//! one runtime, from opposite directions.
//!
//! ORDER. `registerModuleOnce` skips a specifier that is already claimed, so a
//! caller that registers the site's own `z-runtime.config.json` `resolve` map
//! FIRST keeps a deliberate site override winning over these defaults. Both
//! callers do exactly that.

import { createRequire } from "node:module";
import { registerModuleOnce } from "./ssr-resolve.ts";

import * as index from "../src/index.ts";
import * as core from "../src/core.ts";
import * as host from "../src/host.ts";
import * as flags from "../src/flags.ts";
import * as compat from "../src/compat/index.ts";
import * as compatClient from "../src/compat/client.ts";
import * as islands from "../src/islands.ts";
import * as jsx from "../src/jsx-runtime.ts";
import * as ssrEnv from "../src/ssr-env.ts";
import * as slots from "../src/slots.ts";
import * as router from "../src/router.ts";

type Namespace = Record<string, unknown>;

/**
 * Every specifier this table answers, and the module namespace it answers
 * with. The `@z/runtime*` rows mirror `runtime/package.json`'s `exports` map
 * one-for-one (minus `./testing*`, which is a bun-test surface and has no
 * business in a build); the `react*` rows mirror the compat aliases
 * `effectiveResolveMap` installs, so a bridged npm component SSRs here too.
 *
 * `./testing*` is omitted deliberately rather than forgotten: importing it from
 * an island would pull happy-dom into a production build, and its absence is a
 * resolution error naming the specifier, which is the correct diagnosis.
 */
const MODULES: Record<string, Namespace> = {
  "@z/runtime": index,
  "@z/runtime/core": core,
  "@z/runtime/host": host,
  "@z/runtime/flags": flags,
  "@z/runtime/compat": compat,
  "@z/runtime/compat/client": compatClient,
  "@z/runtime/islands": islands,
  "@z/runtime/jsx-runtime": jsx,
  "@z/runtime/jsx-dev-runtime": jsx,
  "@z/runtime/ssr-env": ssrEnv,
  "@z/runtime/slots": slots,
  "@z/runtime/router": router,
  react: compat,
  "react-dom": compat,
  "react-dom/client": compatClient,
  "react/jsx-runtime": jsx,
  "react/jsx-dev-runtime": jsx,
};

// Overridden modules are served to `require()` as well as to `import`, and Bun
// wires both loaders only when the FIRST fetch of a specifier is a require() —
// the same constraint `ssr-resolve.ts`'s `registerOverride` pre-warms for. A
// bridged CJS shim doing `require("react")` after an island has already imported
// it otherwise dies with "Requested module is already fetched".
const requireSpec = createRequire(import.meta.url);

/** Register the bundled runtime under every name in `MODULES`. Returns the
 *  specifiers actually claimed — a site's own `resolve` map got there first for
 *  any that are missing. Exported for the test, which asserts the exports map
 *  and this table agree. */
export function registerBundledRuntime(): string[] {
  const claimed: string[] = [];
  for (const [spec, ns] of Object.entries(MODULES)) {
    // A namespace object is not spreadable into a CJS-shaped `module.exports`
    // on its own: a consumer writing `import Preact from "react"` wants a
    // default, and these modules export only named bindings. Synthesize one
    // pointing at the namespace itself (the esModuleInterop shape), unless the
    // module really does have a default.
    const exports: Namespace = { ...ns };
    if (!("default" in exports)) exports.default = ns;
    if (!registerModuleOnce(spec, () => ({ exports, loader: "object" }))) continue;
    claimed.push(spec);
    try {
      requireSpec(spec);
    } catch {
      /* the override answers it; a failure here surfaces at first real import */
    }
  }
  return claimed;
}
