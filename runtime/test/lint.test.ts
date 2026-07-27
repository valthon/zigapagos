import { test, expect } from "bun:test";
import { lintIslandImports, buildAllow } from "../scripts/lint-island-imports.ts";
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

// buildAllow compiles each configured specifier into a RegExp, so a specifier
// carrying regex metacharacters — routine in package names: "lodash.merge",
// "core-js", "c++filt" — must be escaped or the allow-rule matches more than
// the author allowed. That is `RegExp.escape`'s job here (the patterns are
// internal and never read by a human; contrast escapePcre in
// emit-host-config.ts). Previously nothing pinned it.
test("buildAllow treats regex metacharacters in a specifier as LITERAL", () => {
  const allows = (spec: string, subject: string) =>
    buildAllow({ islandImports: { firstParty: [spec], npmCompat: [] } })
      .some((re) => re.test(subject));

  // A "." in a package name must not match an arbitrary character...
  expect(allows("lodash.merge", "lodash.merge")).toBe(true);
  expect(allows("lodash.merge", "lodashXmerge")).toBe(false);
  // ...including via the subpath rule the specifier also generates.
  expect(allows("lodash.merge", "lodash.merge/fp")).toBe(true);
  expect(allows("lodash.merge", "lodashXmerge/fp")).toBe(false);
  // A "+" must be a literal plus, not a quantifier over the previous char.
  expect(allows("c++filt", "c++filt")).toBe(true);
  expect(allows("c++filt", "cfilt")).toBe(false);
  // Grouping/alternation in a specifier must not become real regex syntax:
  // unescaped, "^(a|b)$" would allow the bare "b".
  expect(allows("(a|b)", "(a|b)")).toBe(true);
  expect(allows("(a|b)", "b")).toBe(false);
});
