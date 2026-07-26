// Tests for the `resolve` override map in z-runtime.config.json:
// config validation, the compat defaults (active whenever firstParty/npmCompat
// is non-empty), and the lint integration (mapped specifiers are importable).
import { test, expect } from "bun:test";
import {
  validateConfig,
  effectiveResolveMap,
  RESOLVE_DEFAULTS,
  RUNTIME_SELF_ENTRIES,
  EMPTY_CONFIG,
  type ZRuntimeConfig,
} from "../scripts/z-runtime-config.ts";
import { IMPORT_MAP_SPECIFIERS } from "../scripts/react-alias.ts";
import { REACT_ALIAS } from "../scripts/react-alias.ts";
import { buildAllow } from "../scripts/lint-island-imports.ts";

test("validateConfig accepts a resolve map of string -> string", () => {
  const c = validateConfig({
    islandImports: { npmCompat: ["some-lib"] },
    resolve: { react: "@z/runtime/compat", "my-store": "@z/runtime/compat" },
  });
  expect(c.resolve).toEqual({ react: "@z/runtime/compat", "my-store": "@z/runtime/compat" });
});

test("validateConfig loud-fails on a non-object resolve", () => {
  expect(() => validateConfig({ resolve: ["react"] })).toThrow(/resolve/);
  expect(() => validateConfig({ resolve: "react" })).toThrow(/resolve/);
});

test("validateConfig loud-fails on non-string resolve values", () => {
  expect(() => validateConfig({ resolve: { react: 42 } })).toThrow(/resolve/);
  expect(() => validateConfig({ resolve: { react: null } })).toThrow(/resolve/);
});

test("effectiveResolveMap: empty config -> no overrides (zero behavior change)", () => {
  expect(effectiveResolveMap(EMPTY_CONFIG)).toEqual({});
});

test("effectiveResolveMap: npmCompat non-empty activates the react->compat defaults + runtime self-entries", () => {
  const c: ZRuntimeConfig = {
    islandImports: { firstParty: [], npmCompat: ["react-router-dom"] },
  };
  expect(effectiveResolveMap(c)).toEqual({ ...RESOLVE_DEFAULTS, ...RUNTIME_SELF_ENTRIES });
});

test("effectiveResolveMap: firstParty non-empty also activates the defaults", () => {
  const c: ZRuntimeConfig = {
    islandImports: { firstParty: ["@myapp/shared"], npmCompat: [] },
  };
  expect(effectiveResolveMap(c)).toEqual({ ...RESOLVE_DEFAULTS, ...RUNTIME_SELF_ENTRIES });
});

test("RUNTIME_SELF_ENTRIES: identity entries over import-map specifiers only (client side keeps them external)", () => {
  for (const [spec, target] of Object.entries(RUNTIME_SELF_ENTRIES)) {
    expect(spec).toBe(target); // identity — never redirected
    expect(IMPORT_MAP_SPECIFIERS.has(spec)).toBe(true); // bundler externalizes, never inlines
  }
});

test("effectiveResolveMap: a user resolve entry OVERRIDES the default for that key", () => {
  const c: ZRuntimeConfig = {
    islandImports: { firstParty: [], npmCompat: ["x"] },
    resolve: { react: "./my-react-shim.ts" },
  };
  const m = effectiveResolveMap(c);
  expect(m["react"]).toBe("./my-react-shim.ts");
  expect(m["react-dom"]).toBe(RESOLVE_DEFAULTS["react-dom"]); // other defaults intact
});

test("effectiveResolveMap: user resolve entries apply even without bridge packages", () => {
  const c: ZRuntimeConfig = {
    islandImports: { firstParty: [], npmCompat: [] },
    resolve: { "@acme/greeting": "./greeting.ts" },
  };
  expect(effectiveResolveMap(c)).toEqual({ "@acme/greeting": "./greeting.ts" });
});

test("RESOLVE_DEFAULTS is pinned to the client bridge's REACT_ALIAS (one source of truth per side, no drift)", () => {
  expect(RESOLVE_DEFAULTS).toEqual({ ...REACT_ALIAS });
});

test("lint: resolve-map keys are importable (exact specifier only, no subpaths)", () => {
  const c: ZRuntimeConfig = {
    islandImports: { firstParty: [], npmCompat: [] },
    resolve: { "my-store": "@z/runtime/compat" },
  };
  const allow = buildAllow(c);
  expect(allow.some((re) => re.test("my-store"))).toBe(true);
  // Resolution is exact-match, so the lint must NOT allow subpaths of a mapped key.
  expect(allow.some((re) => re.test("my-store/sub"))).toBe(false);
});
