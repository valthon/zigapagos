# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Toolchain

`mise.toml` pins **zig 0.16.0** and **bun 1.2**; `build.zig.zon` sets
`.minimum_zig_version = "0.16.0"`. Your shell is expected to resolve those — the commands below are
written bare.

If `zig` resolves to a different version, the build fails at *configure* time with a wall of
dependency errors (`std.Io.Dir`, `Child.StdIo`, `Build.Graph.io`). They look like code defects and
are pure version skew, so check `zig version` before believing them.

**Do not add a repo-level `.tool-versions`.** `mise.toml` is the single source of truth and mise
reads it directly; a second file beside it is a version pin that can silently drift.

The repo tracks *released* Zig, not nightlies. CI runs ubuntu + macOS only: Windows is dropped
because upstream's `WindowsWatcher.zig`/`wuffs.zig` don't compile on stable 0.16.0, and is slated to
return with the Zig 0.17 port at the next upstream release-tag sync (see `docs/ROADMAP.md`).

### Verifying a command actually passed

Two shell facts worth internalising, because both yield a *plausible wrong answer* rather than an
error — and this repo's gates are all exit-code checks:

- **`cmd | tail` reports `tail`'s exit status, not `cmd`'s.** Run unpiped and check `$?`, or capture
  to a file and read it. `${PIPESTATUS[0]}` is a bashism that expands empty under zsh.
- **zsh does not word-split unquoted `$VAR`**, so `for f in $FILES` iterates once over the whole
  string. Pipe into `while IFS= read -r`, or use an array.

## Commands

```sh
zig build                      # → zig-out/bin/zigapagos
zig build test                 # SNAPSHOT tests only — see below
zig build check                # compile exe + all test binaries, run nothing
zig build check -Dsingle-threaded   # required guard, see below
zig build api-check            # fail if contract/generated drifted from the schema
cd runtime && bun install --frozen-lockfile   # ONCE per fresh worktree
cd runtime && bun test         # TypeScript suite (685 tests)
cd runtime && bun test src/router   # one file — filter is a PATH substring
bash scripts/check-allocator-contracts.sh   # allocator-contract gate (see NO_SLOP.md §2.2a)
bash scripts/check-allocator-contracts.test.sh   # the gate's own self-tests
bash tests/spa/prerender-order.sh           # one shell e2e script
bash site/build.sh                          # build the marketing site
bash examples/tsx-site/build.sh             # build the tsx example
```

**`zig build` builds ZIGAPAGOS, never a website.** There is no consumer build API: a site is
built by RUNNING the binary, and `site/build.sh` / `examples/tsx-site/build.sh` are the two
worked invocations — one place each where that project's islands and SPAs are declared. Both
honour `ZIGAPAGOS_BIN` and otherwise fall back to compiling `zig-out/bin/zigapagos` once.
Both also export `ZIGAPAGOS_RUNTIME_DIR=<repo>/runtime`, which is where the sidecar, the
bundlers and both runtime slicers come from; without it a `--spa` entry cannot be bundled at
all (only prerendered).

**`zig build test` does NOT run the unit tests.** It builds the three-root snapshot fixtures and
diffs them. The Zig unit tests live in seventeen separate steps, and CI runs them explicitly:

```sh
zig build test-islands test-props test-migrate test-sidecar test-init \
  test-release test-debug test-spa test-assets test-e2e test-dev \
  test-doctor test-slugs test-validate test-explain test-diag test-summary
```

**Running a single test.** Each `test-*` step is already a *filtered slice* of one test binary.
In Zig 0.16 `filters` is a **compile-time** option (passed to the compiler as `--test-filter`),
declared per step in `build/tests.zig` — there is no runtime flag to narrow a run. To isolate one
test, run its suite step, or temporarily narrow that step's `filters` in `build/tests.zig`.

**`-Dsingle-threaded` is a real gate, not ceremony.** Single-threaded paths are comptime-pruned
from the default build, so `check -Dsingle-threaded` compiles the exe *and every test binary* to
catch rot in test-only code. A test that reaches `std.Thread.spawn` is a hard `@compileError`
there. A runtime `return error.SkipZigTest` does **not** help — Zig analyses the whole function
body regardless of runtime control flow — so prune the branch at comptime:
`if (comptime !builtin.single_threaded) …`.

**Shell e2e.** CI runs every `tests/*/*.sh` (currently 46). They are hermetic; `tests/dev/*`
boot real servers via a stub-zigbase binary and need `bun` on `PATH`. A new `tests/<area>/` is
picked up by the glob automatically. `tests/branding.sh`, `tests/branding.test.sh` and
`tests/confidentiality.sh` sit at `tests/` top level on purpose — they are cheap gates CI runs
early, outside that glob, and are therefore named explicitly in `ci.yml`'s `gates` job.

The branding gate takes an inline opt-out: `<!-- branding-ok: why -->` sanctions the upstream
name on that line, and `<!-- branding-ok:begin why -->` / `<!-- branding-ok:end -->` sanctions a
block. A reason is required, an unbalanced block fails, and a marker that exempts nothing fails
as stale — so it is an exemption you have to justify, not a mute button.

**A fresh git worktree needs `bun install` in `runtime/` before anything bun-dependent.** Without
it `bun test` reports every file as failing (`0 pass / 54 fail`, an `ENOENT resolving 'typescript'`
per file) and `examples/tsx-site/build.sh` dies in the SPA-runtime step — both look like code
breakage and are neither.

**Formatting is gated, with no exceptions.** The whole first-party tree is `zig fmt`-clean and CI
enforces it as its first Zig step:

```sh
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
```

Run that before pushing. The file list comes from `git ls-files` rather than a directory walk on
purpose: `zig-pkg/` is a **gitignored** tree of materialized third-party dependencies, so a
path-based invocation passes on a clean checkout and then starts failing on vendored source as
soon as anything populates it. Never reformat it.

Note `zig fmt` rewrites manually column-aligned literals into one element per line; that is the
canonical formatter's call, so take it rather than fighting it.

## Architecture

A permanent fork of [Zine](https://zine-ssg.io) (fork point `ca8f3e5`, upstream `496e42d`
v0.11.2) that adds islands architecture and native SPAs. Upstream files are kept close to
upstream where that costs nothing, because a release-tag sync is read by hand — but that is a
mild preference, not a rule. **Fix the file that is actually wrong, inherited or not.** What is
forbidden is paying daily complexity to avoid an inherited file: never add a generator, shim,
wrapper or any other indirection whose purpose is to keep a diff out of upstream code. Syncs are
infrequent and both histories get reviewed either way, so `git log` on the file is all the
tractability the rare manual merge needs — note the sync cost once in the commit message,
factually, and move on.

```
content/*.smd ──► Zig core (SuperMD/SuperHTML) ──► page HTML ─┐
components/*.island.tsx ──► Bun sidecar (SSR) ────────────────┤──► static site
                            └─► esbuild-style bundle ─────────┘    + import map + one runtime
```

**`src/root.zig` is the build orchestrator and its pass order is load-bearing.** Config validation
→ content scan → parse → analyze → **SPA prerender** → page render+emit → props-check gate →
island manifest (dev) → asset installs.

Failures in these passes become a `fatal.msg` exit and the output tree is written in place, so a
mid-build failure leaves a partially-updated tree. **Ordering therefore decides how destructive a
given failure is**, which is why the SPA prerender runs before the page pass: it is the pass that
executes the author's own code (the sidecar runs `.spa.tsx`'s `describe`/`staticPaths`) and it
holds the spec validation — overlapping bases, basename collisions, `..` in a route path, a
declared SPA with no sidecar — all of which abort before it writes its first file. Running it after
the page pass meant those failures fataled with every page already rewritten (16 of 16 on the
`tests/spa/prerender-order.sh` fixture; now 0). This is **not** atomicity: a failure partway
through *writing* shells still leaves partial output, and a page-render failure still fails after
pages are emitted.

Two constraints on any further reordering:

- **Two early returns gate the tail of the function** — `mode == .memory` (the in-memory builds
  behind `validate`/`explain` never prerender or install) and `incremental` (dev's changed-files
  fast path re-emits only changed pages). The prerender call sits *above* both, so it carries an explicit
  `if (build.mode == .disk and !incremental)` guard; anything else moved up must do the same.
- **The asset-install phase must come last**: both the page pass and the SPA prerender bump
  refcounts on `install_always` assets (e.g. `spa/<name>.js`) that the install phase reads.

Side effect of that order worth knowing: the site-wide `404.html` is written before the page pass,
so a content page explicitly aliased to `404.html` overwrites the SPA fallback rather than losing
to it.

**The render seam** is `src/worker.zig`'s `renderPage` → `src/islands/pass.zig`'s `process`: after
a page renders, `<island>` elements are tokenized, SSR'd through the sidecar, and spliced back
with a `data-z-props` JSON block, an import map, and one shared runtime script.

- `src/islands/` — `pass.zig` (tokenize/splice, comment- and raw-text-aware), `props.zig`
  (Ziggy → JSON), `props_check.zig` (tsc gate), `manifest.zig` (dev island-usage manifest),
  `sidecar.zig` (Bun subprocess client), `render_arena.zig` (see below).
- `src/spa.zig` — route skeletons, dynamic-route `_shell.html`, per-namespace routing manifests,
  site-wide `404.html`.
- `src/cli/` — `dev.zig` (the zigbase-backed dev loop), `watcher.zig` + `watcher/` (the per-OS
  file watcher and its debouncer), `reload.zig` (SSE live reload), `zigbase.zig` (the ZigBase
  locator/downloader), `migrate*.zig` / `init_from_astro.zig` (Astro importer).
- `runtime/src/` — the **shipped** first-party `@z/runtime`: SPA router, island hydration, host
  bindings. Bugs here reach every visitor's browser.
- `runtime/sidecar/` — **build-time** Bun SSR. The Zig↔Bun protocol is NDJSON over
  stdin/stdout, one request per line.
- `runtime/scripts/` — codegen (`apigen`/`apiclient`), the host-config emitters
  (zigbase/nginx/apache), runtime slicing, parity harness.
- `build.zig` is a table of contents; the real wiring is in `build/*.zig`
  (`exe`, `deps`, `tests`, `release`, `codegen`, `config`, `snapshot`, `docgen`, `camera`).
  It builds ZIGAPAGOS and nothing else: there is no consumer build API, and a website is
  built by running the binary (`site/build.sh` and `examples/tsx-site/build.sh` are the
  two worked invocations).

The behaviour these subsystems are *supposed* to have is specified in `docs/islands.md`,
`docs/spa.md`, `docs/assets.md`, `docs/cross-tier-codegen.md`, `docs/observability.md` and
`docs/migration/*.md`.
`docs/migration/` is written as a deterministic mapping spec so an agent can complete an
Astro→zigapagos port unattended — read it before changing the importer.

**Module-root constraint (Zig 0.16).** `src/islands/props.zig` and `src/islands/sidecar.zig` are
the root source files of their own test modules (`test-props`, `test-sidecar`), and Zig rejects an
import that escapes a module's own directory. This is why `render_arena.zig` lives in
`src/islands/` despite being used from `spa.zig`, `root.zig`, `worker.zig` and `src/cli/` —
moving it to `src/` breaks those two suites. The same rule is why `src/cli/migrate_detect.zig`
(root of `test-migrate`) cannot adopt the type at all.

## Review standard

`NO_SLOP.md` is the quality bar every change is reviewed against. Its load-bearing section is
**§2.2a, allocator ownership** — four contracts, and every allocator-taking function must be
exactly one of them and say which:

1. **Self-freeing** — frees all scratch, one allocation escapes as the return. Correct under any
   allocator. The default.
2. **Owned-result** — result owns a graph, caller `deinit`s.
3. **Caller-buffer** — allocates nothing.
4. **Arena-scoped** — takes `RenderArena` (`src/islands/render_arena.zig`), not an `Allocator`,
   so a GPA cannot flow in by accident. Requires a written justification.

`RenderArena.from(*std.heap.ArenaAllocator)` is the production constructor;
`RenderArena.forTest(std.testing.allocator)` lets a test satisfy an arena-scoped signature while
keeping **leak detection on**. Wrapping the testing allocator in a real arena disables Zig's leak
detector for that test — every such site needs a row with a justification in
`scripts/allocator-allowlist.txt`, and the gate fails the build on a new one. Before assuming a
function needs an arena, check whether it is actually contract 1; most of the original allowlist
turned out to be contract-1 helpers whose tests simply shouldn't have been arena-wrapped.

## Repo conventions

- **`gh` defaults to the `kristoff-it/zine` upstream remote.** Always pass
  `--repo valthon/zigapagos` to `gh pr create` and friends.
- `gh issue view` / `gh pr edit` fail on this repo with a Projects-classic GraphQL error — use
  `gh api` REST instead (e.g. `gh api -X PATCH repos/valthon/zigapagos/pulls/N -f body=…`).
- Never push to `main`, force-push, or merge.
- Commit messages explain the defect and the reasoning, not just the change; several fixes cite
  audit IDs (`AUD-*`, `AUDF-*`) and issue numbers, and the codebase's comments carry the *why*.
  Match that density.
- Regression tests must be verified to **fail without the fix** — that is the only way to know
  they pin anything.
