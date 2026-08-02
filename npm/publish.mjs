#!/usr/bin/env node
// Assemble, verify, and (only when asked) pack or publish the three npm packages.
//
//   node npm/publish.mjs [--archives <dir>] [--pack <dir>] [--publish] [--provenance]
//
// The pipeline is always the same and always runs: generate the manifests, place
// the platform binaries, verify. What happens after that is opt-in:
//
//   (nothing)      stop after verifying. Safe to run anywhere; touches no registry.
//   --pack <dir>   `npm pack` all three into <dir>. Local; this is what CI's smoke
//                  job and tests/npm/packaging.sh use.
//   --publish      upload for real, in dependency order.
//
// PUBLISHING IS OPT-IN BY DESIGN. `node npm/publish.mjs` with no flags cannot
// reach the registry, so neither a mistyped command nor an automated agent
// running "the publish script" can ship a release. The workflow that does publish
// is additionally gated on a repository variable, and authenticates with npm OIDC
// trusted publishing rather than a stored token — see npm/README.md.
//
// `--archives <dir>` extracts the binaries out of the release workflow's own
// artifacts (the archives named in `cli/targets.json`) rather than building
// anything. That is deliberate: the bytes on npm must be the bytes in the GitHub
// release, and a rebuild — even from the same commit — is a second chance to be
// different.
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { genPackages, toolchainDeps, versionFromBuildZon } from "./gen-packages.mjs";
import { stageRuntime } from "./stage-runtime.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..");

function flagValue(name) {
  const i = process.argv.indexOf(name);
  if (i < 0) return null;
  const v = process.argv[i + 1];
  if (!v || v.startsWith("--")) throw new Error(`publish: ${name} needs a directory argument`);
  return resolve(v);
}
const ARCHIVES = flagValue("--archives");
const PACK_DIR = flagValue("--pack");
const PUBLISH = process.argv.includes("--publish");
const PROVENANCE = process.argv.includes("--provenance");

const targets = JSON.parse(readFileSync(join(HERE, "cli", "targets.json"), "utf8"));
const version = versionFromBuildZon(REPO_ROOT);

// Dependency order, and it is not cosmetic: npm resolves a dependency at install
// time, so @zigapagos/cli is installable only once its optional platform packages
// exist, and the `zigapagos` alias only once @zigapagos/cli does. Publishing the
// other way round leaves a window in which the registry serves a package that
// cannot be installed.
const PLATFORM_DIRS = targets.map((t) => `cli-${t.key}`);
const ORDER = [...PLATFORM_DIRS, "cli", "zigapagos"];

console.log(`version ${version} (from build.zig.zon)`);

// --- 1. Manifests -----------------------------------------------------------
genPackages({ version, targets, npmDir: HERE, ...toolchainDeps(REPO_ROOT) });
console.log(`generated manifests for ${ORDER.length} packages`);

// --- 1b. The runtime tree ---------------------------------------------------
// `@zigapagos/cli` ships the @z/runtime sources and the Bun sidecar so an
// npm-only install can SSR and bundle islands. They are STAGED here rather than
// committed under npm/, for the same reason the manifests are generated: a
// second copy in the tree is a copy that can drift from the runtime/ the test
// suite actually exercises.
//
// The rules — which entries, which exclusions, which files must survive — live in
// stage-runtime.mjs, because the release's `runtime.tar.xz` asset stages the same
// tree for the curl installer. The two channels must ship identical trees, and
// two lists that have to agree eventually do not.
stageRuntime(REPO_ROOT, join(HERE, "cli", "runtime"));
console.log(`staged runtime/ -> cli/runtime (sources for the Bun sidecar and island bundler)`);

// --- 2. Binaries ------------------------------------------------------------
// One binary per platform package, extracted from the release archive of the
// same name. `tar`/`unzip` rather than a JS decompressor: both are present on
// every runner and on any machine that can cut a release, and this avoids adding
// a dependency to a directory that otherwise has none.
function extract(archivePath, destDir) {
  if (archivePath.endsWith(".zip")) {
    // -j: flatten, -o: overwrite. The archive holds exactly `zigapagos`.
    execFileSync("unzip", ["-q", "-o", "-j", archivePath, "zigapagos", "-d", destDir], {
      stdio: "inherit",
    });
  } else if (archivePath.endsWith(".tar.xz")) {
    execFileSync("tar", ["-xJf", archivePath, "-C", destDir, "zigapagos"], { stdio: "inherit" });
  } else {
    throw new Error(`publish: unknown archive format: ${archivePath}`);
  }
}

if (ARCHIVES) {
  for (const t of targets) {
    const archive = join(ARCHIVES, t.archive);
    if (!existsSync(archive)) {
      throw new Error(
        `publish: ${t.archive} not found in ${ARCHIVES} — the release workflow uploads it as ` +
          `artifact release-${t.zig}; check that job succeeded`,
      );
    }
    const dir = join(HERE, `cli-${t.key}`);
    mkdirSync(dir, { recursive: true });
    extract(archive, dir);
    // The exec bit survives npm pack but not every archive/download path, and a
    // non-executable binary fails at spawn with a message about the launcher.
    chmodSync(join(dir, "zigapagos"), 0o755);
    console.log(`extracted ${t.archive} -> cli-${t.key}/zigapagos`);
  }
}

// --- 3. Verify --------------------------------------------------------------
// Everything below would otherwise be discovered by a user, after publishing.
const readPkg = (dir) => JSON.parse(readFileSync(join(HERE, dir, "package.json"), "utf8"));
const problems = [];

for (const dir of ORDER) {
  const pkg = readPkg(dir);
  if (pkg.version !== version) {
    problems.push(`${pkg.name}: version ${pkg.version} != build.zig.zon ${version}`);
  }
}

const cli = readPkg("cli");
for (const t of targets) {
  const name = `@zigapagos/cli-${t.key}`;
  if (cli.optionalDependencies?.[name] !== version) {
    problems.push(
      `@zigapagos/cli: optionalDependencies['${name}'] is ` +
        `'${cli.optionalDependencies?.[name]}', expected '${version}'`,
    );
  }
}
const alias = readPkg("zigapagos");
if (alias.dependencies?.["@zigapagos/cli"] !== version) {
  problems.push(
    `zigapagos (alias): dependencies['@zigapagos/cli'] is ` +
      `'${alias.dependencies?.["@zigapagos/cli"]}', expected the exact version '${version}'`,
  );
}

for (const t of targets) {
  const bin = join(HERE, `cli-${t.key}`, "zigapagos");
  if (!existsSync(bin)) {
    problems.push(
      `cli-${t.key}/zigapagos is missing — pass --archives <dir> with the release archives, ` +
        `or drop the binary in by hand`,
    );
    continue;
  }
  const st = statSync(bin);
  if (st.size === 0) problems.push(`cli-${t.key}/zigapagos is empty`);
  if (!(st.mode & 0o111)) problems.push(`cli-${t.key}/zigapagos is not executable`);
}

if (problems.length > 0) {
  console.error("FAIL: package tree is not publishable:");
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("verified: versions pinned, binaries present and executable");

// --- 4. Pack / publish ------------------------------------------------------
if (PACK_DIR) {
  mkdirSync(PACK_DIR, { recursive: true });
  for (const dir of ORDER) {
    execFileSync("npm", ["pack", "--pack-destination", PACK_DIR], {
      cwd: join(HERE, dir),
      stdio: "inherit",
    });
  }
  console.log(`packed ${ORDER.length} tarballs into ${PACK_DIR}`);
}

if (PUBLISH) {
  // Idempotent: a partially failed release can be re-run. `npm view` on a
  // version that does not exist exits non-zero, which is the "publish it" case;
  // a network failure lands there too, and then the publish itself fails, which
  // is the correct place for that error to surface.
  const alreadyPublished = (name, v) => {
    const r = spawnSync("npm", ["view", `${name}@${v}`, "version"], {
      encoding: "utf8",
      timeout: 30_000,
    });
    return r.status === 0 && r.stdout.trim() === v;
  };
  for (const dir of ORDER) {
    const pkg = readPkg(dir);
    if (alreadyPublished(pkg.name, version)) {
      console.log(`skip ${pkg.name}@${version} (already on the registry)`);
      continue;
    }
    // `--access public` is also in each generated package.json's publishConfig;
    // passed here as well because the FIRST publish of a scoped package defaults
    // to restricted, and that failure is confusing after the fact.
    const flags = ["publish", "--access", "public"];
    if (PROVENANCE) flags.push("--provenance");
    console.log(`publish ${pkg.name}@${version}`);
    execFileSync("npm", flags, { cwd: join(HERE, dir), stdio: "inherit" });
  }
  console.log("published");
} else if (!PACK_DIR) {
  console.log("no --pack or --publish given: assembled and verified only, nothing was uploaded");
}
