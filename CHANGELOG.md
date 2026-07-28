# Changelog

Notable changes to Zigapagos. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[semver](https://semver.org/spec/v2.0.0.html) with the pre-1.0 caveat that a
minor bump may break an API.

Two things to know before reading it:

- **This file starts at the first public release, deliberately.** The repository
  carries 372 commits, but only the last two are this fork's: the full history of
  the upstream generator it forks, then a Zig 0.16 port and one squashed commit
  for all of the fork's own work. Splitting work that was never released into a
  per-version history would be invention, so this file does not do it. The
  subsystem specs in `docs/` are the source of truth for *what the code does*;
  this file records *when it changed*, starting now.
- **The `v0.7.0` … `v0.11.2` tags in this repository are not Zigapagos
  releases.** They are inherited upstream tags from before the fork. `0.1.0` is
  the first Zigapagos version number and is what `build.zig.zon` declares. Note
  that `zigapagos version` prints a `git describe` string derived from those
  inherited tags (`v0.11.2-dev.19+22ea4a0`), so the trailing commit hash — not
  the leading `v0.11.2` — is what identifies a build.

## [Unreleased]

Pending changes are **not listed here** — they live one file each in
[`changelog.d/`](changelog.d/), and `scripts/assemble-changelog.sh` folds them
into a new version section at release time. That is the whole point: two pull
requests each adding their own fragment merge cleanly, whereas two pull requests
each appending a bullet to this block collide on the same lines. To see what is
queued for the next release, read `changelog.d/`.

## [0.1.1] - 2026-07-28

### Internal

- Changelog entries are now recorded as one fragment file per change in `changelog.d/`,
  assembled into a version section by `scripts/assemble-changelog.sh` at release, so
  parallel pull requests never conflict on `CHANGELOG.md`. See `changelog.d/README.md`.
- Four byte-identical private copies of `escapeRegExp` in build-time TypeScript are
  gone, replaced by the right tool for each of the two contexts they were serving.
  The three JavaScript call sites (`lint-island-imports.ts`, `react-alias.ts`,
  `sidecar/bundle-island.ts`) now use the standard `RegExp.escape`, which is
  specified for exactly the ECMAScript `RegExp` position they feed. The fourth,
  `emit-host-config.ts`, emits Apache `RewriteRule` patterns — PCRE, a different
  dialect — so it gets a purpose-named `escapePcre` whose contract matches its
  output language and which keeps a deployed `.htaccess` readable
  (`^app/.*$`, not `^\x61pp/.*$`).
- Generated Apache config now has a validation net rather than only literal-string
  greps: `emit-host-config.test.ts` runs each emitted `RewriteRule` pattern through
  a real Perl-compatible regex engine and asserts it matches the URLs it should and
  rejects the near-misses an unescaped `.` would have swallowed. `buildAllow` gained
  the metacharacter-escaping test it never had.
- Eleven of the fourteen test scripts `tests/meta/unrun-scripts.txt` inventoried as knowingly
  unrun now run in CI: the non-browser `examples/tsx-site/test/*.sh` — island SSR and the
  bundle/import-map wiring, SSR↔CSR parity, byte-parity against a raw `bun build`, depfile
  incrementality, the props-check gate in both directions, `migrate --doctor`, and the four SPA
  prerender scripts (routing manifest, nginx/zigbase host config, code splitting, baked flag
  defaults, guarded routes, nested layouts) — plus the live-server smoke test.

  They are a step in the existing `e2e-dev-loop` job rather than a `tests/<area>/` shim, and the
  distinction is the whole point. Every one of them runs `zig build` inside `examples/tsx-site`,
  i.e. a full consumer build of zigapagos-as-a-dependency, and `e2e-dev-loop` is the only job
  that already pays for one — its `tests/serve/dev.sh` step drives that project's own
  `zig build dev`. A shim would have put them in `e2e-rest`, which builds the repo and not the
  example, buying a cold ~265s consumer build and making that job the run's critical path.
  Measured against the warm tree the job already has, the eleven cost **49s** in CI (29s
  locally) against the 468s the `dev.sh` step above them takes. `serve.sh` alone was
  inventoried at 76.1s; behind `dev.sh` it is ~5s, which is the placement argument in one
  number.

  The list is literal, not a glob, for the opposite reason `e2e-rest` uses a glob: a new sibling
  in that directory should NOT be adopted onto the PR path automatically — it might be the next
  one that needs a browser or four minutes. Being unnamed there is exactly what makes
  `script-coverage.sh` stop and ask.

- `tests/meta/script-coverage.sh` no longer counts a script as CI-run because a workflow
  *comment* names it. Its rule (b) was a plain `git grep` over `.github/workflows/`, so prose
  saying "these two are deliberately not run here" would have vouched for precisely the scripts
  it was disclaiming — and, since both are also inventoried, would have failed the gate with
  "run by CI but also listed". Rule (b) now applies the same non-comment filter rule (c) already
  had. The two Playwright paths are spelled in full in that comment on purpose: they pin the
  filter, because removing it turns the gate red by name.

  (`site/test/build.sh` and the two Playwright scripts were the three still inventoried at this
  point; all three were wired up before this release shipped — see the entry below for where
  each ended up and why.)
- The `typescript` devDependency moves 5.9.3 → 6.0.3, the final JavaScript-based TypeScript
  line. The compiler API that `runtime/scripts/slice-host.ts` and
  `runtime/sidecar/hot-transform.ts` parse with is fully present, so neither needed
  re-platforming, and the runtime suite is unchanged at 617 passing. `site/bun.lock` and
  `examples/tsx-site/bun.lock` are regenerated in step: each embeds its own copy of
  `@z/runtime`'s resolved dependencies and bun does not refresh them for a linked package on a
  plain install, so left alone they would have kept the props-check gate running 5.9.3 while the
  runtime was tested on 6.0.3.

- TypeScript 7.x is capped out via a Dependabot `ignore` on `>=7.0.0`. 7.0 is the Go rewrite and
  its npm package no longer ships the JavaScript compiler API — `import ts from "typescript"`
  resolves to `lib/version.cjs` and yields only `{version, versionMajorMinor}`, taking the
  runtime suite to 566 passing / 51 failing. The cap is deliberately a version bound rather than
  a major-block, which is what let 6.x through. It lifts when a 7.x ships a usable programmatic
  API (7.1 at the earliest).

- The `tsconfig.json` files were audited against TypeScript 6.0's deprecation list and needed no
  changes: none uses `baseUrl`, `outFile`, `downlevelIteration`, `target: es5`,
  `moduleResolution: node|node10|classic`, `module: amd|umd|system|none`, or an explicitly false
  `esModuleInterop` / `allowSyntheticDefaultImports` / `alwaysStrict`. No source file uses the
  `module` namespace keyword or import `assert` syntax. `ignoreDeprecations` is therefore not
  needed, and the config surface is already clean for whatever 7.x removes.

- Dependabot no longer groups major version bumps with routine ones. The `bun` groups for
  `runtime/` are restricted to minor and patch, and a new `runtime-majors` group collects every
  major into its own pull request, so a breaking major can no longer block unrelated updates
  from merging. `github-actions` deliberately keeps its single group: every `uses:` is pinned to
  a bare major tag, so majors are the only update it can produce and splitting would reintroduce
  per-action pull-request spam.

- `happy-dom` and `@happy-dom/global-registrator` move to 20.11.0.
- `tests/meta/unrun-scripts.txt` is **empty**. All 36 tracked test scripts are now run by CI;
  the inventory that started at 14 rows and was cut to 3 is at 0. The file stays because the
  gate reading it is the point, not the list.

  `site/test/build.sh` moved into `pages.yml`, between `Build site` and `Upload artifact`. That
  makes it a **deploy gate**: a failed assertion fails the build job, the artifact is never
  uploaded, and `deploy` (which `needs: build`) never runs, so the previous good deployment
  stays live. It is nearly free there — the workflow has already built `site/`, so the script's
  own install and build are warm no-ops and the five greps measured 1.7s — against ~120s in any
  `ci.yml` job, because `site/` is a third consumer project with its own `.zig-cache` that
  nothing else warms. The residual gap is stated rather than glossed: `pages.yml` triggers on
  push to `main` and manual dispatch only, so these assertions gate the deploy and not the PR.

  `examples/tsx-site/test/{hydrate,spa_slice}.sh` moved into a new `browser-e2e.yml` on a
  nightly `schedule:` plus `workflow_dispatch:`. Scheduled rather than PR-gating because each is
  ~125s on top of a ~265s cold consumer build plus a ~150MB browser install, and because what
  they catch — a real-browser hydration or runtime-slicing regression — arrives with a
  `runtime/src` change or a dependency bump, unattended. Each script gets its own matrix runner
  (`fail-fast: false`): `spa_slice.sh` opens by `rm -rf`ing `.zig-cache` and `zig-out`, so the
  two cannot share a build, and separate runners make that hazard structurally impossible rather
  than merely avoided.

  One correction to the plan the inventory carried: the install step is
  `playwright install --with-deps chrome`, **not** `chromium`. All ten `*_playwright.py` helpers
  launch with `channel="chrome"`, which on Linux resolves to `/opt/google/chrome/chrome` — the
  bundled Chromium build satisfies none of them, and the run would have died at browser launch
  after paying for the whole consumer build.

- `tests/meta/script-coverage.sh` gained a self-test, `tests/meta/script-coverage.test.sh`,
  in the shape of `scripts/check-allocator-contracts.test.sh`: seven cases against throwaway git
  repos in `$TMPDIR`. That gate has shipped three defects already — a self-vouching inventory, a
  `pipefail` + `grep -q` SIGPIPE race, and a comment filter applied to one rule but not the
  other — and every one made it pass when it should have failed.

  Two of the cases exist because emptying the inventory silently removed the only thing pinning
  the comment filter. That filter is what stops a script a workflow merely *mentions* in prose
  from counting as run, and it was pinned by accident: while the two Playwright scripts were
  inventoried, dropping the filter made the gate see them as both CI-run and listed and fail by
  name. With the inventory empty, removing the filter now breaks nothing in the tree —
  confirmed by deleting the filter line and watching the real gate still pass 36/36. Case 5
  makes the pin deliberate; case 6 is its guard rail, that comment-awareness has not become
  "never believe a workflow".
- `contract/test/drift.sh` — the test that proves the cross-tier codegen gate is not vacuous —
  was itself vacuous, and now runs in CI. Its Case B asserted only that `tsc --noEmit` exited
  non-zero, which a compiler that fails to *launch* also does: `contract/` has no
  `node_modules`, so `bun x tsc` resolved `tsc` off `PATH`, hit mise's shim, and died with
  `No version is set for shim: tsc` — exit 1, nothing type-checked, `PASS Case B` printed. Cases
  A and B now assert on the diagnostic text (the `experiments` → `variants` hunk in api-check's
  staged diff; both assignability directions of the `_assert.ts` tripwire, and no diagnostic
  from anywhere else), and a new Case D feeds those assertions canned "the tool never ran"
  output to prove they reject it.

- The same script now runs the repo's *pinned* TypeScript rather than whatever `bun x` resolves.
  `bun x tsc` with no local install can fetch from npm, where `latest` is 7.x — the line this
  repo deliberately caps out — so the gate could have silently type-checked with a compiler the
  manifest pins away from. It now invokes `runtime/node_modules/typescript` through bun and
  fails if the installed version does not match the one locked in `runtime/bun.lock`.

- `drift.sh`'s restore no longer discards more than it mutates. It used to
  `git checkout HEAD -- contract/`, which covers `contract/test/drift.sh` itself — editing the
  script and running it reverted the edit mid-run. The restore set is now exactly the two paths
  a case writes to, a pre-flight refuses to start when either is already dirty, and the EXIT
  trap both restores and fails the run if anything is left behind.

- A `tests/contract/drift.sh` shim puts the gate in CI's `tests/*/*.sh` glob, alongside the
  existing `tests/changelog/assemble.sh` and `tests/release/scripts.sh` hooks. It costs ~1.5s
  and spawns no server, so it runs in the `e2e-rest` shard rather than a job of its own. Being
  outside that glob, and unnamed in `ci.yml`, is why the rot above went unseen.

- `examples/tsx-site/test/spa.sh` had rotted the same way, and is fixed. Its two nginx
  assertions expected the *unquoted* `try_files $uri $uri/ /app/index.html;`, but
  `emit-host-config.ts` has run every interpolated route value through `nginxQuote()` since
  that helper landed, so both greps had matched nothing for as long as they had existed — and
  the script sits outside the `tests/*/*.sh` glob, so nothing ran it. They now match the quoted
  form byte-for-byte, with a third assertion covering the dynamic `location`'s `try_files`
  order. The emitter itself was never at risk: `runtime/scripts/emit-host-config.test.ts` pins
  the same strings and does run in CI. What the e2e assertions add is that those bytes actually
  reach `zig-out/site/app/nginx.nginx.conf` in a real build.

- A new gate, `tests/meta/script-coverage.sh`, makes that class of rot impossible to introduce
  silently: every test script must be either run by CI or listed in `tests/meta/unrun-scripts.txt`
  with a written reason, and the gate fails on one that is neither — as well as on a stale row
  for a script that has since been wired up or deleted. This is the same shape as
  `scripts/allocator-allowlist.txt` and its checker. It is `git ls-files` plus `grep` over
  tracked text, so it costs no toolchain and runs in well under a second.

  The inventory it enforces records the audit behind it: all 34 tracked test scripts were run by
  hand, 20 are covered by CI, and the 14 that are not (`site/test/build.sh` plus the 13 under
  `examples/tsx-site/test/`) all currently pass. Each row carries its measured wall-clock and
  what adopting it would cost, so the trade-off can be re-checked rather than re-derived.

## [0.1.0] - 2026-07-26

First public release. Fork point: upstream `496e42d` (`v0.11.2-17-g496e42d`).

Everything below is "added" relative to that fork point; the sections separate
what is new from what the port changed and removed.

### Added

- **TSX islands.** Each `.island.tsx` is server-rendered at build time through a
  Bun sidecar and spliced into the page as real HTML with a `data-z-props` JSON
  block. In the browser it hydrates on `client:load`, `client:idle`,
  `client:visible`, `client:media` or `client:only`. Islands share **one** Preact
  instance via a generated import map pointing at a single shared runtime, so a
  page with no islands ships no JavaScript.
- **`@z/runtime`**, the first-party shipped runtime: the hook set
  (`useState`/`useEffect`/`useLayoutEffect`/`useRef`/`useMemo`/`useCallback`/`useReducer`/`useContext`/`useSyncExternalStore`),
  `createContext`, `createPortal`, the `host.*` bindings (store, `fetchShared`,
  cookies, clock, scroll/resize/`matchMedia`, scoped enhancers, `loadScript`,
  `portal`, `reportError`, `pathname`), feature-flag hooks
  (`useFlag`/`useVariant`/`FeatureFlag`/`Experiment`/`initFlags`), and the island
  lifecycle (`bootIsland`/`initIslands`).
- **Native SPAs** from a single `.spa.tsx` exporting `spa` + `routes`:
  prerendered per-route skeletons, a `_shell.html` for dynamic routes, two-phase
  hydration, soft navigation, route guards with a cascade over nested scopes,
  nested layouts via `children` + `<Outlet/>`, a site-wide `404.html`, a
  `spa.head` hook, per-route code splitting via `lazy()`, and host-agnostic
  routing manifests emitted for ZigBase, nginx and Apache.
- **Dev loop.** `zigapagos dev` builds, serves through the stock ZigBase binary,
  and rebuilds on change; the bundled live server adds live reload over SSE, a
  `--proxy PREFIX=UPSTREAM` reverse proxy for cookie-auth backends, and live
  feature flags. Both understand SPAs, including incremental island rebuilds.
- **Astro migration tooling.** `zigapagos migrate <dir>` scans an Astro project,
  detects `client:*` usage and writes a `MIGRATION.md` worklist;
  `zigapagos init --from-astro` scaffolds islands with the React → `@z/runtime`
  import swaps already applied and refuses to clobber existing files. The specs
  in `docs/migration/` are written as a deterministic mapping so an agent can
  complete a port unattended.
- **Cross-tier codegen** for a typed backend client, with `zig build api-check`
  failing the build when `contract/generated` drifts from the schema.
- **Strict-CSP emit.** For any site with islands or SPAs, the build scans the
  emitted HTML, computes a sha256 for each unique inline script, and writes
  `csp.nginx.conf`, `csp.apache.conf` and `csp.zigbase.txt` at the site root:
  `script-src` is `'self'` plus hashes with no `unsafe-inline`. Verified with zero
  CSP violations in real Chrome against a hardened vhost.
- **Correctness gates**, all wired into CI: eleven `test-*` unit suites, a
  616-test Bun suite for `runtime/`, twelve hermetic shell e2e scripts (real
  server boots against a stub ZigBase), a `zig fmt --check` gate over every
  tracked `.zig` file, a `-Dsingle-threaded` compile gate over the exe *and*
  every test binary, an island-props `tsc` gate, and
  `scripts/check-allocator-contracts.sh`, which fails on any new test that wraps
  `std.testing.allocator` in an arena (that turns Zig's leak detector off) unless
  it is allowlisted with a written justification.
- **`NO_SLOP.md`**, the review standard every Zig change is held to, including the
  four allocator-ownership contracts and the `RenderArena` marker type that makes
  contract 4 compiler-checked rather than convention.
- **Docs and examples:** `docs/islands.md`, `docs/spa.md`,
  `docs/observability.md`, `docs/cross-tier-codegen.md`, `docs/migration/*`,
  `docs/ROADMAP.md`; a worked `examples/tsx-site/` with SSR and real-browser
  hydration tests; and `site/`, the project's own dogfooded site.

### Changed

- Ported to **released Zig 0.16.0**. Upstream moved to 0.17-dev; this fork tracks
  released Zig only and defers the 0.17 port until 0.17.0 ships, at which point it
  lands together with the next upstream release-tag sync.
- Renamed throughout — binary, branding, generated asset names — with a CI gate
  that fails on a stray upstream name outside the attribution allowlist.
- **Build-pass order in `src/root.zig` is now load-bearing.** The SPA prerender
  runs *before* the page render/emit pass, because it is the pass that executes
  the author's own code and holds the SPA spec validation (overlapping bases,
  basename collisions, `..` in a route path, a declared SPA with no sidecar).
  Running it after the page pass meant those failures aborted with every page
  already rewritten. This is not atomicity: a failure partway through writing
  shells still leaves partial output.
- The import map is emitted before any `modulepreload` or module script in
  `<head>`, since the first module script closes the window in which a map may be
  declared.

### Removed

- The old Zig-WASM island path (`render(*Z)`) and its `engine/` tree. Islands are
  TSX only; porting from React is now a near-mechanical import swap.
- `windows-latest` from CI. Inherited upstream code
  (`src/cli/serve/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile
  on stable Zig 0.16.0 — `std.os.windows` no longer exposes `OVERLAPPED` /
  `PAGE_READONLY` — and the fix rides upstream's 0.17-dev branch. It returns with
  the 0.17 port.

### Known limitations

- **No Windows support** until the Zig 0.17 port (above).
- **FreeBSD needs 15 or newer** for live reload: the watcher reuses the
  inotify-based `LinuxWatcher`, and inotify entered the FreeBSD base system in 15.
  There is no kqueue backend. Building and serving static output is unaffected.
- **Strict CSP requires deploying the emitted header.** The build writes the
  hash-strict policy, but serving it (and re-serving it after a rebuild, since the
  hashes are byte-exact) is the host's job. `style-src` still needs
  `unsafe-inline` for the framework's inline `style` attributes.
- `host_url_override` on a locale is not supported by the live server.
- **No published binary releases.** Build from source at a commit you choose.
- Pre-1.0: APIs may change between minor versions.

[Unreleased]: https://github.com/valthon/zigapagos/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/valthon/zigapagos/compare/22ea4a0...v0.1.1
[0.1.0]: https://github.com/valthon/zigapagos/compare/496e42d...22ea4a0
