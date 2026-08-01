// Per-SITE islands runtime slicer — the BUILD driver.
//
// Reads every island's BUILT bundle, asks slice-islands.ts which of them can be
// proved safe and which named `@z/runtime` exports they collectively need, and
// then either
//   - FALLBACK (no island was provably safe): writes a `{"fallback": true}`
//     manifest and NO bundle. Every island page keeps the shared
//     /zigapagos-runtime.js — worst case is today's behaviour; or
//   - SLICED: generates an entry re-exporting exactly that union (plus the JSX
//     names and islands.ts's hydration auto-init), bundles it to
//     `<outdir>/_runtime.js`, and writes a manifest naming the islands the
//     slice covers.
//
// The manifest is threaded to `zigapagos release --islands-slice=<path>`, which
// points a page's import map at the slice IFF every island on that page is
// covered — one URL per page, so one Preact per page by construction.
//
// Exactly two runtime artifacts exist site-wide (the shared one and at most one
// slice). Per-page bespoke bundles are architecturally impossible: page
// composition is only known at render time inside `zigapagos release`, which
// never invokes a bundler.
import { resolve } from "node:path";
import { mkdirSync, readFileSync } from "node:fs";
import { basename } from "node:path";
import { makeDepfile, retargetSourceMappingUrl } from "../sidecar/bundle-island.ts";
import {
  analyzeIslandBundles,
  generateIslandsEntry,
  runtimeExportNames,
  type IslandBundle,
} from "./slice-islands.ts";

/** The slice's output basename, and therefore a RESERVED island bundle name. */
export const RUNTIME_BASENAME = "_runtime";

export interface IslandsRuntimeArgs {
  /** Built island bundles (`<name>.js`). */
  bundles: string[];
  islandsModule: string; // absolute path to runtime/src/islands.ts
  indexModule: string;   // absolute path to runtime/src/index.ts
  jsxModule: string;     // absolute path to runtime/src/jsx-runtime.ts
  outdir: string;        // dir `_runtime.js` is written into (installed to /islands)
  manifest: string;      // slice-manifest json path
  depfile: string;
  minify: boolean;
  /** Emit a linked `.map` next to the slice (release-only opt-in). */
  sourcemap?: boolean;
  runtimeStamp?: string;
}

/** Bundle basename with `.js` stripped. Yields the same name that
 *  src/cli/release.zig's `bundleName` and src/islands/pass.zig's
 *  `islandModuleName` derive from the island's SOURCE path — all three drop the
 *  directory and the FINAL extension only, so `Hero.island.tsx` and the
 *  `Hero.island.js` built from it both give `Hero.island`. That agreement is what
 *  makes the manifest's `islands` list joinable against a page's islands. */
export function bundleName(path: string): string {
  const base = basename(path);
  return base.endsWith(".js") ? base.slice(0, -3) : base;
}

export async function buildIslandsRuntime(args: IslandsRuntimeArgs): Promise<{ fallback: boolean }> {
  mkdirSync(args.outdir, { recursive: true });

  const bundles: IslandBundle[] = [];
  for (const p of args.bundles) {
    const name = bundleName(p);
    if (name === RUNTIME_BASENAME) {
      // `<outdir>/_runtime.js` is the slice's own output name; an island called
      // `_runtime` would be overwritten by it in the install directory.
      console.error(`build-islands-runtime: '${RUNTIME_BASENAME}' is a reserved island name (it collides with the sliced runtime)`);
      process.exit(1);
    }
    try {
      bundles.push({ name, code: readFileSync(p, "utf8") });
    } catch (e) {
      // Never a silent drop: an unread bundle is an island whose runtime
      // surface is unknown, and admitting the rest would under-slice into a
      // page that loads a runtime missing what that island imports. Fall the
      // WHOLE SITE back, loudly — the same posture as build-spa-runtime.ts's
      // `readSourcesOrFail`.
      console.error(`build-islands-runtime: could not read island bundle ${p} — falling back to the shared runtime:`, e);
      return await writeFallback(args, `could not read ${p}`);
    }
  }

  const exportsOfIndex = runtimeExportNames(readFileSync(args.indexModule, "utf8"));
  const verdict = analyzeIslandBundles(bundles, exportsOfIndex);
  for (const [name, why] of Object.entries(verdict.bailed)) {
    console.error(`build-islands-runtime: ${name} keeps the shared runtime — ${why}`);
  }

  if (verdict.sliceable.length === 0) {
    return await writeFallback(args, "no island could be proved safe to slice");
  }

  const entrySource = generateIslandsEntry(verdict.exports, {
    islandsModule: resolve(args.islandsModule),
    indexModule: resolve(args.indexModule),
    jsxModule: resolve(args.jsxModule),
  });
  // Written OUTSIDE `outdir`: everything in outdir is installed wholesale to
  // /islands, and the entry is build scratch, not a deployable. Its own import
  // specifiers are absolute, so its location is irrelevant.
  const entryPath = resolve(args.outdir, "..", "_islands-entry.ts");
  await Bun.write(entryPath, entrySource);

  const captured = new Set<string>();
  const res = await Bun.build({
    entrypoints: [entryPath],
    format: "esm",
    minify: args.minify,
    sourcemap: args.sourcemap ? "linked" : "none",
    plugins: [{
      name: "dep-capture",
      setup(build) {
        build.onLoad({ filter: /.*/ }, (a) => { captured.add(a.path); return undefined; });
      },
    }],
  });
  if (!res.success) {
    for (const m of res.logs) console.error(m);
    process.exit(1);
  }

  const entryName = `${RUNTIME_BASENAME}.js`;
  if (args.sourcemap) {
    const entry = res.outputs.find((o) => o.kind === "entry-point");
    const map = res.outputs.find((o) => o.kind === "sourcemap");
    if (!entry || !map) {
      console.error("build-islands-runtime: sourcemap requested but entry/map output missing");
      process.exit(1);
    }
    const mapName = `${entryName}.map`;
    await Bun.write(resolve(args.outdir, entryName), retargetSourceMappingUrl(await entry.text(), mapName));
    await Bun.write(resolve(args.outdir, mapName), await map.text());
  } else {
    if (res.outputs.length !== 1) {
      console.error(`build-islands-runtime: expected 1 output, got ${res.outputs.length}`);
      process.exit(1);
    }
    await Bun.write(resolve(args.outdir, entryName), await res.outputs[0].text());
  }

  await Bun.write(args.manifest, JSON.stringify({
    runtime: `/islands/${entryName}`,
    islands: verdict.sliceable,
    exports: verdict.exports,
    bailed: verdict.bailed,
  }));
  await writeDepfile(args, [...captured].map((p) => resolve(process.cwd(), p)));
  return { fallback: false };
}

/** The manifest shape that means "no slice": every island page keeps the shared
 *  runtime, and NOTHING is written into `outdir` (which is installed wholesale,
 *  so an empty dir installs nothing — the shipped SPA-slicer's exact shape). */
async function writeFallback(args: IslandsRuntimeArgs, why: string): Promise<{ fallback: boolean }> {
  console.error(`build-islands-runtime: shared runtime for every island page — ${why}`);
  await Bun.write(args.manifest, JSON.stringify({ fallback: true }));
  await writeDepfile(args, []);
  return { fallback: true };
}

/** Deps common to both outcomes: every island bundle, the three runtime modules
 *  the entry re-exports from, the version stamp, plus (when sliced) the
 *  transitive closure the bundler actually loaded. */
async function writeDepfile(args: IslandsRuntimeArgs, extra: string[]): Promise<void> {
  const deps = [
    ...args.bundles.map((p) => resolve(p)),
    resolve(args.islandsModule), resolve(args.indexModule), resolve(args.jsxModule),
    ...(args.runtimeStamp ? [resolve(args.runtimeStamp)] : []),
    ...extra,
  ];
  await Bun.write(args.depfile, makeDepfile(resolve(args.manifest), [...new Set(deps)]));
}

if (import.meta.main) {
  const get = (k: string) => {
    const a = process.argv.find((x) => x.startsWith(`--${k}=`));
    return a ? a.slice(k.length + 3) : undefined;
  };
  const req = (k: string) => {
    const v = get(k);
    if (!v) { console.error(`build-islands-runtime: --${k}= is required`); process.exit(1); }
    return v;
  };
  const bundles = process.argv
    .filter((x) => x.startsWith("--bundle="))
    .map((x) => x.slice("--bundle=".length));
  await buildIslandsRuntime({
    bundles,
    islandsModule: req("islands-module"),
    indexModule: req("index-module"),
    jsxModule: req("jsx-module"),
    outdir: req("outdir"),
    manifest: req("manifest"),
    depfile: req("depfile"),
    minify: process.argv.includes("--minify"),
    sourcemap: process.argv.includes("--sourcemap"),
    runtimeStamp: get("runtime-stamp"),
  });
}
