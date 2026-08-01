> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/runtime-dependencies/> — the site is the canonical reading experience.

# Runtime dependencies

`zigapagos` is a standalone executable. `zig build` builds *zigapagos*; it does
not build websites. Nothing in a Zigapagos project is a Zig build graph, and
**no Zig toolchain is needed to build a site** — download the precompiled binary
from the [releases page](https://github.com/valthon/zigapagos/releases), or run
`npx zigapagos`.

What the binary does need at run time is two external programs, and it needs
each of them only for specific work:

- **[Bun](https://bun.sh)** — server-renders islands and SPAs, bundles their
  client code, minifies CSS, and typechecks island props. Only `release` shells
  out to it (and `dev`, through the `release` it re-runs).
- **[ZigBase](https://github.com/valthon/zigbase)** — the HTTP server `dev` and
  `e2e` serve the built tree with. Zigapagos has no bundled server of its own.

Plus one thing that is not a program: the **`@z/runtime` source tree**, which
the Bun sidecar and the bundlers are scripts *inside*. See
[the runtime tree](#the-runtime-tree) — it is the piece that a release-archive
install has to supply for itself.

## What each command needs

Exhaustive: every command the binary accepts, and the external programs it
requires to complete successfully. `zigapagos` with no command at all prints the
help menu and exits 0, and needs nothing.

| Command | Bun | ZigBase | Notes |
| --- | --- | --- | --- |
| `zigapagos init` | no | no | Writes a sample site. Pure file I/O. |
| `zigapagos migrate` | no | no | Scans an Astro project and writes `MIGRATION.md`. It converts nothing and runs nothing. |
| `zigapagos doctor` | no | no | Reads a built tree. |
| `zigapagos validate` | no | no | Parse + analyze in memory, deliberately without a sidecar. |
| `zigapagos explain` | no | no | Route introspection, same memory build. |
| `zigapagos release` | **conditional** | no | See [when `release` needs Bun](#when-release-needs-bun). |
| `zigapagos dev` | **conditional** | **yes** | Rebuilds with `release` (so it inherits that condition) and serves the tree. |
| `zigapagos e2e` | no | **yes** | Serves an already-built tree and runs your command against it. |
| `zigapagos develop` | **conditional** | **yes** | A second spelling of `dev`. |
| `zigapagos debug` | no | no | Dumps the parsed content graph. Not in the help menu; internal. |
| `zigapagos languages` | no | no | Prints the code-fence language registry. |
| `zigapagos explain-code` | no | no | Prints a diagnostic code's long form. |
| `zigapagos help` | no | no | Also `-h` / `--help`. |
| `zigapagos version` | no | no | Also `-v` / `--version`. |

### When `release` needs Bun

`release` spawns the island sidecar when — and only when — it has all three of a
Bun path, a sidecar script and an island source directory. Two ways that
happens:

1. You passed `--island-sidecar=` yourself. That one flag arms it: `--bun=`
   and `--island-src-dir=` then default to `bun` on `PATH` and `.` unless you
   set them too.
2. `ZIGAPAGOS_RUNTIME_DIR` is set, which fills all three in for you. An `npx
   zigapagos` install always sets it (the launcher points it at the runtime tree
   it ships).

**The condition is the configuration, not the content.** With
`ZIGAPAGOS_RUNTIME_DIR` set, a site containing zero `.island.tsx` and zero
`.spa.tsx` files still spawns the sidecar, and fails if Bun is missing:

```
error: island sidecar interpreter not found: 'bun'
  the sidecar script '…/runtime/sidecar/standalone.ts' resolves — the missing thing is the interpreter itself.
```

So "a content-only site needs no Bun" is true of the *binary invoked without a
runtime tree* — a from-source checkout that does not export the variable, or a
release-archive binary — and not of an npm install. Unset the variable if you
want a content-only build on a machine with no Bun.

Three further pieces of `release` are Bun-driven and each is opt-in:

- `--css-minify-driver=PATH` — minifies `.css` site assets. Omit it and CSS is
  copied verbatim, which is what `dev`'s default rebuild does.
- `--island-props-check=warn|error` — runs `bun x tsc` over generated
  assignability checks. `bun x` resolves `typescript` at run time, from
  `node_modules` if it is there and from the npm registry (network) if it is
  not.
- SPAs additionally use `typescript` for the per-SPA runtime slice. That one
  degrades rather than failing: if `typescript` cannot be resolved, the slicer
  writes a fallback manifest and every SPA page loads the full shared runtime.

### How Bun is obtained

Any Bun on `PATH` works; `--bun=PATH` overrides the search. The repository pins
`bun = "1.2"` in `mise.toml`, and that pin is what the npm package's `bun`
dependency range is derived from.

- `npm i zigapagos` installs Bun as an optional dependency, and the launcher
  appends its `node_modules/.bin` to `PATH` — appended, so a Bun you put on
  `PATH` deliberately still wins.
- Otherwise install it yourself: `npm i -D bun`, Bun's own installer, or your
  package manager.

### How ZigBase is obtained

The locator tries three places in order: `--zigbase=PATH`, then `zigbase` on
`PATH`, then the pinned release in the cache.

The pinned release is **v0.12.0** from `valthon/zigbase`, cached at:

```
$XDG_CACHE_HOME/zigapagos/zigbase/v0.12.0/zigbase
```

falling back to `$HOME/.cache/zigapagos/zigbase/v0.12.0/zigbase` when
`XDG_CACHE_HOME` is unset, and `%LOCALAPPDATA%\zigapagos\zigbase\v0.12.0\zigbase.exe`
on Windows. Dropping a binary there yourself works; nothing else looks at the
directory.

Who fetches it differs by command, deliberately:

- **`dev` fetches by default.** It is the zero-config entry point and cannot
  start without a server. `--no-download` turns that off and fails with
  instructions instead — the escape hatch for offline and air-gapped machines,
  and for CI that pins its own binary.
- **`e2e` never fetches unless asked** (`--download-zigbase`). It runs in CI,
  where an unannounced network fetch is a supply-chain surprise rather than a
  convenience.

The fetch shells out to **`curl`** and **`tar`**, so both must be on `PATH` for
it to work. The tarball's SHA256 is verified in-process against the release's
published `SHA256SUMS` before anything is extracted, and a mismatch is fatal.

Four host platforms have a release asset zigapagos knows how to name — x86_64
and aarch64, on Linux (musl) and macOS. On any other host there is nothing to
fetch, and the fetch says so instead of guessing: install ZigBase yourself, or
pass `--zigbase=`.

If you install zigapagos from npm you already have ZigBase: `@zigapagos/cli`
depends on `@zigbase/server` at exactly the pinned version, and a gate
(`npm/check-toolchain.mjs`) fails the build if that range and
`src/cli/zigbase.zig`'s pin ever disagree — otherwise `dev` would run a
different server depending on how you installed it.

## The runtime tree

The Bun sidecar (`sidecar/standalone.ts`), the island and SPA bundle drivers,
the runtime slicers and the host-config emitter are all **scripts inside the
`@z/runtime` tree**. The binary is told where that tree is by one environment
variable:

```sh
export ZIGAPAGOS_RUNTIME_DIR=/path/to/runtime
```

Set it and the island paths, `--bun`, and the island source directory all
default themselves, entry discovery for `*.island.tsx` / `*.spa.tsx` turns on,
and SPAs can have their client half built. Leave it unset and the binary can
still prerender a SPA and render a page's islands *if* you point the
`--island-*` flags at a tree yourself, but it has no defaults to fall back on.

**`@z/runtime` is not on npm and cannot be installed.** `runtime/package.json`
carries `"private": true`, and it is a workspace-internal package, not a
published one. That is unchanged, and it is why "just install Bun from npm" is
not sufficient advice on its own: Bun without a runtime tree cannot render an
island, because the script Bun would run does not exist on your disk.

There are exactly two places the tree comes from:

- **`@zigapagos/cli`** ships it inside itself, at
  `node_modules/@zigapagos/cli/runtime/`, staged from this repository's own
  `runtime/` at publish time. The launcher sets `ZIGAPAGOS_RUNTIME_DIR` to it.
- **A checkout** has it at `runtime/`. `site/build.sh` and
  `examples/tsx-site/build.sh` both export it that way.

A binary from a release archive has neither, which is the next section.

## What each distribution gives you

| | `npx zigapagos` / `npm i zigapagos` | release archive | `git clone` + `zig build` |
| --- | --- | --- | --- |
| `zigapagos` binary | yes | yes | you build it |
| `@z/runtime` tree | yes, and `ZIGAPAGOS_RUNTIME_DIR` is set for you | **no** | yes, at `runtime/`; export the variable yourself |
| Bun | yes (optional dependency) | **no** | `mise install` |
| ZigBase | yes (optional dependency, pinned version) | fetched on first `dev` | fetched on first `dev` |
| `typescript` | yes (optional dependency) | **no** | `runtime/` devDependency |
| Zig toolchain | not needed | not needed | required, 0.16.0 |
| Node.js | required (>= 18) to run the launcher | not needed | not needed |

The **release archive contains the binary and nothing else** — one file, no
runtime tree. Everything in the command table that says "no" under Bun works
from an archive with no further setup, as does `dev` (it fetches ZigBase). What
does *not* work out of the archive is islands and SPAs: for those, get the
`@z/runtime` tree from an `@zigapagos/cli` install or a checkout, and point
`ZIGAPAGOS_RUNTIME_DIR` at it.

npm is a distribution mechanism, not a different product. It exists so that one
`npm i` produces a working install of *all* of the above; it does not enable any
capability the binary does not otherwise have. See
[`npm/README.md`](../npm/README.md) for the package layout, the platform matrix,
and the install size.

## Keeping this page true

A page about what to install is the most drift-prone document a tool can have:
nothing in an ordinary change breaks it, nothing in an ordinary review reads it,
and the person it misleads is the one least able to notice. So the facts above
are checked against the sources they came from by
[`tests/meta/runtime-deps-doc.sh`](../tests/meta/runtime-deps-doc.sh), which
runs in CI with every other `tests/*/*.sh` script. It asserts that the command
table is exactly the binary's command set, that the pinned ZigBase version and
its cache path match `src/cli/zigbase.zig`, that the environment variable
matches `src/cli/release.zig`, that `@z/runtime` is still private, that a
release archive still carries the binary alone, and that every flag named above
is still one the binary parses. Its own failure modes are pinned by
[`tests/meta/runtime-deps-doc.test.sh`](../tests/meta/runtime-deps-doc.test.sh).
A claim here that stops being true fails the build.
