# npm distribution

Publishes the `zigapagos` binary to npm, so a site can be scaffolded and built with
`npx zigapagos` and no Zig toolchain. Three package shapes, all released together at
the version in `build.zig.zon`:

| package | what it is |
| --- | --- |
| `@zigapagos/cli-<key>` | one per release target; carries the prebuilt binary and nothing else, with `os`/`cpu` set so npm installs exactly one |
| `@zigapagos/cli` | **the canonical package**: the resolver (`cli/index.js`), the `zigapagos` launcher, `optionalDependencies` pinned to the exact version of every platform package, and `os`/`cpu` set to the union of theirs so an unsupported host fails at install time |
| `zigapagos` | the bare name, an **alias**: depends on `@zigapagos/cli` at the same exact version and re-enters its launcher in three lines |

The unscoped name is an alias rather than the primary package for one reason: the
scoped name is where the version, the resolver and the platform packages have to
agree, and a second implementation of that agreement is a second thing to keep in
sync. `zigapagos` therefore holds no resolver, no `main`, and no platform
dependencies — deleting it would cost `npx zigapagos` and nothing else.

The same distribution strategy as `esbuild`: a meta package whose
`optionalDependencies` are per-platform binary packages, resolved at run time.

## What is committed, and what is generated

Committed:

```
npm/cli/targets.json          the npm side of the release matrix (gated, see below)
npm/cli/index.js              platform resolution, and the reason for each refusal
npm/cli/bin/zigapagos.js      the launcher: exec the binary, propagate its exit code
npm/zigapagos/bin/zigapagos.js   the alias's hand-off
npm/gen-packages.mjs          generates every package.json + README
npm/check-targets.mjs         the release-target drift gate
npm/check-toolchain.mjs       the dependency-range drift gate
npm/publish.mjs               assemble, verify, pack, publish
npm/gen-packages.test.mjs     unit tests for the generator and both gates' parsers
```

Generated and gitignored: every `package.json`, every `README.md` under
`cli/`, `cli-*/` and `zigapagos/`, the binaries in `cli-*/`, and `cli/runtime/`.
Run `node npm/gen-packages.mjs` to produce the manifests; never edit them.

`cli/runtime/` is the `@z/runtime` + Bun-sidecar tree that `@zigapagos/cli` ships so
an npm-only install can SSR and bundle islands. `publish.mjs` stages it from the
repository's own `runtime/` on every run — it is not committed, for the same reason
the manifests are not: a second copy in the tree is a copy that can drift from the
`runtime/` the test suite actually exercises. `*.test.ts` and `test/` are excluded
(their fixtures import `react`, `@acme/greeting` and `my-store`, which nothing we
ship depends on); `src/testing/` is kept, because it is a target of
`runtime/package.json`'s `exports` map and that map is what makes the sidecar's
`@z/runtime` self-reference resolve.

## The target matrix lives in three places, and a gate keeps them equal

`build/release.zig` decides **what** ships. `.github/workflows/release.yml`'s matrix
decides **where** each target is built and what its archive is called.
`npm/cli/targets.json` decides what npm **publishes**. Adding a target means editing
all three.

`npm/check-targets.mjs` fails when they disagree, and derives the npm `key`/`os`/`cpu`
and the archive filename from the zig triple rather than trusting `targets.json` — so
a hand-edited row cannot invent a mapping. It runs in CI through
`tests/npm/targets.sh` (which also self-tests each failure mode) and again in the
release workflow before anything is packed.

Today's matrix is two targets, `x86_64-macos` and `x86_64-linux-musl`, because those
are the two that build on released Zig 0.16.0 — see the comment in
`build/release.zig` for why each of the other six is out and what has to be fixed
first.

## arm64 is a hard failure, on both operating systems

There is no aarch64 release build, and an arm64 host therefore gets **no package**
— not the x86_64 one. Apple Silicon could run the x64 binary under Rosetta 2, and
an earlier revision of this channel mapped `darwin-arm64` onto `darwin-x64` for
exactly that reason; it was removed deliberately. Substituting an architecture is
invisible: the build is slower, anything the binary shells out to sees a different
`process.arch`, and nothing in the output distinguishes an emulated build from a
native one. A build tool that quietly changes what it is cannot be debugged from
its output, so the package refuses the host and names the reason instead.

Both arm64 hosts are refused through one code path and one string
(`AARCH64_REASON` in `cli/index.js`), and the refusal happens twice, deliberately:

- at **install** time — the two launcher packages declare the `os`/`cpu` union of the
  platform packages, so `npm install` on arm64 fails with `EBADPLATFORM` instead of
  installing a launcher whose every platform package npm silently skipped;
- at **run** time — `resolveTarget()` throws for anyone who installed past that
  (`--force`), naming the missing aarch64 build and pointing at the from-source
  path.

One fact, so nobody re-derives it as a bug report: a `node` process running under
Rosetta reports `darwin-x64` and therefore resolves the x64 package and works. That
is a property of the host, not a supported configuration, and nothing here looks
for it.

**When native arm64 lands**: add `aarch64-macos` to `build/release.zig`, the
workflow matrix and `targets.json`, and delete the `darwin-arm64` row from
`FALLBACK_ROWS` and its entry in `UNSUPPORTED_REASON`. The generated platform table
drops a fallback row automatically once a native target for its key exists —
`npm/gen-packages.test.mjs` pins that — so a half-done removal shows up as a
contradiction between the code and the docs rather than as stale prose.

## The dependency ranges are derived, and a second gate keeps them derived

`@zigapagos/cli` declares four dependencies, and none of their versions is a number
this directory chooses: `preact` and `preact-render-to-string` come from
`runtime/package.json` (the CLI ships those sources, so their imports are its
imports), `@zigbase/server` from `pinned_version` in `src/cli/zigbase.zig`, and `bun`
from the `[tools]` pin in `mise.toml`. `gen-packages.mjs` reads all four rather than
restating them.

The zigbase one is the reason this gate exists. npm installs the declared range and a
`PATH` miss downloads the pin, so a divergence would leave `zigapagos dev` running a
different zigbase depending on how the user installed zigapagos. Note it must be the
**scoped** `@zigbase/server`: the bare `zigbase` alias was published exactly once, so
`0.12.0` is the only version it will ever have and it cannot follow a pin. It equals
the pin today, which is why the gate rejects the alias on presence rather than on the
version it resolves to — and since these are *optional* dependencies, npm skips a range
it cannot resolve without failing the install, so the next bump would split the two
install paths silently.

`npm/check-toolchain.mjs` generates the manifest through the tree's own generator and
checks it against parsers of its own — deliberately not the generator's, since a
generator that hardcoded a version in both places would agree with itself while
disagreeing with the Zig source. `tests/npm/toolchain.sh` self-tests it.

## Local verification

```sh
node npm/check-targets.mjs                 # the release-target drift gate
node npm/check-toolchain.mjs               # the dependency-range drift gate
node --test npm/gen-packages.test.mjs      # generator + parser unit tests
bash tests/npm/targets.sh                  # the target gate's own failure cases
bash tests/npm/toolchain.sh                # the dependency gate's own failure cases
bash tests/npm/packaging.sh                # pack, INSTALL, and run both packages
node npm/gen-packages.mjs                  # write the manifests locally
```

`tests/npm/packaging.sh` is the one that matters: it packs the tree, installs the
tarballs into throwaway projects with `npm install --offline`, and runs the
`zigapagos` command through both `@zigapagos/cli` and the bare alias — with a stub
binary for argv/exit-code assertions and with the real binary for the rest. It needs
`node` (>= 18) and `npm` on `PATH`; neither is in `mise.toml`, because node is not a
zigapagos build dependency, only the runtime of this distribution channel.

## Releasing

npm publishing hangs off the existing `v*` tag release. The workflow **consumes the
archives the release already builds** — it does not rebuild — so the bytes on npm are
the bytes in the GitHub release.

On any run of `release.yml` (tag, `workflow_dispatch`, or a PR touching the release
plumbing) the `npm-package` job assembles the tree from those archives, packs all
three packages and runs the install e2e against the real ReleaseFast binary. Nothing
is uploaded. That is the smoke test; a broken package is caught on the PR that broke
it rather than on a tag that cannot be un-pushed.

### Two gates stand between a tag and the registry

1. The repository **variable** `NPM_PUBLISH_ENABLED` must be `true`. Absent (the
   current state), the `publish-npm` job is skipped and a tag ships the GitHub
   release exactly as it does today.
2. The repository **secret** `NPM_TOKEN` must exist. If the variable is set and the
   secret is not, the job fails immediately with an explanatory error rather than
   attempting a publish.

`npm/publish.mjs` is also opt-in on its own: with no flags it assembles and verifies
and touches no registry. Only `--publish` uploads.

### First publish (a human, once)

Automation cannot do this part: the `@zigapagos` org has to exist and someone has to
be logged in.

1. Create the `@zigapagos` org (or scope) on npmjs.com with publish rights for the
   releasing account. `zigapagos` and `@zigapagos/*` were unclaimed as of
   2026-07-29 — check again before relying on that.
2. `npm login`.
3. Rehearse locally from a checkout at the tag, with the release archives in `dist/`
   (`gh release download v<version> --dir dist`):

   ```sh
   node npm/publish.mjs --archives dist --pack /tmp/zigapagos-tarballs
   ```

   That assembles, verifies and packs; inspect the tarballs (`tar tzf`) before going
   further.
4. Publish, in this order — the script does it for you and skips anything already on
   the registry, so a partial run is safe to re-run:

   ```sh
   node npm/publish.mjs --archives dist --publish
   ```

   Order matters: the platform packages must exist before `@zigapagos/cli` is
   installable, and `@zigapagos/cli` before the `zigapagos` alias is.

   A scoped package's **first** publish is `restricted` unless told otherwise. Both
   the generated `publishConfig.access` and the explicit `--access public` the script
   passes cover that; if you publish by hand, pass it yourself.
5. Then set `NPM_PUBLISH_ENABLED=true` and `NPM_TOKEN` in the repository settings, so
   subsequent tags publish themselves.
