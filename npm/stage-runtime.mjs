#!/usr/bin/env node
// Stage the `@z/runtime` tree — the Bun sidecar, the bundlers, the slicers and
// the runtime sources — into a destination directory.
//
//   import { stageRuntime } from "./stage-runtime.mjs"   // npm/publish.mjs
//   node npm/stage-runtime.mjs <dest>                    // scripts/pack-runtime.sh
//
// TWO CONSUMERS, ONE COPY OF THE RULES. `@zigapagos/cli` stages this tree into
// itself at publish time, and the release's `runtime.tar.xz` asset — what the
// curl installer unpacks — stages the same tree. Both exist so an install that
// is not a git checkout can SSR and bundle islands, and they must contain the
// same files: a user who installed with the shell script and one who installed
// from npm hitting different sidecar behaviour is a bug report nobody can
// reproduce. Hence this module rather than a second list.
//
// What is excluded is excluded on purpose, not to save bytes:
//   - `test/`, `*.test.ts` — the bun-test suite and its fixtures. Those fixtures
//     import `react`, `@acme/greeting` and `my-store`, none of which are
//     dependencies of anything we ship; packing them would put unresolvable bare
//     imports inside the tarball and invite exactly the "why does this package
//     need React?" question, with no upside.
//   - `node_modules/` — the two consumers resolve it differently and neither
//     wants the checkout's copy. npm declares the dependencies and lets the
//     consumer's own install place them; the release asset vendors a freshly
//     resolved tree (see scripts/pack-runtime.sh).
// `src/testing/` IS shipped, though nothing reaches it at build time: it is a
// target of runtime/package.json's `exports` map, and that map is load-bearing
// here — the sidecar resolves `@z/runtime` through package SELF-REFERENCE, which
// requires the shipped subtree to keep its package.json intact and its export
// targets present.
import { cpSync, existsSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** The top-level entries of `runtime/` that get staged. */
export const RUNTIME_ENTRIES = ["package.json", "src", "sidecar", "scripts"];

// The files the binary is pointed at BY NAME (npm/cli/bin/zigapagos.js ->
// ZIGAPAGOS_RUNTIME_DIR -> src/cli/release.zig's runtimeDefaults). A copy that
// silently missed one would ship a tree whose islands fail at spawn, or whose
// SPA build dies in the bundler, so assert them here rather than discover it in
// a consumer's build log. Keep this list in lockstep with `runtimeDefaults` —
// every path it joins is one row here.
export const RUNTIME_REQUIRED = [
  "sidecar/standalone.ts",
  "sidecar/bundle-island.ts",
  "src/browser-entry.ts",
  "sidecar/bundle-standalone.ts",
  "scripts/build-spa-runtime.ts",
  "src/spa-entry.ts",
  "src/host.ts",
  "src/ssr-env.ts",
];

/**
 * Copy `<repoRoot>/runtime` into `dest`, applying the exclusions above, then
 * assert every path in RUNTIME_REQUIRED arrived.
 *
 * Self-freeing in the filesystem sense: `dest` is removed first, so a stale file
 * from an earlier staging cannot survive into the result. Callers pass a
 * directory they own.
 *
 * @param {string} repoRoot absolute path to the repository root
 * @param {string} dest absolute path to stage into; replaced if it exists
 * @returns {string} `dest`
 */
export function stageRuntime(repoRoot, dest) {
  const src = join(repoRoot, "runtime");
  rmSync(dest, { recursive: true, force: true });
  for (const entry of RUNTIME_ENTRIES) {
    cpSync(join(src, entry), join(dest, entry), {
      recursive: true,
      filter: (from) => {
        const rel = from.slice(src.length + 1);
        if (rel.endsWith(".test.ts")) return false;
        return !rel.split(/[\\/]/).includes("node_modules");
      },
    });
  }
  for (const rel of RUNTIME_REQUIRED) {
    if (!existsSync(join(dest, rel))) {
      throw new Error(`stage-runtime: runtime/${rel} did not make it into the staged tree`);
    }
  }
  return dest;
}

// CLI entry: `node npm/stage-runtime.mjs <dest>`. Exists so scripts/pack-runtime.sh
// can reuse this without reimplementing the filter in shell, where the
// `.test.ts`/`node_modules` exclusions would be a `tar --exclude` list that looks
// equivalent and is not.
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  const dest = process.argv[2];
  if (!dest) {
    console.error("usage: node npm/stage-runtime.mjs <dest>");
    process.exit(2);
  }
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  stageRuntime(repoRoot, resolve(dest));
}
