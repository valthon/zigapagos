# Contributing to Zigapagos

Thanks for looking. This is a solo-maintained, pre-1.0 project, so the most
useful thing this document can do is stop you losing an afternoon to something
that is a property of the build rather than a bug in your patch. There are two
such traps and they are both in "Build and test" below — read that section even
if you skip the rest.

## Scope: what belongs here and what belongs upstream

Zigapagos is a **permanent fork** of an existing Zig static-site generator, and
the fork exists because of a design disagreement, not neglect: upstream is
deliberately JavaScript-free, and this project embraces a minimal TSX toolchain
(Bun, a Preact-compatible `@z/runtime`) to get islands and client-routed SPAs.
See the README's Acknowledgements for the upstream project and `docs/ROADMAP.md`
for the sync policy (release tags only, never upstream main).

The practical consequence for a contributor:

- **Fork-owned surface — bring it here.** `src/islands/`, `src/spa.zig`,
  `src/cli/serve.zig`, `src/cli/dev.zig`, `src/cli/reload.zig`,
  `src/cli/migrate*.zig`, `src/cli/init_from_astro.zig`, all of `runtime/`, and
  the `build/` wiring for those.
- **Inherited core — consider upstream first.** The SuperHTML/SuperMD templating
  and content pipeline, the Ziggy frontmatter layer, the site graph. A fix there
  helps far more people upstream and comes back to us at the next release-tag
  sync. Upstream files are also kept deliberately clean so those syncs stay
  tractable, so a change to one needs a reason why it could not live in
  fork-added code. (Concretely: a request-path bound belongs in
  `src/cli/serve.zig`'s guard, not in the inherited `src/PathTable.zig`.)

## Prerequisites

`mise.toml` pins the toolchain and is the single source of truth:

```
zig = "0.16.0"
bun = "1.2"
```

```sh
mise install          # or install zig 0.16.0 + bun 1.2 yourself
```

This repo tracks **released** Zig, not nightlies — `build.zig.zon` sets
`.minimum_zig_version = "0.16.0"`. If `zig` resolves to some other version the
build fails at *configure* time with a wall of dependency errors mentioning
`std.Io.Dir`, `Child.StdIo` or `Build.Graph.io`. They look like real defects and
are pure version skew, so check `zig version` before believing them. Do not add a
repo-level `.tool-versions`: a second pin beside `mise.toml` can silently drift.

CI runs ubuntu and macOS only. Windows is dropped because inherited upstream code
(`src/cli/serve/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile on
stable 0.16.0; it returns with the Zig 0.17 port.

## Build and test

```sh
zig build                                      # → zig-out/bin/zigapagos
cd runtime && bun install --frozen-lockfile     # ONCE per fresh clone/worktree
```

**Trap 1: `zig build test` does not run the unit tests.** It builds the
three-root snapshot fixtures and diffs them. The Zig unit tests live in **eleven
separate steps**, and this is the command you actually want:

```sh
zig build test-islands test-props test-migrate test-sidecar test-init \
  test-release test-spa test-assets test-serve test-e2e test-dev
```

**Trap 2: a fresh clone or git worktree needs `bun install` in `runtime/` before
anything Bun-dependent.** Without it `bun test` reports every file as failing
(`0 pass / 54 fail`, one `ENOENT resolving 'typescript'` per file) and an
`examples/tsx-site` build dies in the SPA-runtime step. Both look like code
breakage and are neither.

```sh
cd runtime && bun test              # TypeScript suite (616 tests / 54 files)
cd runtime && bun test src/router   # one file — the filter is a PATH substring
```

### Running a single Zig test

You can't, not with a flag. Each `test-*` step is already a *filtered slice* of
one test binary, and in Zig 0.16 `filters` is a **compile-time** option (handed
to the compiler as `--test-filter`) declared per step in `build/tests.zig`. There
is no runtime equivalent. So either run the narrowest suite step that covers your
test, or temporarily narrow that step's `filters` in `build/tests.zig` while you
iterate — and revert it before you push.

### `-Dsingle-threaded` is a real gate

```sh
zig build check                    # compile exe + all test binaries, run nothing
zig build check -Dsingle-threaded  # the gate
```

Single-threaded paths are comptime-pruned from the default build, so `check
-Dsingle-threaded` compiles the exe *and every test binary* to catch rot in
test-only code. A test that reaches `std.Thread.spawn` is a hard `@compileError`
there, and a runtime `return error.SkipZigTest` does **not** help — Zig analyses
the whole function body regardless of runtime control flow. Prune the branch at
comptime instead: `if (comptime !builtin.single_threaded) …`.

## The local gate, before you open a PR

CI runs all of this; running it locally is much faster than round-tripping a red
build. In order of how quickly it fails:

```sh
# 1. cheap text gates (no toolchain needed)
bash tests/branding.sh                            # no stray upstream-name references
bash tests/confidentiality.sh                     # no references to the author's private project
bash scripts/check-allocator-contracts.test.sh    # the gate's own self-tests
bash scripts/check-allocator-contracts.sh         # allocator-contract gate, NO_SLOP.md §2.2a
bash scripts/assemble-changelog.test.sh           # changelog assembler self-tests

# 2. formatting — gated with no exceptions
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check

# 3. Zig
zig build test                                    # snapshot diff
zig build check -Dsingle-threaded
zig build test-islands test-props test-migrate test-sidecar test-init \
  test-release test-spa test-assets test-serve test-e2e test-dev
zig build api-check                               # if contract/ or apigen.ts changed

# 4. TypeScript + shell e2e
(cd runtime && bun install --frozen-lockfile && bun test)
for s in tests/*/*.sh; do bash "$s" || echo "FAIL $s"; done   # 13 scripts, hermetic
```

Notes on the ones with sharp edges:

- **The formatting file list comes from `git ls-files`, not a directory walk.**
  `zig-pkg/` and `examples/tsx-site/zig-pkg/` are **gitignored** trees of
  materialized third-party dependencies, so a path-based `zig fmt` invocation
  passes on a clean checkout and then starts failing on vendored source the
  moment a build populates them. Never reformat those. Also note `zig fmt`
  rewrites hand-column-aligned literals to one element per line; that is the
  canonical formatter's call — take it.
- **The shell e2e are hermetic but not free.** `tests/serve/*` boot real servers
  against a stub `zigbase` and need `bun` on `PATH`. A new `tests/<area>/*.sh` is
  picked up by CI's glob automatically. `tests/branding.sh` and
  `tests/confidentiality.sh` deliberately sit at the `tests/` top level, outside
  that glob, because CI runs them early as cheap gates.
- **Check exit codes, not output.** Every gate here is an exit-code check, and
  two shell facts each yield a *plausible wrong answer* rather than an error:
  `cmd | tail` reports `tail`'s status, not `cmd`'s (and `${PIPESTATUS[0]}`
  expands empty under zsh); and zsh does not word-split unquoted `$VAR`, so
  `for f in $FILES` iterates once over the whole string.

## The code-quality bar

**[`NO_SLOP.md`](NO_SLOP.md) is the standard every Zig change is reviewed
against.** Read it before requesting review. It is a distillation of the
idiomatic-Zig bar — explicit allocators, no swallowed errors, precise error sets,
no hidden control flow, correctness reasoned past "the tests are green".

Its load-bearing section is **§2.2a, allocator ownership.** Every
allocator-taking function must be exactly one of four contracts, and must say
which:

1. **Self-freeing** (the default) — `fn f(alloc, …) ![]u8`. Frees all scratch;
   exactly one allocation escapes, the return value. Correct under *any*
   allocator.
2. **Owned-result** — `fn f(alloc, …) !Result` with `Result.deinit(alloc)`. The
   result owns an internal graph; the caller deinits.
3. **Caller-buffer** — `fn f(buf: []u8, …)`. Allocates nothing. Preferred when
   the output is bounded by its input.
4. **Arena-scoped** — `fn f(arena: RenderArena, …) !T`, using the marker type in
   `src/islands/render_arena.zig`. `RenderArena` is deliberately *not* an
   `Allocator` and its production constructor takes the concrete
   `*std.heap.ArenaAllocator`, so a GPA cannot flow in by accident and the
   *compiler* checks it rather than a parameter name. This contract must be
   earned: interlinked graph, freeing individually would be pointless
   pointer-chasing, genuinely pass-scoped lifetime — plus a written
   justification. "It is currently written that way" is not one.

The bug this exists to catch is a function that allocates scratch and never frees
it: correct under a caller's arena, a leak under anything else. A plain
`std.mem.Allocator` parameter merely *named* `arena` is a smell in itself.

Two mechanical consequences for tests:

- **New tests use raw `std.testing.allocator`.** Wrapping it in an
  `ArenaAllocator` turns Zig's leak detector *off* for that test — the arena
  frees everything at `deinit`, so a missing `defer free` can never be observed.
- If a signature demands contract 4, `RenderArena.forTest(std.testing.allocator)`
  satisfies the type while keeping leak detection **on**. Reach for that first.
  `scripts/check-allocator-contracts.sh` fails on any new arena-wrapped
  testing-allocator site until it is listed with a justification in
  `scripts/allocator-allowlist.txt`; a row there is the fallback for code that
  genuinely cannot run on a GPA (a `*Leaky` parse graph with no `deinit`), not
  the default. Swapping the arena for another non-detecting allocator is not a
  fix — it hides the site from the scanner and restores no detection.

### Regression tests must be verified to fail without the fix

Write the test, run it against the *unfixed* code, watch it fail, then apply the
fix. A regression test that was never observed red pins nothing, and saying so in
the PR body ("reverting the one-line change in `pass.zig` fails this test with
…") is the evidence that it does.

## Changelog: add a fragment, never edit `CHANGELOG.md`

If your change is worth recording, add **one small file** to
[`changelog.d/`](changelog.d/) rather than editing `CHANGELOG.md`:

```markdown
<!-- changelog.d/spa-guard-cascade.md -->
### Fixed

- A route guard on a nested scope no longer runs twice on a soft navigation.
```

The filename is `changelog.d/<slug>.md`, kebab-case, usually the branch name, and
unique enough not to collide with another open PR. The body is one or more
`### <Section>` headings with bullets under them; one fragment may populate
several sections, and the recognized names (`Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, `Security`, `Known limitations`, `Internal`) with guidance on
choosing between them are in [`changelog.d/README.md`](changelog.d/README.md).

**Why the indirection.** Fragments exist so parallel PRs never conflict on
`CHANGELOG.md`. Two branches each adding their own file merge cleanly; two
branches each appending a bullet to a shared `## [Unreleased]` block collide on
the same lines, and one of them gets rebased by hand for no engineering reason.
This project routinely has several branches open at once, so that cost is real
and recurring. That is also why `## [Unreleased]` in `CHANGELOG.md` is a
*pointer* at `changelog.d/` and not somewhere to write.

At release, `scripts/assemble-changelog.sh` aggregates every fragment's bullets
per section into one `## [<version>] - <date>` block, inserts it, fixes the
compare links at the foot of the file, and `git rm`s the fragments it consumed.
Two things follow from that:

- **Do not run the assembler in a feature PR.** Adding your fragment is the whole
  job; the release PR runs it once.
- **The heading it emits is an interface, not a style choice.**
  `scripts/extract-release-notes.sh` finds a section by matching `## [<version>]`
  at the start of a line and slices through to the next `## `, and the `v*`
  release workflow uses the result as the GitHub release body. Malformed, it
  fails nothing and silently ships empty or run-on release notes — which is why
  `scripts/assemble-changelog.test.sh` pins the exact format (and why that
  self-test also runs in CI, via `tests/changelog/assemble.sh`).

Not every change needs a fragment. The decision rule: would someone *building a
site* with Zigapagos notice? Then a user-facing section. Only a contributor
notices (build/CI, test infra, a refactor)? Then `### Internal`. Nobody needs it
recorded? Then no fragment — git history is enough.

## Commits and pull requests

- **One concern per branch**, one feature per PR. Never push to `main`,
  force-push, or merge.
- **Commit messages explain the defect and the reasoning, not just the change.**
  The history here is dense on purpose — several commits cite audit IDs
  (`AUD-*`, `AUDF-*`) and issue numbers, and code comments carry the *why*. Match
  that. A conventional-commit-ish prefix (`fix(area):`, `feat(area):`) is used
  widely but the body matters more than the prefix.
- **Fill in the PR template** (`.github/pull_request_template.md`). It is not
  ceremony: it has a required **docs-and-examples sync** section, because stale
  docs ship wrong guidance. If you changed behaviour, defaults, fields, CLI flags
  or env vars, the matching `docs/*.md`, `examples/tsx-site/` and — where it
  exercises the surface — `site/` come with the change, in the same PR.
- **Say what you ran.** List the gates you executed and their result; "CI will
  tell us" is not a verification step.
- The behaviour each subsystem is *supposed* to have is specified in
  `docs/islands.md`, `docs/spa.md`, `docs/cross-tier-codegen.md`,
  `docs/observability.md` and `docs/migration/*.md`. `docs/migration/` is written
  as a deterministic mapping spec so an agent can complete an Astro port
  unattended — read it before touching the importer, and update it with any
  change to the mapping.

## Where things are

`CLAUDE.md` at the repo root is the orientation document — pass ordering in
`src/root.zig`, the render seam, the Zig 0.16 module-root constraint that decides
where files may live, and the repo conventions. It is written for an AI assistant
but it is the most accurate map of the codebase available, so read it as a human
too.

## Reporting bugs and vulnerabilities

Bugs: use the issue templates. Security: **do not** open a public issue — see
[`SECURITY.md`](SECURITY.md).

## Licence and conduct

Contributions are accepted under the MIT licence in [`LICENSE`](LICENSE), which
retains the upstream copyright. Participation is governed by
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
