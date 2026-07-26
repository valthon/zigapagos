import { test, expect } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join, basename } from "node:path";
import {
  analyzeHostUsage, generateSlicedHost, BASELINE_MEMBERS, HOST_MEMBERS,
  type Source, type HostMember,
} from "./slice-host.ts";

const BASE = new Set(BASELINE_MEMBERS);
const one = (code: string): Source[] => [{ path: "App.spa.tsx", code }];
const analyze = (code: string) => analyzeHostUsage(one(code));

// ── used-set detection ───────────────────────────────────────────────────────

test("a clean SPA yields EXACTLY the baseline ∪ its used members", () => {
  const used = analyze(`
    import { host, Router } from "@z/runtime";
    export default function App() {
      const y = host.pathname();
      host.fetchOpts({ url: "/x" });
      host.store.getStr("s");
      return null;
    }
  `);
  expect(used).not.toBeNull();
  expect(used).toEqual(new Set<HostMember>([...BASE, "pathname", "fetchOpts", "store"]));
});

test("a SPA that touches no host member still gets the baseline set", () => {
  const used = analyze(`import { Router } from "@z/runtime"; export default () => null;`);
  expect(used).toEqual(new Set(BASE));
});

test("the admin-only members (loadScript / recaptchaToken) are recorded when used", () => {
  const used = analyze(`
    import { host } from "@z/runtime";
    export default async function App() { await host.loadScript("/x.js"); return host.recaptchaToken(); }
  `);
  expect(used).not.toBeNull();
  expect(used!.has("loadScript")).toBe(true);
  expect(used!.has("recaptchaToken")).toBe(true);
});

test("`host as h` aliased named import is tracked", () => {
  const used = analyze(`
    import { host as h } from "@z/runtime";
    export default () => h.fetchOpts({ url: "/x" });
  `);
  expect(used).not.toBeNull();
  expect(used!.has("fetchOpts")).toBe(true);
});

test("host imported from @z/runtime/host is tracked", () => {
  const used = analyze(`
    import { host } from "@z/runtime/host";
    export default () => host.now();
  `);
  expect(used!.has("now")).toBe(true);
});

test("an unrelated `.host` property access does NOT record or bail", () => {
  const used = analyze(`
    import { host } from "@z/runtime";
    export default (cfg: any) => { const a = cfg.host; return host.cookies.get("c") + a; }
  `);
  expect(used).not.toBeNull();               // cfg.host must not trip the fallback
  expect(used).toEqual(new Set(BASE));        // cookies is already baseline
});

test("member usage spread across multiple files unions correctly", () => {
  const used = analyzeHostUsage([
    { path: "a.tsx", code: `import { host } from "@z/runtime"; export const a = () => host.onScroll(() => {});` },
    { path: "b.tsx", code: `import { host } from "@z/runtime"; export const b = () => host.portal("#x");` },
  ]);
  expect(used).toEqual(new Set<HostMember>([...BASE, "onScroll", "portal"]));
});

// ── SAFE-FALLBACK triggers: each must return null ────────────────────────────

test("fallback: computed access host[expr]", () => {
  expect(analyze(`import { host } from "@z/runtime"; export const f = (k: string) => (host as any)[k]();`)).toBeNull();
});

test("fallback: computed access with a string literal host['loadScript']", () => {
  expect(analyze(`import { host } from "@z/runtime"; export const f = () => (host as any)["loadScript"]("/x");`)).toBeNull();
});

test("fallback: alias const h = host", () => {
  expect(analyze(`import { host } from "@z/runtime"; const h = host; export const f = () => h.now();`)).toBeNull();
});

test("fallback: destructure const { cookies } = host", () => {
  expect(analyze(`import { host } from "@z/runtime"; const { cookies } = host; export const f = () => cookies.get("c");`)).toBeNull();
});

test("fallback: spread { ...host }", () => {
  expect(analyze(`import { host } from "@z/runtime"; export const bag = { ...host };`)).toBeNull();
});

test("fallback: shorthand { host }", () => {
  expect(analyze(`import { host } from "@z/runtime"; export const bag = { host };`)).toBeNull();
});

test("fallback: host passed as an argument", () => {
  expect(analyze(`import { host } from "@z/runtime"; declare function use(h: any): void; export const f = () => use(host);`)).toBeNull();
});

test("fallback: host returned as a value", () => {
  expect(analyze(`import { host } from "@z/runtime"; export const get = () => host;`)).toBeNull();
});

test("fallback: namespace import z.host.store", () => {
  expect(analyze(`import * as z from "@z/runtime"; export const f = () => z.host.store.getStr("s");`)).toBeNull();
});

test("fallback: namespace import of the /host SUBPATH (H.host.loadScript)", () => {
  // Regression: the namespace branch used to test `spec === "@z/runtime"` only,
  // so the subpath form recorded NO locals at all, the file was skipped, and
  // `loadScript` was silently dropped from the slice ⇒ prod TypeError.
  const used = analyze(
    `import * as H from "@z/runtime/host"; export const f = () => H.host.loadScript("/x.js");`,
  );
  expect(used).toBeNull();
});

// ── SAFE-FALLBACK: a sliced runtime omits the compat/react surface, so a SPA
//    that imports it must use the full shared runtime (else a prod crash). ────

for (const spec of [
  "@z/runtime/compat", "@z/runtime/compat/client",
  "react", "react-dom", "react-dom/client", "react/jsx-runtime", "react/jsx-dev-runtime",
]) {
  test(`fallback: value import of compat/react specifier "${spec}"`, () => {
    // Uses host statically too, so WITHOUT the guard it would slice (non-null).
    expect(analyze(`import { host } from "@z/runtime"; import { X } from "${spec}"; export const f = () => host.now() && X;`)).toBeNull();
  });
}

test("fallback: a compat import with NO host usage still forces the fallback", () => {
  expect(analyze(`import { makeSharedResource } from "@z/runtime/compat"; export const r = makeSharedResource;`)).toBeNull();
});

test("fallback: an `export … from \"react\"` re-export forces the fallback", () => {
  expect(analyze(`export { memo } from "react";`)).toBeNull();
});

test("a type-only `import type … from \"react\"` does NOT force the fallback", () => {
  // Type-only imports are erased by the bundler — they never need the runtime
  // surface, so they must not over-fallback.
  const used = analyze(`import type { FC } from "react"; import { host } from "@z/runtime"; export const f: any = () => host.now();`);
  expect(used).not.toBeNull();
  expect(used!.has("now")).toBe(true);
});

// ── generateSlicedHost ───────────────────────────────────────────────────────

test("generateSlicedHost imports only the used members and assembles them", () => {
  const src = generateSlicedHost(new Set<HostMember>(["store", "fetchShared", "reportError", "cookies", "fetchOpts"]), {
    hostModule: "/abs/src/host.ts", ssrEnvModule: "/abs/src/ssr-env.ts", name: "public",
  });
  expect(src).toContain(`import { store, fetchShared, reportError, cookies, fetchOpts } from "/abs/src/host.ts";`);
  // the admin-only members are absent from the sliced host source
  expect(src).not.toContain("loadScript");
  expect(src).not.toContain("recaptchaToken");
  // no ssr-env import when pathname is unused
  expect(src).not.toContain("currentPathname");
  // object assembled deterministically in HOST_MEMBERS order
  expect(src).toContain("export const host = {");
  expect(src.indexOf("store,")).toBeLessThan(src.indexOf("fetchShared,"));
});

test("generateSlicedHost maps pathname to currentPathname from ssr-env", () => {
  const src = generateSlicedHost(new Set<HostMember>([...BASELINE_MEMBERS, "pathname"]), {
    hostModule: "/abs/src/host.ts", ssrEnvModule: "/abs/src/ssr-env.ts",
  });
  expect(src).toContain(`import { currentPathname } from "/abs/src/ssr-env.ts";`);
  expect(src).toContain("pathname: currentPathname,");
});

test("generateSlicedHost maps search/hash to currentSearch/currentHash from ssr-env, not from host.ts", () => {
  const src = generateSlicedHost(new Set<HostMember>([...BASELINE_MEMBERS, "search", "hash"]), {
    hostModule: "/abs/src/host.ts", ssrEnvModule: "/abs/src/ssr-env.ts",
  });
  expect(src).toContain(`import { currentSearch, currentHash } from "/abs/src/ssr-env.ts";`);
  expect(src).toContain("search: currentSearch,");
  expect(src).toContain("hash: currentHash,");
  // host.ts exports no `search`/`hash` bindings of its own — they must never be
  // pulled from hostModule, or the generated import would fail to resolve.
  const hostImportLine = src.split("\n").find((l) => l.includes(`from "/abs/src/host.ts"`));
  expect(hostImportLine).not.toMatch(/\b(search|hash)\b/);
});

// ── drift guard: BASELINE must cover every host.<member> the always-bundled ──
// core runtime modules access, or a sliced host would crash them at runtime. ──

test("BASELINE_MEMBERS covers every host.<member> used by ANY always-bundled runtime module", () => {
  // Scan ALL of runtime/src that can end up in a sliced runtime's bundle —
  // spa-entry.ts -> index.ts re-exports core/router/flags/api/islands/slots/
  // ssr-env/dev-reload/errors, plus host.ts — MINUS the modules a sliced runtime
  // never includes (compat/* surface, the testing harness, *.test.ts, mock-host).
  // Deriving the set instead of hardcoding it means a NEW always-bundled host
  // user is covered automatically (its host.<member> must be in BASELINE or a
  // sliced runtime would crash on it).
  const srcDir = join(import.meta.dir, "..", "src");
  const files = readdirSync(srcDir, { recursive: true })
    .map(String)
    .map((f) => f.replaceAll("\\", "/"))
    .filter((f) => /\.tsx?$/.test(f) && !f.endsWith(".test.ts"))
    .filter((f) => !f.startsWith("compat/") && !f.includes("/compat/"))
    .filter((f) => !f.startsWith("testing/") && !f.includes("/testing/"))
    .filter((f) => basename(f) !== "mock-host.ts");

  const found = new Set<string>();
  for (const rel of files) {
    const code = readFileSync(join(srcDir, rel), "utf8")
      .replace(/\/\/[^\n]*/g, "")        // strip line comments (they mention host.* prose)
      .replace(/\/\*[\s\S]*?\*\//g, ""); // strip block comments
    // Require the member be immediately CALLED or further-accessed (`host.x(` or
    // `host.x.`) so an import path like `from "./host.ts"` is not mistaken for a
    // `host.ts` member access.
    for (const m of code.matchAll(/\bhost\.([A-Za-z_$][\w$]*)\s*[.(]/g)) found.add(m[1]);
  }
  const base = new Set<string>(BASELINE_MEMBERS);
  const missing = [...found].filter((m) => !base.has(m));
  expect(missing).toEqual([]); // if this fails, add the new member(s) to BASELINE_MEMBERS
});

test("HOST_MEMBERS matches the host literal in host.ts (order + membership)", () => {
  const code = readFileSync(join(import.meta.dir, "..", "src", "host.ts"), "utf8");
  const start = code.indexOf("export const host = {");
  const body = code.slice(start, code.indexOf("};", start));
  // keys are `name,` or `pathname: currentPathname,`
  const keys = [...body.matchAll(/^\s*([A-Za-z_$][\w$]*)(?::|,)/gm)].map((m) => m[1]);
  expect(keys).toEqual([...HOST_MEMBERS]);
});
