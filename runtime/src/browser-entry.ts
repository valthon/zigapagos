// The entry bun-build'd into /zigapagos-runtime.js — the ONE shared runtime.
// It re-exports the full @z/runtime barrel (so islands' `import … from "@z/runtime"`
// resolves here via the page's import map) AND the jsx-runtime names (so
// `@z/runtime/jsx-runtime` resolves here too). Importing the barrel pulls in
// islands.ts, whose module body auto-inits the loader (discovers placeholders,
// import()s each island module, hydrates). One module instance, one Preact.
// The compat subpath symbols are also exported here so that `@z/runtime/compat`
// can map to this same file in the import map (one bundle, one Preact instance).
export * from "./index.ts";
export { jsx, jsxs, jsxDEV, Fragment } from "./jsx-runtime.ts";

// Publish the dev-only island HMR global. Inert in production: it
// only assigns `window.__zigapagos_hmr`, which nothing calls unless the dev
// reload snippet (src/cli/reload.zig, DEV-ONLY) is on the page.
import { installHmr } from "./hmr.ts";
installHmr();
// compat-only symbols (not already in ./index.ts):
export { makeSharedResource, FlagsProvider, useExperiment } from "./compat/index.ts";
export { ReCAPTCHA, useRecaptcha } from "./compat/index.ts";
export type { RecaptchaHandle, SharedResource } from "./compat/index.ts";
// The FULL preact/compat React surface, so `@z/runtime/compat` (import-map ->
// this same bundle) serves an allowlisted npm React component's `react`/`react-dom`
// imports at runtime => ONE Preact. EXPLICIT named re-exports (not `export *`):
// a second `export *` here would collide with `./index.ts` on overlapping names
// (useState, Fragment, forwardRef, …) and Bun would silently DROP them, breaking
// `import { useState } from "@z/runtime"`. So we re-export only the names NOT
// already in the barrel; `lazy` is deliberately omitted (the barrel's router
// `lazy` owns that name in the shared bundle — React.lazy is unavailable here).
export {
  Children, Component, PureComponent, StrictMode, Suspense, SuspenseList,
  cloneElement, createElement, createFactory, createRef, findDOMNode, flushSync,
  hydrate, isFragment, isMemo, isValidElement, memo, render,
  startTransition, unmountComponentAtNode, unstable_batchedUpdates, useDebugValue,
  useDeferredValue, useId, useInsertionEffect, useTransition,
  version,
} from "./compat/index.ts";
export { default } from "./compat/index.ts"; // the React default object (React.createElement, …)
export { createRoot, hydrateRoot } from "./compat/client.ts"; // react-dom/client surface
