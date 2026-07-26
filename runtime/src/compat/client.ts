// @z/runtime/compat/client — the react-dom/client surface (createRoot, hydrateRoot)
// backed by preact/compat/client. An allowlisted npm component doing
// `import { createRoot } from "react-dom/client"` is aliased (react-alias.ts) to
// this subpath, which the import-map maps to the shared runtime => one Preact.
export { createRoot, hydrateRoot } from "preact/compat/client";
import compatClientDefault from "preact/compat/client";
export default compatClientDefault;
