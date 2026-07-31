import { test, expect } from "bun:test";
import { join } from "node:path";
import { SOURCE_RE, readSourcesOrFail } from "./build-spa-runtime.ts";

// ── SOURCE_RE: every CODE module extension Bun may load (incl .mts/.cts) ─────

test("SOURCE_RE matches all code-module extensions incl .mts/.cts", () => {
  for (const ext of ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"]) {
    expect(SOURCE_RE.test(`/x/foo.${ext}`)).toBe(true);
  }
});

test("SOURCE_RE ignores non-code assets (css/json/svg/wasm)", () => {
  for (const ext of ["css", "json", "svg", "wasm", "png"]) {
    expect(SOURCE_RE.test(`/x/foo.${ext}`)).toBe(false);
  }
});

// ── readSourcesOrFail: read failure → fallback (null), never a silent drop ───

test("readSourcesOrFail reads real code files and skips @z/runtime + non-code", () => {
  const here = import.meta.dir;
  const res = readSourcesOrFail([
    join(here, "slice-host.ts"),
    join(here, "..", "src", "index.ts"),
    "/somewhere/node_modules/@z/runtime/src/host.ts", // external — skipped, not read
    join(here, "..", "package.json"),                  // non-code — skipped
  ]);
  expect(res).not.toBeNull();
  const paths = res!.map((s) => s.path);
  expect(paths.some((p) => p.endsWith("slice-host.ts"))).toBe(true);
  expect(paths.some((p) => p.endsWith("index.ts"))).toBe(true);
  expect(paths.some((p) => p.includes("@z/runtime"))).toBe(false);
  expect(paths.some((p) => p.endsWith("package.json"))).toBe(false);
});

test("readSourcesOrFail returns null (fallback) when a captured CODE file cannot be read", () => {
  const res = readSourcesOrFail([
    join(import.meta.dir, "slice-host.ts"),
    "/nonexistent/definitely/missing.tsx", // a code file that fails to read
  ]);
  expect(res).toBeNull();
});

// ── The slicer must be reached LAZILY, so typescript stays optional ─────────

// `slice-host.ts` does `import ts from "typescript"` at module scope. This file
// is shipped inside @zigapagos/cli, where typescript is an OPTIONAL dependency —
// so on an install that skipped it, a VALUE import of slice-host.ts here makes
// this whole module unloadable and fails the build outright, for a step that is
// only ever an optimization (`loadSlicer` falls back to the shared runtime).
//
// That is exactly what happened: a hermetic npm install died with "Cannot find
// package 'typescript'". The property is a source-level one — whether the edge
// is static or dynamic — so it is asserted on the source. A behavioural test
// cannot reach it: Bun resolves node_modules by walking up from the FILE, so a
// test process cannot hide typescript from a module in this tree.
test("build-spa-runtime imports slice-host lazily, never as a static value import", async () => {
  const src = await Bun.file(join(import.meta.dir, "build-spa-runtime.ts")).text();
  // A type-only import is erased at runtime, so it is fine and expected.
  expect(src).toContain('import type { Source, HostMember } from "./slice-host.ts"');
  // Any non-`type` static import of it is the defect.
  const staticValueImport = /^import\s+(?!type\b)[^;]*from\s+["']\.\/slice-host\.ts["']/m;
  expect(staticValueImport.test(src)).toBe(false);
  // ...and the lazy edge has to actually be there, or the first assertion would
  // pass on a file that simply stopped slicing.
  expect(src).toContain('await import("./slice-host.ts")');
});
