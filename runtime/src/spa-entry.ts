// The entry for a PER-SPA SLICED runtime (see runtime/scripts/build-spa-runtime.ts
// + build.zig's addSpaAssets). It is browser-entry.ts MINUS the preact/compat +
// React-surface re-exports: a sliced runtime is only ever used by a first-party
// SPA that does NOT touch @z/runtime/compat or bare `react` (the slicer falls
// back to the full shared /zigapagos-runtime.js the moment a SPA uses those), so
// omitting that surface is safe and buys the real size + separation win — the
// compat shims (e.g. recaptcha.ts, which references host.loadScript) are never in
// a sliced bundle, so an admin-only host binding can be genuinely DCE'd out.
//
// The per-SPA host slice is applied at BUILD time, not here: the driver bundles
// this entry with a Bun onResolve alias that redirects the runtime's own
// `./host.ts` imports (in index.ts, router.ts, flags.ts, api.ts) to a generated
// sliced-host module built from only the members that SPA uses. This file is
// host-agnostic; do not import host here.
export * from "./index.ts";
export { jsx, jsxs, jsxDEV, Fragment } from "./jsx-runtime.ts";
