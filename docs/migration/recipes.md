> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/migration-recipes/> — the site is the canonical reading experience.

# TSX island authoring guide

Islands in Zigapagos are **TypeScript TSX components** — authored with React/Preact
semantics, SSR'd at build time by a Bun sidecar, and hydrated client-side via an
import map. Standard React patterns (state, effects, refs, lists, conditionals, event
handlers) work as-is because the runtime is Preact-compat. This doc covers the
Zigapagos-specific layer on top: the authoring contract, how to import from
`@z/runtime`, the `host.*` escape hatches, feature flags, the no-npm guardrail, and
project setup. See `examples/tsx-site/` for a complete worked example.

---

## Authoring contract

An island is a file named `<Name>.island.tsx` that default-exports a component and
exports a typed `Props` interface:

```tsx
// components/Hero.island.tsx
import { useState } from "@z/runtime";

export interface Props { headline: string }

export default function Hero({ headline }: Props) {
  const [open, setOpen] = useState(false);
  return (
    <section>
      <h1>{headline}</h1>
      <button onClick={() => setOpen(!open)}>{open ? "−" : "+"}</button>
    </section>
  );
}
```

Place it in a layout with an `<island>` tag:

```html
<island src="components/Hero.island.tsx" client:load prop-headline="$page.title"></island>
```

- **`src`** — path relative to the project root; matches the entry in `build.zig`.
- **`client:*`** — hydration timing: `load` | `idle` | `visible` | `media="(query)"` | `only`.
- **`prop-NAME="$expr"`** — a SuperHTML/Scripty expression evaluated at build time.
  The result is JSON-serialised and passed to the component as the named prop.
  Props arrive typed and are dev-validated against `Props` at SSR time.

Static props can also be written inline:

```html
<island src="components/Hero.island.tsx" client:load prop-headline="$page.title"
        prop-cta="Book now"></island>
```

---

## Imports

Everything the island needs comes from `@z/runtime`:

```ts
import {
  // React hooks (standard Preact-compat — use exactly as in React)
  useState, useEffect, useLayoutEffect, useRef,
  useMemo, useCallback, useReducer,
  useContext, useSyncExternalStore, createContext, createPortal,

  // SSR-safe browser bindings
  host,

  // Server-resolved feature flags
  useFlag, useVariant, FeatureFlag, Experiment, initFlags,

  // Island lifecycle (used by the runtime, not by island authors)
  bootIsland, initIslands,
} from "@z/runtime";
```

JSX is also from `@z/runtime` via `jsxImportSource` — no explicit `h` import needed
(the `tsconfig.json` wires it).

---

## `host.*` — SSR-safe browser bindings

`host` is the escape hatch for browser APIs that are unsafe to call during SSR.
Every `host.*` method no-ops (or returns a safe default) on the server and becomes
real on the client. Call them inside `useEffect`/event handlers, not in render,
unless the method is explicitly documented as SSR-safe with a deterministic baseline.

| Method | Returns / behaviour |
|---|---|
| `host.store.getStr(name)` | Cross-island reactive string store (read). |
| `host.store.setStr(name, value)` | Write + notify all subscribers. |
| `host.store.getNum(name)` | Returns `bigint`; 0n if unset. |
| `host.store.setNum(name, value)` | Write numeric value. |
| `host.store.getJson<T>(name)` | Parse store as JSON — **throws** if empty or malformed (loud-fail, never returns a default). |
| `host.store.subscribe(name, cb, signal?)` | Subscribe to store changes; pass an `AbortSignal` to auto-unsub. |
| `host.fetchShared(url, storeName)` | One de-duped fetch across all islands; result goes into `storeName`. No-op on server. |
| `host.cookies.get(name)` | Returns cookie value string; `""` on server. |
| `host.cookies.set(name, value, opts?)` | Write `document.cookie`; no-op on server. |
| `host.now()` | `Date.now()` ms; `0` on server. |
| `host.localDateParts()` | `{ year, month, day, weekday, hour, minute, second }`; all-zero on server. |
| `host.onScroll(cb, signal?)` | Calls `cb(scrollY)` once immediately, then on scroll. No-op on server. |
| `host.onResize(cb, signal?)` | Calls `cb(width, height)` once + on resize. No-op on server. |
| `host.matchMedia(query, cb, signal?)` | Calls `cb(matches)` once + on change. No-op on server. |
| `host.enhance.setText(id, text)` | Set `textContent` of a server-rendered sibling by id. No-op on server. |
| `host.enhance.setHtml(id, html)` | Set `innerHTML` (XSS risk — never use with untrusted input). No-op on server. |
| `host.enhance.setStyle(id, prop, value)` | Set one inline style on a sibling by id. No-op on server. |
| `host.enhance.addClass/removeClass/toggleClass(id, cls)` | `classList` helpers on a sibling by id. No-op on server. |
| `host.loadScript(url)` | Returns `Promise<boolean>`; injects `<script src>` once (de-duped). `false` on server. |
| `host.getValue(id)` | Read `.value` or `textContent` of an element by id; `""` on server. |
| `host.fetchOpts(req)` | Richer fetch: `{ url, method?, headers?, body? }` → `Promise<{ status, headers, body }>`. Zero-envelope on server or error. |
| `host.portal(selector)` | Resolve a CSS selector to an `Element` for portal mounting; `null` on server or if not found. |
| `host.reportError(msg)` | Calls `window.zigapagosOnError(msg)` if defined, else `console.error`. No-op on server. |
| `host.pathname()` | The current page path (`window.location.pathname` on client; page's own path at SSR). |
| `host.search()` | The current query string (`window.location.search` on client; parsed from the build-time SSR URL when one carries a query, else `""`). |
| `host.hash()` | The current fragment (`window.location.hash` on client; always `""` on the server — fragments never reach a server). |

### Scroll + resize example

```tsx
import { useState, useEffect } from "@z/runtime";
import { host } from "@z/runtime";

export interface Props {}

export default function StickyHeader(_: Props) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const ctrl = new AbortController();
    host.onScroll((y) => setScrolled(y > 8), ctrl.signal);
    return () => ctrl.abort();
  }, []);

  return <header class={scrolled ? "shadow" : ""}>…</header>;
}
```

### Cross-island store example

```tsx
import { useSyncExternalStore } from "@z/runtime";
import { host } from "@z/runtime";

export interface Props {}

// Both islands share the "count" store — clicking one updates all.
export default function Counter(_: Props) {
  const count = useSyncExternalStore(
    (cb) => { const ctrl = new AbortController(); host.store.subscribe("count", cb, ctrl.signal); return () => ctrl.abort(); },
    () => host.store.getNum("count"),
  );
  return (
    <button onClick={() => host.store.setNum("count", count + 1n)}>
      {String(count)}
    </button>
  );
}
```

### Portal example

```tsx
import { useState, createPortal } from "@z/runtime";
import { host } from "@z/runtime";

export interface Props {}

export default function Modal(_: Props) {
  const [open, setOpen] = useState(false);
  const target = host.portal("body"); // null during SSR — createPortal handles it
  return (
    <>
      <button onClick={() => setOpen(true)}>Open</button>
      {open && target && createPortal(
        <div class="modal"><button onClick={() => setOpen(false)}>×</button></div>,
        target,
      )}
    </>
  );
}
```

---

## Server-resolved feature flags

Flags and experiments are resolved **server-side** — the client never buckets.
Call `initFlags()` once (e.g. in your base layout script) to prefetch the flags
store; islands read it via hooks:

```tsx
import { useFlag, useVariant, FeatureFlag, Experiment } from "@z/runtime";

export interface Props {}

export default function PromoArea(_: Props) {
  const showPromo = useFlag("promo");          // boolean
  const variant   = useVariant("hero-cta");   // "" until resolved

  return (
    <>
      {showPromo && <p>Promo active!</p>}
      <FeatureFlag name="new-nav"><nav>…</nav></FeatureFlag>
      <Experiment name="hero-cta" variant="b"><button>Get started</button></Experiment>
    </>
  );
}
```

`useFlag`/`useVariant` return the unresolved default (`false` / `""`) until the
`/api/flags/state` fetch completes. For flags known at build time, prefer baking
them as props (`prop-show-promo="$site.data('flags').get('promo')"`) — zero runtime
cost, no loading flash.

### Live flags (kill-switch propagation)

`initFlags(url, { live: true })` keeps open tabs current: it subscribes to the
backend's `__features` topic over ZigBase 0.10's SSE endpoint
(`GET /api/realtime/sse`, via `EventSource` — no SDK) and re-fetches the flag state
whenever the backend signals a change, so flipping a kill-switch propagates to
already-loaded pages without a reload.

```tsx
initFlags("/api/flags/state", { live: true });   // optional: { sseUrl: "/api/realtime/sse" }
```

Opt-in only — plain `initFlags()` is unchanged (a single prefetch, no connection).
If the SSE endpoint is unavailable it **falls back silently** to re-fetching on
navigation (back/forward and tab-refocus). A re-fetch failure is surfaced via
`host.reportError` (never a silently-stale default).

---

## Slot composition (named + default slots)

Islands can receive slot content — HTML fragments composed from the layout/template layer and
passed into the component. This enables **composite islands**: a Panel that accepts a custom
heading, a Card whose footer is caller-controlled, etc.

### Island side (author)

Declare `children` (the default slot) and `slots` (the named-slot record) as optional props:

```tsx
// components/Panel.island.tsx
import type { ComponentChildren } from "@z/runtime";
import type { Slots } from "@z/runtime";

export interface Props {
  title: string;
  children?: ComponentChildren;   // default slot
  slots?: Slots;                   // named slots
}

export default function Panel({ title, children, slots }: Props) {
  return (
    <section class="panel">
      <header>{slots?.heading ?? <h2>{title}</h2>}</header>
      <div class="panel-body">{children}</div>
    </section>
  );
}
```

Key rules:
- **`children`** receives the default slot content (anything not inside a `<template slot="…">`).
- **`slots?.NAME`** receives a named slot by its `slot` attribute value.
- Both are **optional** — the island should always fall back gracefully when no slot content is
  provided (use `?? <DefaultElement>` or a conditional).
- `children` and `slots` are **reserved prop names**: do not declare unrelated props with these
  names.
- `slot="default"` is reserved for the default slot — do not write a named template with
  `slot="default"` unless you intend to target the default slot explicitly.

### Consumer side (layout / template)

Mount the island with a `<template slot="NAME">` for each named slot; everything else goes into
the default slot:

```html
<island src="components/Panel.island.tsx" client:load :props='{ .title = "Panel" }'>
  <template slot="heading"><h2>Custom Heading</h2></template>
  <p>This paragraph goes into the default (children) slot.</p>
  <island src="components/Hero.island.tsx" client:load prop-headline="Nested"></island>
</island>
```

- `<template slot="NAME">` elements are extracted and routed to `props.slots.NAME`.
- Everything **outside** a `<template>` element becomes the `children` (default slot).
- Leading and trailing whitespace in slot content is trimmed automatically.
- Nested `<island>` tags inside slots are fully supported: they SSR in place and hydrate
  independently via the global `initIslands()` walk.

### How it works (SSR + hydration)

At **build time**, the Zig pass extracts slot content from the `<island>` tag body, recurses
into nested islands, then forwards the slot HTML map to the Bun sidecar as `slots_json`.
The sidecar calls `buildSlots()` from `@z/runtime` to produce `<z-slot data-z-slot="…">` VNodes
(with `dangerouslySetInnerHTML`) and passes them into the component. The SSR output already
contains the slot DOM — Preact adopt-hydration in the browser reuses it byte-for-byte.

At **hydrate time**, `bootIsland` reads the `data-z-slots` JSON script, calls `buildSlots()`
(the same function) to get identical VNodes, and passes them to `hydrate()`. Preact's
adopt-hydration sees the existing `<z-slot>` DOM matches the VNode tree and leaves it untouched —
no innerHTML clobber, no flash of unstyled content, nested islands kept interactive.

---

## Port doctor (`zigapagos migrate --doctor`)

Before porting an island by hand, run the port doctor to get a per-component
checklist of everything that needs attention:

```bash
zigapagos migrate --doctor src/components/ContactForm.tsx
```

The doctor is **non-mutating** (reads only, writes nothing) and exits **non-zero
when any guardrail violation is found**, making it safe to run in CI.

It reports four categories:

- **Hooks** — every React hook used, whether `@z/runtime` has a drop-in
  equivalent, and what to do when it does not.
- **Host bindings you'll need** — browser-API smells (`fetch(`, `document.cookie`,
  `window.matchMedia(`, …) and the corresponding `host.*` binding to use instead.
- **Imports (no-npm guardrail)** — each import specifier classified as OK,
  `react_rewrite` (→ `@z/runtime`), or `FORBIDDEN`. Forbidden imports also carry
  a suggested shim target (see `@z/runtime/compat` below).
- **@legacy-app/shared symbols** — maps each `@legacy-app/shared` name to its
  `@z/runtime` or `@your-org/shared-lite` equivalent (see the `compat-shims`
  backlog item for the full shim set).

The import suggestions for forbidden npm packages point at the `@z/runtime/compat`
shims: e.g. `react-google-recaptcha` → `@z/runtime/compat (ReCAPTCHA)`.

### JSON output

Pass `--json` to emit a machine-readable object instead of the Markdown checklist
(pipeable to `jq`):

```bash
zigapagos migrate --doctor src/components/ContactForm.tsx --json | jq '.guardrailViolations'
```

The JSON shape: `{ component, hasDefaultExport, hooks[], hostNeeds[], imports[], shared[], guardrailViolations }`.

---

## No-npm guardrail

By default an island may import only `@z/runtime` (and subpaths), relative paths,
and use web globals. Two opt-in extensions live in `z-runtime.config.json` at the
website root:

```json
{ "islandImports": {
    "firstParty": ["@your-org/shared-lite"],
    "npmCompat":  ["react-router-dom"]
} }
```

- `firstParty` — extra allowed import scopes (a package name; its subpaths are
  allowed too). For your own workspace packages.
- `npmCompat` — third-party React-compatible npm packages. The linter allows
  them, and the client bundler inlines them per-island while keeping
  `react`/`react-dom` external — the import map resolves those to the shared
  runtime, preserving the one-Preact invariant. Build-time SSR resolves them
  through the same alias automatically: whenever `firstParty`/`npmCompat` is
  non-empty, `react`/`react-dom`/the jsx runtimes default-map to the shared
  compat surface in BOTH the sidecar and the bundler (override or extend via
  the config's `resolve` map — see docs/migration/react-spa-bridge.md).

Two more config-gated imports: keys of the config's `resolve` override map are
importable (exact specifier), and `@z/site-data` — the build-time content
module fed from the config's `data` map — is importable whenever `data` is
declared (see docs/spa.md → Build-Time Site Data).

Anything else — packages that ship their own React/Preact copy, or that the
config doesn't list — still fails the lint, by design. This keeps `@z/runtime`
external (it maps to the shared `/zigapagos-runtime.js` via import map) so
there is exactly one Preact instance on the page: bundling a second copy of
Preact or Preact-compat breaks hook state and causes hydration mismatches.

---

## Project setup

A consumer project is a **Bun project** with `@z/runtime` as a path-dependency.

**`package.json`:**
```json
{
  "name": "my-site",
  "private": true,
  "type": "module",
  "dependencies": { "@z/runtime": "file:../../runtime" }
}
```

**`tsconfig.json`:**
```json
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler",
    "strict": true,
    "skipLibCheck": true
  }
}
```

**`build.zig`** — register each island in `zigapagos.website(.islands)`:

```zig
const site = zigapagos.website(b, .{
    .islands = &.{
        .{ .root = b.path("components/Hero.island.tsx"),
           .src  = "components/Hero.island.tsx" },
        .{ .root = b.path("components/Promo.island.tsx"),
           .src  = "components/Promo.island.tsx" },
    },
    .output_path = "site",
    .force = true,
});
```

`src` is the string you write in `<island src="...">`. The build spawns the Bun
sidecar to SSR each island and bundles each to an ES module at
`/islands/<Name>.island.js`, keeping `@z/runtime` external. An import map in the
output HTML wires `@z/runtime` → the shared `/zigapagos-runtime.js` bundle, ensuring
one Preact instance across all islands.

---

## SSR + hydration model

```
build time                           runtime (browser)
──────────────────────────────────   ──────────────────────────────────────────
Bun sidecar SSRs each island         import map: "@z/runtime" → /zigapagos-runtime.js
  → HTML fragment in page            each /islands/Name.island.js imports it (external)
  → data-z-props (JSON)              initIslands() boots each island from its JS module
  → data-z-module attr                 reads props JSON → hydrates over SSR'd HTML
  → import map injected into <head>
```

The one shared `/zigapagos-runtime.js` is the single Preact instance. Islands do not
inline Preact — their bundles are small ES modules with `@z/runtime` as an external.
Bun is **build-time only**; production is nginx + static files + the API server.

---

## Dev loop (`zigapagos dev`) — live island preview

`zigapagos dev` live-previews island sites: edit a `.island.tsx`, and the loop
rebuilds the affected pages and swaps the island in the browser with its state
intact.

### Setup

None. `zigapagos dev` is zero-config — run it in the site directory:

```bash
zigapagos dev
```

It rebuilds with `zigapagos release --output=public --force`, discovering your
`*.island.tsx` and `*.spa.tsx` entries itself, boots the stock ZigBase binary
over the built tree (fetching the pinned release into its cache if you have not
installed one), and watches your content, layout, asset and component
directories. Browse to `http://127.0.0.1:1990/`.

Every default is overridable — `--site=DIR` for a different output tree,
`--port=N`, `--no-download` on an offline machine, or `-- CMD ARGS...` to
substitute your own rebuild command. `zigapagos dev --help` lists them.

### What the dev bundle looks like

The dev bundle is the production bundle plus the fast-refresh transform, which is
what makes the state-preserving hot-swap possible. Both use:

- `--external=@z/runtime` — keeps the one shared Preact instance (import-map wired)
- `NODE_ENV=production` — forces production JSX transforms (`jsx`/`jsxs`, not `jsxDEV`)
- `--format=esm` — ES module output

This means the one-Preact-instance invariant and hydration behaviour are identical
in dev and prod.

### State-preserving hot-swap

Only the changed island's DOM subtree is swapped; unrelated component state is not
reset, and the changed component's own `useState`/`useReducer` state survives when
its hook signature is unchanged. See
[Dev hot-swap (HMR) and fast refresh](../islands.md#dev-hot-swap-hmr-and-fast-refresh).
