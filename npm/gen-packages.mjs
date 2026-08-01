#!/usr/bin/env node
// Generate the three npm package shapes from ONE version (build.zig.zon) and ONE
// target list (cli/targets.json):
//
//   @zigapagos/cli-<key>   one per release target, carrying just the binary.
//   @zigapagos/cli         the resolver + `zigapagos` bin, optionalDependencies
//                          pinned to the exact version of every platform package.
//   zigapagos              a bare-name ALIAS depending on @zigapagos/cli at the
//                          same exact version and re-exposing its bin.
//
// Only this script, cli/targets.json, cli/index.js, cli/bin/ and zigapagos/bin/
// are committed; every package.json and README.md below is generated and
// gitignored. Adding a platform is one entry in cli/targets.json — and that
// entry is gated against build/release.zig by check-targets.mjs, so it cannot
// name a target the release does not build.
//
// The three versions are written from a single `version` argument on purpose: a
// skew between the alias and the package it aliases installs a `zigapagos` that
// pulls a DIFFERENT @zigapagos/cli than the one that was tested with it.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

const REPO = { type: "git", url: "git+https://github.com/valthon/zigapagos.git" };
const HOMEPAGE = "https://github.com/valthon/zigapagos";
const BUGS = "https://github.com/valthon/zigapagos/issues";
const LICENSE = "MIT";
const KEYWORDS = ["static-site-generator", "ssg", "zig", "islands", "spa", "bun", "tsx"];

const OS_LABEL = { linux: "Linux", darwin: "macOS", win32: "Windows" };

// Named in the published README because the LICENSE retains the upstream project's
// copyright and this is a permanent fork of it — a package page that hides where the
// Zig core came from would be the inaccurate version. Hoisted into a constant so the
// line can carry the marker tests/branding.sh requires; interpolated below.
const UPSTREAM_ATTRIBUTION = "forked from [Zine](https://zine-ssg.io)"; // branding-ok: attribution to the upstream project this is a fork of, as in README.md's Acknowledgements

// Hosts worth naming in the platform table even though they have no package of
// their own — a table that lists only what works reads as an oversight on the
// host you are standing on. Each row is dropped automatically once its key
// appears in targets.json, so adding a native build cannot leave a stale "not
// supported" row behind.
//
// Both aarch64 rows carry the SAME note, because both hosts get the same
// treatment: no package, and the resolver in cli/index.js refuses them by name
// with the reason. There is no cross-architecture substitution for either.
const AARCH64_NOTE = "not supported yet — no aarch64 release build";
const FALLBACK_ROWS = [
  { key: "darwin-arm64", label: "macOS arm64 (Apple Silicon)", note: AARCH64_NOTE },
  { key: "linux-arm64", label: "Linux arm64", note: AARCH64_NOTE },
  { key: "win32-x64", label: "Windows x64", note: "not supported yet — use WSL2" },
];

function writeJson(path, obj) {
  writeFileSync(path, JSON.stringify(obj, null, 2) + "\n");
}

/** Read the released version from build.zig.zon — the single source of truth. */
export function versionFromBuildZon(repoRoot) {
  const zon = readFileSync(join(repoRoot, "build.zig.zon"), "utf8");
  // First match only: the package's own `.version` is declared above
  // `.dependencies`, whose entries may carry their own. Same reasoning as
  // scripts/assert-version.sh's `head -1`.
  const m = zon.match(/^\s*\.version\s*=\s*"([^"]+)"/m);
  if (!m) throw new Error("gen-packages: could not read .version from build.zig.zon");
  return m[1];
}

// --- Dependency ranges, DERIVED rather than restated ------------------------
//
// Every range below is read out of the file that already owns that number, so
// there is no second copy to drift. That is the whole design: a hand-written
// `"@zigbase/server": "0.12.0"` in this file would be correct exactly until
// someone bumped `pinned_version` in the Zig source and not here, at which point
// `zigapagos dev` would resolve one zigbase from npm and download a DIFFERENT one
// into the cache — the same tool at two versions depending on how the user
// installed it, which is the failure this whole seam exists to prevent.
//
// check-toolchain.mjs re-derives each of these and asserts the GENERATED manifest
// still carries it, so a future refactor that reintroduces a literal is caught.

/**
 * The runtime sources' own npm dependencies, from `runtime/package.json`.
 *
 * `@zigapagos/cli` ships `runtime/src` and `runtime/sidecar` (see `files`
 * below), and those files import `preact` and `preact-render-to-string` by bare
 * name. Whatever range the runtime package was tested against is therefore the
 * range the CLI package must declare — copying the list by hand would let the
 * shipped sources meet a major version they were never built against.
 */
export function runtimeDepsFromPackageJson(repoRoot) {
  const pkg = JSON.parse(readFileSync(join(repoRoot, "runtime", "package.json"), "utf8"));
  const deps = pkg.dependencies ?? {};
  // Anti-vacuity: an empty map here would silently publish a CLI whose bundled
  // runtime cannot resolve Preact, and this function would report success.
  if (Object.keys(deps).length === 0) {
    throw new Error(
      "gen-packages: runtime/package.json declares no dependencies — either the field " +
        "moved or the runtime lost Preact; this gate is now checking nothing",
    );
  }
  return { ...deps };
}

/**
 * The zigbase range, from `pinned_version` in `src/cli/zigbase.zig`.
 *
 * WHICH PACKAGE, AND WHY IT IS THE SCOPED ONE. zigbase is on npm twice: the bare
 * `zigbase` alias, published once and therefore only ever `0.12.0`, and
 * `@zigbase/server`, which carries the full history back to `0.4.0`. Only the
 * scoped package can follow a pin at all. That the alias happens to equal the
 * current pin (`v0.12.0`) makes it MORE dangerous, not less: it resolves today,
 * so nothing complains, and the next bump leaves the npm path installing 0.12.0
 * while the download fallback fetches the new pin — one zigapagos running two
 * different zigbases depending on how it was installed. Worse, this lands in
 * `optionalDependencies` (see genPackages), where npm SKIPS a range it cannot
 * resolve without failing the install, so the alias's failure mode is silence
 * either way. check-toolchain.mjs rejects the alias by name for that reason.
 *
 * Exact, not a caret range, for the same reason the platform packages are exact:
 * the pin names the one build this harness was verified against, and `^0.12.0`
 * would let npm install a zigbase the download path would never produce.
 */
export function zigbaseDepFromZig(repoRoot) {
  const src = readFileSync(join(repoRoot, "src", "cli", "zigbase.zig"), "utf8");
  const m = src.match(/^\s*pub const pinned_version\s*=\s*"v?([0-9]+\.[0-9]+\.[0-9]+)"/m);
  if (!m) {
    throw new Error(
      "gen-packages: could not read `pinned_version` from src/cli/zigbase.zig — the " +
        "declaration moved or was renamed, and this gate is now checking nothing",
    );
  }
  return { "@zigbase/server": m[1] };
}

/**
 * The bun range, from the `mise.toml` pin.
 *
 * CLAUDE.md makes mise.toml the single source of truth for the toolchain and
 * forbids a second pin beside it; this reads that one rather than adding one.
 * A caret, unlike the two above: mise pins the version this repo DEVELOPS on,
 * and a consumer wants "that minor or newer, same major" — bun is the tool the
 * sidecar is executed by, not an artifact whose bytes have to match.
 */
export function bunDepFromMise(repoRoot) {
  const toml = readFileSync(join(repoRoot, "mise.toml"), "utf8");
  const m = toml.match(/^\s*bun\s*=\s*"([0-9]+(?:\.[0-9]+)*)"/m);
  if (!m) {
    throw new Error(
      "gen-packages: could not read the bun pin from mise.toml — the [tools] entry " +
        "moved or was renamed, and this gate is now checking nothing",
    );
  }
  return { bun: `^${m[1]}` };
}

/**
 * The typescript range, from `runtime/package.json`'s DEV dependencies.
 *
 * WHY IT IS SHIPPED AT ALL, AND WHY OPTIONAL. Two shipped scripts parse source
 * with the TS compiler API: `scripts/slice-host.ts` (the per-SPA runtime slicer)
 * and `sidecar/hot-transform.ts` (dev fast refresh). Both already degrade
 * gracefully when it cannot be loaded — the slicer falls back to the shared
 * runtime, the transform to a full remount — so this is an optimization the
 * package should HAVE by default and must not REQUIRE. `optionalDependencies` is
 * exactly that: installed unless asked otherwise, and `--omit=optional` still
 * leaves a working build.
 *
 * The range is read rather than written because the `^6` cap is load-bearing:
 * typescript 7.0 is the Go rewrite and dropped the JavaScript compiler API, so
 * `ts.createSourceFile` and friends simply do not exist there. slice-host.ts and
 * hot-transform.ts both carry that note, .github/dependabot.yml enforces the cap,
 * and a literal here would be a fourth place for it to drift out of agreement.
 */
export function typescriptDepFromPackageJson(repoRoot) {
  const pkg = JSON.parse(readFileSync(join(repoRoot, "runtime", "package.json"), "utf8"));
  const range = (pkg.devDependencies ?? {}).typescript;
  if (!range) {
    throw new Error(
      "gen-packages: runtime/package.json declares no `typescript` devDependency — the " +
        "field moved or the slicer stopped needing it, and this gate is now checking nothing",
    );
  }
  return { typescript: range };
}

/** Every derived range, in the two fields they belong in. See genPackages. */
export function toolchainDeps(repoRoot) {
  return {
    dependencies: runtimeDepsFromPackageJson(repoRoot),
    optionalTools: {
      ...bunDepFromMise(repoRoot),
      ...zigbaseDepFromZig(repoRoot),
      ...typescriptDepFromPackageJson(repoRoot),
    },
  };
}

function platformLabel(t) {
  return `${OS_LABEL[t.os] ?? t.os} ${t.cpu}`;
}

/**
 * The `os`/`cpu` the two launcher packages accept: the union of what the platform
 * packages carry.
 *
 * WHY THE LAUNCHERS DECLARE THEM AT ALL. Without these, `npm install
 * @zigapagos/cli` on an arm64 host SUCCEEDS. Every platform package is skipped by
 * its own `os`/`cpu`, and an optionalDependency npm declines to install is not an
 * error — so the install looks clean and contains no binary, and its first failure
 * is at build time in someone else's log. Declaring them moves the refusal to
 * `npm install` itself (`EBADPLATFORM`, naming wanted vs. current), which is the
 * earliest point at which it can be reported; the platform table above says why
 * the host is missing, and `npm install --force` remains a deliberate override for
 * anyone who wants the unusable tree anyway.
 *
 * A cross product, so it is exact only while every target shares one cpu. The
 * imprecision can only ADMIT an unsupported host — which then gets the resolver's
 * own named error — never reject a supported one, so `cli/index.js` stays the
 * authority and this is the cheap early half of the same refusal.
 */
function launcherPlatform(targets) {
  return {
    os: [...new Set(targets.map((t) => t.os))].sort(),
    cpu: [...new Set(targets.map((t) => t.cpu))].sort(),
  };
}

/** The published platform table, generated so it cannot disagree with targets.json. */
function platformTable(targets) {
  const have = new Set(targets.map((t) => t.key));
  const rows = targets.map(
    (t) => `| ${platformLabel(t)} | \`@zigapagos/cli-${t.key}\` | native |`,
  );
  for (const f of FALLBACK_ROWS) {
    if (have.has(f.key)) continue;
    rows.push(`| ${f.label} | — | ${f.note} |`);
  }
  return ["| Host | Package | Status |", "| --- | --- | --- |", ...rows].join("\n");
}

// Both published READMEs carry this verbatim. It is the least optional part of
// either, because it is the answer to "what do I actually get" — and an earlier
// revision of it got that answer WRONG in a way worth recording, since the same
// mistake is easy to make again.
//
// That revision said an npm install cannot build islands, on the reasoning that
// the sidecar script and the `@z/runtime` sources "are handed to the binary by the
// Zig build integration" and that `@z/runtime` is unpublished. Both halves are
// true and the conclusion does not follow. `--island-sidecar=` and
// `--island-src-dir=` are ordinary RUNTIME flags (src/cli/release.zig), not
// build-time-only wiring, so anything that can put those files on disk and name
// them can build an island; and `private: true` governs publishing `@z/runtime`
// as its own package for consumers to import, not whether OUR package may ship
// the same sources inside itself. What was really being described was a
// packaging choice — we shipped one file — written up as though it were a
// property of the design.
//
// So the package now ships `runtime/` and declares the deps those sources need,
// the launcher points the binary at them, and islands/SPAs work. See
// `files`/`dependencies` below and npm/cli/bin/zigapagos.js.
const REQUIREMENTS = `## Requirements

- **Node.js >= 18** — runs the launcher; the binary itself is native.
- One of the platforms in the table above.

Nothing else. No Zig toolchain, no separately-installed Bun, no \`build.zig\`.

## What this package can build

Everything, from \`npm i zigapagos\` alone:

- the whole **content** pipeline — \`init\`, \`migrate\` (the Astro importer),
  \`doctor\`, \`validate\`, \`explain\` and \`release\`;
- **islands** (\`.island.tsx\`) — server-rendered through the bundled Bun sidecar
  and hydrated in the browser from a client bundle built by the same Bun;
- **native SPAs** (\`.spa.tsx\`) — prerendered route skeletons plus a code-split
  client bundle, including lazy routes, per-route \`modulepreload\` and the
  per-deployable runtime slice;
- **\`zigapagos dev\`** — the watch/rebuild loop, served by zigbase.

To make that true the package carries three things beyond the binary: the
\`@z/runtime\` sources and the Bun build tools (in \`runtime/\`), and dependencies on
\`bun\`, \`@zigbase/server\` and \`typescript\` so the tools it shells out to are
installed rather than asked for. The last three are OPTIONAL dependencies:
\`--omit=optional\` still builds, it just loses \`dev\`'s server, and the SPA runtime
slicer falls back to the shared runtime.

The remaining differences from a Zig build are about CACHING, not capability.
\`build.zig\` drives Bun through the build graph, so a depfile lets Zig skip an
unchanged bundle; here every \`release\` rebundles from scratch. And the per-SITE
islands runtime slice (which needs a second pass over the built bundles) is not
computed, so island pages load the full shared \`/zigapagos-runtime.js\` instead of
a trimmed one — the documented no-slice default. SPAs still get their own
per-deployable slice.

### The size, and where it goes

\`npm i zigapagos\` is **~535 MB** installed on linux-x64. Measured, not estimated:

| Component | Installed | Why |
| --- | --- | --- |
| \`@oven/bun-*\` + \`bun\` | ~347 MB | the Bun binary — SSR and client bundling |
| \`@zigapagos/cli-<platform>\` | ~156 MB | the zigapagos binary |
| \`typescript\` | ~24 MB | the compiler API the SPA runtime slicer parses with |
| \`@zigbase/server-<platform>\` | ~4.8 MB | the server \`dev\` runs |
| \`preact\` + \`preact-render-to-string\` | ~3.1 MB | imported by the bundled runtime |
| \`@zigapagos/cli\` (launcher + \`runtime/\`) | ~0.7 MB | the sidecar and \`@z/runtime\` sources |

Two thirds of that is Bun, and most of Bun's share is npm over-fetching rather
than Bun itself: the \`@oven/bun-linux-x64*\` packages declare no \`libc\`, so on a
linux-x64 host npm installs the glibc, musl, baseline and musl-baseline builds —
four ~87 MB binaries where one is used. That is upstream packaging, not something
this package can select around.

**There is no smaller supported install.** \`--omit=optional\` does not give you a
lean content-only CLI: the per-platform \`@zigapagos/cli-<platform>\` package is
itself an optional dependency (that is how one binary is fetched instead of all
of them), so omitting optional dependencies removes the zigapagos binary too and
leaves an install that cannot run at all — \`binaryPath()\` says exactly that if
you try. If you need a build-only footprint, use the
[release archives](${HOMEPAGE}/releases) rather than npm.

### Building a site with islands

Nothing special:

\`\`\`bash
npm i zigapagos
npx zigapagos init
npx zigapagos release --output=public --force
\`\`\`

The build finds your \`*.island.tsx\` entries by scanning the site root, so there is
no list to keep up to date — under a Zig build \`build.zig\` enumerates them at
configure time, and this is the toolchain-free equivalent. \`--island=SRC\`
(repeatable) still overrides the scan when you want an exact set.

That scan is not a convenience. The two halves of an island come from different
places — the SSR'd markup from the Bun sidecar, the client bundle from Bun — and
only the first is automatic. A page whose bundle was never built renders
perfectly and then 404s on hydration, with nothing wrong-looking in the output
tree, so the entries are discovered rather than left to be forgotten.

Your components import \`@z/runtime\` by its bare name exactly as they do under a
Zig build: the sidecar serves that specifier from the copy inside this package,
and on the client an import map points it at the one shared
\`/zigapagos-runtime.js\`, so the page still ends up with a single Preact instance.
See [docs/islands.md](${HOMEPAGE}/blob/main/docs/islands.md).

**One genuine gap:** \`--island-props-check\` (the \`tsc\` gate that typechecks island
props against their \`Props\` interface) is \`off\` by default here, where a Zig build
turns it on for you. Pass it yourself to opt in; the \`typescript\` this package
already installs is the one \`bun x tsc\` will find.

### Building a native SPA

Also nothing special. Write a \`*.spa.tsx\` exporting \`spa\` and \`routes\` and run
the same \`release\`: the scan that finds islands finds SPA entries too, and each
one's \`spa.base\` decides where it mounts. \`--spa=SRC|BASE\` (repeatable) overrides
the scan, and \`|BASE\` there is the restated base a Zig build checks against the
module — omit it and the module is simply believed.

Each SPA gets exactly what \`build.zig\` produces: prerendered route skeletons and
a \`_shell.html\` per dynamic pattern, a per-namespace \`routing-manifest.json\`, a
code-split client bundle under \`/spa/\` (one entry chunk plus one content-hashed
chunk per \`lazy(() => import(…))\`), a \`modulepreload\` for the chunk each route
needs, and the per-deployable runtime slice — \`/spa/<name>-runtime.js\` when the
slicer can prove which \`host.*\` members the SPA uses, the shared
\`/zigapagos-runtime.js\` when it cannot. \`@z/runtime\` stays external in every
bundle, so a page carrying both a SPA and islands still has one Preact.

See [docs/spa.md](${HOMEPAGE}/blob/main/docs/spa.md). The routing manifest is also
what the host-config emitters read, so deploying behind zigbase, nginx or Apache
works the same way it does under a Zig build.

### \`zigapagos dev\`

\`\`\`bash
npm pkg set scripts.dev="zigapagos dev --site=public"
npm run dev     # dev: zigbase = …/node_modules/.bin/zigbase (path_env)
\`\`\`

The [zigbase](https://github.com/valthon/zigbase) that \`dev\` serves through is
installed with this package, at the exact version the CLI pins — so the npm path
and the \`--download-zigbase\` fallback can never disagree. The launcher adds this
install's \`node_modules/.bin\` to the child's \`PATH\`, so a bare \`zigapagos dev\`
finds it too, not just \`npm run\` and \`npx\`.

A zigbase already on your \`PATH\` still wins, and \`--zigbase=PATH\` still overrides
both.
`;

/**
 * Write every generated package.json + README under `npmDir`.
 * @param {{version: string, targets: object[], npmDir: string,
 *          dependencies: object, optionalTools: object}} opts
 *   `dependencies` — what the shipped runtime/ sources import (Preact & co).
 *   `optionalTools` — the external binaries (`bun`, `@zigbase/server`), merged
 *   into optionalDependencies alongside the platform-resolution table.
 *   Both come from `toolchainDeps(repoRoot)`; they are parameters rather than
 *   read here so this stays a pure function of its inputs, like `targets`.
 * @returns {string[]} the paths written.
 */
export function genPackages({ version, targets, npmDir, dependencies, optionalTools }) {
  // Anti-vacuity: a generator handed an empty list would happily emit a meta
  // package with no platform packages at all, i.e. one that throws on every
  // host. Fail instead.
  if (!Array.isArray(targets) || targets.length === 0) {
    throw new Error("gen-packages: targets is empty — nothing to generate");
  }
  for (const t of targets) {
    for (const field of ["key", "zig", "os", "cpu", "archive"]) {
      if (!t[field]) throw new Error(`gen-packages: target ${t.key ?? "?"} is missing '${field}'`);
    }
  }
  // Same anti-vacuity reasoning as `targets`, checked after them so a malformed
  // target still reports itself first: generating a CLI package with no
  // dependencies is exactly what a broken derivation looks like, and it publishes
  // a tarball whose bundled runtime cannot resolve Preact and whose `dev` cannot
  // find a zigbase. Both maps are required, and both must be non-empty.
  for (const [name, map] of [
    ["dependencies", dependencies],
    ["optionalTools", optionalTools],
  ]) {
    if (!map || Object.keys(map).length === 0) {
      throw new Error(`gen-packages: ${name} is empty — nothing would be installed`);
    }
  }

  const written = [];
  const table = platformTable(targets);
  const platform = launcherPlatform(targets);

  // --- One package per platform: the binary and nothing else. -----------------
  for (const t of targets) {
    const dir = join(npmDir, `cli-${t.key}`);
    mkdirSync(dir, { recursive: true });
    const pkgPath = join(dir, "package.json");
    writeJson(pkgPath, {
      name: `@zigapagos/cli-${t.key}`,
      version,
      description: `Zigapagos prebuilt binary for ${t.key} (${t.zig}).`,
      // `os`/`cpu` make npm skip this package on a host it cannot run, which is
      // what turns the optionalDependencies list in @zigapagos/cli into
      // "download exactly one binary" rather than all of them.
      os: [t.os],
      cpu: [t.cpu],
      files: ["zigapagos", "README.md"],
      publishConfig: { access: "public" },
      repository: REPO,
      license: LICENSE,
    });
    const readmePath = join(dir, "README.md");
    writeFileSync(
      readmePath,
      `# @zigapagos/cli-${t.key}\n\n` +
        `The \`zigapagos\` binary for ${platformLabel(t)} (\`${t.zig}\`), built by the\n` +
        `[zigapagos](${HOMEPAGE}) release workflow.\n\n` +
        `Installed automatically as an optional dependency of\n` +
        `[\`@zigapagos/cli\`](https://www.npmjs.com/package/@zigapagos/cli) — depend on that,\n` +
        `not on this.\n`,
    );
    written.push(pkgPath, readmePath);
  }

  // --- The real package: resolver + bin + runtime + dependencies. -------------
  const cliDir = join(npmDir, "cli");
  mkdirSync(cliDir, { recursive: true });
  // `optionalDependencies` carries TWO kinds of entry, and the difference is
  // worth keeping straight because only the first kind is gated by
  // check-targets.mjs:
  //
  //   1. The PLATFORM-RESOLUTION TABLE — one `@zigapagos/cli-<key>` per release
  //      target, derived from targets.json, gated against build/release.zig, and
  //      verified entry-by-entry by publish.mjs. Exactly one of these installs on
  //      any given host (each declares its own `os`/`cpu`).
  //   2. The EXTERNAL TOOLS — `bun` and `@zigbase/server`, the two binaries the
  //      CLI shells out to. Derived from mise.toml and src/cli/zigbase.zig
  //      respectively (see toolchainDeps).
  //
  // WHY THE TOOLS ARE OPTIONAL RATHER THAN REQUIRED. npm installs
  // optionalDependencies BY DEFAULT — `--omit=optional` is the opt-out — so this
  // is still batteries-included, not opt-in. What `optional` buys is the failure
  // mode: a host where one of them cannot install degrades to a working
  // content-only CLI that names what is missing (`no island sidecar is
  // configured`, or the zigbase locator's own message), instead of failing the
  // whole `npm install` for someone who was never going to build an island. It
  // also gives the ~120 MB of native tooling a documented escape hatch, which a
  // hard dependency would not.
  //
  // (`peerDependencies` was the third option and is the wrong tool: an OPTIONAL
  // peer is not auto-installed at all — the opposite of what is wanted — and a
  // non-optional one turns a version difference into a hard error and behaves
  // differently across npm, pnpm and yarn.)
  const optionalDependencies = {};
  for (const t of targets) optionalDependencies[`@zigapagos/cli-${t.key}`] = version;
  Object.assign(optionalDependencies, optionalTools);
  const cliPkgPath = join(cliDir, "package.json");
  writeJson(cliPkgPath, {
    name: "@zigapagos/cli",
    version,
    description:
      "Zigapagos — a static site generator with islands and native SPAs. " +
      "Official prebuilt binary distribution.",
    // See launcherPlatform: this is what makes npm refuse an arm64 host at
    // install time instead of installing a launcher with no binary behind it.
    ...platform,
    bin: { zigapagos: "bin/zigapagos.js" },
    main: "index.js",
    // NOTE: deliberately no `exports` field. The bare `zigapagos` alias package
    // hands off with `require("@zigapagos/cli/bin/zigapagos.js")`, and an
    // `exports` map would make that deep path unresolvable.
    //
    // `runtime` is the @z/runtime + Bun-sidecar tree, staged here by publish.mjs
    // from the repository's runtime/ (it is NOT committed under npm/). Without it
    // in `files` the sources are simply absent from the tarball and every island
    // build fails at the sidecar spawn — which is precisely the state this package
    // used to be in, and used to describe as a limitation of the design.
    files: ["bin", "index.js", "targets.json", "runtime", "README.md"],
    engines: { node: ">=18" },
    publishConfig: { access: "public" },
    // The shipped runtime/ sources import these by bare name, so they are real,
    // non-optional dependencies of this package — unlike the two external tools
    // above, a missing Preact is not a degraded mode, it is an unresolvable
    // import inside files we ship.
    dependencies,
    optionalDependencies,
    keywords: KEYWORDS,
    repository: REPO,
    homepage: HOMEPAGE,
    bugs: { url: BUGS },
    license: LICENSE,
  });

  const cliReadmePath = join(cliDir, "README.md");
  writeFileSync(
    cliReadmePath,
    `# @zigapagos/cli

The official prebuilt [Zigapagos](${HOMEPAGE}) binary — a static site generator with
islands architecture and native SPAs, ${UPSTREAM_ATTRIBUTION}.

This package ships no binary of its own. It resolves the right
\`@zigapagos/cli-<platform>\` optional dependency at run time — the same distribution
strategy as \`esbuild\` — so an install downloads exactly one binary.

## Usage

\`\`\`sh
npx @zigapagos/cli init      # scaffold a site
npx @zigapagos/cli dev       # dev loop on http://127.0.0.1:1990
\`\`\`

Run bare it prints its help and exits: there is no default action.

After \`npm install @zigapagos/cli\` the \`zigapagos\` binary is on \`PATH\` in npm
scripts:

\`\`\`sh
zigapagos release --output=public --force   # build the site
zigapagos --help
\`\`\`

From Node, resolve the binary path instead of shelling out to \`npx\`:

\`\`\`js
const { binaryPath } = require("@zigapagos/cli");
const bin = binaryPath(); // absolute path to this host's binary
\`\`\`

The unscoped [\`zigapagos\`](https://www.npmjs.com/package/zigapagos) package is an
alias for this one, at the same version. Either works; this is the canonical name.

## Supported platforms

${table}

The platform packages install automatically — do not depend on them directly.

A host with no package of its own is refused, not served a binary for another
architecture: \`npm install\` fails with \`EBADPLATFORM\` (this package declares the
\`os\`/\`cpu\` its platform packages cover), and if you install past that,
\`binaryPath()\` throws naming the reason. **arm64 is not supported on either
macOS or Linux** — there is no aarch64 release build yet, because \`zig
translate-c\` currently SIGSEGVs on a C dependency for every aarch64 target on
released Zig 0.16.0. Build [from source](${HOMEPAGE}#from-source) (zig 0.16.0 +
bun 1.2) meanwhile.

${REQUIREMENTS}
## License

MIT — see the [repository](${HOMEPAGE}).
`,
  );
  written.push(cliPkgPath, cliReadmePath);

  // --- The bare-name alias. --------------------------------------------------
  const aliasDir = join(npmDir, "zigapagos");
  mkdirSync(aliasDir, { recursive: true });
  const aliasPkgPath = join(aliasDir, "package.json");
  writeJson(aliasPkgPath, {
    name: "zigapagos",
    version,
    description: "Zigapagos static site generator — alias for @zigapagos/cli.",
    // Repeated rather than left to the dependency: npm would refuse the install
    // either way (@zigapagos/cli is a hard dependency here), but the error should
    // name the package the user typed. Same union, same source.
    ...platform,
    bin: { zigapagos: "bin/zigapagos.js" },
    // No `main`: this package is a bin, not a library. Programmatic users want
    // @zigapagos/cli, whose index.js exports binaryPath().
    files: ["bin", "README.md"],
    engines: { node: ">=18" },
    publishConfig: { access: "public" },
    // Exact, not a range: the alias and the package it aliases are released as
    // one unit, and a range would let `npx zigapagos` run a build of the CLI
    // this version was never tested against.
    dependencies: { "@zigapagos/cli": version },
    keywords: KEYWORDS,
    repository: REPO,
    homepage: HOMEPAGE,
    bugs: { url: BUGS },
    license: LICENSE,
  });

  const aliasReadmePath = join(aliasDir, "README.md");
  writeFileSync(
    aliasReadmePath,
    `# zigapagos

**This package is an alias.** It exists so that \`npx zigapagos\` works and the
unscoped name belongs to the project; it contains one three-line launcher and
nothing else.

The canonical package is
[**\`@zigapagos/cli\`**](https://www.npmjs.com/package/@zigapagos/cli) — this package
depends on it at the exact same version (\`${version}\`) and re-exposes its \`zigapagos\`
bin. Platform resolution, the binary, and the documentation all live there.

\`\`\`sh
npx zigapagos init      # scaffold a site
npx zigapagos dev       # dev loop on http://127.0.0.1:1990
\`\`\`

For programmatic use, depend on \`@zigapagos/cli\` directly — this package exports
nothing.

## Supported platforms

${table}

${REQUIREMENTS}
## License

MIT — see the [repository](${HOMEPAGE}).
`,
  );
  written.push(aliasPkgPath, aliasReadmePath);

  return written;
}

// CLI: generate in place from the committed targets.json + build.zig.zon.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const repoRoot = join(HERE, "..");
  const targets = JSON.parse(readFileSync(join(HERE, "cli", "targets.json"), "utf8"));
  const version = versionFromBuildZon(repoRoot);
  const written = genPackages({ version, targets, npmDir: HERE, ...toolchainDeps(repoRoot) });
  console.log(`generated ${written.length} files at version ${version}:`);
  for (const p of written) console.log(`  ${p}`);
}
