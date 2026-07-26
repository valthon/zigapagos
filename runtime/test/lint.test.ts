import { test, expect } from "bun:test";
import { lintIslandImports } from "../scripts/lint-island-imports.ts";
import type { ZRuntimeConfig } from "../scripts/z-runtime-config.ts";
import { resolve } from "node:path";

const fixture = (name: string) => resolve(import.meta.dir, "fixtures", name);

// A config mirroring what a consumer declares to bridge a React SPA.
const CONFIG: ZRuntimeConfig = {
  islandImports: {
    firstParty: ["@myapp/shared"],
    npmCompat: ["react-router-dom"],
  },
};

test("base allow: forbidden third-party import is flagged (no config)", () => {
  const bad = fixture("bad-import.island.tsx");
  expect(lintIslandImports([bad])).toContainEqual({ file: bad, spec: "canvas-confetti" });
});

test("base allow: forbidden DYNAMIC import() is flagged (no config)", () => {
  const bad = fixture("bad-import.island.tsx");
  expect(lintIslandImports([bad])).toContainEqual({ file: bad, spec: "lodash" });
});

test("base allow: @z/runtime + relative imports pass (no config)", () => {
  const ok = fixture("Gate.island.tsx"); // imports only @z/runtime
  expect(lintIslandImports([ok])).toEqual([]);
});

test("firstParty (config) is allowed; npmCompat (config) is allowed; a non-allowlisted npm is still flagged", () => {
  const f = fixture("compat-import.island.tsx");
  const v = lintIslandImports([f], CONFIG);
  // firstParty scope + its subpath allowed.
  expect(v.some((x) => x.spec === "@myapp/shared/customer")).toBe(false);
  // npmCompat package allowed.
  expect(v.some((x) => x.spec === "react-router-dom")).toBe(false);
  // @z/runtime/compat always allowed (base).
  expect(v.some((x) => x.spec === "@z/runtime/compat")).toBe(false);
  // A package NOT in the config is still a violation.
  expect(v).toContainEqual({ file: f, spec: "some-uninstalled-widget" });
});

test("without config, the firstParty + npmCompat specifiers ARE flagged (hardcode removed)", () => {
  const f = fixture("compat-import.island.tsx");
  const v = lintIslandImports([f]); // EMPTY_CONFIG
  expect(v.some((x) => x.spec === "@myapp/shared/customer")).toBe(true);
  expect(v.some((x) => x.spec === "react-router-dom")).toBe(true);
  // @z/runtime/compat remains allowed by the base list.
  expect(v.some((x) => x.spec === "@z/runtime/compat")).toBe(false);
});
