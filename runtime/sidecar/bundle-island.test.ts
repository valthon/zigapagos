import { test, expect } from "bun:test";
import { bundleIsland, bundleSpa, makeDepfile, findTsconfig, retargetSourceMappingUrl, findRouteChunk } from "./bundle-island.ts";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, mkdirSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** Strip the trailing `//# debugId=` / `//# sourceMappingURL=` comment lines a
 *  linked-sourcemap build appends, leaving just the code — so two bundles can be
 *  compared for CODE parity independent of which map name each points at. */
function stripMapComments(js: string): string {
  return js.replace(/\n*\/\/# debugId=\S*\n?/g, "").replace(/\n*\/\/# sourceMappingURL=\S*\n?/g, "");
}

test("makeDepfile escapes spaces and uses Make continuation", () => {
  const d = makeDepfile("/out/a b.js", ["/src/x y.tsx", "/src/z.tsx"]);
  expect(d).toContain("/out/a\\ b.js: \\");
  expect(d).toContain("/src/x\\ y.tsx");      // space escaped
  expect(d).toContain("/src/z.tsx");
});

test("bundleIsland depfile lists the island + its transitive relative dep + tsconfig", async () => {
  const dir = mkdtempSync(join(tmpdir(), "bundle-test-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "dep.ts"), `export const greeting = "hi";\n`);
  writeFileSync(join(dir, "island.tsx"), `import { greeting } from "./dep.ts";\nexport default () => greeting;\n`);
  const out = join(dir, "out.js"), dep = join(dir, "out.d");
  const deps = await bundleIsland({ entry: join(dir, "island.tsx"), outfile: out, depfile: dep, external: [], minify: false });
  expect(deps.some((p) => p.endsWith("island.tsx"))).toBe(true);
  expect(deps.some((p) => p.endsWith("dep.ts"))).toBe(true);          // the TRANSITIVE dep — the whole point
  expect(deps.some((p) => p.endsWith("tsconfig.json"))).toBe(true);   // tsconfig tracked

  // bonus: outfile is written and non-empty
  const outContent = readFileSync(out, "utf8");
  expect(outContent.length).toBeGreaterThan(0);
});

test("PARITY: bundleSpa's entry is byte-identical to the single-outfile bundle for a no-import SPA", async () => {
  const dir = mkdtempSync(join(tmpdir(), "spa-parity-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "util.ts"), `export const g = (n: string) => "hi " + n;\n`);
  writeFileSync(join(dir, "entry.ts"), `import { g } from "./util.ts";\nexport default () => g("x");\n`);

  const single = join(dir, "single.js");
  await bundleIsland({ entry: join(dir, "entry.ts"), outfile: single, depfile: join(dir, "single.d"), external: [], minify: true });

  const outdir = join(dir, "out");
  await bundleSpa({
    entry: join(dir, "entry.ts"), entryName: "entry.js", outdir,
    chunksJson: join(dir, "chunks.json"), depfile: join(dir, "split.d"), external: [], minify: true,
  });

  // The whole point: splitting mode on a no-import SPA emits ONE entry chunk
  // whose bytes match today's single-outfile build exactly.
  expect(readFileSync(join(outdir, "entry.js"), "utf8")).toBe(readFileSync(single, "utf8"));
  const meta = JSON.parse(readFileSync(join(dir, "chunks.json"), "utf8"));
  expect(meta.entry).toBe("entry.js");
  expect(meta.chunks).toEqual([]); // no extra chunks for a non-lazy SPA
  expect(meta.routeChunks).toEqual({});
});

// --- z-runtime.config.json `resolve` overrides ---------------------------

test("resolve override: an unimportable target fails the CLIENT bundle with the actionable config message", async () => {
  const dir = mkdtempSync(join(tmpdir(), "resolve-bad-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "z-runtime.config.json"),
    JSON.stringify({ resolve: { "my-store": "./does-not-exist.ts" } }),
  );
  writeFileSync(join(dir, "island.ts"), `import { x } from "my-store";\nexport default () => x;\n`);
  let msg = "";
  try {
    await bundleIsland({
      entry: join(dir, "island.ts"), outfile: join(dir, "out.js"), depfile: join(dir, "out.d"),
      external: ["@z/runtime"], minify: false,
    });
  } catch (e) {
    // Bun.build rejects with an AggregateError; the plugin's message is inside.
    const agg = e as AggregateError;
    msg = [agg.message, ...(agg.errors ?? []).map((x: unknown) => (x instanceof Error ? x.message : String(x)))].join("\n");
  }
  // Same actionable failure as the SSR side (shared resolveConfigTarget) — not
  // a bare Bun resolveSync stack.
  expect(msg).toMatch(/resolve target "\.\/does-not-exist\.ts" is not importable/);
});

test("resolve override: a custom specifier mapped to a @z/runtime surface is rewritten to it (kept external)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "resolve-rt-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "z-runtime.config.json"),
    JSON.stringify({ resolve: { "my-store": "@z/runtime/compat" } }),
  );
  writeFileSync(join(dir, "island.ts"), `import { useState } from "my-store";\nexport default () => useState(0);\n`);
  const out = join(dir, "out.js");
  const deps = await bundleIsland({
    entry: join(dir, "island.ts"), outfile: out, depfile: join(dir, "out.d"),
    external: ["@z/runtime"], minify: false,
  });
  const js = readFileSync(out, "utf8");
  // The bare custom specifier is gone; the page import-map key survives external.
  expect(js).toContain('"@z/runtime/compat"');
  expect(js).not.toContain('"my-store"');
  // The config file is a tracked build input (editing it invalidates the bundle).
  expect(deps.some((p) => p.endsWith("z-runtime.config.json"))).toBe(true);
});

test("resolve override: a relative target resolves from the config dir and is bundled", async () => {
  const dir = mkdtempSync(join(tmpdir(), "resolve-rel-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "z-runtime.config.json"),
    JSON.stringify({ resolve: { "@acme/greeting": "./greeting.ts" } }),
  );
  writeFileSync(join(dir, "greeting.ts"), `export const greeting = "INLINED-GREETING-MARKER";\n`);
  writeFileSync(join(dir, "island.ts"), `import { greeting } from "@acme/greeting";\nexport default () => greeting;\n`);
  const out = join(dir, "out.js");
  await bundleIsland({
    entry: join(dir, "island.ts"), outfile: out, depfile: join(dir, "out.d"),
    external: ["@z/runtime"], minify: false,
  });
  const js = readFileSync(out, "utf8");
  expect(js).toContain("INLINED-GREETING-MARKER"); // bundled, not external
  expect(js).not.toContain("@acme/greeting");
});

test("resolve defaults: with npmCompat non-empty, `react` stays external under its own name (byte-parity with the no-config bridge)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "resolve-default-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "island.ts"), `import { useState } from "react";\nexport default () => useState(1);\n`);
  const single = join(dir, "no-config.js");
  await bundleIsland({
    entry: join(dir, "island.ts"), outfile: single, depfile: join(dir, "a.d"),
    external: ["@z/runtime"], minify: false,
  });
  writeFileSync(
    join(dir, "z-runtime.config.json"),
    JSON.stringify({ islandImports: { npmCompat: ["some-lib"] } }),
  );
  const withCfg = join(dir, "with-config.js");
  await bundleIsland({
    entry: join(dir, "island.ts"), outfile: withCfg, depfile: join(dir, "b.d"),
    external: ["@z/runtime"], minify: false,
  });
  // `react` is in the page import map, so the default map keeps the ORIGINAL
  // specifier external — the emitted bytes must not change when the defaults
  // activate.
  expect(readFileSync(withCfg, "utf8")).toBe(readFileSync(single, "utf8"));
  expect(readFileSync(withCfg, "utf8")).toContain('"react"');
});

test("bundleSpa applies the same resolve overrides", async () => {
  const dir = mkdtempSync(join(tmpdir(), "resolve-spa-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "z-runtime.config.json"),
    JSON.stringify({ resolve: { "my-store": "@z/runtime/compat" } }),
  );
  writeFileSync(join(dir, "entry.ts"), `import { useState } from "my-store";\nexport const routes = [];\nexport default () => useState(0);\n`);
  const outdir = join(dir, "out");
  await bundleSpa({
    entry: join(dir, "entry.ts"), entryName: "e.js", outdir,
    chunksJson: join(dir, "chunks.json"), depfile: join(dir, "e.d"),
    external: ["@z/runtime"], minify: false,
  });
  const js = readFileSync(join(outdir, "e.js"), "utf8");
  expect(js).toContain('"@z/runtime/compat"');
  expect(js).not.toContain('"my-store"');
});

test("bundleSpa splits a dynamic import into its own chunk, kept out of the entry", async () => {
  const dir = mkdtempSync(join(tmpdir(), "spa-split-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "heavy.ts"), `export const heavy = () => "HEAVY-MARKER-Q payload";\n`);
  writeFileSync(join(dir, "entry.ts"), `export async function load() { return (await import("./heavy.ts")).heavy(); }\nexport default () => "e";\n`);

  const outdir = join(dir, "out");
  await bundleSpa({
    entry: join(dir, "entry.ts"), entryName: "e.js", outdir,
    chunksJson: join(dir, "chunks.json"), depfile: join(dir, "split.d"), external: [], minify: true,
  });

  const entryJs = readFileSync(join(outdir, "e.js"), "utf8");
  expect(entryJs).not.toContain("HEAVY-MARKER-Q"); // the heavy code is NOT in the entry
  const meta = JSON.parse(readFileSync(join(dir, "chunks.json"), "utf8"));
  expect(meta.chunks.length).toBeGreaterThan(0);
  const inAChunk = meta.chunks.some((c: string) => readFileSync(join(outdir, c), "utf8").includes("HEAVY-MARKER-Q"));
  expect(inAChunk).toBe(true); // it lives in a separate chunk
});

// --- lazy-route -> chunk matching (same-prefix modules) ---------------------

test("findRouteChunk anchors the hash segment — a same-prefix sibling is NOT matched", () => {
  const chunks = ["Heavy-Extra-a1b2c3.js", "Heavy-d4e5f6.js", "entry-000000.js"];
  // A bare startsWith("Heavy-") prefix test matches Heavy-Extra-a1b2c3.js first
  // (output order decides), mapping /heavy to a chunk that route never loads.
  expect(findRouteChunk("./views/Heavy", chunks)).toBe("Heavy-d4e5f6.js");
  expect(findRouteChunk("./views/Heavy-Extra", chunks)).toBe("Heavy-Extra-a1b2c3.js");
  expect(findRouteChunk("./views/Heavy.tsx", chunks)).toBe("Heavy-d4e5f6.js");
});

test("findRouteChunk matches an unhashed chunk exactly, and misses cleanly", () => {
  expect(findRouteChunk("./views/Heavy", ["Heavy.js"])).toBe("Heavy.js");
  expect(findRouteChunk("./views/Missing", ["Heavy-a1.js"])).toBeUndefined();
});

test("findRouteChunk emits NO mapping when more than one chunk matches", () => {
  // Both an unhashed and a hashed candidate: guessing would preload the wrong one.
  expect(findRouteChunk("./views/Heavy", ["Heavy.js", "Heavy-a1b2c3.js"])).toBeUndefined();
});

test("findRouteChunk treats a '.' in the module name as a literal, not a regex wildcard", () => {
  // "v1.0" must not match "v1X0" via an unescaped regex metacharacter.
  expect(findRouteChunk("./views/v1.0", ["v1X0-a1b2.js"])).toBeUndefined();
  expect(findRouteChunk("./views/v1.0", ["v1.0-a1b2.js"])).toBe("v1.0-a1b2.js");
});

// --- dev fast-refresh transform -------------------------------------------

test("hot: the entry is recognised through a SYMLINKED path (macOS $TMPDIR)", async () => {
  // Regression: the hot transform identified the entry with `resolve()`, which
  // normalises but does NOT follow symlinks, while Bun reports the realpath to
  // onLoad. Anywhere a path component is a symlink the two disagreed and the
  // entry was silently skipped -- the build succeeded and fast refresh quietly
  // degraded to a full remount. macOS hit it on every run because $TMPDIR is
  // /var/folders/... symlinked to /private/var/folders/..., so this failed only
  // on the macOS CI leg. Reproduced here on any platform by routing the entry
  // through an explicit symlink.
  const base = mkdtempSync(join(tmpdir(), "hot-symlink-"));
  const real = join(base, "real");
  mkdirSync(real);
  const link = join(base, "link");
  symlinkSync(real, link);

  writeFileSync(join(real, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(real, "Counter.island.tsx"),
    `import { useState } from "@z/runtime";\nexport default function Counter() {\n  const [n] = useState(0);\n  return <div>{n}</div>;\n}\n`,
  );

  const out = join(real, "out.js");
  await bundleIsland({
    // entry addressed THROUGH the symlink; Bun will report the realpath
    entry: join(link, "Counter.island.tsx"), outfile: out, depfile: join(real, "out.d"),
    external: ["@z/runtime"], minify: false, hot: true,
  });
  const js = readFileSync(out, "utf8");
  expect(js).toContain("__zHotRegister");
  expect(js).toContain('"Counter"');
});

test("hot: entry components are routed through the hot registry; @z/runtime stays external; depfile intact", async () => {
  const dir = mkdtempSync(join(tmpdir(), "hot-on-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "Counter.island.tsx"),
    `import { useState } from "@z/runtime";\nexport default function Counter() {\n  const [n] = useState(0);\n  return <div>{n}</div>;\n}\n`,
  );
  const out = join(dir, "out.js");
  const deps = await bundleIsland({
    entry: join(dir, "Counter.island.tsx"), outfile: out, depfile: join(dir, "out.d"),
    external: ["@z/runtime"], minify: false, hot: true,
  });
  const js = readFileSync(out, "utf8");
  expect(js).toContain("__zHotRegister"); // the registry import survives…
  expect(js).toContain('"@z/runtime"'); // …and stays external (import map serves it)
  expect(js).toContain('"Counter"');
  // dep-capture unaffected by the second onLoad plugin: entry still tracked.
  expect(deps.some((p) => p.endsWith("Counter.island.tsx"))).toBe(true);
});

test("hot transforms ONLY the entry: a component in a transitive dep is not registered", async () => {
  const dir = mkdtempSync(join(tmpdir(), "hot-dep-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "Inner.tsx"),
    `import { useState } from "@z/runtime";\nexport function Inner() {\n  const [x] = useState(1);\n  return <b>{x}</b>;\n}\n`,
  );
  writeFileSync(
    join(dir, "Outer.island.tsx"),
    `import { useState } from "@z/runtime";\nimport { Inner } from "./Inner.tsx";\nexport default function Outer() {\n  const [n] = useState(0);\n  return <div><Inner />{n}</div>;\n}\n`,
  );
  const out = join(dir, "out.js");
  await bundleIsland({
    entry: join(dir, "Outer.island.tsx"), outfile: out, depfile: join(dir, "out.d"),
    external: ["@z/runtime"], minify: false, hot: true,
  });
  const js = readFileSync(out, "utf8");
  expect(js).toMatch(/__zigapagos_hot_register.*\(Outer,/); // entry component wrapped
  expect(js).not.toMatch(/__zigapagos_hot_register.*\(Inner,/); // dep component NOT wrapped
});

test("PARITY: without hot the output contains no registry call and is byte-identical to hot:false (release gate)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "hot-off-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "Counter.island.tsx"),
    `import { useState } from "@z/runtime";\nexport default function Counter() {\n  const [n] = useState(0);\n  return <div>{n}</div>;\n}\n`,
  );
  const a = join(dir, "default.js"), b = join(dir, "hot-false.js"), c = join(dir, "hot-true.js");
  await bundleIsland({ entry: join(dir, "Counter.island.tsx"), outfile: a, depfile: join(dir, "a.d"), external: ["@z/runtime"], minify: true });
  await bundleIsland({ entry: join(dir, "Counter.island.tsx"), outfile: b, depfile: join(dir, "b.d"), external: ["@z/runtime"], minify: true, hot: false });
  await bundleIsland({ entry: join(dir, "Counter.island.tsx"), outfile: c, depfile: join(dir, "c.d"), external: ["@z/runtime"], minify: true, hot: true });
  // hot omitted === hot:false, byte for byte — release builds are untouched.
  expect(readFileSync(a, "utf8")).toBe(readFileSync(b, "utf8"));
  expect(readFileSync(a, "utf8")).not.toContain("__zHotRegister");
  // …and the hot build differs ONLY because it opted in.
  expect(readFileSync(c, "utf8")).toContain("__zHotRegister");
});

// --- external source maps ------------------------------------------------

test("retargetSourceMappingUrl rewrites only the URL value, leaving code + debugId", () => {
  const js = "code;\n//# debugId=ABC\n//# sourceMappingURL=island.island.js.map\n";
  const out = retargetSourceMappingUrl(js, "Counter.js.map");
  expect(out).toContain("//# sourceMappingURL=Counter.js.map");
  expect(out).not.toContain("island.island.js.map");
  expect(out).toContain("//# debugId=ABC"); // debugId untouched
  expect(out.startsWith("code;")).toBe(true); // code untouched
});

test("bundleIsland with sourcemap emits a valid linked .map and retargets the comment to the SERVED name", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sm-island-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "dep.ts"), `export const greeting = "hi";\n`);
  writeFileSync(join(dir, "island.tsx"), `import { greeting } from "./dep.ts";\nexport default () => greeting;\n`);
  const out = join(dir, "Counter.js");
  const mapfile = join(dir, "Counter.js.map");
  await bundleIsland({
    entry: join(dir, "island.tsx"), outfile: out, mapfile, depfile: join(dir, "out.d"),
    external: [], minify: true, sourcemap: true,
  });
  const js = readFileSync(out, "utf8");
  // The comment points at the SERVED basename (`Counter.js.map`), not Bun's own
  // entry name — so both devtools and the client symbolicator (which appends
  // `.map` to the script URL) resolve to the same served file.
  expect(js).toContain("//# sourceMappingURL=Counter.js.map");
  expect(existsSync(mapfile)).toBe(true);
  const map = JSON.parse(readFileSync(mapfile, "utf8"));
  expect(map.version).toBe(3);
  expect(Array.isArray(map.sources)).toBe(true);
  expect(map.mappings.length).toBeGreaterThan(0);
});

test("bundleIsland without sourcemap is byte-identical to a sourcemap build with the comments stripped (parity: opt-in only appends a map)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sm-parity-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "island.tsx"), `export default () => "x";\n`);
  const plain = join(dir, "plain.js"), mapped = join(dir, "mapped.js");
  await bundleIsland({ entry: join(dir, "island.tsx"), outfile: plain, depfile: join(dir, "a.d"), external: [], minify: true });
  await bundleIsland({ entry: join(dir, "island.tsx"), outfile: mapped, mapfile: join(dir, "mapped.js.map"), depfile: join(dir, "b.d"), external: [], minify: true, sourcemap: true });
  // The maps-off build (what the byte-parity gate compares) is unchanged: the
  // only delta the opt-in introduces is the appended sourcemap/debugId comments.
  const trimTail = (s: string) => s.replace(/\n+$/, "");
  expect(trimTail(stripMapComments(readFileSync(mapped, "utf8")))).toBe(trimTail(readFileSync(plain, "utf8")));
});

test("bundleSpa with sourcemap emits entry + chunk maps; entry comment points at the served entry name", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sm-spa-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "heavy.ts"), `export const heavy = () => "HEAVY-SM payload";\n`);
  writeFileSync(join(dir, "entry.ts"), `export async function load() { return (await import("./heavy.ts")).heavy(); }\nexport default () => "e";\n`);
  const outdir = join(dir, "out");
  await bundleSpa({
    entry: join(dir, "entry.ts"), entryName: "App.js", outdir,
    chunksJson: join(dir, "chunks.json"), depfile: join(dir, "split.d"), external: [], minify: true, sourcemap: true,
  });
  const entryJs = readFileSync(join(outdir, "App.js"), "utf8");
  // Entry comment retargeted from Bun's `entry.js.map` to the served `App.js.map`.
  expect(entryJs).toContain("//# sourceMappingURL=App.js.map");
  expect(existsSync(join(outdir, "App.js.map"))).toBe(true);
  const meta = JSON.parse(readFileSync(join(dir, "chunks.json"), "utf8"));
  // Every chunk has a self-consistent sibling map whose comment matches its name.
  for (const c of meta.chunks as string[]) {
    expect(existsSync(join(outdir, c + ".map"))).toBe(true);
    expect(readFileSync(join(outdir, c), "utf8")).toContain(`//# sourceMappingURL=${c}.map`);
  }
});

test("PARITY (sourcemap reconciliation): bundleSpa's entry with sourcemaps matches the single-outfile bundle once the trailing map comments are stripped", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sm-spa-parity-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "util.ts"), `export const g = (n: string) => "hi " + n;\n`);
  writeFileSync(join(dir, "entry.ts"), `import { g } from "./util.ts";\nexport default () => g("x");\n`);

  const single = join(dir, "single.js");
  await bundleIsland({ entry: join(dir, "entry.ts"), outfile: single, mapfile: join(dir, "single.js.map"), depfile: join(dir, "single.d"), external: [], minify: true, sourcemap: true });

  const outdir = join(dir, "out");
  await bundleSpa({ entry: join(dir, "entry.ts"), entryName: "entry.js", outdir, chunksJson: join(dir, "chunks.json"), depfile: join(dir, "split.d"), external: [], minify: true, sourcemap: true });

  // Splitting-mode entry and single-outfile entry differ ONLY in which `.map`
  // their comment names (entry.js.map vs single.js.map); the CODE is identical.
  // This is exactly why gating emission behind the opt-in leaves the existing
  // byte-parity gate (which runs with sourcemaps OFF) untouched.
  expect(stripMapComments(readFileSync(join(outdir, "entry.js"), "utf8"))).toBe(stripMapComments(readFileSync(single, "utf8")));
});
