// Resolve the compiler from the shipped runtime installation, rather than the
// user's PATH or Bun's package runner (which could download a different tsc).
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
let compiler: string;
try { compiler = require.resolve("typescript/bin/tsc"); }
catch { throw new Error("Island props checking requires TypeScript in the Zigapagos runtime installation; reinstall the runtime dependencies."); }
await import(compiler);
