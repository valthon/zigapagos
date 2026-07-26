# Zigapagos roadmap

North star: **excellent DX + LLM-native unattended migration from Astro.** Every
item below is judged against "does this help an LLM migrate a real Astro site
cleanly, and does the result run correctly with good DX."

---

## What shipped (post-pivot baseline)

The **TSX island engine is built and merged to main**:

- **Bun sidecar SSR** — each `.island.tsx` is SSR'd at build time; the HTML
  fragment + `data-z-props` JSON is injected into the page.
- **Import-map hydration** — each island bundles to `/islands/<Name>.island.js`
  with `@z/runtime` external; a generated import map wires it to the shared
  `/zigapagos-runtime.js`, giving one Preact instance across all islands.
- **`@z/runtime` barrel** — hooks (`useState`/`useEffect`/`useLayoutEffect`/
  `useRef`/`useMemo`/`useCallback`/`useReducer`/`useContext`/`useSyncExternalStore`),
  `createContext`, `createPortal`, `host.*` bindings, feature-flag hooks
  (`useFlag`/`useVariant`/`FeatureFlag`/`Experiment`/`initFlags`), and the island
  lifecycle (`bootIsland`/`initIslands`).
- **`host.*` bindings** — store, `fetchShared`, cookies, clock, scroll/resize/
  matchMedia, scoped enhancers, `loadScript`/`getValue`, `fetchOpts`, `portal`,
  `reportError`, `pathname`.
- **`client:load|idle|visible|media|only`** directives all wired.
- **Zig-WASM island path retired/deleted.** The old `render(*Z)` / WASM island
  path has been removed. Migration from React is now a near-mechanical import
  swap (see [astro-to-zigapagos.md](migration/astro-to-zigapagos.md)).
- **Worked example**: `examples/tsx-site/` — `Hero.island.tsx`, layout, `build.zig`,
  `package.json`/`tsconfig.json`, SSR + hydration tests.

---

## Fork policy (decided 2026-07-08)

Zigapagos is a **permanent fork** of the upstream SSG (see [README
Acknowledgements](../README.md#acknowledgements); git remote name `upstream`). Policy:

- **Sync at upstream release tags only** (v0.12.0, v0.13.0, …) — never track
  upstream main/nightly. Each sync is a deliberate merge with its own branch,
  test pass, and review.
- **Zig 0.17 port is deferred until Zig 0.17.0 is released.** Upstream moved to
  0.17.0-dev; we stay on released Zig 0.16.0. When 0.17.0 ships, the port and
  the next upstream tag sync should land together (upstream v0.12.0+ already
  targets 0.17).
- **Keep the seam narrow:** new features go in new files with guarded hooks.
  The upstream-touched surface is ~18 files; avoid growing it without need.
- **Windows CI is suspended until the Zig 0.17 port.** Inherited upstream code
  (`src/cli/serve/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile
  on stable Zig 0.16.0 (`std.os.windows` no longer exposes `OVERLAPPED` /
  `PAGE_READONLY`); the fix rides the upstream 0.17-dev branch. CI runs
  ubuntu + macos; re-add `windows-latest` with the 0.17 port.
- **FreeBSD requires FreeBSD 15 or newer.** The dev-server / `serve` file
  watcher on FreeBSD reuses the inotify-based `LinuxWatcher`; inotify entered the
  FreeBSD base system in 15. There is no native kqueue backend, so on FreeBSD
  < 15 live reload does not work (the inotify symbols are unresolved / fail at
  runtime). Building and serving the static output is unaffected.

---

## Forward workstream

The active work is migrating a real production Astro site to Zigapagos —
porting its React islands to `@z/runtime`, decoupling its backend behind the
existing HTTP contract, and evaluating a `ZigBase` swap for it. Project-specific
migration notes live outside this repository.

---

## Delivery rule

Each item lands the established way: one feature per branch → unit test + real-
browser e2e → code review → fast-forward merge to main.

---

## Migration-phase ordering

A migration-fit review (2026-07-05) of the native SPA stack (`docs/spa.md`) against a
real production frontend — a static marketing site plus two cookie-auth-gated SPAs on
a ZigBase backend — queued the migration backlog. Ordering for the migration phase:

1. **Unblock the day-one dev loop:** `dev-server-api-proxy` (HIGH) — relative
   `/api/*` must reach a running backend before any gated flow can be exercised.
   ✅ **shipped 2026-07-05** (`zigapagos serve --proxy`; see `docs/spa.md`).
2. **Unblock a cookie-auth-gated app:** `spa-route-guards` (HIGH) +
   `nested-layout-routes` — no gated-content first-paint flash; shared chrome.
   Both ✅ **shipped 2026-07-06** (`RouteDef.guard` + `Router fallback`; `children` + `<Outlet/>` with per-scope guard cascade; see `docs/spa.md`).
3. **Unblock the typed contract:** `zigbase-native-codegen` (HIGH) — consume the
   backend's own `gen-client` output instead of a drifting hand-authored OpenAPI doc.
4. **Shipped alongside:** `per-route-code-splitting` (`lazy()` + per-route
   `modulepreload`, see `docs/spa.md`) and `configurable-import-allowlist` — the
   latter is the incremental preact/compat bridge that replaces the retired
   de-React codemod.
5. **Any time:** browser error relay, same-origin fetch defaults, live flags,
   router paper cuts, state-preserving reload. CSP-compatible emit is **shipped**:
   any site with islands or SPAs gets per-inline-script sha256 hashes written to
   `csp.{nginx.conf,apache.conf,zigbase.txt}` (`build/site.zig`, `docs/spa.md`).

**Cross-cutting — ZigBase integration seams.** Route guards, browser error relay,
same-origin fetch defaults, live flags, and native codegen each have a backend
half. Those are tracked publicly as **zigbase#244** (`ctx.reportError` + reporter
plugin) and the already-shipped `__features` signal, SSE endpoint
(`GET /api/realtime/sse`), and `gen-client` typed output. The zigapagos-side items
above proceed against those existing/tracked backend capabilities.

---

