import { expect, test, describe, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readdirSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { buildIslandsRuntime, bundleName, RUNTIME_BASENAME } from "./build-islands-runtime.ts";

const SRC = resolve(import.meta.dir, "../src");
const MODULES = {
  islandsModule: join(SRC, "islands.ts"),
  indexModule: join(SRC, "index.ts"),
  jsxModule: join(SRC, "jsx-runtime.ts"),
};

let work: string;
beforeAll(() => { work = mkdtempSync(join(tmpdir(), "z-islands-rt-")); });
afterAll(() => { rmSync(work, { recursive: true, force: true }); });

/** Write island bundles into a fresh case dir and run the driver over them. */
async function run(name: string, bundles: Record<string, string>) {
  const dir = join(work, name);
  const bundleDir = join(dir, "bundles");
  const outdir = join(dir, "out");
  mkdirSync(bundleDir, { recursive: true });
  const paths: string[] = [];
  for (const [file, code] of Object.entries(bundles)) {
    const p = join(bundleDir, file);
    writeFileSync(p, code);
    paths.push(p);
  }
  const manifest = join(dir, "slice.json");
  const depfile = join(dir, "slice.d");
  const res = await buildIslandsRuntime({
    bundles: paths, ...MODULES, outdir, manifest, depfile, minify: true,
  });
  return {
    ...res,
    outdir,
    manifest: JSON.parse(readFileSync(manifest, "utf8")),
    depfile: readFileSync(depfile, "utf8"),
    installed: readdirSync(outdir),
    slice: existsSync(join(outdir, "_runtime.js"))
      ? readFileSync(join(outdir, "_runtime.js"), "utf8")
      : null,
  };
}

/** The shared runtime, built the same way build/bundles.zig builds it, so the
 *  size and marker comparisons below are against the real thing rather than a
 *  remembered number. */
async function sharedRuntime(): Promise<string> {
  const res = await Bun.build({
    entrypoints: [join(SRC, "browser-entry.ts")],
    format: "esm",
    minify: true,
  });
  expect(res.success).toBe(true);
  return await res.outputs[0].text();
}

describe("buildIslandsRuntime — the SLICED decision", () => {
  test("emits a slice that is materially smaller than the shared runtime, and drops the right code", async () => {
    const r = await run("sliced", {
      "Counter.island.js": `import{useState as r}from"@z/runtime";import{jsx as o}from"@z/runtime/jsx-runtime";export default function(){const[n,s]=r(0);return o("button",{onClick:()=>s(n+1)},n)}`,
      "Tabs.island.js": `import{useEffect as e}from"@z/runtime";import{jsxs as j}from"@z/runtime/jsx-runtime";export default function(){e(()=>{},[]);return j("p",{},"hi")}`,
    });

    expect(r.fallback).toBe(false);
    expect(r.manifest).toMatchObject({
      runtime: "/islands/_runtime.js",
      islands: ["Counter.island", "Tabs.island"],
      exports: ["useEffect", "useState"],
      bailed: {},
    });
    expect(r.installed).toEqual(["_runtime.js"]);

    const shared = await sharedRuntime();
    expect(r.slice!.length).toBeLessThan(shared.length);

    // Size alone proves nothing — a slice that kept everything but minified
    // differently would still be "smaller". These markers are the actual
    // subsystems the slice must have dropped: recaptcha + the compat surface,
    // the SPA router and its prefix/guard machinery, observability, and the
    // error relay. Each is asserted PRESENT in the shared runtime too, so the
    // test fails loudly (rather than vacuously passing) if a marker is renamed.
    for (const marker of [
      "g-recaptcha-response",
      "data-z-prefix",
      "data-z-guard-pending",
      "largest-contentful-paint",
      "unhandledrejection",
      "scrollRestoration",
      "matchChain",
      "initObservability",
    ]) {
      expect(shared).toContain(marker);
      expect(r.slice).not.toContain(marker);
    }

    // The auto-init side effect must survive: it is what discovers
    // [data-z-island] roots. A slice without it hydrates nothing.
    expect(r.slice).toContain("data-z-island");

    // The depfile must name every input, or a changed island bundle would not
    // invalidate the slice and the site would ship a stale runtime.
    expect(r.depfile).toContain("Counter.island.js");
    expect(r.depfile).toContain("Tabs.island.js");
    expect(r.depfile).toContain("index.ts");
  }, 30_000);
});

describe("buildIslandsRuntime — the FALLBACK decision", () => {
  test("one unsafe island among safe ones bails only itself", async () => {
    const r = await run("partial", {
      "Clean.island.js": `import{useState as a}from"@z/runtime";`,
      "Widget.island.js": `import{useState as o}from"react";`,
    });
    expect(r.fallback).toBe(false);
    expect(r.manifest.islands).toEqual(["Clean.island"]);
    expect(r.manifest.bailed["Widget.island"]).toContain("react");
  }, 30_000);

  test("every island unsafe: fallback manifest, and NOTHING installed", async () => {
    const r = await run("fallback", {
      "Widget.island.js": `import{useState as o}from"react";`,
      "Flagged.island.js": `import{FlagsProvider as e}from"@z/runtime/compat";`,
    });
    expect(r.fallback).toBe(true);
    expect(r.manifest).toEqual({ fallback: true });
    // The output dir is installed wholesale to /islands; leaving a bundle there
    // would ship a runtime no page's import map points at.
    expect(r.installed).toEqual([]);
    // Still depfile-tracked, so adding a sliceable island rebuilds the decision.
    expect(r.depfile).toContain("Widget.island.js");
  }, 30_000);

  test("an unreadable island bundle falls the WHOLE SITE back, never silently drops it", async () => {
    const dir = join(work, "unreadable");
    mkdirSync(dir, { recursive: true });
    const manifest = join(dir, "slice.json");
    const res = await buildIslandsRuntime({
      // A path that does not exist: its runtime surface is unknown, and
      // admitting the others would under-slice into a page that loads a runtime
      // missing what this island imports.
      bundles: [join(dir, "Ghost.island.js")],
      ...MODULES,
      outdir: join(dir, "out"),
      manifest,
      depfile: join(dir, "slice.d"),
      minify: false,
    });
    expect(res.fallback).toBe(true);
    expect(JSON.parse(readFileSync(manifest, "utf8"))).toEqual({ fallback: true });
  }, 30_000);
});

describe("the reserved output name", () => {
  test("bundleName matches build/validate.zig's islandName", () => {
    expect(bundleName("/cache/o/abc/Hero.island.js")).toBe("Hero.island");
    expect(bundleName("Hero.island.js")).toBe("Hero.island");
    expect(RUNTIME_BASENAME).toBe("_runtime");
  });

  test("an island named _runtime is rejected loudly rather than being overwritten", async () => {
    const dir = join(work, "reserved");
    mkdirSync(dir, { recursive: true });
    const bundle = join(dir, "_runtime.js");
    writeFileSync(bundle, `import{useState}from"@z/runtime";`);
    // Driven as a subprocess: the guard is a `process.exit(1)`, which in-process
    // would take the test runner down with it.
    const proc = Bun.spawn([
      "bun", resolve(import.meta.dir, "build-islands-runtime.ts"),
      `--bundle=${bundle}`,
      `--islands-module=${MODULES.islandsModule}`,
      `--index-module=${MODULES.indexModule}`,
      `--jsx-module=${MODULES.jsxModule}`,
      `--outdir=${join(dir, "out")}`,
      `--manifest=${join(dir, "slice.json")}`,
      `--depfile=${join(dir, "slice.d")}`,
    ], { stdout: "pipe", stderr: "pipe" });
    const code = await proc.exited;
    const err = await new Response(proc.stderr).text();
    expect(code).toBe(1);
    expect(err).toContain("reserved island name");
  }, 30_000);
});
