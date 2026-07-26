import { test, expect } from "bun:test";
import * as testing from "@z/runtime/testing";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

test("public surface is exported from @z/runtime/testing", () => {
  for (const name of ["mockHost", "renderIsland", "ssrIsland", "renderForTest", "act", "click", "type", "flush", "mockSiteData"]) {
    expect(typeof (testing as any)[name]).toBe("function");
  }
});

test("no production source imports src/testing (one-Preact / no-leak guard)", () => {
  const roots = [resolve(import.meta.dir, "../../src"), resolve(import.meta.dir, "../../sidecar")];
  const offenders: string[] = [];
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = resolve(dir, e.name);
      if (e.isDirectory()) { if (e.name !== "testing") walk(p); continue; }
      if (!e.name.endsWith(".ts")) continue;
      // .test.ts files are tests, not production source: they are never imported by
      // browser-entry.ts and never bundled into zigapagos-runtime.js, so they can't
      // leak the testing harness (happy-dom / a second Preact) into production output.
      if (e.name.endsWith(".test.ts")) continue;
      if (/from\s+["'][^"']*\/testing(\/[^"']*)?["']/.test(readFileSync(p, "utf8"))) offenders.push(p);
    }
  };
  roots.forEach(walk);
  expect(offenders).toEqual([]);
});
