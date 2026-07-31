#!/usr/bin/env node
// Drift gate: the release target matrix exists in THREE places, and this asserts
// they name the same set.
//
//   build/release.zig                the source of truth for WHAT is shipped
//   npm/cli/targets.json             what the npm packages are generated for
//   .github/workflows/release.yml    WHERE each target is built, and the archive
//                                    name the npm job downloads
//
// Why a gate rather than care: each disagreement is silent and each fails late.
// A target in build/release.zig with no targets.json row is simply never
// published. A targets.json row with no release.zig entry publishes an
// `@zigapagos/cli-<key>` package whose binary nobody builds — an install that
// resolves and then cannot run. A release.zig entry with no workflow row builds
// nowhere, so the release ships a smaller matrix than it claims. build/release.zig
// already rejects a workflow row naming an unknown triple (`-Drelease-target`),
// which is the fourth combination and the only one that was already covered.
//
// Everything except the triple list is DERIVED here rather than trusted: the npm
// key/os/cpu and the archive filename all follow from the zig triple, so a
// hand-edited targets.json cannot quietly invent `linux-arm64 -> x86_64-macos`.
//
//   node npm/check-targets.mjs [--root <dir>]
//
// `--root` exists for the gate's own tests (tests/npm/targets.sh), which build
// fixture trees where the three files disagree on purpose. Production callers
// pass nothing.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// zig triple component -> npm's `process.arch` / `process.platform` spelling.
// An unknown component is an error, not a passthrough: adding aarch64 or windows
// to the release matrix must land here deliberately.
const NPM_ARCH = { x86_64: "x64", aarch64: "arm64" };
const NPM_OS = { linux: "linux", macos: "darwin", windows: "win32", freebsd: "freebsd" };

/**
 * The `targets` literal in build/release.zig, as zig triples.
 * Mirrors what `std.Target.Query.zigTriple` would print for those entries:
 * `<arch>-<os>` plus `-<abi>` when an abi is given.
 */
export function targetsFromReleaseZig(src) {
  const block = src.match(
    /const\s+targets\s*:\s*\[\]const\s+std\.Target\.Query\s*=\s*&\.\{([\s\S]*?)\n\s*\};/,
  );
  if (!block) {
    throw new Error(
      "check-targets: could not find the `targets: []const std.Target.Query` literal in " +
        "build/release.zig — the declaration moved or was renamed, and this gate is now " +
        "checking nothing",
    );
  }
  const triples = [];
  for (const entry of block[1].matchAll(/\.\{([^{}]*)\}/g)) {
    const body = entry[1];
    const arch = body.match(/\.cpu_arch\s*=\s*\.(\w+)/)?.[1];
    const os = body.match(/\.os_tag\s*=\s*\.(\w+)/)?.[1];
    const abi = body.match(/\.abi\s*=\s*\.(\w+)/)?.[1];
    if (!arch || !os) {
      throw new Error(
        `check-targets: release matrix entry '.{${body.trim()}}' has no .cpu_arch/.os_tag — ` +
          "this gate cannot derive its triple",
      );
    }
    triples.push(abi ? `${arch}-${os}-${abi}` : `${arch}-${os}`);
  }
  if (triples.length === 0) {
    throw new Error("check-targets: parsed zero targets from build/release.zig");
  }
  return triples;
}

/**
 * The build matrix rows of .github/workflows/release.yml, as
 * `{target, archive, runner}`. A hand-rolled scan rather than a YAML parser: the
 * repo has no YAML dependency, the shape is three flat keys, and an unparseable
 * file is a hard failure below rather than a silent empty result.
 */
export function matrixFromReleaseYaml(src) {
  const rows = [];
  let row = null;
  for (const line of src.split("\n")) {
    if (/^\s*#/.test(line)) continue;
    const start = line.match(/^\s*-\s*target:\s*(\S+)\s*$/);
    if (start) {
      row = { target: start[1] };
      rows.push(row);
      continue;
    }
    if (!row) continue;
    const kv = line.match(/^\s*(runner|archive):\s*(\S+)\s*$/);
    if (kv) {
      row[kv[1]] = kv[2];
      continue;
    }
    // Any other non-blank line ends the row: matrix entries are contiguous.
    if (line.trim() !== "") row = null;
  }
  if (rows.length === 0) {
    throw new Error(
      "check-targets: found no `- target:` matrix rows in .github/workflows/release.yml — " +
        "the build matrix moved, and this gate is now checking nothing",
    );
  }
  return rows;
}

/** npm key/os/cpu and archive filename, derived from a zig triple. */
export function deriveTarget(triple) {
  const parts = triple.split("-");
  const [arch, os] = parts;
  const cpu = NPM_ARCH[arch];
  const npmOs = NPM_OS[os];
  if (!cpu) throw new Error(`check-targets: unknown cpu_arch '${arch}' in '${triple}'`);
  if (!npmOs) throw new Error(`check-targets: unknown os_tag '${os}' in '${triple}'`);
  // build/release.zig zips macOS and Windows and tars everything else.
  const ext = os === "macos" || os === "windows" ? "zip" : "tar.xz";
  return { key: `${npmOs}-${cpu}`, os: npmOs, cpu, archive: `${triple}.${ext}` };
}

const sorted = (xs) => [...xs].sort();
const missingFrom = (a, b) => sorted(a.filter((x) => !b.includes(x)));

/**
 * @returns {string[]} one line per problem; empty means agreement.
 */
export function check(root) {
  const problems = [];
  const json = JSON.parse(readFileSync(join(root, "npm", "cli", "targets.json"), "utf8"));
  const zig = targetsFromReleaseZig(readFileSync(join(root, "build", "release.zig"), "utf8"));
  const matrix = matrixFromReleaseYaml(
    readFileSync(join(root, ".github", "workflows", "release.yml"), "utf8"),
  );

  if (!Array.isArray(json) || json.length === 0) {
    problems.push("npm/cli/targets.json is empty or not an array");
    return problems;
  }

  const jsonTriples = json.map((t) => t.zig);
  const matrixTriples = matrix.map((r) => r.target);

  for (const [a, aName, b, bName] of [
    [jsonTriples, "npm/cli/targets.json", zig, "build/release.zig"],
    [zig, "build/release.zig", matrixTriples, "release.yml's build matrix"],
  ]) {
    for (const t of missingFrom(a, b)) problems.push(`${t}: in ${aName} but not in ${bName}`);
    for (const t of missingFrom(b, a)) problems.push(`${t}: in ${bName} but not in ${aName}`);
  }

  const seenKeys = new Map();
  for (const t of json) {
    if (!t.zig) {
      problems.push(`npm/cli/targets.json entry ${JSON.stringify(t)} has no 'zig' triple`);
      continue;
    }
    let want;
    try {
      want = deriveTarget(t.zig);
    } catch (err) {
      problems.push(err.message);
      continue;
    }
    for (const field of ["key", "os", "cpu", "archive"]) {
      if (t[field] !== want[field]) {
        problems.push(
          `${t.zig}: targets.json ${field}='${t[field]}' but '${t.zig}' derives ${field}='${want[field]}'`,
        );
      }
    }
    if (seenKeys.has(t.key)) {
      problems.push(`duplicate key '${t.key}' in npm/cli/targets.json`);
    }
    seenKeys.set(t.key, t);

    // The npm publish job downloads `release-<target>` and extracts the archive
    // the matrix row named. A mismatch here is a download that succeeds and then
    // finds no file.
    const row = matrix.find((r) => r.target === t.zig);
    if (row && row.archive && row.archive !== t.archive) {
      problems.push(
        `${t.zig}: release.yml archive='${row.archive}' but targets.json archive='${t.archive}'`,
      );
    }
    if (row && !row.archive) {
      problems.push(`${t.zig}: release.yml matrix row has no 'archive:' for the npm job to extract`);
    }
  }
  return problems;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const i = process.argv.indexOf("--root");
  const root = i >= 0 ? process.argv[i + 1] : join(HERE, "..");
  let problems;
  try {
    problems = check(root);
  } catch (err) {
    console.error(`FAIL: ${err.message}`);
    process.exit(1);
  }
  if (problems.length > 0) {
    console.error("FAIL: release target matrix disagrees across its three declarations:");
    for (const p of problems) console.error(`  - ${p}`);
    console.error(
      "\nFix by editing build/release.zig (what ships), npm/cli/targets.json (what npm\n" +
        "publishes) and .github/workflows/release.yml's matrix (where each is built)\n" +
        "together. A target belongs in all three or none.",
    );
    process.exit(1);
  }
  const json = JSON.parse(readFileSync(join(root, "npm", "cli", "targets.json"), "utf8"));
  console.log(`ok: ${json.length} release target(s) agree across all three declarations:`);
  for (const t of json) console.log(`  ${t.zig} -> @zigapagos/cli-${t.key} (${t.archive})`);
}
