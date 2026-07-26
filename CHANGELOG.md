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

Nothing yet.

## [0.1.0] — 2026-07-26

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

[Unreleased]: https://github.com/valthon/zigapagos/compare/22ea4a0...HEAD
[0.1.0]: https://github.com/valthon/zigapagos/compare/496e42d...22ea4a0
