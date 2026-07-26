# `@z/runtime/testing` — island test harness

Render any `.island.tsx` in [happy-dom](https://github.com/capricorn86/happy-dom) with a mocked host, then assert output and interactions — no browser needed.

## Quick start

```ts
import { renderIsland, click } from "@z/runtime/testing";
import { Hero } from "./Hero.island.tsx";

const { get, click: c, text } = renderIsland(Hero, { headline: "hi" });
await click(get("button"));
expect(text()).toContain("clicked");
```

## Consumer setup

Add one line to your project's `bunfig.toml`:

```toml
[test]
preload = ["@z/runtime/testing/preload"]
```

Before any test file runs, this preload:

1. registers **happy-dom** as the global DOM environment (for `renderIsland` and the hydration helpers);
2. applies your site's `z-runtime.config.json` **`resolve` map as bun-test module overrides** — the exact registration the SSR sidecar uses — so views reached through an **out-of-tree workspace symlink** (bun links workspace packages as symlinks and `bun test` realpaths their files outside the project root, where tsconfig `paths` and the package's own node_modules can't resolve anything) still resolve `react`, `@z/runtime`, and the JSX runtime to the one shared runtime, exactly like the real build;
3. provides **`@z/site-data`** — fed from the same config `data` map the build uses, and swappable per test via [`mockSiteData`](#mocksitedata--supplying-zsite-data-in-tests).

The config is discovered by walking up from the current working directory (same as the sidecar), so run `bun test` from the website root or below. With no config, only happy-dom and a mock-only `@z/site-data` are set up. No other setup is needed.

## Render modes

`renderIsland(Component, props?, opts?)` accepts `opts.mode` with three values:

| Mode | Behavior | When to use |
|------|----------|-------------|
| `"hydrate"` *(default)* | SSRs with `__setServerForTest(true)`, writes HTML into the container, then hydrates with Preact | Standard island test: exercises both the server render and the client adoption path |
| `"render"` | Client-only `render()` — no SSR step | Test client-only branches, or components with DOM-only behavior that has no server render |
| `"ssr"` | SSR only — populates `container.innerHTML` but does not hydrate | Snapshot/assert the raw server HTML without client-side effects |

## `ssrIsland` — pure SSR string

```ts
import { ssrIsland } from "@z/runtime/testing";

const html = ssrIsland(MyIsland, { title: "hello" }, { pathname: "/about" });
expect(html).toContain("<h1>hello</h1>");
```

Returns the raw `renderToString` output with `isServer() === true`, exactly matching what the Bun sidecar produces at build time. Accepts an optional `{ pathname? }` option to set the SSR pathname.

## `renderForTest` — unit-test a view with injected props / guard data / flags

`ssrIsland` renders a component with props, but a real **view** also reads route **guard data** (`useGuardData()`) and baked **feature flags** (`useFlag()` / `useVariant()`). `renderForTest` is the browser-free primitive for asserting on exactly that: it renders the view to the same SSR string the Bun sidecar (`runtime/sidecar/render.ts`) produces at build time (`isServer() === true`), with every input injected through the same seam the runtime uses — no browser, no Router, no full build.

```ts
import { renderForTest } from "@z/runtime/testing";
import { Dashboard } from "./Dashboard.tsx";

const html = renderForTest(Dashboard, {
  props: { title: "Home" },
  guardData: { user: { name: "Ada" } }, // what the route guard returned via { ok: true, data }
  flags: { promoBanner: true },          // baked spa.flags default
  experiments: { hero: "b" },
  pathname: "/app/dashboard",            // drives host.pathname() / useLocation()
});
expect(html).toContain("Ada");
```

| Option | Type | Injected as / read in the view via |
|--------|------|-----------------------------------|
| `props` | `P` | the component's props (default `{}`) |
| `guardData` | `unknown` | the nearest enclosing guard's `{ ok: true, data }` → `useGuardData<T>()` |
| `flags` | `Record<string, boolean>` | baked flag defaults → `useFlag(name)` |
| `experiments` | `Record<string, string>` | variant assignments → `useVariant(name)` |
| `pathname` | `string` | SSR pathname (default `"/"`) → `host.pathname()` / `useLocation()` |

Returns the raw HTML string. State injection is fully scoped: the SSR pathname and the page-global flags store are saved and restored around the render (mirroring the sidecar's per-request seed/clear of `spa.flags`), so calls never bleed into one another. Unlike `renderIsland`, `renderForTest` renders to a string and touches no DOM, so it does **not** require the happy-dom preload — use it for pure render-logic assertions, and reach for `renderIsland` when you need to hydrate and drive interactions.

## `mockSiteData` — supplying `@z/site-data` in tests

At build/SSR time `@z/site-data` is a virtual module materialized from `z-runtime.config.json`'s `data` map; under plain `bun test` it doesn't exist. With the preload installed it does, twice over:

- **Config-fed baseline**: when the discovered config declares a `data` map, the module's default export is built from it lazily on first read — the same `buildSiteData` the sidecar runs, so tests see exactly the data the build would bake in (and a broken data map fails only the tests that actually read site data).
- **Per-test override**: `mockSiteData(data)` replaces the contents in place and returns a restore function:

```ts
import { renderForTest, mockSiteData } from "@z/runtime/testing";
import { Hours } from "@acme/shared";

test("renders mocked hours", () => {
  const restore = mockSiteData({ hours: { mon: "closed" } });
  expect(renderForTest(Hours)).toContain("closed");
  restore(); // back to the preset baseline
});
```

`restore()` reverts to the **preset baseline** — the config's `data` map when one exists, otherwise the unseeded state (where any read throws an actionable error pointing at the config / `mockSiteData`). It does not stack: it never restores a *previous* mock.

Caveats:

- A view that destructures site data at **module scope** (`const { hours } = site;` at the top level) captures values at import time — call `mockSiteData` before importing such a view (e.g. via a dynamic `import()`), or read the data lazily inside the component.
- Resolution parity is **exact-specifier**, same as the sidecar: out-of-tree packages may import `react`, `react-dom`(/`client`), `react/jsx-runtime`, `react/jsx-dev-runtime`, `@z/runtime`, `@z/runtime/jsx-runtime`, `@z/runtime/jsx-dev-runtime`, `@z/runtime/compat`(/`client`) — the `RESOLVE_DEFAULTS` + `RUNTIME_SELF_ENTRIES` set, plus any user `resolve` entries. Other `@z/runtime` subpaths imported from out-of-tree files fail in tests exactly as they do in the real build.

## `mockHost` — config reference

`mockHost(config?)` builds a mocked host that drives the real `host` singleton through environment control. All keys are optional.

| Key | Type | What it controls |
|-----|------|-----------------|
| `flags` | `Record<string, boolean>` | Initial feature flags |
| `experiments` | `Record<string, string>` | Initial experiment variant strings |
| `shared` | `Record<string, string \| object>` | Pre-seeded shared-store values (keyed by store name) |
| `cookies` | `Record<string, string>` | Cookies written to `document.cookie` on install |
| `fetch` | `(url, init?) => string \| object \| Response \| FetchEnvelope \| Promise<…>` | Intercepts all `globalThis.fetch` calls; return a string, JSON-serializable object, a `Response`, or a `FetchEnvelope` |
| `now` | `number \| Date` | Pins `Date.now()` via Bun's `setSystemTime` |
| `scrollY` | `number` | Initial `window.scrollY` value |
| `viewport` | `{ width: number; height: number }` | Sets `window.innerWidth` / `window.innerHeight` |
| `media` | `Record<string, boolean>` | Initial `matchMedia` query results (keyed by query string) |
| `scripts` | `Record<string, boolean> \| boolean` | Controls whether injected `<script src>` tags fire `load` or `error`; `true`/`false` sets the default for all scripts; an object overrides per-URL |
| `recaptchaToken` | `string` | Pre-fills `#g-recaptcha-response` textarea |
| `server` | `boolean` | Overrides `isServer()` for the whole test (use `ssrIsland`/`renderIsland` instead unless you need fine-grained control) |

## Live drivers

After install, a `MockHost` handle exposes live drivers that update state and flush Preact:

| Method | Signature | What it does |
|--------|-----------|-------------|
| `setFlags` | `(flags, experiments?) => Promise<void>` | Updates flags/experiments and flushes |
| `resolveShared` | `(store, body) => Promise<void>` | Resolves a shared store and flushes |
| `setCookie` | `(name, value) => void` | Writes a cookie to `document.cookie` |
| `setScroll` | `(y) => Promise<void>` | Sets `scrollY`, dispatches `"scroll"`, flushes |
| `setViewport` | `(w, h) => Promise<void>` | Sets `innerWidth`/`innerHeight`, dispatches `"resize"`, flushes |
| `setMedia` | `(query, matches) => Promise<void>` | Updates a `matchMedia` result and fires listeners |
| `advanceClock` | `(ms) => void` | Advances the pinned clock by `ms` milliseconds |
| `setRecaptchaToken` | `(token) => void` | Updates `#g-recaptcha-response` |

## Captured egress

| Property | Type | What it captures |
|----------|------|-----------------|
| `errors` | `string[]` | Messages delivered to `window.zigapagosOnError` |
| `fetches` | `Array<{ url: string; init?: RequestInit }>` | Every `fetch` call intercepted (in order) |
| `cookies` | `Record<string, string>` | Live snapshot of `document.cookie` (parsed) |
| `scriptsLoaded` | `string[]` | `src` URLs of every `<script>` appended to `<head>` |

## `renderIsland` return surface

```ts
const {
  container,   // HTMLElement — the mounted island root
  html,        // () => string — current innerHTML
  host,        // MockHost — the live host handle
  get,         // (sel) => HTMLElement — throws if 0 or >1 match
  query,       // (sel) => HTMLElement | null — first match or null
  getAll,      // (sel) => HTMLElement[] — all matches
  text,        // (sel?) => string — trimmed textContent (whole container if no sel)
  rerender,    // (props) => Promise<void> — re-render with new props and flush
  unmount,     // () => void — unmounts, removes container, calls host.restore()
} = renderIsland(MyIsland, props, opts);
```

## Interaction helpers

```ts
import { act, click, type, flush } from "@z/runtime/testing";

await click(el);           // el.click() + flush
await type(input, value);  // sets .value, dispatches "input", flushes
await act(() => { ... });  // run arbitrary side effects + flush
await flush();             // drain microtasks, macrotasks, and one rAF tick
```

## Manual `mockHost` lifecycle

When you need a host shared across multiple `renderIsland` calls, or want explicit lifecycle control:

```ts
const mh = mockHost({ flags: { newNav: true } });
mh.install();

const { get } = renderIsland(Nav, {}, { host: mh });
await mh.setFlags({ newNav: false });
expect(get("[data-old-nav]")).toBeTruthy();

mh.restore(); // cleans up DOM patches, stores, clock
```

`renderIsland` calls `install()` automatically and `unmount()` calls `restore()` — so when you pass a pre-built `MockHost`, `restore()` is still called exactly once on unmount.

---

## Relation to upcoming backlog items

The `"hydrate"` mode and `ssrIsland` both toggle `__setServerForTest(true)` around `renderToString`, reproducing the "sidecar SSRs skeleton → client adopts" cycle in-process. This is the shared foundation for the planned `ssr-hydration-parity` work (an automated SSR↔hydration mismatch gate). The raw string returned by `ssrIsland` feeds the planned `astro-tsx-parity-gate` work (a byte/visual diff against Astro's own SSR output).
