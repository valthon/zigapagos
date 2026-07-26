import { test, expect } from "bun:test";
import { resolve } from "node:path";

test("browser-entry bundles to a single file exporting the barrel + jsx-runtime, with the island loader", async () => {
  const entry = resolve(import.meta.dir, "../src/browser-entry.ts");
  const proc = Bun.spawn(["bun", "build", entry, "--format=esm"], { stdout: "pipe", cwd: resolve(import.meta.dir, "..") });
  const out = await new Response(proc.stdout).text();
  expect(await proc.exited).toBe(0);
  // The shared runtime must export both import-map targets' surfaces:
  expect(out).toContain("useState");   // barrel (from @z/runtime)
  expect(out).toContain("hydrate");    // for the loader
  // The jsx factory must be present (so @z/runtime/jsx-runtime resolves here):
  expect(out).toMatch(/\bjsx\b/);
  // The island loader's auto-init must be bundled in (it runs on DOMContentLoaded):
  expect(out).toContain("DOMContentLoaded");
});
