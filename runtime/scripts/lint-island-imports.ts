import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { EMPTY_CONFIG, loadConfig, type ZRuntimeConfig } from "./z-runtime-config.ts";

// Base allowlist: islands may always import the runtime and relative paths.
// (Web-platform features like fetch/document are runtime GLOBALS, not import
// specifiers, so there is nothing to allowlist for them.) A project extends this
// via z-runtime.config.json: `islandImports.firstParty` (extra allowed scopes,
// e.g. a shared app package) and `islandImports.npmCompat` (opt-in npm packages
// bundled with react -> @z/runtime/compat). Both are matched as a package name
// plus its subpaths — same shape as the base @z/runtime rule.
const BASE_ALLOW = [/^@z\/runtime(\/.*)?$/, /^\.\.?\//];
// Static `import … from "x"` / `export … from "x"` / `import "x"`, plus dynamic
// `import("x")` — the latter needs its own pattern because `import(` has no
// whitespace after `import` (the static regex requires one).
const IMPORT_RE = /(?:import|export)\s+(?:[^'"]*?\sfrom\s+)?["']([^"']+)["']/g;
const DYNAMIC_RE = /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g;

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Build the allow-regex list for a config: base + firstParty + npmCompat (pkg + subpaths)
 *  + `resolve` override keys (EXACT specifier only — resolution is exact-match)
 *  + `@z/site-data` iff the config declares a `data` map. */
export function buildAllow(config: ZRuntimeConfig): RegExp[] {
  const specToRe = (s: string) => new RegExp("^" + escapeRegExp(s) + "(\\/.*)?$");
  const exactRe = (s: string) => new RegExp("^" + escapeRegExp(s) + "$");
  return [
    ...BASE_ALLOW,
    ...config.islandImports.firstParty.map(specToRe),
    ...config.islandImports.npmCompat.map(specToRe),
    ...Object.keys(config.resolve ?? {}).map(exactRe),
    ...(Object.keys(config.data ?? {}).length > 0 ? [/^@z\/site-data$/] : []),
  ];
}

export function lintIslandImports(
  files: string[],
  config: ZRuntimeConfig = EMPTY_CONFIG,
): { file: string; spec: string }[] {
  const allow = buildAllow(config);
  const out: { file: string; spec: string }[] = [];
  for (const file of files) {
    const src = readFileSync(file, "utf8");
    for (const re of [IMPORT_RE, DYNAMIC_RE]) {
      for (const m of src.matchAll(re)) {
        const spec = m[1];
        if (!allow.some((a) => a.test(spec))) out.push({ file, spec });
      }
    }
  }
  return out;
}

// CLI entry: `bun scripts/lint-island-imports.ts [--config <path>] <glob...>`
// Config is taken from --config, else auto-discovered by walking up from the
// first linted file's directory (z-runtime.config.json).
if (import.meta.main) {
  const argv = process.argv.slice(2);
  let configPath: string | undefined;
  const files: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--config") { configPath = argv[++i]; continue; }
    if (argv[i].startsWith("--config=")) { configPath = argv[i].slice("--config=".length); continue; }
    files.push(argv[i]);
  }
  const startDir = files.length ? dirname(resolve(files[0])) : process.cwd();
  const { config } = loadConfig({ configPath, startDir });
  const violations = lintIslandImports(files, config);
  if (violations.length) {
    for (const v of violations) console.error(`forbidden import in ${v.file}: ${v.spec}`);
    process.exit(1);
  }
}
