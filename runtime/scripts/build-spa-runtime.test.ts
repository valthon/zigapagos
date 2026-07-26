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
