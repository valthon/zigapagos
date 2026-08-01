// Per-deployable runtime slicer — the BUILD driver.
//
// For ONE SPA it: (1) captures the SPA's transitive sources (reusing the same
// onLoad module capture), (2) asks slice-host.ts which host.* members the SPA
// uses (or null ⇒ SAFE-FALLBACK), and then either
//   - FALLBACK: writes a `{ "fallback": true }` slice manifest and NO runtime
//     bundle — the SPA keeps using the shared /zigapagos-runtime.js (worst case
//     = today's behavior); or
//   - SLICED: bundles spa-entry.ts into /spa/<name>-runtime.js with a Bun
//     onResolve alias that redirects the runtime's own `./host.ts` imports to a
//     generated sliced-host module (only the used members), so unused members —
//     e.g. admin-only host.loadScript on a public SPA — are DCE'd out. Writes a
//     `{ "runtime": "/spa/<name>-runtime.js", "members": [...] }` slice manifest.
//
// `zigapagos release` runs this driver per SPA (release.zig's `bundleSpas`) and
// hands the manifest it writes to the prerender pass as `SpaSpec.slice_json`,
// which points that SPA's shell import-map at the per-SPA runtime (SLICED) or
// the shared one (FALLBACK). One runtime per page ⇒ one Preact, always.
import { resolve, dirname, isAbsolute } from "node:path";
import { mkdirSync, readFileSync } from "node:fs";
import type { BunPlugin } from "bun";
import { reactAliasBuildPlugin, resolveOverridePlugin } from "./react-alias.ts";
import { makeDepfile, findTsconfig, siteConfigFor, retargetSourceMappingUrl } from "../sidecar/bundle-island.ts";
import { effectiveResolveMap } from "./z-runtime-config.ts";
import { siteDataPlugin } from "./site-data.ts";
// TYPE-ONLY, so this module can be loaded without `typescript` on the resolution
// path — see `loadSlicer`. A value import here would be eager and fatal.
import type { Source, HostMember } from "./slice-host.ts";

// Every code-module extension Bun may load as a source that could `import { host }`
// or a compat/react specifier: ts/tsx/js/jsx + the mjs/cjs/mts/cts variants. A
// captured CODE file that matches this but can't be read forces the fallback (see
// readSourcesOrFail) — we never silently drop a source we failed to analyze.
export const SOURCE_RE = /\.(m|c)?[tj]sx?$/;

/**
 * Read every captured CODE file (a @z/runtime source is external, so skipped) for
 * analysis. Returns null — the SAFE-FALLBACK — if ANY captured code file fails to
 * read: dropping an unreadable source would UNDER-count host usage (a fail-open
 * under-slice ⇒ a missing-member crash), so an unknown source widens to the full
 * shared runtime instead.
 */
export function readSourcesOrFail(captured: string[]): Source[] | null {
  const sources: Source[] = [];
  for (const p of captured) {
    if (!SOURCE_RE.test(p) || p.includes("/node_modules/@z/runtime/")) continue;
    try {
      sources.push({ path: p, code: readFileSync(p, "utf8") });
    } catch (e) {
      console.error(`build-spa-runtime: could not read captured source ${p} — falling back to the shared runtime:`, e);
      return null;
    }
  }
  return sources;
}

export interface SpaRuntimeArgs {
  entry: string;        // the SPA entry (e.g. app/Public.spa.tsx)
  spaEntry: string;     // the fixed core runtime entry (runtime/src/spa-entry.ts)
  hostModule: string;   // absolute path to runtime/src/host.ts
  ssrEnvModule: string; // absolute path to runtime/src/ssr-env.ts
  outdir: string;       // dir to write <name>-runtime.js into (installed to /spa)
  name: string;         // SPA name (e.g. "public") — the runtime is <name>-runtime.js
  manifest: string;     // slice-manifest json path
  depfile: string;
  minify: boolean;
  /** Emit a linked `.map` next to the sliced runtime (release-only opt-in).
   *  Installed with the rest of `outdir`, so it lands at /spa/<name>-runtime.js.map. */
  sourcemap?: boolean;
  runtimeStamp?: string;
}

/** Run Bun.build over the SPA entry (@z/runtime external) purely to enumerate the
 *  SPA's transitive source files (reuses the same onLoad-capture technique). */
async function captureSpaSources(entry: string): Promise<string[]> {
  const site = siteConfigFor(entry);
  const captured = new Set<string>();
  const res = await Bun.build({
    entrypoints: [entry],
    external: ["@z/runtime", "@z/runtime/jsx-runtime"],
    format: "esm",
    minify: false,
    plugins: [
      // Same z-runtime.config.json `resolve` overrides + @z/site-data
      // virtual module as the real bundle — without them, a mapped or
      // virtual specifier would fail this capture build.
      resolveOverridePlugin(effectiveResolveMap(site.config), site.baseDir),
      siteDataPlugin(site.config.data ?? {}, site.baseDir),
      reactAliasBuildPlugin(), // keep react* external (never bundle a 2nd Preact)
      {
        name: "dep-capture",
        setup(build) {
          build.onLoad({ filter: /.*/ }, (a) => { captured.add(a.path); return undefined; });
        },
      },
    ],
  });
  if (!res.success) {
    for (const m of res.logs) console.error(m);
    process.exit(1);
  }
  const root = process.cwd();
  return [...captured].map((p) => resolve(root, p));
}

/** The onResolve/onLoad plugin that swaps the runtime's `./host.ts` for the
 *  generated sliced-host module (whose own ABSOLUTE host.ts import is passed
 *  through untouched, so the real member fns still resolve). */
function slicedHostPlugin(slicedSource: string, resolveDir: string): BunPlugin {
  return {
    name: "z-host-slice",
    setup(build) {
      build.onResolve({ filter: /(^|\/)host\.ts$/ }, (args) => {
        // The generated module imports the REAL members from host.ts via an
        // ABSOLUTE path — let that through to the real file. Only the runtime's
        // own RELATIVE `./host.ts` imports get redirected to the slice.
        if (isAbsolute(args.path)) return null;
        return { path: "z-sliced-host", namespace: "z-sliced-host" };
      });
      build.onLoad({ filter: /.*/, namespace: "z-sliced-host" }, () => ({
        contents: slicedSource, loader: "ts", resolveDir,
      }));
    },
  };
}

/**
 * `slice-host.ts`, or null when it cannot be loaded — which in practice means
 * `typescript` is not resolvable, since the slicer parses every source with the
 * TS compiler API.
 *
 * WHY LAZY, AND WHY NOT FATAL. `typescript` is a devDependency of the runtime
 * package: a repo checkout that has run `bun install` always has it, and a
 * consumer's tree may not — `@zigapagos/cli` declares it only as an
 * OPTIONAL dependency, so `--omit=optional` (or any install that skips it) leaves
 * this module resolvable and its analysis impossible. An eager import turned that
 * into a hard build failure with a message about a package the user never named.
 *
 * Returning null instead routes it into the SAFE-FALLBACK this file already has
 * for every other "cannot prove what this SPA uses" case: no per-SPA runtime, the
 * shared `/zigapagos-runtime.js`, worst case = the pre-slicing behaviour. Slicing
 * is a size optimization; not being able to do it must never fail a build.
 * `sidecar/hot-transform.ts` degrades on the same dependency the same way.
 */
async function loadSlicer(): Promise<typeof import("./slice-host.ts") | null> {
  try {
    return await import("./slice-host.ts");
  } catch (e) {
    console.error(
      "build-spa-runtime: the host slicer is unavailable (typescript not resolvable?) — " +
        "this SPA will use the shared runtime:",
      e,
    );
    return null;
  }
}

export async function buildSpaRuntime(args: SpaRuntimeArgs): Promise<{ fallback: boolean }> {
  mkdirSync(args.outdir, { recursive: true });

  // (1) capture + (2) analyze. A captured CODE file that fails to read forces the
  // SAFE-FALLBACK (readSourcesOrFail returns null) — never a silent drop. So does
  // an unloadable slicer (see `loadSlicer`).
  const slicer = await loadSlicer();
  const captured = await captureSpaSources(args.entry);
  const sources = slicer === null ? null : readSourcesOrFail(captured);
  const used = sources === null ? null : slicer!.analyzeHostUsage(sources);

  // Deps common to both outcomes: the SPA's transitive sources + tsconfig + stamp.
  const baseDeps = [
    ...captured,
    ...findTsconfig(resolve(args.entry)),
    ...(args.runtimeStamp ? [resolve(args.runtimeStamp)] : []),
  ];

  if (used === null) {
    // SAFE-FALLBACK: no per-SPA runtime; the SPA uses the shared runtime.
    await Bun.write(args.manifest, JSON.stringify({ fallback: true }));
    await Bun.write(args.depfile, makeDepfile(resolve(args.manifest), [...new Set(baseDeps)]));
    return { fallback: true };
  }

  // (3) SLICED: bundle spa-entry.ts with host.ts aliased to the generated slice.
  // `slicer` is non-null here: `used` is only non-null when it loaded.
  const slicedSource = slicer!.generateSlicedHost(used, {
    hostModule: args.hostModule, ssrEnvModule: args.ssrEnvModule, name: args.name,
  });
  const captured2 = new Set<string>();
  const res = await Bun.build({
    entrypoints: [args.spaEntry],
    format: "esm",
    minify: args.minify,
    // Release-only opt-in: a linked map so errors in the sliced runtime
    // symbolicate too. "none" (default) keeps the single-output byte-for-byte.
    sourcemap: args.sourcemap ? "linked" : "none",
    plugins: [
      slicedHostPlugin(slicedSource, dirname(args.hostModule)),
      {
        name: "dep-capture",
        setup(build) {
          build.onLoad({ filter: /.*/ }, (a) => { captured2.add(a.path); return undefined; });
        },
      },
    ],
  });
  if (!res.success) {
    for (const m of res.logs) console.error(m);
    process.exit(1);
  }

  const entryName = `${args.name}-runtime.js`;
  if (args.sourcemap) {
    const entry = res.outputs.find((o) => o.kind === "entry-point");
    const map = res.outputs.find((o) => o.kind === "sourcemap");
    if (!entry || !map) {
      console.error("build-spa-runtime: sourcemap requested but entry/map output missing");
      process.exit(1);
    }
    const mapName = `${entryName}.map`;
    await Bun.write(resolve(args.outdir, entryName), retargetSourceMappingUrl(await entry.text(), mapName));
    await Bun.write(resolve(args.outdir, mapName), await map.text());
  } else {
    if (res.outputs.length !== 1) {
      console.error(`build-spa-runtime: expected 1 output, got ${res.outputs.length}`);
      process.exit(1);
    }
    await Bun.write(resolve(args.outdir, entryName), await res.outputs[0].text());
  }
  const members = [...used].sort();
  await Bun.write(args.manifest, JSON.stringify({ runtime: `/spa/${entryName}`, members }));

  const root = process.cwd();
  const deps = [
    ...baseDeps,
    ...[...captured2].map((p) => resolve(root, p)),
    resolve(args.spaEntry), resolve(args.hostModule), resolve(args.ssrEnvModule),
  ];
  await Bun.write(args.depfile, makeDepfile(resolve(args.manifest), [...new Set(deps)]));
  return { fallback: false };
}

if (import.meta.main) {
  const get = (k: string) => {
    const a = process.argv.find((x) => x.startsWith(`--${k}=`));
    return a ? a.slice(k.length + 3) : undefined;
  };
  const req = (k: string) => {
    const v = get(k);
    if (!v) { console.error(`build-spa-runtime: --${k}= is required`); process.exit(1); }
    return v;
  };
  await buildSpaRuntime({
    entry: req("entry"),
    spaEntry: req("spa-entry"),
    hostModule: req("host-module"),
    ssrEnvModule: req("ssr-env-module"),
    outdir: req("outdir"),
    name: req("name"),
    manifest: req("manifest"),
    depfile: req("depfile"),
    minify: process.argv.includes("--minify"),
    sourcemap: process.argv.includes("--sourcemap"),
    runtimeStamp: get("runtime-stamp"),
  });
}
