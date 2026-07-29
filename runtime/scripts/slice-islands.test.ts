import { expect, test, describe } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  JSX_NAMES,
  analyzeIslandBundles,
  generateIslandsEntry,
  runtimeExportNames,
  type IslandBundle,
} from "./slice-islands.ts";

const INDEX_TS = resolve(import.meta.dir, "../src/index.ts");

// A permissive stand-in for the barrel's export set, so an analysis test states
// its own preconditions instead of depending on what index.ts happens to hold.
const EXPORTS = new Set(["useState", "useEffect", "host", "Router", "useFlag"]);

function bundle(code: string, name = "Test.island"): IslandBundle {
  return { name, code };
}

function verdictOf(code: string) {
  return analyzeIslandBundles([bundle(code)], EXPORTS);
}

describe("runtimeExportNames", () => {
  test("reads the real barrel's VALUE exports and skips the type-only ones", () => {
    const names = runtimeExportNames(readFileSync(INDEX_TS, "utf8"));
    // Value exports an island can legitimately import.
    expect(names.has("useState")).toBe(true);
    expect(names.has("host")).toBe(true);
    expect(names.has("Router")).toBe(true);
    expect(names.has("bootIsland")).toBe(true);
    // `export type { … }` statements name nothing importable at runtime, so a
    // slice must not try to re-export them (Bun.build would fail on the name).
    expect(names.has("VNode")).toBe(false);
    expect(names.has("RouteDef")).toBe(false);
    expect(names.has("HmrGlobal")).toBe(false);
  });

  test("records the EXPORTED name of a renamed re-export", () => {
    const names = runtimeExportNames(`export { a as b } from "./x.ts";`);
    expect([...names]).toEqual(["b"]);
  });

  test("`export * from` names nothing (it cannot be enumerated)", () => {
    expect(runtimeExportNames(`export * from "./x.ts";`).size).toBe(0);
  });
});

describe("analyzeIslandBundles — sliceable islands", () => {
  test("records a named @z/runtime import under its IMPORTED name, not its alias", () => {
    const v = verdictOf(`import{useState as r}from"@z/runtime";export default function(){return r(0)}`);
    expect(v.sliceable).toEqual(["Test.island"]);
    expect(v.exports).toEqual(["useState"]);
  });

  test("a jsx-only bundle is sliceable and contributes no export", () => {
    const v = verdictOf(`import{jsx as o,jsxs as n}from"@z/runtime/jsx-runtime";export default()=>o("p",{})`);
    expect(v.sliceable).toEqual(["Test.island"]);
    expect(v.exports).toEqual([]);
  });

  test("the union spans islands, and one bailing island does not lose the others", () => {
    const v = analyzeIslandBundles([
      bundle(`import{useState as a}from"@z/runtime";`, "A.island"),
      bundle(`import{useEffect as b}from"@z/runtime";`, "B.island"),
      bundle(`import{useState as c}from"react";`, "C.island"),
    ], EXPORTS);
    expect(v.sliceable).toEqual(["A.island", "B.island"]);
    expect(v.exports).toEqual(["useEffect", "useState"]);
    expect(Object.keys(v.bailed)).toEqual(["C.island"]);
  });

  test("relative specifiers left in a bundle are fine", () => {
    const v = verdictOf(`import"./chunk-abc.js";import{jsx}from"@z/runtime/jsx-runtime";`);
    expect(v.sliceable).toEqual(["Test.island"]);
  });
});

describe("analyzeIslandBundles — the bail rules", () => {
  // Each of these would, if admitted, produce a page whose import map points at
  // a runtime missing something the browser asks for at load — a prod crash,
  // not a size regression. Hence: bail, and keep the shared runtime.
  const cases: Array<[string, string, RegExp]> = [
    ["@z/runtime/compat", `import{FlagsProvider as e}from"@z/runtime/compat";`, /runtime subpath/],
    ["@z/runtime/compat/client", `import{createRoot}from"@z/runtime/compat/client";`, /runtime subpath/],
    ["bare react", `import{useState as o}from"react";`, /imports "react"/],
    ["react-dom/client", `import{createRoot}from"react-dom/client";`, /react-dom\/client/],
    ["namespace import", `import*as z from"@z/runtime";`, /namespace import/],
    ["default import", `import z from"@z/runtime";`, /default import/],
    ["re-export", `export*from"@z/runtime";`, /re-exports/],
    ["named re-export", `export{useState}from"@z/runtime";`, /re-exports/],
    ["dynamic import", `const m=await import("@z/runtime");`, /dynamic import/],
    ["computed dynamic import", `const m=await import(u);`, /computed dynamic import/],
    ["unknown barrel name", `import{nope as n}from"@z/runtime";`, /does not export/],
    ["non-jsx name from jsx-runtime", `import{useState}from"@z/runtime/jsx-runtime";`, /only exports/],
    ["JSX name from the bare specifier", `import{jsx}from"@z/runtime";`, /JSX name/],
    ["unresolved bare specifier", `import{x}from"lodash";`, /unresolved bare specifier/],
  ];
  for (const [label, code, why] of cases) {
    test(`bails on ${label}`, () => {
      const v = verdictOf(code);
      expect(v.sliceable).toEqual([]);
      expect(v.exports).toEqual([]);
      expect(v.bailed["Test.island"]).toMatch(why);
    });
  }

  test("every island bailing yields an empty sliceable set (the whole-site fallback trigger)", () => {
    const v = analyzeIslandBundles([
      bundle(`import{useState}from"react";`, "A.island"),
      bundle(`import*as z from"@z/runtime";`, "B.island"),
    ], EXPORTS);
    expect(v.sliceable).toEqual([]);
    expect(Object.keys(v.bailed).sort()).toEqual(["A.island", "B.island"]);
  });
});

describe("generateIslandsEntry", () => {
  const opts = {
    islandsModule: "/abs/runtime/src/islands.ts",
    indexModule: "/abs/runtime/src/index.ts",
    jsxModule: "/abs/runtime/src/jsx-runtime.ts",
  };

  test("golden output: unconditional islands import, JSX names, sorted exports", () => {
    expect(generateIslandsEntry(["useState", "useEffect"], opts)).toBe(
      `// GENERATED by runtime/scripts/build-islands-runtime.ts — do not edit.
// The per-site sliced islands runtime: islands.ts's hydration auto-init, the
// JSX-transform names, and the 2 @z/runtime export(s) this site's islands use.
import "/abs/runtime/src/islands.ts";
export { jsx, jsxs, jsxDEV, Fragment } from "/abs/runtime/src/jsx-runtime.ts";
export { useEffect, useState } from "/abs/runtime/src/index.ts";
`,
    );
  });

  test("no exports: the index.ts line is omitted, the islands import is NOT", () => {
    const out = generateIslandsEntry([], opts);
    // The auto-init side effect is what hydrates the page; without it a
    // JSX-only site would ship a runtime that does nothing.
    expect(out).toContain(`import "/abs/runtime/src/islands.ts";`);
    expect(out).not.toContain("/abs/runtime/src/index.ts");
  });

  test("Fragment is emitted exactly once, sourced from the jsx module", () => {
    // Two explicit re-exports of one name is a hard Bun.build error, and
    // Fragment is exported from BOTH core.ts (via index.ts) and jsx-runtime.ts.
    const out = generateIslandsEntry([...JSX_NAMES, "useState"], opts);
    expect(out.match(/Fragment/g)!.length).toBe(1);
    expect(out).toContain(`export { jsx, jsxs, jsxDEV, Fragment } from "/abs/runtime/src/jsx-runtime.ts";`);
    expect(out).toContain(`export { useState } from "/abs/runtime/src/index.ts";`);
  });
});
