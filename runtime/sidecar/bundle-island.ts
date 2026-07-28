import { resolve, dirname, join, basename } from "node:path";
import { existsSync, readFileSync, mkdirSync, realpathSync } from "node:fs";
import { reactAliasBuildPlugin, resolveOverridePlugin } from "../scripts/react-alias.ts";
import { loadConfig, effectiveResolveMap, type ZRuntimeConfig } from "../scripts/z-runtime-config.ts";
import { siteDataPlugin } from "../scripts/site-data.ts";
import { registerSsrModuleOverrides } from "./ssr-resolve.ts";

export interface BundleArgs {
  entry: string;
  outfile: string;
  depfile: string;
  external: string[];
  minify: boolean;
  runtimeStamp?: string;
  /** Explicit z-runtime.config.json path (else discovered upward from the entry's dir). */
  configPath?: string;
  /** Emit an external (linked) source map next to the bundle (release-only opt-in).
   *  When set, `sourcemap: "linked"` is passed to Bun.build, the map
   *  is written to `mapfile` (defaulting to `outfile + ".map"`), and the entry's
   *  trailing `//# sourceMappingURL=` comment is retargeted to the map's SERVED
   *  basename so it matches both browser devtools and the client symbolicator
   *  (observability.ts, which appends `.map` to each script URL). Off by default,
   *  so a bundle built without it is byte-identical to today (byte-parity gate). */
  sourcemap?: boolean;
  /** Where to write the `.map` when `sourcemap` is set. Defaults to `outfile + ".map"`. */
  mapfile?: string;
  /** Dev-only fast-refresh transform: route the entry's top-level function
   *  components through @z/runtime's hot registry (sidecar/hot-transform.ts) so
   *  an island hot-swap preserves plain useState/useReducer state. Off by
   *  default — the transform changes bundle bytes, so release builds (the
   *  byte-parity gate) never set it. */
  hot?: boolean;
}

/** Retarget the trailing `//# sourceMappingURL=` comment Bun appends under
 *  `sourcemap: "linked"` to `mapName`. Bun names the map after its OWN entry
 *  basename (e.g. `Counter.island.js.map`), but the bundle is served under a
 *  different name (`/islands/Counter.js`), so the comment — and the map we
 *  write — must use the served basename or the browser/symbolicator 404s.
 *  Only the value is rewritten; the `//# debugId=` line (if any) is untouched. */
export function retargetSourceMappingUrl(js: string, mapName: string): string {
  return js.replace(/(\/\/# sourceMappingURL=)\S*/, `$1${mapName}`);
}

/** `realpathSync`, falling back to the input when the path cannot be stat'ed.
 *
 *  Used for identity comparison of module paths. Bun reports symlink-resolved
 *  paths to `onLoad`, while `resolve()` does not follow symlinks, so the two
 *  disagree wherever a path component is a symlink — most visibly macOS's
 *  `$TMPDIR` (`/var/folders/…` -> `/private/var/folders/…`). Comparing raw
 *  `resolve()` output there silently fails to match. */
function realpathOr(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

/** The site config for a bundle: explicit path or discovered upward from the entry. */
export function siteConfigFor(entry: string, configPath?: string): {
  config: ZRuntimeConfig;
  path: string | null;
  /** Resolution base for relative `resolve`/`data` values: the config's dir. */
  baseDir: string;
} {
  const entryAbs = resolve(entry);
  const { config, path } = loadConfig({ configPath, startDir: dirname(entryAbs) });
  return { config, path, baseDir: path ? dirname(path) : dirname(entryAbs) };
}

export function makeDepfile(target: string, deps: string[]): string {
  const esc = (p: string) => p.replace(/ /g, "\\ "); // Zig depfile tokenizer: space => separator
  const lines = deps.map((d) => "  " + esc(d) + " \\").join("\n");
  return `${esc(target)}: \\\n${lines}\n`; // trailing `\` on each dep line; final dep also (harmless)
}

export function findTsconfig(entryAbs: string): string[] {
  const out: string[] = [];
  let dir = dirname(entryAbs);
  for (;;) {
    const tc = join(dir, "tsconfig.json");
    if (existsSync(tc)) {
      out.push(tc);
      try {
        const ext = JSON.parse(readFileSync(tc, "utf8")).extends;
        if (typeof ext === "string") {
          const e = resolve(dir, ext);
          if (existsSync(e)) out.push(e);
        }
      } catch {
        /* malformed tsconfig: still tracked above */
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return out;
}

export async function bundleIsland(args: BundleArgs): Promise<string[]> {
  // onLoad plugin captures every module path loaded by Bun.build, including transitive
  // relative deps.  Works on Bun 1.2+.  return undefined = pure observer; output bytes
  // are unchanged (byte-parity with a plain `bun build` is preserved).
  const site = siteConfigFor(args.entry, args.configPath);
  const captured = new Set<string>();
  const contentFiles = new Set<string>();
  // Dev-only fast-refresh transform. Lazily imported so release-build
  // driver runs never pay typescript's multi-MB parse; if it can't resolve,
  // bundle untransformed (graceful remount fallback), never fail the build.
  let hotTransform: ((src: string, file: string, key: string) => string) | null = null;
  if (args.hot) {
    try {
      hotTransform = (await import("./hot-transform.ts")).transformIslandForHot;
    } catch (e) {
      console.error("bundle-island: --hot unavailable (typescript not resolvable?); bundling without fast refresh", e);
    }
  }
  const entryAbs = resolve(args.entry);
  // Symlink-resolved form of the entry, for identity comparison against the
  // paths Bun reports to onLoad. `resolve()` normalises `.`/`..` but does NOT
  // follow symlinks, and Bun hands back the realpath — so on macOS, where
  // $TMPDIR is `/var/folders/…` symlinked to `/private/var/folders/…`, the two
  // never compared equal and the hot transform silently skipped the entry.
  // Symptom: a bundle with no `__zigapagos_hot_register` call and a passing
  // build, i.e. fast refresh degrading to a full remount with no diagnostic.
  // Falls back to the un-resolved path if the file cannot be stat'ed.
  const entryReal = realpathOr(entryAbs);
  const res = await Bun.build({
    entrypoints: [args.entry],
    external: args.external,
    format: "esm",
    minify: args.minify,
    // Release-only opt-in: "linked" appends a `sourceMappingURL` comment
    // and emits a second `.map` output. "none" (the default) keeps the bundle
    // byte-identical to today so the byte-parity gate is untouched.
    sourcemap: args.sourcemap ? "linked" : "none",
    metafile: true, // keep — harmless; populated on Bun 1.3+, ignored on 1.2
    // NODE_ENV (set by Zig) already selects jsx vs jsxDEV — unchanged from today.
    plugins: [
      // The site's `resolve` override map — BEFORE the unconditional
      // react externalization so an explicit user override of a react* key wins.
      resolveOverridePlugin(effectiveResolveMap(site.config), site.baseDir),
      // `@z/site-data` from the config's `data` map; selected content
      // files land in `contentFiles` => the depfile (content edits invalidate).
      siteDataPlugin(site.config.data ?? {}, site.baseDir, contentFiles),
      // Keep react* EXTERNAL (kept external => one Preact via the import-map).
      // Unconditional: react is never legitimately bundled into an island.
      reactAliasBuildPlugin(),
      {
        name: "dep-capture",
        setup(build) {
          build.onLoad({ filter: /.*/ }, (a) => {
            captured.add(a.path);
            return undefined; // pure observer — never alter contents
          });
        },
      },
      // Dev-only fast refresh: rewrite ONLY the entry module. Registered
      // AFTER dep-capture — Bun runs onLoad callbacks in order and a callback
      // returning undefined passes through, so dep capture stays intact.
      ...(hotTransform
        ? [
            {
              name: "hot-transform",
              setup(build) {
                const fn = hotTransform!;
                build.onLoad({ filter: /\.[tj]sx?$/ }, async (a) => {
                  // Compare realpaths, not `resolve()`d paths — see entryReal.
                  if (realpathOr(resolve(a.path)) !== entryReal) return undefined;
                  const src = await Bun.file(a.path).text();
                  // moduleKey = the entry's absolute path: stable across
                  // rebuilds within a dev session, unique per island entry.
                  const out = fn(src, a.path, entryAbs);
                  if (out === src) return undefined; // nothing wrappable
                  const loader = a.path.endsWith(".tsx") ? "tsx"
                    : a.path.endsWith(".ts") ? "ts"
                    : a.path.endsWith(".jsx") ? "jsx" : "js";
                  return { contents: out, loader };
                });
              },
            } as import("bun").BunPlugin,
          ]
        : []),
    ],
  });
  if (!res.success) {
    for (const m of res.logs) console.error(m);
    process.exit(1);
  }
  if (args.sourcemap) {
    // With a linked source map Bun emits the entry chunk + its `.map`. Write the
    // entry (its `sourceMappingURL` comment retargeted to the served map name)
    // and the map alongside it at `mapfile` (served next to the bundle).
    const entry = res.outputs.find((o) => o.kind === "entry-point");
    const map = res.outputs.find((o) => o.kind === "sourcemap");
    if (!entry || !map) {
      console.error("bundle-island: sourcemap requested but entry/map output missing");
      process.exit(1);
    }
    const mapfile = args.mapfile ?? args.outfile + ".map";
    await Bun.write(args.outfile, retargetSourceMappingUrl(await entry.text(), basename(mapfile)));
    await Bun.write(mapfile, await map.text());
  } else {
    if (res.outputs.length !== 1) {
      console.error(`bundle-island: expected 1 output, got ${res.outputs.length}`);
      process.exit(1);
    }
    await Bun.write(args.outfile, await res.outputs[0].text());
  }

  const root = process.cwd();
  // Primary: onLoad plugin captured every loaded module (Bun 1.2+, including transitive deps).
  const fromPlugin = [...captured].map((p) => resolve(root, p));
  // Bonus: metafile.inputs populated on Bun 1.3+ — union in for completeness.
  const fromMeta = res.metafile
    ? Object.keys(res.metafile.inputs).map((p) => resolve(root, p))
    : [];
  // Defensive: ensure entry is always listed even if onLoad didn't fire for some edge case.
  const extra = [
    resolve(args.entry),
    ...findTsconfig(resolve(args.entry)),
    ...(args.runtimeStamp ? [resolve(args.runtimeStamp)] : []),
    ...(site.path ? [site.path] : []), // config edits invalidate the bundle
    ...contentFiles, // @z/site-data content edits invalidate the bundle
  ];
  const deps = [...new Set([...fromPlugin, ...fromMeta, ...extra])];
  await Bun.write(args.depfile, makeDepfile(resolve(args.outfile), deps));
  return deps;
}

export interface SpaBundleArgs {
  entry: string;
  entryName: string; // desired entry filename, e.g. "app.js"
  outdir: string; // directory to write the entry + chunk files into
  chunksJson: string; // path to write the chunk manifest (NOT installed)
  depfile: string;
  external: string[];
  minify: boolean;
  runtimeStamp?: string;
  /** Explicit z-runtime.config.json path (else discovered upward from the entry's dir). */
  configPath?: string;
  /** Emit linked source maps for the entry + every code-split chunk into `outdir`
   *  (release-only opt-in). The whole `outdir` is installed, so the
   *  `.map` files land next to their bundles automatically. Off by default so the
   *  entry stays byte-identical to the single-outfile bundle (byte-parity gate). */
  sourcemap?: boolean;
}

/** Split segments of a route path, dropping leading/trailing/empty slashes. */
function pathSegs(p: string): string[] {
  return p.replace(/^\/+|\/+$/g, "").split("/").filter(Boolean);
}

/**
 * The chunk backing a lazy route's `import("<specifier>")`, or `undefined` when
 * there is no UNAMBIGUOUS answer.
 *
 * Bun names a split chunk `<module-basename>-<hash>.js` (or exactly
 * `<module-basename>.js` when it needs no hash). The hash segment is ANCHORED
 * (`-[A-Za-z0-9]+\.js$`): a bare `startsWith(base + "-")` prefix test also
 * matches a SIBLING module whose name merely starts with `base` — with lazy
 * imports of both `./views/Heavy` and `./views/Heavy-Extra`, `Heavy` would match
 * `Heavy-Extra-a1b2c3.js` depending on the order Bun returned its outputs, and
 * the shell would emit a `modulepreload` for a chunk that route never loads.
 * More than one candidate is reported and mapped to NOTHING: a missing preload
 * hint costs a round-trip, a wrong one is a wasted download plus a wrong answer.
 */
export function findRouteChunk(specifier: string, chunks: string[]): string | undefined {
  const base = basename(specifier).replace(/\.[tj]sx?$/, "");
  // `RegExp.escape`: a module basename legitimately contains "." (and the
  // occasional "+"), which must match literally — see the "v1.0" test. This
  // pattern is internal to chunk lookup and never surfaces in output, so the
  // stdlib escaper is the right call here.
  const hashed = new RegExp("^" + RegExp.escape(base) + "-[A-Za-z0-9]+\\.js$");
  const matches = chunks.filter((c) => c === base + ".js" || hashed.test(c));
  if (matches.length > 1) {
    console.error(
      `bundle-spa: ${JSON.stringify(specifier)} matches ${matches.length} chunks ` +
        `(${matches.join(", ")}); emitting NO route→chunk mapping rather than guessing.`,
    );
    return undefined;
  }
  return matches[0];
}

/**
 * Map each LAZY route's full path to the chunk file that backs it. The SPA entry
 * is imported (side-effect-free: `lazy()` only records a loader, never calls the
 * dynamic import), its `routes` walked; each lazy route's `import("…")` specifier
 * is extracted from the loader source and matched to the chunk Bun named after
 * that module (`import("./views/Heavy")` → `Heavy-<hash>.js`). Returns {} if the
 * module can't be imported (mapping is best-effort; the build still succeeds).
 */
async function mapRouteChunks(entry: string, chunks: string[]): Promise<Record<string, string>> {
  const map: Record<string, string> = {};
  let mod: any;
  try {
    mod = await import(resolve(entry));
  } catch (e) {
    console.error("bundle-spa: could not import SPA to map lazy chunks:", e);
    return map;
  }
  const walk = (routes: any[], prefix: string): void => {
    for (const r of routes ?? []) {
      const full = "/" + [...pathSegs(prefix), ...pathSegs(r.path)].join("/");
      if (r.children && r.children.length) { walk(r.children, full); continue; }
      const lz = r.component && (r.component as any).__zLazy;
      if (!lz) continue;
      const m = /import\(\s*['"]([^'"]+)['"]\s*\)/.exec(String(lz.loader));
      if (!m) continue;
      const chunk = findRouteChunk(m[1], chunks);
      if (chunk) map[full === "/" ? "/" : full] = chunk;
    }
  };
  walk(mod.routes ?? [], "");
  return map;
}

/**
 * Bundle an SPA with code-splitting: one entry chunk + one chunk per `import()`
 * split + shared chunks, `@z/runtime` kept external (one Preact via the import
 * map). Writes the entry as `<entryName>` and every other chunk under its
 * content-hashed name into `outdir`, plus a `spa-chunks.json` (entry name, chunk
 * list, and the lazy-route→chunk map) for the manifest/preload. A NON-lazy SPA
 * produces a single entry output that is BYTE-IDENTICAL to the non-splitting
 * single-outfile path (see the parity test), so this mode is safe for all SPAs.
 */
export async function bundleSpa(args: SpaBundleArgs): Promise<void> {
  const site = siteConfigFor(args.entry, args.configPath);
  // The route-chunk mapping below imports the SPA entry at RUNTIME, so the
  // same overrides must exist as runtime module mocks too (ssr-resolve.ts).
  registerSsrModuleOverrides(dirname(resolve(args.entry)));
  const captured = new Set<string>();
  const contentFiles = new Set<string>();
  const res = await Bun.build({
    entrypoints: [args.entry],
    external: args.external,
    format: "esm",
    minify: args.minify,
    splitting: true,
    // Release-only opt-in: linked maps for the entry + every chunk. "none"
    // (the default) keeps the entry byte-identical to the single-outfile bundle.
    sourcemap: args.sourcemap ? "linked" : "none",
    // Name the dynamic-import chunks after their source module so the
    // route→chunk mapping is derivable (import("./views/Heavy") → Heavy-<hash>.js).
    naming: { entry: "[name].[ext]", chunk: "[name]-[hash].[ext]", asset: "[name]-[hash].[ext]" },
    metafile: true,
    plugins: [
      // The site's `resolve` override map — see bundleIsland.
      resolveOverridePlugin(effectiveResolveMap(site.config), site.baseDir),
      // `@z/site-data` from the config's `data` map — see bundleIsland.
      siteDataPlugin(site.config.data ?? {}, site.baseDir, contentFiles),
      // Keep react* EXTERNAL (=> one Preact via the import-map). Unconditional.
      reactAliasBuildPlugin(),
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

  mkdirSync(args.outdir, { recursive: true });
  const chunks: string[] = [];
  let entryWritten = false;
  // Match each `.map` to its JS by name (`X.js.map` ↔ `X.js`). Bun's `.sourcemap`
  // back-reference is unreliable here (it points at the next output), so the
  // name is the sole robust link. Keyed by Bun's own JS basename.
  const mapByJs = new Map<string, (typeof res.outputs)[number]>();
  if (args.sourcemap) {
    for (const o of res.outputs) {
      if (o.kind === "sourcemap") mapByJs.set(basename(o.path).slice(0, -".map".length), o);
    }
  }
  for (const o of res.outputs) {
    if (o.kind === "sourcemap") continue; // written below alongside its JS
    // The entry is served under `entryName`; chunks keep Bun's hashed name.
    const name = o.kind === "entry-point" ? args.entryName : basename(o.path);
    let text = await o.text();
    const map = mapByJs.get(basename(o.path));
    if (map) {
      // Retarget the entry's comment to its SERVED map name (chunks already
      // match their own name, so this is a no-op for them) and write the map.
      const mapName = name + ".map";
      text = retargetSourceMappingUrl(text, mapName);
      await Bun.write(join(args.outdir, mapName), await map.text());
    }
    await Bun.write(join(args.outdir, name), text);
    if (o.kind === "entry-point") entryWritten = true;
    else chunks.push(name);
  }
  if (!entryWritten) {
    console.error("bundle-spa: no entry-point output produced");
    process.exit(1);
  }

  const routeChunks = await mapRouteChunks(args.entry, chunks);
  await Bun.write(args.chunksJson, JSON.stringify({ entry: args.entryName, chunks, routeChunks }));

  // Depfile: same union as the single-outfile path so Zig tracks the full
  // transitive TS closure (onLoad capture + metafile inputs + entry/tsconfig/stamp).
  const root = process.cwd();
  const fromPlugin = [...captured].map((p) => resolve(root, p));
  const fromMeta = res.metafile ? Object.keys(res.metafile.inputs).map((p) => resolve(root, p)) : [];
  const extra = [
    resolve(args.entry),
    ...findTsconfig(resolve(args.entry)),
    ...(args.runtimeStamp ? [resolve(args.runtimeStamp)] : []),
    ...(site.path ? [site.path] : []), // config edits invalidate the bundle
    ...contentFiles, // @z/site-data content edits invalidate the bundle
  ];
  const deps = [...new Set([...fromPlugin, ...fromMeta, ...extra])];
  await Bun.write(args.depfile, makeDepfile(resolve(args.chunksJson), deps));
}

if (import.meta.main) {
  const get = (k: string) => {
    const a = process.argv.find((x) => x.startsWith(`--${k}=`));
    return a ? a.slice(k.length + 3) : undefined;
  };
  const all = (k: string) =>
    process.argv.filter((x) => x.startsWith(`--${k}=`)).map((x) => x.slice(k.length + 3));
  const entry = get("entry"), depfile = get("depfile");
  const outdir = get("outdir");
  if (outdir) {
    // Code-splitting mode (SPAs): write entry + chunks into `outdir`.
    const entryName = get("entry-name"), chunksJson = get("chunks-json");
    if (!entry || !entryName || !chunksJson || !depfile) {
      console.error("bundle-spa: --entry, --entry-name, --outdir, --chunks-json, --depfile required");
      process.exit(1);
    }
    await bundleSpa({
      entry, entryName, outdir, chunksJson, depfile,
      external: all("external"),
      minify: process.argv.includes("--minify"),
      sourcemap: process.argv.includes("--sourcemap"),
      runtimeStamp: get("runtime-stamp"),
      configPath: get("config"),
    });
  } else {
    // Single-outfile mode (runtime + islands): unchanged.
    const outfile = get("outfile");
    if (!entry || !outfile || !depfile) {
      console.error("bundle-island: --entry, --outfile, --depfile required");
      process.exit(1);
    }
    await bundleIsland({
      entry,
      outfile,
      depfile,
      external: all("external"),
      minify: process.argv.includes("--minify"),
      sourcemap: process.argv.includes("--sourcemap"),
      hot: process.argv.includes("--hot"),
      mapfile: get("mapfile"),
      runtimeStamp: get("runtime-stamp"),
      configPath: get("config"),
    });
  }
}
