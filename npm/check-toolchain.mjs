#!/usr/bin/env node
// Gate: the dependency ranges in the published @zigapagos/cli must still agree
// with the files that own those numbers.
//
//   node npm/check-toolchain.mjs
//
// @zigapagos/cli declares five dependencies, and not one of them is a number
// this repo gets to choose independently:
//
//   preact, preact-render-to-string  <- runtime/package.json `dependencies`
//   @zigbase/server                  <- `pinned_version` in src/cli/zigbase.zig
//   bun                              <- the [tools] pin in mise.toml
//   typescript                       <- runtime/package.json `devDependencies`
//
// gen-packages.mjs DERIVES all five (see toolchainDeps), so today they cannot
// disagree. This gate exists because that property is a property of the current
// implementation, not of the format — a future edit that replaces a derivation
// with a literal, or renames the declaration a parser is looking for, restores
// the drift silently. Each disagreement has its own failure mode:
//
//   - zigbase: the npm range and `pinned_version` are the SAME tool reached two
//     ways. `npm i` installs the range; a PATH miss downloads the pin. If they
//     differ, `zigapagos dev` runs a different zigbase depending on how the user
//     installed — the hardest class of bug to reproduce from a report, because
//     both machines "have zigapagos X".
//   - preact: the CLI ships runtime/src, which imports Preact by bare name. A
//     range wider than the one runtime/ is tested against means those shipped
//     sources can meet a Preact major they were never built against.
//   - bun: CLAUDE.md makes mise.toml the single source of truth for the
//     toolchain and forbids a second pin beside it. A literal here would be that
//     second pin.
//   - typescript: the `^6` cap is not a preference. 7.0 is the Go rewrite and
//     dropped the JavaScript compiler API, so `ts.createSourceFile` — which both
//     scripts/slice-host.ts and sidecar/hot-transform.ts call — does not exist
//     there. A wider range publishes a package whose SPA slicer throws, and
//     because both callers degrade gracefully the symptom is a SILENTLY unsliced
//     runtime rather than a failure.
//
// The parsers read foreign formats (Zig, TOML), so each one THROWS rather than
// returning empty when its pattern stops matching — a gate that finds nothing
// prints PASS. Same reasoning as check-targets.mjs, whose shape this follows.
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * The generator belonging to the tree under test.
 *
 * Imported from `root` rather than statically from beside this file, so that a
 * fixture can corrupt gen-packages.mjs itself and this gate still notices. That
 * matters because the most likely way these ranges ever drift is not a source
 * file moving — the derivations would throw — but someone replacing a derivation
 * with a convenient literal. A gate that always imported the REAL generator
 * could never see that, and its self-tests could not express it either.
 * Production callers pass the repo root, so they get exactly this file's
 * neighbour anyway.
 */
function generatorFor(root) {
  return import(pathToFileURL(join(root, "npm", "gen-packages.mjs")).href);
}

// --- Independent readers ----------------------------------------------------
//
// Deliberately NOT gen-packages.mjs's own derivations, even though they read the
// same three files with the same patterns. Asking the generator what it thinks
// the zigbase pin is, and then checking that against what the generator put in
// the manifest, compares a value with itself: a generator that hardcoded
// `"0.13.0"` in both places would agree with itself perfectly while disagreeing
// with the Zig source, and the gate would print PASS. check-targets.mjs is built
// the same way and for the same reason — it parses build/release.zig itself
// rather than trusting targets.json to describe it.
//
// The duplication is the point. These are the second opinion.

/** `pinned_version` in src/cli/zigbase.zig, without the Zig side's leading `v`. */
function pinnedZigbase(root) {
  const src = readFileSync(join(root, "src", "cli", "zigbase.zig"), "utf8");
  const m = src.match(/^\s*pub const pinned_version\s*=\s*"v?([0-9]+\.[0-9]+\.[0-9]+)"/m);
  if (!m) {
    throw new Error(
      "check-toolchain: could not read `pinned_version` from src/cli/zigbase.zig — the " +
        "declaration moved or was renamed, and this gate is now checking nothing",
    );
  }
  return m[1];
}

/** The bun pin from mise.toml, as the caret range a consumer should get. */
function pinnedBun(root) {
  const toml = readFileSync(join(root, "mise.toml"), "utf8");
  const m = toml.match(/^\s*bun\s*=\s*"([0-9]+(?:\.[0-9]+)*)"/m);
  if (!m) {
    throw new Error(
      "check-toolchain: could not read the bun pin from mise.toml — the [tools] entry " +
        "moved or was renamed, and this gate is now checking nothing",
    );
  }
  return `^${m[1]}`;
}

/** runtime/package.json's own `devDependencies.typescript`. */
function runtimeTypescript(root) {
  const pkg = JSON.parse(readFileSync(join(root, "runtime", "package.json"), "utf8"));
  const range = (pkg.devDependencies ?? {}).typescript;
  if (!range) {
    throw new Error(
      "check-toolchain: runtime/package.json declares no `typescript` devDependency — " +
        "the field moved or the slicer stopped needing it, and this gate is now " +
        "checking nothing",
    );
  }
  return range;
}

/** runtime/package.json's own `dependencies`. */
function runtimeDeps(root) {
  const pkg = JSON.parse(readFileSync(join(root, "runtime", "package.json"), "utf8"));
  const deps = pkg.dependencies ?? {};
  if (Object.keys(deps).length === 0) {
    throw new Error(
      "check-toolchain: runtime/package.json declares no dependencies — either the " +
        "field moved or the runtime lost Preact; this gate is now checking nothing",
    );
  }
  return deps;
}

/**
 * Every problem found, one line each; empty means agreement.
 *
 * The check is END-TO-END: it GENERATES the package manifest exactly as
 * publish.mjs does — through the tree's own generator — and holds the result
 * against the readers above, which parse the source files independently. Both
 * halves matter. Generating rather than inspecting the generator's intermediate
 * values is what survives a refactor of how a range travels from source to
 * manifest; reading the sources independently is what stops the generator from
 * being its own witness.
 *
 * @param {string} root repository root. `--root` exists for this gate's own
 *   tests (tests/npm/toolchain.sh), which build corrupted copies of the tree;
 *   production callers pass nothing.
 * @returns {string[]}
 */
export async function check(root) {
  const { genPackages, toolchainDeps, versionFromBuildZon } = await generatorFor(root);

  const problems = [];
  const targets = JSON.parse(readFileSync(join(root, "npm", "cli", "targets.json"), "utf8"));
  const version = versionFromBuildZon(root);
  const { dependencies, optionalTools } = toolchainDeps(root);

  const dir = mkdtempSync(join(tmpdir(), "zigapagos-toolchain-"));
  let cli;
  try {
    genPackages({ version, targets, npmDir: dir, dependencies, optionalTools });
    cli = JSON.parse(readFileSync(join(dir, "cli", "package.json"), "utf8"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  // 1. Whatever runtime/package.json depends on, the CLI must depend on too —
  //    it ships those sources, so the imports are ITS imports now.
  const runtime = runtimeDeps(root);
  for (const [name, range] of Object.entries(runtime)) {
    const got = cli.dependencies?.[name];
    if (got !== range) {
      problems.push(
        `@zigapagos/cli dependencies['${name}'] is ${got ?? "absent"}, but ` +
          `runtime/package.json declares ${range} — the CLI ships runtime/src, so the ` +
          `two must be the same range`,
      );
    }
  }
  // ...and nothing beyond it. An extra `dependencies` entry is either a tool that
  // belongs in optionalDependencies (where it can be omitted) or a stray.
  for (const name of Object.keys(cli.dependencies ?? {})) {
    if (!(name in runtime)) {
      problems.push(
        `@zigapagos/cli declares dependency '${name}', which runtime/package.json does ` +
          `not — a required dependency of this package must be something its shipped ` +
          `sources import`,
      );
    }
  }

  // 2. The zigbase the npm path installs and the one the download path fetches.
  const zbName = "@zigbase/server";
  const zbRange = pinnedZigbase(root);
  const zbGot = cli.optionalDependencies?.[zbName];
  if (zbGot !== zbRange) {
    problems.push(
      `@zigapagos/cli optionalDependencies['${zbName}'] is ${zbGot ?? "absent"}, but ` +
        `src/cli/zigbase.zig pins v${zbRange} — npm would install one zigbase and ` +
        `--download-zigbase would fetch another`,
    );
  }
  // The bare `zigbase` alias exists on npm but was published exactly once, so
  // 0.12.0 is the only version it will ever have and it cannot follow a pin.
  // Rejected on PRESENCE, not on the version it resolves to, so the check stays
  // correct across every future pin — and because this lives in
  // optionalDependencies, npm skips an unresolvable range silently rather than
  // failing the install. Depending on the alias is how the two paths diverge
  // with nothing to read; name that specifically.
  if (cli.optionalDependencies?.zigbase !== undefined) {
    problems.push(
      `@zigapagos/cli depends on the bare 'zigbase' alias, which is published only at ` +
        `0.12.0 and so cannot track pinned_version — depend on '${zbName}' instead`,
    );
  }

  // 3. bun, against the one toolchain pin CLAUDE.md allows.
  const bunName = "bun";
  const bunRange = pinnedBun(root);
  const bunGot = cli.optionalDependencies?.[bunName];
  if (bunGot !== bunRange) {
    problems.push(
      `@zigapagos/cli optionalDependencies['${bunName}'] is ${bunGot ?? "absent"}, but ` +
        `mise.toml pins bun such that ${bunRange} is required`,
    );
  }

  // 4. typescript, against the cap the slicer and the hot transform both need.
  const tsRange = runtimeTypescript(root);
  const tsGot = cli.optionalDependencies?.typescript;
  if (tsGot !== tsRange) {
    problems.push(
      `@zigapagos/cli optionalDependencies['typescript'] is ${tsGot ?? "absent"}, but ` +
        `runtime/package.json declares ${tsRange} — typescript 7 dropped the JavaScript ` +
        `compiler API the SPA slicer calls, and the slicer fails SILENTLY (fallback)`,
    );
  }

  // 5. The tools must be OPTIONAL, not required. A hard dependency on ~120 MB of
  //    native tooling fails the whole install on a host that cannot take one of
  //    them, for a user who may only ever build content.
  for (const name of Object.keys(optionalTools)) {
    if (cli.dependencies?.[name] !== undefined) {
      problems.push(
        `@zigapagos/cli declares '${name}' in dependencies; it belongs in ` +
          `optionalDependencies so --omit=optional can skip it`,
      );
    }
  }

  // 6. The runtime sources have to actually be in the tarball. Declaring Preact
  //    while shipping nothing that imports it is the inverse mistake, and it
  //    fails at the sidecar spawn in a consumer's build rather than here.
  if (!cli.files?.includes("runtime")) {
    problems.push(
      `@zigapagos/cli files does not include 'runtime' — the sidecar and @z/runtime ` +
        `sources would be absent from the tarball and every island build would fail`,
    );
  }

  return problems;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const i = process.argv.indexOf("--root");
  const root = i >= 0 ? process.argv[i + 1] : join(HERE, "..");
  let problems;
  try {
    problems = await check(root);
  } catch (err) {
    console.error(`FAIL: ${err.message}`);
    process.exit(1);
  }
  if (problems.length > 0) {
    console.error("FAIL: @zigapagos/cli's dependencies disagree with the files that own them:");
    for (const p of problems) console.error(`  - ${p}`);
    console.error(
      "\nThese ranges are DERIVED by gen-packages.mjs (toolchainDeps) from " +
        "runtime/package.json, src/cli/zigbase.zig and mise.toml. Fix the source of " +
        "truth, not the generated manifest — and if a derivation was replaced by a " +
        "literal, put the derivation back.\n",
    );
    process.exit(1);
  }
  const { toolchainDeps } = await generatorFor(root);
  const { dependencies, optionalTools } = toolchainDeps(root);
  console.log("ok: @zigapagos/cli's dependencies agree with their sources:");
  for (const [n, r] of Object.entries(dependencies)) {
    console.log(`  ${n} ${r} (required)   <- runtime/package.json`);
  }
  const from = {
    bun: "mise.toml",
    "@zigbase/server": "src/cli/zigbase.zig",
    typescript: "runtime/package.json (devDependencies)",
  };
  for (const [n, r] of Object.entries(optionalTools)) {
    console.log(`  ${n} ${r} (optional)   <- ${from[n] ?? "?"}`);
  }
}
