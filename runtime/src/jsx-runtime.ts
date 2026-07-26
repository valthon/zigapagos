// The JSX factory the runtime exposes to islands as @z/runtime/jsx-runtime.
// Islands set jsxImportSource: "@z/runtime", so their JSX compiles to imports
// from here; routing it through @z/runtime keeps the JSX factory on the SAME
// Preact instance as the loader's hydrate (one instance — hooks work).
export { jsx, jsxs, jsxDEV, Fragment } from "preact/jsx-runtime";
