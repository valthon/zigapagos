// Unit tests for the package generator and the target-drift gate's parsers.
//
//   node --test npm/gen-packages.test.mjs
//
// Run by tests/npm/packaging.sh, which CI discovers through its `tests/*/*.sh`
// glob. What is pinned here is everything a mistake in would only be visible
// after publishing: the version appearing in all three packages, the exact-pin
// between the alias and the package it aliases, `os`/`cpu` on the platform
// packages (npm skips a platform package on the wrong host by reading them) and
// on the two launcher packages (npm refuses an unsupported host at install time
// by reading them), and the generated platform table dropping a fallback row the
// moment a native target for it appears.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  bunDepFromMise,
  genPackages,
  runtimeDepsFromPackageJson,
  typescriptDepFromPackageJson,
  versionFromBuildZon,
  zigbaseDepFromZig,
} from "./gen-packages.mjs";
import { deriveTarget, matrixFromReleaseYaml, targetsFromReleaseZig } from "./check-targets.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

const TARGETS = [
  {
    key: "darwin-x64",
    zig: "x86_64-macos",
    os: "darwin",
    cpu: "x64",
    archive: "x86_64-macos.zip",
  },
  {
    key: "linux-x64",
    zig: "x86_64-linux-musl",
    os: "linux",
    cpu: "x64",
    archive: "x86_64-linux-musl.tar.xz",
  },
];

// Fixed ranges rather than the repo's real ones: these tests pin the SHAPE of
// the generated manifest, and reading the live values would make every assertion
// restate whatever gen-packages.mjs just derived — a test that cannot fail.
// check-toolchain.mjs is what holds the real values to their sources.
const DEPENDENCIES = { preact: "^10.0.0", "preact-render-to-string": "^6.0.0" };
// The zigbase entry is deliberately a version that has never been published:
// it used to restate the real pin, which made it one more place a pin bump had
// to be chased through for no assertion's benefit. Nothing here reads it back
// from a source of truth — genPackages echoes whatever it is handed.
const OPTIONAL_TOOLS = { bun: "^1.2", "@zigbase/server": "0.0.1", typescript: "^6.0.3" };

function generate(targets = TARGETS, version = "9.9.9") {
  const dir = mkdtempSync(join(tmpdir(), "zigapagos-genpkg-"));
  genPackages({
    version,
    targets,
    npmDir: dir,
    dependencies: DEPENDENCIES,
    optionalTools: OPTIONAL_TOOLS,
  });
  return dir;
}
const readJson = (dir, ...p) => JSON.parse(readFileSync(join(dir, ...p), "utf8"));
const readText = (dir, ...p) => readFileSync(join(dir, ...p), "utf8");

function withGenerated(fn, targets, version) {
  const dir = generate(targets, version);
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("platform package: name, version, os, cpu, files, license", () => {
  withGenerated((dir) => {
    const pkg = readJson(dir, "cli-linux-x64", "package.json");
    assert.equal(pkg.name, "@zigapagos/cli-linux-x64");
    assert.equal(pkg.version, "9.9.9");
    assert.deepEqual(pkg.os, ["linux"]);
    assert.deepEqual(pkg.cpu, ["x64"]);
    assert.deepEqual(pkg.files, ["zigapagos", "README.md"]);
    assert.equal(pkg.license, "MIT");
    assert.equal(pkg.publishConfig.access, "public");
    // A platform package carrying a bin would collide with the launcher's.
    assert.equal(pkg.bin, undefined);
  });
});

test("@zigapagos/cli: bin, main, files, and one exact-pinned optionalDependency per target", () => {
  withGenerated((dir) => {
    const cli = readJson(dir, "cli", "package.json");
    assert.equal(cli.name, "@zigapagos/cli");
    assert.equal(cli.version, "9.9.9");
    assert.equal(cli.bin.zigapagos, "bin/zigapagos.js");
    assert.equal(cli.main, "index.js");
    // Still a deepEqual, and still for the original reason — an entry nobody
    // decided on is a defect, not an addition — but the expected set is no longer
    // just the platform-resolution table.
    //
    // This assertion previously read "no dependencies at all", which encoded a
    // decision that has since been reversed: the CLI now ships the runtime
    // sources and installs the tools it shells out to, so that
    // `npm i zigapagos` builds islands and SPAs and runs `dev` with no further
    // steps. What the deepEqual pins now is the SPLIT — exactly one platform
    // package per target, plus exactly the external tools, and nothing else.
    assert.deepEqual(cli.optionalDependencies, {
      "@zigapagos/cli-darwin-x64": "9.9.9",
      "@zigapagos/cli-linux-x64": "9.9.9",
      ...OPTIONAL_TOOLS,
    });
    // The runtime sources this package ships import these by bare name, so they
    // are required rather than optional: `--omit=optional` must still leave a
    // CLI whose bundled sidecar can resolve its imports.
    assert.deepEqual(cli.dependencies, DEPENDENCIES);
    // peerDependencies remains the wrong tool and stays empty: an optional peer
    // is not auto-installed at all, and a required one turns a version
    // difference into a hard error that resolves differently on npm vs pnpm.
    assert.equal(cli.peerDependencies, undefined);
    // The sidecar and @z/runtime sources have to be IN the tarball; declaring
    // Preact while shipping nothing that imports it fails at the sidecar spawn
    // in a consumer's build rather than here.
    assert.ok(cli.files.includes("runtime"), "files should include the runtime tree");
    // The union of the platform packages'. Without these npm installs this
    // package happily on arm64 — every optionalDependency skipped, no binary in
    // the tree — and the first failure is at build time.
    assert.deepEqual(cli.os, ["darwin", "linux"]);
    assert.deepEqual(cli.cpu, ["x64"]);
    // index.js does `require("./targets.json")`, so shipping it is not optional.
    for (const f of ["bin", "index.js", "targets.json", "README.md"]) {
      assert.ok(cli.files.includes(f), `files should include ${f}`);
    }
    // The alias hands off via require("@zigapagos/cli/bin/zigapagos.js"); an
    // `exports` map would make that deep path unresolvable.
    assert.equal(cli.exports, undefined);
  });
});

test("zigapagos alias: bin, exact dependency on @zigapagos/cli, no resolver of its own", () => {
  withGenerated((dir) => {
    const alias = readJson(dir, "zigapagos", "package.json");
    assert.equal(alias.name, "zigapagos");
    assert.equal(alias.version, "9.9.9");
    assert.equal(alias.bin.zigapagos, "bin/zigapagos.js");
    // Exact, not ^ or ~: the two are released as one unit.
    assert.deepEqual(alias.dependencies, { "@zigapagos/cli": "9.9.9" });
    assert.equal(alias.optionalDependencies, undefined);
    // Repeated from @zigapagos/cli so that `npm install zigapagos` on an
    // unsupported host names the package the user actually typed.
    assert.deepEqual(alias.os, ["darwin", "linux"]);
    assert.deepEqual(alias.cpu, ["x64"]);
    assert.deepEqual(alias.files, ["bin", "README.md"]);
    assert.equal(alias.main, undefined);
  });
});

test("all three packages carry the same version", () => {
  withGenerated((dir) => {
    const versions = new Set(
      ["cli", "zigapagos", "cli-darwin-x64", "cli-linux-x64"].map(
        (d) => readJson(dir, d, "package.json").version,
      ),
    );
    assert.deepEqual([...versions], ["1.2.3"]);
  }, TARGETS, "1.2.3");
});

test("one directory per target and no others", () => {
  withGenerated((dir) => {
    readJson(dir, "cli-darwin-x64", "package.json");
    readJson(dir, "cli-linux-x64", "package.json");
    assert.throws(() => readJson(dir, "cli-darwin-arm64", "package.json"));
    assert.throws(() => readJson(dir, "cli-linux-arm64", "package.json"));
  });
});

test("platform table: a row per target, and every unsupported host named", () => {
  withGenerated((dir) => {
    for (const readme of [readText(dir, "cli", "README.md"), readText(dir, "zigapagos", "README.md")]) {
      // Every column is labelled: an unnamed header renders as a blank cell and
      // leaves the native/unsupported column meaning nothing.
      assert.match(readme, /\| Host \| Package \| Status \|/);
      assert.match(readme, /macOS x64.*@zigapagos\/cli-darwin-x64.*native/);
      assert.match(readme, /Linux x64.*@zigapagos\/cli-linux-x64.*native/);
      // Both arm64 hosts, with no package and the same status: an unsupported
      // host is refused, never served a binary for another architecture.
      assert.match(readme, /Apple Silicon.*\| — \|.*not supported yet/);
      assert.match(readme, /Linux arm64.*\| — \|.*not supported yet/);
      assert.match(readme, /Windows x64.*\| — \|.*not supported yet/);
      // The architecture substitution this channel used to do is gone from the
      // published docs as well as from the code; a table row promising it is how
      // a user would still expect it to work.
      assert.doesNotMatch(readme, /Rosetta|emulat/i);
    }
  });
});

test("a native darwin-arm64 target replaces its unsupported row and widens cpu", () => {
  const withArm = [
    ...TARGETS,
    {
      key: "darwin-arm64",
      zig: "aarch64-macos",
      os: "darwin",
      cpu: "arm64",
      archive: "aarch64-macos.zip",
    },
  ];
  withGenerated((dir) => {
    const readme = readText(dir, "cli", "README.md");
    assert.match(readme, /macOS arm64.*@zigapagos\/cli-darwin-arm64.*native/);
    assert.doesNotMatch(readme, /Apple Silicon.*not supported yet/);
    // Still stated for the host that has no build: adding one target must not
    // quietly imply the other arch is covered.
    assert.match(readme, /Linux arm64.*not supported yet/);
    const cli = readJson(dir, "cli", "package.json");
    assert.equal(cli.optionalDependencies["@zigapagos/cli-darwin-arm64"], "9.9.9");
    // The launcher's os/cpu is derived, not written down: a new target widens it.
    assert.deepEqual(cli.cpu, ["arm64", "x64"]);
    assert.deepEqual(readJson(dir, "zigapagos", "package.json").cpu, ["arm64", "x64"]);
  }, withArm);
});

test("both published READMEs say an npm install builds islands, SPAs and dev", () => {
  withGenerated((dir) => {
    for (const p of [["cli", "README.md"], ["zigapagos", "README.md"]]) {
      const readme = readText(dir, ...p);
      // The headline claim, and the three capabilities that used to be excluded.
      assert.match(readme, /islands/i);
      assert.match(readme, /zigapagos dev/);
      assert.match(readme, /Building a native SPA/);
      // The SPA claim has to be specific enough to be falsifiable: the parts a
      // vague "SPAs are supported" would let rot are the code-split chunks, the
      // per-route preload and the runtime slice — each of which was a separate
      // thing that had to be installed, and each of which fails silently.
      assert.match(readme, /code-split/);
      assert.match(readme, /modulepreload/);
      assert.match(readme, /runtime slice/);
      // How it is delivered: the sources ride along and the tools are installed.
      assert.match(readme, /runtime\//);
      assert.match(readme, /@zigbase\/server/);
      // ...and that no flag is needed for either kind of entry, because `release`
      // discovers them itself on this path. The flags remain documented as
      // overrides.
      assert.match(readme, /--island=SRC/);
      assert.match(readme, /--spa=SRC\|BASE/);
      assert.match(readme, /scanning the site root/);
    }
  });
});

// The READMEs used to say native SPAs were the one thing an npm install could
// not build, "because a SPA's client bundle is bun's code-splitting mode — an
// output DIRECTORY of chunks plus a manifest — and this CLI only knows how to
// install single-file assets". That reasoned from the BUILD GRAPH's constraint:
// `build.zig` must declare its outputs before anything runs, so it cannot name
// content-hashed chunks and installs the directory wholesale. The CLI runs the
// bundler first and simply reads the names off disk. No revision may bring the
// caveat back without bringing back the refusal it described.
test("neither README claims SPAs need a Zig build", () => {
  withGenerated((dir) => {
    for (const p of [["cli", "README.md"], ["zigapagos", "README.md"]]) {
      const readme = readText(dir, ...p);
      assert.doesNotMatch(readme, /SPAs.*still needs? a Zig build/s);
      assert.doesNotMatch(readme, /refuses `--spa=`/);
    }
  });
});

// The claim these READMEs used to make — that an npm install CANNOT build
// islands, because the sidecar and `@z/runtime` sources come from the Zig build
// integration and `@z/runtime` is unpublished — described a packaging choice as
// though it were a property of the design. `--island-sidecar=` is a runtime flag,
// and `private: true` governs publishing that package standalone, not whether
// this one may ship the same sources. The package now ships them, so no revision
// of this README may reintroduce the claim.
test("neither README claims islands are impossible over npm", () => {
  withGenerated((dir) => {
    for (const p of [["cli", "README.md"], ["zigapagos", "README.md"]]) {
      const readme = readText(dir, ...p);
      assert.doesNotMatch(readme, /What it cannot: islands and SPAs/);
      assert.doesNotMatch(readme, /installing bun does not unlock islands/i);
      assert.doesNotMatch(readme, /`@z\/runtime` is unpublished/);
      // The old text sent islands users to build.zig as the only option.
      assert.doesNotMatch(readme, /is a Zig-build project/);
    }
  });
});

// zigbase is now INSTALLED rather than asked for, so the old `npm i -D zigbase`
// instruction must not survive as advice — a reader who follows it installs a
// second copy at a version the CLI does not pin. The size it costs is stated
// instead, because that is the tradeoff the reader is now making silently.
test("both published READMEs stop telling the user to install zigbase themselves", () => {
  withGenerated((dir) => {
    for (const p of [["cli", "README.md"], ["zigapagos", "README.md"]]) {
      const readme = readText(dir, ...p);
      assert.doesNotMatch(readme, /npm i -D zigapagos zigbase/);
      assert.doesNotMatch(readme, /not.*declared as a dependency/i);
      // The measured size is stated instead...
      assert.match(readme, /~535 MB/);
      // ...and `--omit=optional` is documented as the trap it is, not as an
      // escape hatch: it drops the platform package too, because that is where
      // the binary lives. Claiming otherwise was a plausible, wrong answer that
      // an actual install disproved.
      assert.match(readme, /--omit=optional/);
      assert.match(readme, /no smaller supported install/i);
    }
  });
});

// Issue #56 made `zigapagos serve` a real command and stopped the tool calling
// what it starts "the deprecated live server". These two READMEs are the docs for
// the audience that decision was made FOR — the toolchain-free `npx zigapagos`
// consumer npm distribution created — so they are the last place that may keep
// teaching the old world. Two specific rots to keep out: the usage block that
// showed only the bare command (leaving `serve`, the spelling the repo README,
// docs/spa.md and every tests/serve/*.sh use, undocumented), and the words "dev
// server" for it, which now name a DIFFERENT command — `zigapagos dev`, the
// zigbase-backed watch loop these same READMEs describe a few lines earlier.
test("both published READMEs teach `zigapagos serve` and call it the preview server", () => {
  withGenerated((dir) => {
    for (const p of [["cli", "README.md"], ["zigapagos", "README.md"]]) {
      const readme = readText(dir, ...p);
      // The usage block runs the subcommand and names the server the same way
      // the binary's own help menu does.
      assert.match(readme, /npx \S+ serve\s+# preview server on http:\/\/localhost:1990/);
      // Neither of the two names it used to carry. "live server" was the
      // deprecated framing; "dev server" collides with `zigapagos dev`.
      assert.doesNotMatch(readme, /live server/);
      assert.doesNotMatch(readme, /dev server/);
      // The bare command is an ALIAS, not a superseded form, and it stays
      // documented as equivalent: tests/serve/serve-subcommand.sh pins that the
      // two invocations do the same thing, and a README that dropped one would
      // let them diverge unnoticed.
      assert.match(readme, /with no subcommand at all/);
    }
  });
});

test("the alias README says it is an alias and names the canonical package", () => {
  withGenerated((dir) => {
    const readme = readText(dir, "zigapagos", "README.md");
    assert.match(readme, /This package is an alias/);
    assert.match(readme, /@zigapagos\/cli/);
    assert.match(readme, /exports\s*\n?nothing|exports nothing/);
  });
});

test("an empty target list is rejected rather than generating an unusable meta package", () => {
  const dir = mkdtempSync(join(tmpdir(), "zigapagos-genpkg-"));
  try {
    assert.throws(() => genPackages({ version: "9.9.9", targets: [], npmDir: dir }), /targets is empty/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a target missing a field is rejected", () => {
  const dir = mkdtempSync(join(tmpdir(), "zigapagos-genpkg-"));
  try {
    assert.throws(
      () =>
        genPackages({
          version: "9.9.9",
          targets: [{ key: "linux-x64", os: "linux", cpu: "x64" }],
          npmDir: dir,
        }),
      /missing 'zig'/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("versionFromBuildZon reads the package version, not a dependency's", () => {
  const dir = mkdtempSync(join(tmpdir(), "zigapagos-zon-"));
  try {
    writeFileSync(
      join(dir, "build.zig.zon"),
      [
        ".{",
        "    .name = .zigapagos,",
        '    .version = "4.5.6",',
        "    .dependencies = .{",
        "        .some_dep = .{",
        '            .version = "0.0.1",',
        "        },",
        "    },",
        "}",
        "",
      ].join("\n"),
    );
    assert.equal(versionFromBuildZon(dir), "4.5.6");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- check-targets.mjs parsers ----------------------------------------------
// These are the parts of the drift gate that read another language's source, so
// they are the parts that can silently start matching nothing. tests/npm/targets.sh
// covers the gate end to end; these pin the parsers' shape and their refusal to
// return an empty result.

test("targetsFromReleaseZig derives zig triples, with and without an abi", () => {
  const src = `
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    };
  `;
  assert.deepEqual(targetsFromReleaseZig(src), ["x86_64-macos", "x86_64-linux-musl"]);
});

test("targetsFromReleaseZig throws when the declaration is gone (never silently empty)", () => {
  assert.throws(() => targetsFromReleaseZig("const something_else = &.{};\n"), /could not find/);
  assert.throws(
    () => targetsFromReleaseZig("const targets: []const std.Target.Query = &.{\n};\n"),
    /zero targets/,
  );
});

test("matrixFromReleaseYaml reads target/runner/archive rows", () => {
  const yml = [
    "      matrix:",
    "        include:",
    "          - target: x86_64-linux-musl",
    "            runner: ubuntu-latest",
    "            archive: x86_64-linux-musl.tar.xz",
    "          - target: x86_64-macos",
    "            runner: macos-latest",
    "            archive: x86_64-macos.zip",
    "",
    "    runs-on: ${{ matrix.runner }}",
  ].join("\n");
  assert.deepEqual(matrixFromReleaseYaml(yml), [
    { target: "x86_64-linux-musl", runner: "ubuntu-latest", archive: "x86_64-linux-musl.tar.xz" },
    { target: "x86_64-macos", runner: "macos-latest", archive: "x86_64-macos.zip" },
  ]);
});

test("matrixFromReleaseYaml ignores commented-out rows and throws on none", () => {
  assert.throws(
    () => matrixFromReleaseYaml("          # - target: aarch64-macos\n"),
    /found no `- target:` matrix rows/,
  );
});

test("deriveTarget maps triples to npm keys and archive names", () => {
  assert.deepEqual(deriveTarget("x86_64-linux-musl"), {
    key: "linux-x64",
    os: "linux",
    cpu: "x64",
    archive: "x86_64-linux-musl.tar.xz",
  });
  assert.deepEqual(deriveTarget("x86_64-macos"), {
    key: "darwin-x64",
    os: "darwin",
    cpu: "x64",
    archive: "x86_64-macos.zip",
  });
  assert.deepEqual(deriveTarget("aarch64-macos"), {
    key: "darwin-arm64",
    os: "darwin",
    cpu: "arm64",
    archive: "aarch64-macos.zip",
  });
  assert.throws(() => deriveTarget("riscv64-linux-musl"), /unknown cpu_arch 'riscv64'/);
  assert.throws(() => deriveTarget("x86_64-plan9"), /unknown os_tag 'plan9'/);
});

// --- The derived dependency ranges ------------------------------------------
//
// Each of these reads a number out of the file that owns it. They are unit-tested
// here for the SHAPE of what they return and for their anti-vacuity throws;
// tests/npm/toolchain.sh drives the whole gate against corrupted copies of the
// real tree, the way tests/npm/targets.sh does for check-targets.mjs.

test("dependency maps are required, and an empty one is rejected", () => {
  const dir = mkdtempSync(join(tmpdir(), "zigapagos-genpkg-"));
  try {
    const base = { version: "9.9.9", targets: TARGETS, npmDir: dir };
    // A derivation that silently returned {} would otherwise publish a CLI whose
    // bundled runtime cannot resolve Preact — and gen-packages would report success.
    assert.throws(
      () => genPackages({ ...base, dependencies: {}, optionalTools: OPTIONAL_TOOLS }),
      /dependencies is empty/,
    );
    assert.throws(
      () => genPackages({ ...base, dependencies: DEPENDENCIES, optionalTools: {} }),
      /optionalTools is empty/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("runtimeDepsFromPackageJson reads runtime/'s own dependencies", () => {
  const deps = runtimeDepsFromPackageJson(REPO_ROOT);
  // Named explicitly rather than just "non-empty": these are the two the shipped
  // sidecar and browser entry import, and losing one is a resolution failure
  // inside a tarball we published.
  assert.ok(deps.preact, "preact should be a dependency of the shipped runtime");
  assert.ok(deps["preact-render-to-string"], "preact-render-to-string likewise");
  // devDependencies must NOT leak in here. typescript is one, and it IS shipped
  // — but as an OPTIONAL dependency (typescriptDepFromPackageJson below), because
  // the two scripts that use it both degrade gracefully without it. Landing in
  // this map instead would make a compiler mandatory for a content-only site.
  assert.equal(deps.typescript, undefined);
});

test("typescriptDepFromPackageJson carries runtime/'s devDependency range verbatim", () => {
  const dep = typescriptDepFromPackageJson(REPO_ROOT);
  assert.deepEqual(Object.keys(dep), ["typescript"]);
  const declared = JSON.parse(
    readFileSync(join(REPO_ROOT, "runtime", "package.json"), "utf8"),
  ).devDependencies.typescript;
  // Verbatim, not re-derived: the `^6` cap is load-bearing (typescript 7 dropped
  // the JavaScript compiler API the SPA slicer calls), so widening it here would
  // publish a package whose slicer silently falls back forever.
  assert.equal(dep.typescript, declared);
  assert.match(dep.typescript, /\^6\./);
});

test("zigbaseDepFromZig tracks pinned_version, on the scoped package", () => {
  const dep = zigbaseDepFromZig(REPO_ROOT);
  // The scoped package, never the bare `zigbase` alias: the alias was published
  // once, so 0.12.0 is the only version it will ever have and it cannot follow
  // a pin — including past the pin's current value, which happens to be 0.12.0.
  assert.deepEqual(Object.keys(dep), ["@zigbase/server"]);
  // Exact, and with the Zig side's leading `v` stripped — `v0.12.0` is not a
  // semver range and npm would reject it.
  assert.match(dep["@zigbase/server"], /^[0-9]+\.[0-9]+\.[0-9]+$/);
  const pinned = readFileSync(join(REPO_ROOT, "src", "cli", "zigbase.zig"), "utf8").match(
    /pinned_version\s*=\s*"v?([0-9.]+)"/,
  )[1];
  assert.equal(dep["@zigbase/server"], pinned);
});

test("bunDepFromMise turns the mise pin into a caret range", () => {
  assert.deepEqual(bunDepFromMise(REPO_ROOT), { bun: "^1.2" });
});

test("each derivation throws rather than returning empty when its source changes", () => {
  // A parser that stops matching must fail loudly: silently returning {} makes
  // the gate pass while checking nothing, which is the failure mode these
  // anti-vacuity throws exist for.
  const dir = mkdtempSync(join(tmpdir(), "zigapagos-toolchain-src-"));
  try {
    mkdirSync(join(dir, "runtime"), { recursive: true });
    mkdirSync(join(dir, "src", "cli"), { recursive: true });
    writeFileSync(join(dir, "runtime", "package.json"), JSON.stringify({ name: "@z/runtime" }));
    // The version here is deliberately meaningless: what this fixture breaks is
    // the DECLARATION NAME, so any version-shaped literal exercises it equally.
    writeFileSync(join(dir, "src", "cli", "zigbase.zig"), "pub const other = \"v0.0.1\";\n");
    writeFileSync(join(dir, "mise.toml"), "[tools]\nzig = \"0.16.0\"\n");
    assert.throws(() => runtimeDepsFromPackageJson(dir), /declares no dependencies/);
    assert.throws(() => zigbaseDepFromZig(dir), /could not read `pinned_version`/);
    assert.throws(() => bunDepFromMise(dir), /could not read the bun pin/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
