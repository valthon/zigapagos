> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/spa/> — the site is the canonical reading experience.

# Native SPA Support

Zigapagos supports authoring and building first-class Single Page Applications (SPAs) using the same TypeScript + Bun + `@z/runtime` toolchain as islands. This document covers SPA authoring, the build rendering model, the runtime router API, and deployment configuration.

## What an SPA is

An SPA in Zigapagos is declared as a single `.spa.tsx` file that exports:

```ts
export const spa = {
  base?: string;      // URL prefix, e.g. "/app"
  title?: string;     // page <title>
  noindex?: boolean;  // <meta name="robots" content="noindex">; defaults to true
  flags?: Record<string, boolean>;  // build-time feature-flag defaults — see below
};

export const routes = [
  {
    path: string;
    component?: ComponentType;              // required — unless the entry is a `redirect`
    skeleton?: ComponentType | false;       // loading state — REQUIRED on dynamic routes (false = explicit opt-out; redirect entries exempt); see below
    guard?: (loc) => Promise<GuardResult>;  // see Route Guards
      // GuardResult = true | { redirect: string } | { ok: true, data? }
    children?: RouteDef[];                  // nested/layout routes — see Nested & Layout Routes
    staticPaths?: Array<Record<string,string>>
      | (() => Array<Record<string,string>> | Promise<Array<Record<string,string>>>);
                                             // per-entry prerendering — see below
    redirect?: string;                       // declarative redirect — see Declarative Redirects
  }
];

export default function App() {
  // root component, typically wraps a Router
}

// optional, client-only — see "Client-only init" below
export function clientInit(): void {}
```

The `.spa.tsx` module is the **single source of truth** for:
- Route definitions (the namespace and URL patterns)
- Prerendering (which routes are static, which are dynamic patterns)
- Client-side routing (the `Router` component uses the same routes array)
- Host configuration (the base and deploy target)

> **`noindex` defaults to `true`.** SPA shells are non-indexable by default
> (`<meta name="robots" content="noindex">` is emitted into every shell)
> unless you explicitly set `noindex: false` in `export const spa`.

### Head assets

Every SPA shell has a fixed `<head>` — normally that's fine, but a
design-system app often needs its own stylesheet or a font `preconnect`.
`spa.head` is a structured hook for exactly that:

```ts
export const spa = {
  base: "/app",
  title: "…",
  head: [
    { rel: "stylesheet", href: "/styles.css" },
    { rel: "preconnect", href: "https://fonts.example.com" },
  ],
};
```

Each entry is an attribute map for one `<link>` tag, rendered in declaration
order immediately after the import map and before any `modulepreload` —
`<link rel="stylesheet" href="/styles.css"><link rel="preconnect" href="https://fonts.example.com">`.
The structured form (rather than a raw HTML string) keeps the [strict-CSP
hash story](#content-security-policy-strict-csp) intact: `spa.head` can only
ever add `<link>` tags, never a new inline `<script>`. Attribute names must be
a literal HTML attribute name (`[a-zA-Z][a-zA-Z0-9-]*`) — anything else fails
the build with an error naming the SPA and the offending attribute; attribute
values are HTML-escaped.

**Local head assets stage themselves.** A `head` entry with a root-relative
`href` (e.g. `/site.css`) is resolved against the asset pipeline at build
time:

1. If a matching file exists in the assets dir, it is **staged
   automatically** — same mechanics as a `static_assets` entry, no extra
   `build.zig`/`zigapagos.ziggy` wiring needed.
2. Otherwise, if a declared build asset installs that path (its
   `install_path` matches), the reference marks it for install.
3. Otherwise the **build fails**, naming the SPA and the href — a renamed or
   missing stylesheet is a build error, not a silent 404 and an unstyled
   page in production.

A query/fragment on the href (`/site.css?v=2`) is ignored for the file
lookup, and on a site with a `url_path_prefix` (e.g. a GitHub Pages project
site) a prefixed href like `/myproject/site.css` resolves to `site.css` in
the assets dir. External (`https://…`) and protocol-relative (`//…`) hrefs
are not checked — see the [CSP section](#content-security-policy-strict-csp)
for how their origins are folded into the emitted policy. The check runs in
release builds (`zigapagos release`); the dev server serves assets straight
from the assets dir.

**No `spa.head` at all, on a site with stylesheets, is a build-time warning.**
SPA shells have a fixed `<head>` and do not inherit site styles, so a SPA
that declares no `head` while the site has at least one `.css` asset will
render its routes unstyled — the exact failure this project hit dogfooding
its own marketing site. The build prints:

```
warning: spa '<src>' declares no spa.head, but the site has stylesheet assets (e.g. '/<path>') — SPA shells have a fixed <head> and do not inherit site styles, so this SPA's routes will render unstyled. Add a stylesheet to `export const spa` (head: [{ rel: "stylesheet", href: "/site.css" }]), or set head: [] to declare the SPA intentionally loads no head links.
```

naming the SPA and one qualifying stylesheet (picked deterministically — the
lexicographically smallest matching asset path, not build-iteration-order
dependent). `head: []` — an **explicitly empty array**, distinct from an
absent `head` — declares "this SPA intentionally loads no head links"
(inline styles, CSS-in-JS) and silences the warning permanently; any
non-empty `head` (even preconnect-only) is silent too, since declaring the
hook at all means you've made a deliberate choice. It is a warning, not a
build error, and — like the head-asset staging check above — runs in
**release builds only** (`zigapagos release`); the dev server does not
evaluate it.

### Feature-flag defaults (`spa.flags`)

`useFlag` reads the page-global flag state resolved by `initFlags` (a fetch of
`/api/flags/state`). Without defaults, every flag reads `false` until that
answer arrives — so a **default-ON** flag gating primary UI would flash its
OFF branch on every boot. `spa.flags` bakes the defaults in at build time:

```ts
export const spa = {
  base: "/booking",
  flags: { bookAsGuest: true, promoBanner: false },  // defaults, known at build time
};
```

What the build does with it:

- **Every shell carries a snapshot.** The prerender pass inlines the defaults
  into each shell as a JSON **data block** (in declaration order, so shell
  bytes are deterministic):

  ```html
  <script type="application/json" data-z-flags>{"flags":{"bookAsGuest":true,"promoBanner":false},"experiments":{}}</script>
  ```

- **The SSR'd skeleton sees the defaults.** The render sidecar seeds its flag
  store from `spa.flags` before rendering, so the prerendered HTML already
  shows the default-ON branches.
- **The first client render sees them too.** `mountSpa` seeds the flags store
  from the snapshot *before* hydration, so `useFlag`'s first render is the
  declared default — correct by construction, never false-while-loading —
  and both hydration passes agree with the SSR markup.
- **Real state still wins.** The snapshot lands in the same store the real
  `/api/flags/state` answer (and any SSE-triggered re-fetch from
  `initFlags({ live: true })`) writes to, so live state reconciles over the
  defaults through the normal subscription path the moment it arrives. If the
  store already holds resolved state, the seed is skipped.

Values must be booleans — anything else fails the build with an error naming
the offending flag. Flags **not** declared in `spa.flags` behave as before
(`false` until resolved). The snapshot is a `type="application/json"` data
block, never executed, so it needs no strict-CSP `script-src` hash (same as
the `data-z-props`/`data-z-slots` blocks — see
[Content Security Policy](#content-security-policy-strict-csp)).

### Client-only init (`clientInit`)

**The module top level of a `.spa.tsx` should be import-only.** The module
also executes under build-time SSR (the render sidecar imports it to describe
routes and prerender skeletons), so any client-side side effect at module load
— installing an error relay, applying a persisted theme before first paint —
would need a `typeof document === "undefined"` guard, and a forgotten guard
fails the *build* with a sidecar `document is not defined`.

Instead, export the optional client-only lifecycle hook:

```ts
export function clientInit(): void {
  initErrorRelay({ endpoint: "/api/client-errors" });
  document.documentElement.setAttribute("data-theme", storedTheme());
}
```

Semantics:

- The shell bootstrap imports the SPA module as a namespace and hands it to
  `mountSpa`, which calls `clientInit()` (if exported) in the browser
  **before the first render/hydration** — after the [`spa.flags`
  snapshot](#feature-flag-defaults-spaflags) is seeded, so `clientInit` may
  read flag state.
- The **SSR sidecar never calls it**, so no `document`/`window` guards are
  needed inside.
- It runs **once per page load** (a hard navigation), not on soft
  navigations.
- A throwing `clientInit` is reported via the standard error surface
  (`window.zigapagosOnError`, else `console.error`) and hydration proceeds —
  a broken init must not dead-page the app.

`clientInit` is also the place to install client observability — either the
basic error relay (`initErrorRelay`) shown above, or the first-class
`initObservability` (structured, source-map-aware payloads; sampling + dedup;
perf capture; a pluggable adapter). See
[Client Observability](observability.md).

### Example

The example SPA is at `examples/tsx-site/app/app.spa.tsx`:

```ts
import { Router } from "@z/runtime";
import { AppShell, Home, Booking, ClubDetail, ClubSkeleton, NotFound } from "./views/index.ts";

export const spa = { base: "/app", title: "pilot-site app", noindex: true };
export const routes = [
  { path: "/", component: Home },
  { path: "/booking", component: Booking },
  { path: "/club/:id", component: ClubDetail, skeleton: ClubSkeleton },
];

export default function App() {
  return (
    <AppShell>
      <Router base={spa.base} routes={routes} notFound={NotFound} />
    </AppShell>
  );
}
```

Each route has a `component` (the real view) and an optional `skeleton` (the loading state).

**A dynamic route (or any route whose SSR output differs from its first client render) MUST declare an explicit `skeleton`.** The router's two-phase hydration renders `route.skeleton ?? route.component` on BOTH the server pass and the first client render (before flipping to `route.component` post-mount) — see [Hydration and Soft Navigation](#hydration-and-soft-navigation). If you omit `skeleton` and instead branch on `isServer()` *inside* `component`, the SSR pass renders the `isServer() === true` branch, but the first CLIENT render also renders `component` — and by then `isServer()` is `false`, so it renders the client/data branch instead. That mismatches the SSR markup and breaks Preact's hydration (see the `Router` component's hydration comment in `runtime/src/router.ts` for the failure mode). `isServer()` is for data-gating *within* an already-hydration-safe component (loading vs. data, both reachable from the same route entry); it is not a substitute for a route's `skeleton`.

**This rule is ENFORCED at build time** for the mechanically-detectable case: the describe pass **fails the build** when a route whose full path contains a `:param` or `*` segment has no `skeleton`, with an error naming the SPA and the route. Three details of the check:

- **Only the leaf's own `skeleton` counts.** A layout route (one with `children`) renders its real `component` on both hydration passes and never a skeleton, so a parent's `skeleton` cannot cover a dynamic child — declare the skeleton on the **leaf** (this includes a static child under a dynamic layout, e.g. `/club/:id` → `/details`: the full path `/club/:id/details` is dynamic, so the `/details` leaf needs the skeleton).
- **`skeleton: false` is the explicit opt-out.** It means *"I promise this component is hydration-stable — it renders identically on SSR (where every `:param`/`*` is `_`) and on the first client render"* and suppresses the build error. The router treats it exactly like an absent skeleton (the component renders on both passes); the promise is yours to keep. Reach for it only when the component genuinely ignores its params until after hydration.
- **`lazy()` routes are stricter: a real `skeleton` is required, even on a static path, and `skeleton: false` is rejected.** A lazy route's `component` is a code-split marker that cannot render until its chunk loads, so there is nothing hydration-stable to promise — SSR and the first client render must show a skeleton. The describe pass fails the build for a lazy route whose skeleton is absent *or* `false`, on any path shape.

The broader prose rule still applies beyond what the build can prove: a *static* route whose component branches on `isServer()` (client-only content) needs a `skeleton` too, and no build error will catch it.

## The Rendering Model

At `zigapagos release`, the build:

### 1. Describes the SPA
The render sidecar reads the `.spa.tsx` module and extracts `spa` and `routes` via the `describe` request.

### 2. Classifies routes
- **Static routes** (no `:param`): `path: "/"` → prerender `app/index.html`
- **Static routes**: `path: "/booking"` → prerender `app/booking/index.html`
- **Dynamic patterns** (with `:param`): `path: "/club/:id"` → prerender one `app/club/_shell.html` (the `:id` is sanitized to `_`)

#### Per-entry prerendering (`staticPaths`)

By default a dynamic pattern only prerenders its single `_shell.html` — the
build never renders concrete IDs like `app/club/1.html` on its own. A route's
`staticPaths` hook additionally enumerates concrete entries so each one gets a
**real** prerendered page:

```ts
{ path: "/club/:id", component: ClubDetail, skeleton: ClubSkeleton,
  staticPaths: async () => (await loadClubs()).map((c) => ({ id: c.id })) }
```

- `staticPaths` is an **array** of param records, or a **sync/async function**
  returning one. It is resolved **once at build time**, in the sidecar's
  `describe` step — it never ships to the browser.
- Each resolved entry emits `<base>/<concrete>/index.html` (e.g.
  `app/club/1/index.html`) alongside the pattern's `_shell.html`, which keeps
  serving every param the entries didn't enumerate. Each concrete URL is
  listed under the routing manifest's `static` array, so deploy targets serve
  it directly ahead of the dynamic-pattern fallback.
- Param values must be **URL-safe path segments** — percent-encoding-stable
  (`encodeURIComponent(value) === value`), and never `""`, `"."`, or `".."`.
  A non-URL-safe value is a **build error**, not silently encoded: an encoded
  directory like `a%20b` is written encoded to disk, but a host that decodes
  the request path before matching (e.g. nginx's `try_files`) would never serve
  it. Give the entry a clean id (or encode it yourself into a stable segment).
- **Build errors, not silent no-ops:** declaring `staticPaths` on a route with
  no `:param`/`*` segment is a build error (there is nothing to enumerate);
  declaring it on a **layout route** (one with `children`, which prerenders no
  page of its own) is a build error (declare it on the leaf); an entry missing
  a param the pattern requires, or resolving to a non-URL-safe/`.`/`..`/empty
  segment, is also a build error.
- **Duplicate/colliding entries are a build error too:** two `staticPaths`
  entries (on the same route or different routes) that resolve to the same
  concrete URL, or an entry that lands on a declared static route's URL, fail
  the build with a message naming the SPA, both route patterns, and the
  colliding URL — rather than silently writing the same output file twice.
- **`zigapagos serve` renders the same per-entry pages release does:** each
  `staticPaths` entry gets its own shell in dev too (not just the dynamic
  pattern's `_shell.html`), kept in sync on every source-file change like
  every other route's shell, and served ahead of the pattern fallback by the
  dev router's exact-match tier — no separate dev-only behavior to remember.

### 3. Renders skeletons
For each route, the build SSRs the skeleton (loading state):
- If a route has an explicit `skeleton` component, that is rendered.
- Otherwise, the route's `component` is rendered with `isServer()` returning `true`, so the component can branch on that flag to render its skeleton. For a **dynamic** route this branch is only reachable via the explicit `skeleton: false` opt-out — a dynamic route with no `skeleton` at all **fails the build** (see the skeleton rule under [Example](#example) above).

The skeleton is embedded in the HTML shell so the client sees it immediately (before the real data loads and the real component hydrates).

**Hydration safety:** the "otherwise" branch above only produces build-time
(SSR) output — it does NOT make the route hydration-safe. The client
router's first render also uses `route.skeleton ?? route.component`, but by
then `isServer()` is `false`, so an `isServer()`-only `component` renders its
*other* branch on that first client render, mismatching the SSR markup. Give
any route whose SSR output and first-client-render output would otherwise
diverge (in practice: any dynamic route — enforced at build time — and any
static route with client-only content) an explicit `skeleton`.

### 4. Generates shells
Each shell is a complete HTML document that:
- Contains the skeleton HTML
- Includes the import map (mapping `@z/runtime` to the shared runtime bundle)
- Includes the `data-z-flags` JSON data block when the SPA declares [`spa.flags`](#feature-flag-defaults-spaflags)
- Includes `<link rel="modulepreload">` hints for the runtime and SPA bundle
- Includes the mount root `<div id="z-spa-root">` (where the React tree hydrates) — carrying a
  `data-z-prefix` attribute when the site has a `url_path_prefix`, so `mountSpa` can compose the
  router's base identically to what the build's SSR pass used (see [Sites served under a path
  prefix](#sites-served-under-a-path-prefix)); absent on an unprefixed site
- Includes the `mountSpa` boot code to start the hydration

### 5. Emits artifacts
- `<base>/<route>/index.html` — static route shells (e.g., `app/index.html`, `app/booking/index.html`)
- `<base>/<pattern>/_shell.html` — dynamic pattern shells (e.g., `app/club/_shell.html`)
- `spa/<name>.js` — the SPA bundle (e.g., `spa/app.js`)
- `/zigapagos-runtime.js` — the shared runtime (router, islands, Preact)
- `<base>/routing-manifest.json` — canonical routing metadata (consumed by the host-config emitter; not read by any server directly)
- per-target hosting config, keyed by `deploy_target`:
  - **zigbase** → `<base>/.spa` (an empty marker file) + `<base>/zigbase.static_routes.zig` (an optional comptime snippet)
  - **nginx** → `<base>/nginx.nginx.conf`
  - **apache** → `<base>/apache.htaccess`
- `/404.html` — the universal fallback: the 404-owner SPA's `/` shell (`not_found` in `build.zig`; defaults to the first declared SPA)

## Hydration and Soft Navigation

The client-side flow:

1. **First load:** the browser downloads the static shell and boot code. The
   boot seeds the flag store from the [`spa.flags` snapshot](#feature-flag-defaults-spaflags)
   and calls the module's optional [`clientInit()`](#client-only-init-clientinit)
   — both before the first render.
2. **Hydration (two-phase):**
   - The `Router` renders to match the prerendered skeleton (to match the initial HTML).
   - After mount, it re-renders with the real component (which may fetch data).
3. **Soft navigation:** the router intercepts clicks on router-internal `<Link>` elements (base-relative hrefs — see [Navigation is base-relative](#navigation-is-base-relative)), updates the URL, re-renders, and fetches real data from the API. The shell stays in place; only the content inside the `Router` changes.
4. **Hard refresh on dynamic routes:** the browser reloads the page and fetches the pattern shell (`_shell.html`).

Data loading happens entirely in the client: components use `useLocation()` or `useParams()` to determine the current route and fetch data accordingly (not shown in the skeleton).

## Router API

All router symbols are imported from `@z/runtime`:

### Navigation is base-relative

**Router-internal paths resolve relative to `spa.base`.** Every in-SPA
navigation target — `<Link href>`, `navigate(to)`, `useNavigate()(to)`, a
guard's `{ redirect }` target, and a route entry's `redirect` — is an
**in-app** path that the router prefixes with the base:

```tsx
// with spa.base = "/app":
<Link href="/booking">…</Link>     // renders <a href="/app/booking">, soft-navs there
navigate("/login");                 // soft-navigates to /app/login
{ redirect: "/login" }              // guard redirect → /app/login
```

This makes `spa.base` a **single point of configuration**: remounting the SPA
(say `/admin` → root-mounted on its own subdomain) changes `spa.base` only —
no link or `navigate` call site changes.

Resolution rules (`resolveHref(to, base)`, exported for reuse/tests):

- **Root-relative path** (`"/login"`, `"/club/42?tab=x#y"`) → prefixed with
  the base (trailing slashes of the base trimmed). `"/"` resolves to the base
  itself with a trailing slash (`"/app/"`). With a root-mounted base (`""` or
  `"/"`) the path is unchanged.
- **Absolute or protocol-relative URL** (`"https://…"`, `"mailto:…"`,
  `"//host/…"`) → **external**: returned untouched, rendered as a plain
  anchor, and `navigate()` performs a full-page `window.location` navigation.
  This — or a plain `<a>` — is the escape hatch for cross-SPA and external
  targets. `navigate(to, { external: true })` forces a full-page navigation
  even for a same-origin path (no base resolution, no soft-nav).
- **Bare relative path** (`"settings"`, `"?q=1"`, `"#top"`) → untouched;
  `<Link>` does not intercept it (normal browser relative resolution).

Resolution is **always applied** — an already-base-prefixed path is *not*
deduped: `<Link href="/app/booking">` under base `/app` targets
`/app/app/booking`, because `/app/booking` might be a legitimate in-app path.

#### Sites served under a path prefix

The router's **effective base is `url_path_prefix + spa.base`** — composed
inside `<Router>`, never by the author. Nothing at a call site changes: you
still write `base={spa.base}` and still author every `href`/`to`/`redirect`
base-relative exactly as above.

`url_path_prefix` (the site's `zigapagos.ziggy` setting, e.g. a GitHub Pages
project site's `/myrepo`) can't be detected at runtime and folded in
client-side: Preact's `hydrate()` does not diff element **attributes** on its
first pass, so an `<a href>` the SSR pass and the first client render
disagree about is left wrong in the DOM permanently. The prefix therefore has
to reach the build's SSR pass itself, not just the browser.

It gets there over two build-controlled channels that cannot disagree with
each other:

- The build SSRs each route at the **prefixed** pathname and sends the
  prefix to the render sidecar as a `"prefix"` field on the NDJSON render
  request (alongside `"pathname"`).
- The shell carries the same prefix to the browser as a `data-z-prefix`
  attribute on the `#z-spa-root` hydration root, which `mountSpa` reads
  before the first render. The attribute rides on the hydration root
  specifically: hydration renders *into* that element, so its own attributes
  are never diffed away, and putting it there leaves the inline boot script
  byte-unchanged, so a strict-CSP `script-src` hash (see [Content Security
  Policy](#content-security-policy-strict-csp)) does not churn.

What changes observably on a prefixed deploy: prerendered `<a href>` values
are the real deployable URLs and work **without JavaScript**; a soft
navigation now pushes the prefixed URL, so a subsequent hard refresh
resolves instead of 404ing; and `useLocation().pathname` under SSR now
agrees with what the browser reports. **A site with no `url_path_prefix` is
unaffected, byte for byte** — the composition is a no-op.

The prefix reaches the rest of the build too:

- **Island pages get the same parity.** An island's SSR pathname
  (`host.pathname()`, `useLocation()`) carries the prefix, so an island that
  branches on the path — active-nav highlighting, breadcrumbs — renders the
  same thing at build time as it does after hydration. (Same reason as above:
  `hydrate()` does not repair a mismatched attribute.)
- **The [host-config emitters](#deploy-targets) honour it**, each according to
  its own semantics rather than by prepending the prefix everywhere — see
  [Deploy targets under a path prefix](#deploy-targets-under-a-path-prefix).

> **Migration (prerelease breaking change).** Previously `navigate(to)`
> pushed `to` **verbatim** and `<Link href>` needed the full base-prefixed
> path (`<Link href="/app/booking">`). Migrate every router-internal call
> site by stripping the base prefix: `href="/app/booking"` → `href="/booking"`,
> `navigate("/app/login")` → `navigate("/login")`, and guard redirects
> `{ redirect: "/app/login" }` → `{ redirect: "/login" }`. Links that
> deliberately pointed *outside* the base (previously rendered as plain
> anchors) must become absolute URLs or plain `<a>` tags — a root-relative
> `<Link href>` is now always router-internal.

### Components

**`<Router>`**
```tsx
<Router
  base={spa.base}         // URL prefix (must match spa.base)
  routes={routes}         // array of RouteDef
  notFound={NotFound}     // component shown for unmatchedRoutes
/>
```
Renders the matched route's component, or `notFound` if no match.

**`<Link>`**
```tsx
<Link href="/booking" className="...">Book Now</Link>
```
`href` is **base-relative** (see [Navigation is base-relative](#navigation-is-base-relative)):
the rendered anchor carries the resolved `href` (`/app/booking`), and a click
soft-navigates (hijacked, no reload). An absolute/protocol-relative URL
renders a plain anchor (full-page navigation).

**Outside a `<Router>` is a build error.** With no router context the `href`
cannot resolve against the SPA base and the click is never intercepted, so
the prerendered shell would ship a dead link — on a path-prefixed host, a
hard 404. The build's SSR pass therefore throws, and the build fails naming
the `.spa.tsx` and the offending `href`. On the **client**, the same
situation only warns once per `href` and degrades to a plain anchor rather
than throwing — throwing during hydration would unmount the whole subtree,
which is worse than one link that does a full page load.

**Consequence worth stating explicitly:** `<Link>` is router-internal, so a
`<Link>` inside an `.island.tsx` on an ordinary content page is now a build
error too (an island SSRs through the same path). Use a plain `<a>` there.
The same applies to a view unit-tested in isolation with `renderForTest`
(see [Unit-testing a view](#unit-testing-a-view-renderfortest)) — wrap it in
a `<Router>`, or use a plain `<a>`.

### Hooks

**`useParams<T>()`**
Returns `T` (the captured params for the matched route).

```tsx
function ClubDetail() {
  const { id } = useParams<{ id: string }>();
  return <h1>Club {id}</h1>;
}
```

**`useLocation()`**
Returns `{ pathname: string; search: string }`. `pathname` is the router's
current-route pathname, which is the **full** `window.location.pathname`
(NOT stripped of `base`) — `matchRoute` strips `base` internally only when
matching against `routes`; `useLocation()` hands back the raw, un-stripped
pathname. `search` is not router state at all: it's read directly from
`window.location.search` on the client on every call; server-side it's parsed
from the SSR pathname's query when the build threaded one, else `""` (the
hardened SSR-vs-client read centralized as `currentSearch()` in ssr-env,
which `host.search()` also aliases).

**`useNavigate()`**
Returns a function to navigate programmatically.

```tsx
const navigate = useNavigate();
navigate("/booking"); // soft-navigate to <base>/booking — base-relative
```

**`useSearchParams()`**
Returns `[URLSearchParams, setSearchParams]` (React-Router-shaped). Unlike
`useLocation().search` (a raw string, and not reactive to a query-only change),
the getter is a parsed, **reactive** `URLSearchParams` that re-renders on any
navigation — including one that changes only the query. The setter accepts a
`URLSearchParams | Record<string,string> | string` and navigates to the same
pathname (and hash) with the new query (push by default, `{ replace: true }` to
replace). SSR-safe (server → the SSR pathname's query, or empty).

```tsx
const [params, setParams] = useSearchParams();
const tab = params.get("tab") ?? "overview";
// update the query without a full navigation:
setParams({ tab: "billing" });          // pushes ?tab=billing
setParams({ tab: "billing" }, { replace: true });
```

### Utilities

**`navigate(to, options?)`**
Programmatic navigation. Options: `{ replace?: boolean; external?: boolean }`.
`to` is **base-relative** (see [Navigation is base-relative](#navigation-is-base-relative));
an absolute URL or `{ external: true }` performs a full-page
`window.location` navigation instead of a soft-nav.

**`resolveHref(to, base)` / `isExternalHref(to)`**
The resolution primitives `Link`/`navigate` use, exported for reuse and tests.

**`mountSpa(App, selector)`**
Bootstrap the SPA: creates a Preact instance and hydrates it into the DOM element matching `selector` (usually `"#z-spa-root"`). Called automatically by the generated shells, but available for custom mount points.

**Scroll restoration** (on by default)
Soft navigation manages scroll like a browser: a **push** (new entry via `navigate`/`Link`)
scrolls to the top; **back/forward** (popstate) restores the scroll position saved for *that*
history entry. Positions are keyed to the history entry (a monotonic id in `history.state`),
not the pathname, so a repeated path restores the right position. Call
`setScrollRestoration(false)` to opt out (e.g. to manage scroll yourself).

**`isServer()`**
Returns `true` during SSR (build time), `false` in the browser. Used for
data-gating (loading vs. real content) inside a component that is **not**
itself a route's top-level hydration boundary — e.g. a component only ever
reached after the route has already flipped to its real `component` post-hydration.
It is **not** sufficient, by itself, as a route's `skeleton`: see
[The `.spa.tsx` module](#what-an-spa-is) above for why an `isServer()`-only
branch inside a route's `component` breaks hydration on that route's first
client render. Always give a dynamic (or otherwise SSR/first-client-render-divergent)
route an explicit `skeleton` instead.

```tsx
function ClubDetail() {
  const { id } = useParams<{ id: string }>();
  if (isServer()) return <p>Loading…</p>;
  return <h1>Club {id}</h1>;
}
```

(This `ClubDetail` example is safe only because its route also declares an
explicit `skeleton: ClubSkeleton` — see the routes array above — so the
router never actually reaches `ClubDetail`'s own `isServer()` branch during
hydration; it renders `ClubSkeleton` instead until hydration completes.)

## Declarative Redirects

An index alias ("/" should land on the dashboard) needs no component:

```ts
export const routes = [
  { path: "/", redirect: "/dashboard" },   // base-relative target
  { path: "/dashboard", component: Dashboard },
];
```

The router resolves a `redirect` entry **before rendering** — SSR included —
so the target's view renders on the very first frame (no throwaway
`useNavigate`-in-an-effect frame), and on the client the browser URL is
**replace**-synced to the target (the redirecting path never lands in
history). Semantics:

- The target is a concrete **base-relative** in-app pathname (consistent with
  [navigation](#navigation-is-base-relative)): `"/dashboard"` under base
  `/app` lands on `/app/dashboard`. No `:param`/`*` segments, no query/hash —
  the *current* location's query and hash are preserved automatically.
- `redirect` is mutually exclusive with `component`, `children`, and
  `staticPaths` (a redirect entry is a pure alias); declaring both is a build
  error.
- Redirect **chains** (`/legacy` → `/` → `/dashboard`) are followed and must
  terminate at a concrete (non-redirect) route — a cycle of **any** length is
  a build error. At runtime a broken table (e.g. a stale bundle) still fails
  soft: `notFound`, dev-warned once, never an infinite loop.
- The entry still **prerenders its own shell** (`<base>/home/index.html` for
  `{ path: "/home", redirect: "/" }`) so deep links and hard refreshes work —
  and that shell carries the **target's** SSR'd content.

**Build-time validation.** The describe pass ships each `redirect` to the Zig
build, which validates every target against the same SPA's route table,
**following chains**: a target that matches no route (or isn't a concrete
root-relative pathname) anywhere along the chain, or a chain that cycles
instead of terminating at a concrete route, fails the build with an error
naming the SPA and the offending entry — a typo'd target or a redirect loop
never reaches production as a runtime 404. (A target may land on a
`:param`/`*` route by supplying concrete segments, e.g. `redirect: "/club/1"`
against `/club/:id`.)

## Route Guards & Gated SPAs

A cookie-auth-gated area (an admin panel, a members section) needs two guarantees the naive
prerender can't give: the gated content must **not flash** on first paint before a client-side
auth check redirects an anonymous visitor, and it must **not ship** inside the statically
served shell. Route guards provide both.

A route (or the whole SPA) declares an async `guard`:

```tsx
type GuardResult<T = unknown> = true | { redirect: string } | { ok: true; data?: T };
type GuardLocation = { pathname: string; params: Record<string, string> };

export const routes = [
  {
    path: "/secret",
    component: Secret,
    guard: async (loc: GuardLocation): Promise<GuardResult> => {
      const ok = await checkSession();           // hits the backend / reads a cookie
      return ok ? true : { redirect: "/login" }; // BASE-RELATIVE: → <base>/login
    },
  },
];

// App: supply a neutral fallback shown while any guard is pending.
<Router base="/app" routes={routes} fallback={LoadingSpinner} />
```

`Router` also accepts a **namespace-wide** `guard` prop that runs before the matched route's
guard on every navigation — the common "the whole area is gated" case. When both are present
the Router-level guard runs first; the first non-`true` result wins (a redirect short-circuits).

**Why this is safe by construction.** Guards are async and read cookies / call the backend, so
they **cannot run during build-time SSR**. The Router therefore renders the neutral `fallback`
for a guarded route on the SSR pass *and* on the first client render (reusing the two-phase
hydration described above — the fallback plays the skeleton's role), then runs the guard
post-mount and only *then* flips to the real component or issues the redirect. Consequences:

- The prerendered `<base>/secret/index.html` contains the **fallback**, never the gated
  component — so no gated content is served statically (no `spa.zig` change needed; the
  prerender drives the same Router).
- The real component never mounts (and its data-fetching effects never fire) until the guard
  resolves `true` for the current pathname, so an anonymous hard-refresh shows the fallback
  then redirects with **no gated-content flash**.
- Navigation resets the authorized state, so returning to a gated route always re-validates
  from the fallback — no stale-authorized paint. A guard that throws/rejects or never resolves
  **fails closed** (stays on the fallback, never paints the component).
- **Misconfiguration fails closed too:** a guarded route with no `fallback` renders a neutral
  empty placeholder (`<div data-z-guard-pending>`), never `skeleton`/`component` — so the API
  can't leak gated content even if you forget the fallback (it warns once in dev).

The server still enforces the actual authorization on its data endpoints — guards remove the
client-side flash and the public gated HTML; they are not the security boundary themselves.

v1 notes: a namespace-wide `guard` gates every matched route and shows the `fallback` in place
of a dynamic route's `skeleton`; the not-found route is not gated. Per-route error→redirect and
the parent-guard cascade for nested routes are v2.

### Guard data (`useGuardData`)

A guard usually has to *fetch something* to decide — the session, the current user — and the
guarded subtree then needs that same object. Instead of smuggling it through a module
singleton, a guard may return its data alongside the verdict with the `{ ok: true, data }`
form, and anything under the guarded scope reads it with `useGuardData<T>()`:

```tsx
import { useGuardData, apiFetch, type GuardResult } from "@z/runtime";

const requireUser = async (): Promise<GuardResult<User>> => {
  const res = await apiFetch("/api/me");
  if (!res.ok) return { redirect: "/login" }; // base-relative: → <base>/login
  return { ok: true, data: await res.json() };
};

// anywhere under the guarded route (the guarded component itself, a child
// view, a component inside a guarded layout's <Outlet/> subtree):
function ProfileHeader() {
  const user = useGuardData<User>();
  return <span>{user?.name}</span>;
}
```

Semantics:

- `true` stays valid and is equivalent to `{ ok: true }` — `useGuardData()` is `undefined`.
- **Nested guards: the nearest guard wins.** Each guarded route (and a Router-level `guard`)
  provides its own data to itself + its subtree; an inner guarded route *shadows* an outer
  one (even when the inner guard returned plain `true`, i.e. `undefined` data). An unguarded
  child under a guarded layout sees the layout guard's data — the nearest guarded *ancestor*.
- Outside any guarded scope (and on SSR, where guards never run) it's `undefined`.
- The value updates when the guard re-validates (every navigation into the scope re-runs the
  guard in the background), and is evicted with the scope's authorization when you navigate
  out of the guarded area.
- A malformed verdict (anything that isn't `true`, `{ redirect }`, or `{ ok: true, … }`)
  **fails closed**: reported via the host error pipe, the scope stays on the `fallback`.

> **Unit-testing a view with injected guard data.** You don't need a browser, the
> Router, or a full build to test what a view renders for a given guard result. The
> `@z/runtime/testing` `renderForTest(View, { guardData, props, flags, pathname })`
> helper renders the view to the same SSR string the build produces, with the guard
> data (and flags) injected as if the guard had already resolved — see
> [Unit-testing a view](#unit-testing-a-view-renderfortest).

### Session expiry (automatic guard re-run on 401)

Every cookie-authed SPA needs the same behavior: a mid-session 401 (expired session) should
send the visitor to the login route. That policy is framework-level — **zero per-site
wiring, no callback to register**:

> When [`apiFetch`](#calling-the-backend--apifetch) sees a **same-origin 401 or 403** while a guarded
> scope is active, the Router re-runs the **active route's guard pipeline once** (Router-level
> guard first, then the chain outermost→innermost, exactly like a navigation). The guard is
> already the single source of truth for "who may be here", so its `{ redirect }` verdict
> navigates to the login route; a `true` verdict means the session is actually fine (the 401
> was endpoint-specific) and nothing changes.

Notes and guarantees:

- Only **`apiFetch`** responses trigger it (raw `fetch` bypasses the policy), and only
  **same-origin** ones — a cross-origin 401 is not our session. The caller still receives
  the 401/403 `Response` unchanged; the re-run happens in the background.
- **Re-entrancy safe:** no re-run starts while a guard run is already in flight, so a guard
  whose *own* probe 401s (e.g. `zbGuard`'s auth-refresh call, or any guard using `apiFetch`)
  cannot recurse — that in-flight run's own verdict settles the question.
- **Loop-bounded:** 401-triggered re-runs are rate-limited by a short cooldown (3s). If the
  guard keeps answering `true` while some endpoint keeps 401ing (an object-level 403, a
  server disagreement), the guard is not hammered on every failed request — while a *real*
  expiry minutes later (past the cooldown) still triggers a fresh re-run and redirect.
- A 401 outside any guarded scope is a no-op (there is no guard to re-run — public routes
  handle their own errors).
- Guard data (`useGuardData`) refreshes with the re-run, and a `{ redirect }` navigation
  evicts the scope's authorization as usual (fail-closed on re-entry).

There is deliberately **no `onUnauthorized` callback surface**: the pure guard-re-run
variant composes with guard data and keeps the guard the single place where "who may be
here" is decided. If a site needs custom behavior, its guard *is* the hook.

### ZigBase auth guard — `zbGuard`

On the ZigBase deploy target you don't hand-roll the session probe at all. `@z/runtime`
ships a guard factory that authenticates against the backend's canonical per-collection
session-introspection route, `POST /api/collections/{collection}/auth-refresh` (the
PocketBase-lineage auth-refresh endpoint — it validates the current cookie session and
returns the authenticated identity):

```tsx
import { zbGuard } from "@z/runtime";

// superuser-gated admin SPA (spa.base = "/admin" — the redirect is
// BASE-RELATIVE, so "/login" lands on /admin/login):
{ path: "/", component: AdminLayout, children: […],
  guard: zbGuard({ collection: "_superusers", redirect: "/login" }) }

// record-auth customer SPA (spa.base = "/portal" → /portal/login):
guard: zbGuard<Customer>({ collection: "customers", redirect: "/login" })
```

- **Fail-closed by construction:** a network error, an offline backend, or any non-OK
  response resolves `{ redirect }` — it never throws into the Router and never authorizes
  on doubt.
- On success it resolves `{ ok: true, data: identity }` — the auth record from the
  `{ token, record }` envelope — so the identity lands in
  [`useGuardData<T>()`](#guard-data-useguarddata) for the whole gated subtree.
- The probe goes through `apiFetch` (same-origin `credentials: "include"` + the `zb_csrf`
  CSRF echo on the POST), so it works identically behind `zigapagos serve --proxy` in dev
  and on the ZigBase host in production, and it composes with the
  [session-expiry policy](#session-expiry-automatic-guard-re-run-on-401): a mid-session
  401 re-runs this guard, which then issues the redirect (the Router's in-flight
  suppression keeps the probe's own 401 from recursing).

## Nested & Layout Routes

Flat route arrays force every view to re-wrap the app chrome. A **layout route** declares
`children`, and its `component` is called with the matched child route **as its `children`
prop** — render it (`{children}`) to place shared chrome around it:

```tsx
function DashLayout({ children }) {
  return (
    <div data-dash-chrome>
      <nav>{/* persistent sidebar/tabs */}</nav>
      {children}        {/* the matched child renders here */}
    </div>
  );
}

export const routes = [
  {
    path: "/dash",
    component: DashLayout,
    children: [
      { path: "/overview", component: Overview },
      { path: "/settings", component: Settings },
    ],
  },
];
```

`<Outlet/>` is the **identical explicit form** — `children` literally *is* an `<Outlet/>`
element, so there is no second mechanism that could drift between the two spellings:

```tsx
import { Outlet } from "@z/runtime";

function DashLayout() {
  return (
    <div data-dash-chrome>
      <nav>{/* persistent sidebar/tabs */}</nav>
      <Outlet />        {/* the matched child renders here */}
    </div>
  );
}
```

**Render exactly one of the two.** Rendering both `{children}` and an explicit `<Outlet/>`
mounts the matched child **twice** — duplicate DOM, duplicate effects/fetches — and the router
does not suppress the second instance: which one "won" would depend on render order, and
silently picking one would make the client diverge from what SSR (which has no such ordering
concept) produced. Rendering **neither** means the matched child route never renders at all —
the silent trap this diagnostic exists for: the layout compiles, SSRs, and paints a
plausible-looking but empty container, with its child route's component never invoked. Both
cases are caught with a `console.warn` (once per layout route path) in the browser; both checks
run in mount effects, so neither ever fires under SSR / at build time — a bad layout still
builds cleanly and only warns once it's actually rendered in a browser.

> **Known false positive.** The "rendered neither" check is deferred past its commit's whole
> effect flush, so a correct layout never trips it on ordering. But a layout that deliberately
> gates its outlet behind state flipped *after* mount (`{ready && children}` for a tab, an
> auth-ready flag) genuinely renders neither channel on that first pass, so it warns — and
> because the warning is once-per-path, it is never retracted when the outlet does appear. It is
> console noise, not a behaviour change: the child renders normally once the gate opens. Render
> the outlet unconditionally and gate *inside* the child if you would rather not see it.

`/dash/overview` and `/dash/settings` each render `DashLayout` wrapping their child at the
`<Outlet/>`. Matching is first-match-wins at **every** level; `:param` captures accumulate down
the chain (nearest-wins on a name collision); a leaf only matches when it consumes every
remaining segment. An **index child** is just `{ path: "/" }` (matches the layout's own path).

**Prerender model (no `spa.zig` change).** The sidecar `describe` flattens the route tree into
leaf **full-paths** (`/dash/overview`, `/dash/settings`), so the segment-agnostic prerender
loop writes each leaf's own `<base>/dash/overview/index.html` — each containing the layout
chrome around the child's skeleton/content. A layout route contributes no shell of its own, so
a layout with no matching child (an index-less layout at its bare path) is served by the SPA
catch-all fallback rather than a dedicated prerendered shell.

**Layout instance persists across soft-nav.** Navigating between sibling children keeps the
same layout instance mounted (React/Preact preserves the component at its tree position) — only
the `<Outlet/>` subtree swaps. Layout state (open menus, scroll, form drafts) survives a tab
switch; there is no full reload.

**Guard cascade.** A guard on a layout (or a Router-level `guard`) gates its whole subtree: an
unauthorized visitor never sees the layout chrome or any gated child (the outermost unauthorized
scope shows the `fallback`; fail-closed as in [Route Guards](#route-guards--gated-spas)).
Authorization is keyed per **guard scope** (the guarded route's matched prefix), so an already-
authorized layout **stays mounted while you switch tabs under it** (re-validating in the
background — no fallback re-flash), while navigating *out* of a gated scope evicts it so a true
re-entry (e.g. after logout) re-gates from the fallback. Guards run outermost→innermost, first
non-`true` wins.

> **Caveat (dynamic layouts):** a layout component renders on the hydration pass, and Preact
> does not diff element *attributes* on that pass. So a layout must not bind a dynamic path
> param to an **attribute** (`<div data-org={org}>`) on a dynamic route — the attribute would
> stick at the prerendered placeholder value. Rendering the param as **text** (`<span>{org}</span>`)
> is safe (text children self-heal on hydrate). This mirrors the dynamic-leaf skeleton rule above.

## Declaring an SPA in `build.zig`

An SPA is declared in the consumer's `build.zig` via a `zigapagos.Spa` entry in the website configuration:

```zig
var opts = try zigapagos.Options.init(b, .{ .site = site });
try opts.spas.append(.{
  .root = b.path("app/app.spa.tsx"),  // path to the .spa.tsx file
  .src = "app/app.spa.tsx",           // relative from site root
  .base = "/app",                     // URL base (MUST match export const spa.base)
});
```

The `.base` in the struct **must** match the `base` exported from the `.spa.tsx` module. The build validates this match and fails loudly if they diverge.

### Choosing the 404 owner (`not_found`)

On a multi-SPA site, the universal `/404.html` reuses ONE SPA's `/` shell. By
default that is the **first declared** SPA in `spas`. To make the choice
explicit and order-independent, name the owner with `not_found`:

```zig
const site = zigapagos.website(b, .{
    .spas = spas,
    .not_found = "booking",  // which SPA's "/" shell backs 404.html
});
```

The name is the SPA's **file basename sans `.spa.tsx`** (the same name that
keys `spa/<name>.js` — `"booking"` for `app/booking.spa.tsx`), not its `base`
URL. A `not_found` that names no declared SPA is a configure-time error.
`serve()` accepts (and validates) the option but has no `404.html` to own —
the dev server serves per-namespace fallback shells and its own 404 page.

## Static Asset Minification (CSS)

Release builds minify text static assets so a Zigapagos site ships them at the
same gzip size a Vite/esbuild build would — the static-asset path is now
consistent with the island/SPA **JS** path, which already minifies.

**Scope.** Currently `.css` **site assets** (files under `assets_dir_path`,
staged because a layout or content file `link`s them, e.g.
`$site.asset('style.css').link()`). Non-CSS and binary assets are always copied
**byte-for-byte**. The hook (`installMinifiedCss` in `src/root.zig`, driven by
`runtime/sidecar/minify-css.ts`) generalizes to other text asset types later.

**How.** Each `.css` asset is piped through Bun's CSS minifier
(`Bun.build({ minify: true })`) with **`external: ["*"]`** — this makes it a
**pure minification** pass, never a bundle: every `url(...)` and `@import` target
is preserved verbatim (no resolving, no hashing, no rewriting), so any
`url_prefix` / path the stylesheet already encodes survives untouched. Only
redundant bytes go: comments, whitespace, and safe value collapses
(`#ffffff` → `#fff`, longhand → shorthand, later-declaration-wins dead drops).
The rendered result is unchanged.

**This is minification only — not purging.** Unused selectors are **never**
removed (no PurgeCSS-style dead-selector pruning); that would require scanning
for used class names and is unsafe with dynamically-composed classes.

**Release-only, mirroring Vite (minify on build, not dev).** Minification runs
only in the **release** (disk-mode) build — `zigapagos release` / `zig build` /
the `zigapagos dev` loop, which all serve the real release tree. The in-memory
preview server (`zigapagos serve`) copies CSS **verbatim**, so
fast-iteration dev output stays readable and un-mangled. The gate is structural:
`build.zig`'s `website()` threads `--bun=bun --css-minify-driver=…` into the
`release` invocation; the live server never does, and the install phase that
minifies is disk-mode-only. A hand-written `zigapagos release` without
`--css-minify-driver` also copies verbatim (backward compatible).

**Failure behavior.** A `.css` asset that Bun's parser rejects **fails the
build** with an actionable error naming the file; Bun's own diagnostics reach
the build log via inherited stderr. This matches the JS bundling path (a broken
bundle fails the build) and surfaces genuinely broken CSS rather than silently
shipping it.

## Deploy Targets

The build supports multiple deployment targets via `deploy_target` in the site's `zigapagos.ziggy`:

```ziggy
{
  deploy_target = "zigbase",  // default: "zigbase" | "nginx" | "apache"
}
```

Each target emits:

### ZigBase (default)

Requires **ZigBase ≥ 0.10.0**, which ships native SPA-fallback static serving (ZigBase issue #183). Two tiers, matching ZigBase's own model — a zero-config default in the shipped binary, and a more precise comptime option for custom builds.

**Tier 1 — the `.spa` marker (what the stock `zigbase serve` binary reads).**
**File:** `<base>/.spa` (an **empty**, presence-only marker).

ZigBase treats any directory containing a `.spa` file as an SPA root: any GET/HEAD **miss** at or below it serves that directory's `index.html` with status **200** (real files, `/api`, the admin UI, and custom routes always win). So dropping `<base>/.spa` into the deployed tree makes `/app/orders/42`-style deep links and hard refreshes work with **no ZigBase configuration**. The marker requires `<base>/index.html` to exist — it does, since that's the `/` route's shell. In dir mode the marker is resolved live per request (no restart needed to add/remove it); embedded manifests derive it once at startup.

Tradeoff: the marker always serves the generic namespace shell (`<base>/index.html`), so a dynamic-route deep link gets the `/` route's skeleton on first paint rather than the route's dedicated `_shell.html`. The client router still boots, reads the URL, and renders the correct view — only the pre-hydration skeleton is generic. Tier 2 recovers the dedicated shell.

**Tier 2 — comptime `static_routes` (optional, custom ZigBase build).**
**File:** `<base>/zigbase.static_routes.zig` (a ready-to-paste snippet; **not** auto-installed — it's compiled into the app).

To serve each dynamic route's dedicated prerendered shell, a custom ZigBase build can declare explicit `match → serve` rewrites. The emitter generates the snippet from the route table:

```zig
.static_routes = &.{
    .{ .match = "/app/club/:id", .serve = "/app/club/_shell.html" },
    .{ .match = "/app/**",       .serve = "/app/index.html" },
},
```

Paste it into your `zigbase.App(.{ ... })` config. First match wins in declaration order; `:id` matches one segment, `**` matches zero-or-more trailing segments. Declaring `static_routes` turns the `.spa` marker off by default (set `.enable_spa_marker = true` to keep both — routes match first, the marker is the residual fallback). Real files always win over both tiers, so the static route shells (`<base>/booking/index.html`, …) are served directly and don't need rules.

> The pre-0.10.0 adapter emitted a `zigbase.zigbase.json` manifest copy on the assumption ZigBase would read it directly. It never did; the `.spa` marker (+ optional `static_routes`) is the real contract, so the manifest copy is no longer emitted. The canonical `<base>/routing-manifest.json` remains as zigapagos's own artifact (the emitter reads it) but no server consumes it.

### Nginx
**File:** `<base>/nginx.nginx.conf`

A location block for nginx. Include this in your nginx config inside the `http` or `server` block:

```nginx
include /path/to/app/nginx.nginx.conf;
```

The emitted config:
- Serves static files from the base directory.
- Uses `try_files` to fall back to route shells for unmatchedRoutes.
- Routes dynamic patterns to `_shell.html` (e.g., `/app/club/*` → `/app/club/_shell.html`).

Example emitted snippet:

```nginx
location /app/ {
  try_files $uri $uri/ /app/index.html;
}
location /app/club/ {
  try_files $uri /app/club/_shell.html /app/index.html;
}
```

### Apache
**File:** `<base>/apache.htaccess`

An `.htaccess` file for Apache. Install this as `.htaccess` in your document
root. It uses `mod_rewrite` (not `<Directory>` blocks, which are **forbidden**
inside `.htaccess` context and would make Apache fatal on startup):

```
# Generated by emit-host-config.ts for SPA namespace /app — install as <docroot>/.htaccess
RewriteEngine On
# Dynamic route patterns → their prerendered shell
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^app/club/.*$ /app/club/_shell.html [L]
# Namespace fallback → the SPA shell
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^app/.*$ /app/index.html [L]
```

One `RewriteRule` block per dynamic route pattern (matched against its static
prefix directory), followed by one fallback block per SPA namespace. Rule
*patterns* are relative (no leading slash, matched against the per-directory
request path); rewrite *targets* keep their leading slash.

### Deploy targets under a path prefix

When the site sets a `url_path_prefix` (see [Sites served under a path
prefix](#sites-served-under-a-path-prefix)), the emitted host configs account
for it — but **not by prepending it everywhere**, because the three targets do
not mean the same thing by a path.

The reason is one fact about the build: **the output tree contains no prefix
directory.** `url_path_prefix` says where a host *mounts* the tree, not where
files sit inside it. So a path in the generated config is either a **request
path** (which carries the prefix) or a **tree-relative path** (which must not),
and which one it is depends on the directive:

| target | prefixed | left tree-relative |
|--------|----------|--------------------|
| nginx | `location` selectors; `try_files` fallback/shell targets (an internal redirect that must re-enter the same `location`) | — |
| Apache | a `RewriteBase <prefix>/` directive | `RewriteRule` patterns (a per-directory `.htaccess` matches with the directory's URL-path already stripped) and their targets, which resolve against `RewriteBase` |
| ZigBase | `.match` patterns | `.serve` targets — ZigBase resolves them against its static root, so a prefixed one would name a file that does not exist |

The `.spa` marker is unchanged: it is presence-only, and its meaning is its
location in the tree.

`routing-manifest.json` therefore carries the prefix as its own
`url_path_prefix` field and leaves every route value tree-relative, so each
emitter can apply it its own way. The field is **omitted entirely** when there
is no prefix, so an unprefixed site's manifest and configs are byte-identical to
those built before this existed.

> The manifest's `bundle` (and the `chunks` *values*) are the deliberate
> exception — they are already-prefixed URLs, because they are baked verbatim
> into the shell's `<script>` and `modulepreload` tags.

### Universal `404.html`
**File:** `/404.html`

A fallback for any unmatchedRoutes outside explicit base paths. This is the 404-owner SPA's shell — the SPA named by `build.zig`'s `not_found` option, or the first declared SPA by default (see [Choosing the 404 owner](#choosing-the-404-owner-not_found)); it ensures deep-link requests to SPAs don't 404 at the hosting layer. (Multi-SPA `404.html` covers only the owner's namespace; per-namespace catch-all is the real mechanism.)

Overriding this fallback from a content page requires the alias to be root-absolute (`"/404.html"`); a bare `"404.html"` lands inside the page's own output directory instead and now warns at build time.

### Content Security Policy (strict CSP)

A hardened deployment runs CSP without `unsafe-inline`, which would block the generated inline
`<script type="importmap">` and the inline `mountSpa` bootstrap. Their content is deterministic
at build time, so `emit-host-config.ts` scans the built HTML, computes a **sha256** for each
unique inline script, and writes a ready-to-merge CSP at the site root:

- `csp.nginx.conf` — an `add_header Content-Security-Policy "…" always;` line.
- `csp.apache.conf` — a `Header set Content-Security-Policy "…"` line.
- `csp.zigbase.txt` — the header value to set in ZigBase's response-header config.

All three carry the same host-agnostic value:

```
default-src 'self'; script-src 'self' 'sha256-…' 'sha256-…'; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'self'
```

- **`script-src` is hash-strict** — `'self'` (external `/zigapagos-runtime.js`, `/spa/*.js`,
  `/islands/*.js`) plus a `'sha256-…'` per inline script, **no `unsafe-inline`**. This is the
  XSS-critical control. The `data-z-props`/`data-z-slots`/`data-z-flags` blocks are
  `type="application/json"` (data blocks, not executed) and need no hash. **If the shell's inline content ever changes, regenerate**
  (the hashes are recomputed on every build; a stale hosted header would break the site — the
  hash is byte-exact).
- **`style-src` allows `'unsafe-inline'`** because the framework emits inline `style` attributes
  (e.g. `display:contents` on slot wrappers) that CSP hashes cannot cover (hashes apply to
  `<style>`/`<script>` elements, not style *attributes*). Style injection is far lower-risk than
  script injection; the XSS-critical `script-src` stays strict. (v2: move those inline styles to
  a class/external stylesheet to enable a fully-strict `style-src`.)
- **External head origins are folded in automatically.** If the built HTML references external
  origins via `<link>` tags — typically a [`spa.head`](#head-assets) with a Google Fonts
  stylesheet and its `preconnect` — the emitted CSP would otherwise block the very resources the
  same build linked. The rule is simple and predictable: **every external origin referenced by a
  `<link href="…">` in the built HTML is unioned into both `style-src` and `font-src`** (the
  `font-src` directive is only emitted when at least one external origin exists; without one the
  header value is unchanged and fonts fall back to `default-src 'self'`). So

  ```ts
  head: [
    { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "anonymous" },
    { rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=Inter&display=swap" },
  ]
  ```

  yields `style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://fonts.gstatic.com`
  and `font-src 'self' https://fonts.googleapis.com https://fonts.gstatic.com` in all three
  emitted flavors. `script-src` is never widened by head entries.

Verified end-to-end: a strict-CSP vhost serves a hydrated SPA (+ an island page) with **zero
CSP violations** in real Chrome (`examples/tsx-site/test/spa_csp_playwright.py`).

## Code Splitting (lazy routes)

One bundle per SPA means a heavy view (a rich editor, a dashboard) sits in the initial bundle
even when the first paint is a login screen. Wrap a route's component in `lazy()` to split it
into its own chunk, loaded on demand:

```tsx
import { lazy } from "@z/runtime";

export const routes = [
  { path: "/",       component: Home },
  { path: "/heavy",  component: lazy(() => import("./views/Heavy.tsx")), skeleton: HeavySkeleton },
];
```

At build time the SPA is bundled with code-splitting: the heavy view becomes a separate
content-hashed chunk (`/spa/Heavy-<hash>.js`), the routing manifest maps the route to its
chunk, and the route's shell emits a `<link rel="modulepreload">` for that chunk so it fetches
in parallel with the shell. `@z/runtime` stays external (one Preact) in every chunk. A SPA with
no `lazy()` routes builds to a byte-identical single bundle — splitting is zero-cost until used.

Rendering: SSR and the first client render show the route's `skeleton`; the loader resolves
post-hydration and the Router flips to the real component (a normal, non-hydrating re-render —
same two-phase rule as a dynamic route). It composes with route guards: a guarded lazy route
shows the guard `fallback` while unauthorized and only reveals the component after authorization
(the component never renders pre-auth, even though its public chunk may prefetch).

Rules & caveats:

- **A `lazy()` route must declare a real `skeleton` — enforced at build time.** The Router shows
  the `skeleton` on SSR + first paint, then flips to the loaded chunk. This applies to **static**
  paths too (the marker component can never render before its chunk loads), and the dynamic-route
  escape hatch **`skeleton: false` is rejected** for lazy routes — a hydration-stability promise
  cannot hold for a component that hasn't loaded. The describe pass fails the build with an error
  naming the SPA and route. (Defense in depth remains: a skeleton-less lazy route that somehow
  reaches SSR throws loudly via the lazy marker, and the client dev-warns.)
- **`lazy()` is zigapagos's router-level code-split, not React.lazy.** An npm component's
  `React.lazy()` is NOT supported through the compat bridge: the shared runtime has a single `lazy`
  (this router one), so a React.lazy component would render the marker and throw. Wrap the *route*
  with zigapagos `lazy()` instead of using `React.lazy()` inside a component.
- **Keep lazy modules side-effect-free at module scope.** The chunk is `import()`-evaluated when
  the route is entered (before a guard authorizes it), so a top-level credentialed fetch or
  global registration would run pre-auth. Put side effects in effects/handlers.
- **`lazy()` is leaf-only** — don't give a `lazy()` route `children` (use a normal layout route
  for nesting).
- **Give lazy view files unique basenames.** The per-route modulepreload is matched by module
  basename, so two lazy views named `View.tsx` in different folders could preload the wrong (but
  still real) chunk. The route itself always loads correctly; only the preload hint is affected.
- A loader that rejects logs via `reportError` and stays on the skeleton (no auto-retry until a
  full reload).

## Build-Time Site Data (`@z/site-data`)

SPA views (and islands) often need site content at build time — copy, business hours, service
definitions maintained as markdown/JSON alongside the site. Instead of a pre-build codegen
script that bakes `content/` into a tracked `siteData.ts` (drift, one more step to forget),
declare a `data` map in `z-runtime.config.json` at the website root and import the virtual
module:

```jsonc
// z-runtime.config.json
{
  "data": {
    "services": "content/services/*.smd",   // glob -> array of documents
    "hours": "content/hours.json"           // single file -> its parsed value
  }
}
```

```tsx
import site from "@z/site-data"; // typed via the emitted z-site-data.d.ts

export default function Services() {
  return <ul>{site.services.map((s) => <li>{s.frontmatter.title}</li>)}</ul>;
}
```

The config lives in `z-runtime.config.json` (not `zigapagos.ziggy` or the SPA entry) because
that is the one config both build sides already read — and the SPA entry can't declare it: the
entry module can only be imported after `@z/site-data` resolves.

Semantics:

- Paths/globs are relative to the config file's directory (the website root).
- **Single file** (no glob magic): `.json` → its parsed value; `.smd`/`.md` →
  `{ frontmatter, body }` (frontmatter between the `---` fences is either the ziggy struct the
  content pipeline reads — detected by its leading `.field =` — or YAML via Bun's native
  parser, so an existing gray-matter-style `.md` content dir works without conversion — the same
  frontmatter the content pipeline reads; `@date("…")` values become their string argument).
- **Glob**: an array sorted by path of `{ path, frontmatter, body }` (`.smd`/`.md`) or
  `{ path, data }` (`.json`), `path` relative to the website root.
- A missing file, an empty glob, or an unsupported extension **fails the build loudly** — a
  content-selection typo must not ship an empty array.
- The bundler resolves `@z/site-data` to an inlined JSON module and registers the selected
  content files as build inputs in the bundle's depfile — a content edit rebuilds exactly the
  bundles that import the data (build-time SSR reads content fresh each build via the render
  sidecar). It also emits `z-site-data.d.ts` next to the config so the import is fully typed;
  the file is generated — gitignore it or commit it, either works (it's rewritten only when
  the data shape changes).
- The import lint allows `@z/site-data` exactly when the config declares a `data` map.
- The module has a single **default export**. The data is static at build time — for anything
  runtime-dynamic, use the API client, not `@z/site-data`.
- Under `bun test`, the testing preload provides the module — fed from the same `data` map, or
  overridden per test with `mockSiteData(...)` — see
  [views that import workspace packages or `@z/site-data`](#views-that-import-workspace-packages-or-zsite-data).

## Per-Deployable Runtime Slicing

All islands and SPAs normally share one `/zigapagos-runtime.js` (one Preact). But the shared
runtime bundles **every** `host.*` binding (cookies, scroll, recaptcha, `loadScript`, …), so a
public SPA ships bindings only the admin SPA uses. At `zigapagos release`, each SPA gets its **own
sliced runtime** (`/spa/<name>-runtime.js`) containing only the `host.*` members that SPA
actually uses — a smaller bundle, and (the real win) **admin-only bindings never ship to a
non-admin SPA**. The build statically analyzes each SPA's transitive sources for `host.<member>`
access; the SPA's shell points its import-map + preload + module-script at its sliced runtime.
Islands keep the shared runtime (v1).

**Fail-safe by design — a slice never omits a binding the SPA uses.** The analyzer falls back to
the full shared runtime (worst case = today's behavior) on *any* uncertainty, including:

- dynamic/aliased host access — `host[expr]`, `const h = host`, `const {x} = host`, `{...host}`,
  passing `host` as a value, etc. (anything but a direct `host.member` read);
- a SPA that imports `@z/runtime/compat` or bare `react`/`react-dom` (the [React bridge](migration/react-spa-bridge.md)) — the sliced runtime omits the compat surface, so those SPAs use the full runtime;
- any source file that can't be read or statically analyzed.

A small **baseline** set (the members the always-bundled runtime core needs) is always included,
guarded by a test that scans the whole runtime so a new core `host` use can't stale it. SSR
always uses the full host; only the client runtime is sliced. Each page still loads exactly one
runtime → one Preact.

## Invariants

### One Preact Instance
The SPA bundle declares `@z/runtime` as **external** (`--external=@z/runtime`). The router is shipped in the shared `/zigapagos-runtime.js` bundle (not in the SPA bundle). A single Preact instance is shared across all soft-nav transitions and across any islands on the same page.

### No-npm Guardrail
By default a `.spa.tsx` and its views may import only:
- `@z/runtime` (and subpaths like `@z/runtime/router`)
- Relative paths (`./`, `../`)
- Web globals

The build enforces this via `runtime/scripts/lint-island-imports.ts`. A project
opts extra imports in via `z-runtime.config.json`'s `islandImports.firstParty`
(first-party workspace scopes) and `islandImports.npmCompat` (third-party
React-compatible npm packages, bundled per-SPA with `react`/`react-dom` kept
external and aliased to the shared runtime) — see the [npm
guardrail](migration/recipes.md#no-npm-guardrail). Anything else — a package
that bundles its own React/Preact copy, or that the config doesn't list —
still fails the lint.

### Build-Time Only
Bun runs only at build time (to bundle and prerender). The deployed artifact is static HTML + JS + a server config file. No runtime Bun process; the server is your hosting layer (Nginx, Apache, or ZigBase).

## v1 Limits

### One Bundle per SPA
Each `.spa.tsx` produces one JS bundle (`spa/<name>.js`). Internal `import()` or Preact.lazy components can split views manually; automatic per-route code-splitting is v2.

### Auth First-Paint Flash
If the client must redirect for auth (e.g., a protected `/admin` page), the browser renders and displays the skeleton first, then fetches auth state, then redirects. This causes a brief flash of the skeleton. v2 will allow skipping the prerender for certain routes.

### Multi-SPA `404.html`
If the site has multiple SPAs (e.g., `/app` and `/admin`), the universal `404.html` falls back to **one** SPA's shell — the one named by `build.zig`'s `not_found` option, or the first declared SPA by default. Per-namespace catch-all is a true mechanism (each SPA has its own pattern-matching in the routing manifest); `404.html` is only the last-resort global fallback. Plan accordingly if your hosting layer doesn't support per-directory `404.html` routing.

## Testing

### Unit-testing a view (`renderForTest`)

The build+serve+browser e2e below covers the whole SPA end to end. For fast,
browser-free coverage of a **single view's render logic** — what it renders for a
given set of props, guard data, and flags — reach for `renderForTest` from
`@z/runtime/testing`. It is a thin, in-process wrapper over the exact
`renderToString` path the Bun SSR sidecar runs at build time (`isServer() ===
true`), with each input injected through the same seam the runtime uses. It
renders with **no `<Router>` context**, so a view under test that renders a
`<Link>` directly needs its own `<Router>` wrapper (or a plain `<a>`) — see
the [`<Link>` outside a Router](#components) note above.

```ts
import { test, expect } from "bun:test";
import { renderForTest } from "@z/runtime/testing";
import { Dashboard } from "./views/Dashboard.tsx";

test("greets the guard's user and shows the promo when flagged", () => {
  const html = renderForTest(Dashboard, {
    props: { title: "Home" },
    guardData: { user: { name: "Ada" } }, // what the route guard returned via { ok: true, data }
    flags: { promoBanner: true },          // baked spa.flags default the shell would snapshot
    pathname: "/app/dashboard",            // drives host.pathname() / useLocation()
  });
  expect(html).toContain("Ada");
  expect(html).toContain("promo");
});
```

| Option | Injected as | Read in the view via |
|--------|-------------|----------------------|
| `props` | the component's props | its own signature |
| `guardData` | the nearest enclosing guard's `{ ok: true, data }` | `useGuardData<T>()` |
| `flags` | baked `spa.flags` defaults | `useFlag(name)` |
| `experiments` | experiment variant assignments | `useVariant(name)` |
| `pathname` | the SSR pathname | `host.pathname()` / `useLocation()` |

The returned string is byte-identical to what the sidecar emits for the same
inputs. State is fully scoped — the SSR pathname and the page-global flags store
are saved and restored around each render, so calls never bleed into one another.
`renderForTest` needs no DOM (it renders to a string), so it runs without the
happy-dom preload the DOM-hydration helpers (`renderIsland`) require; full harness
reference in [`runtime/src/testing/README.md`](../runtime/src/testing/README.md).

#### Views that import workspace packages or `@z/site-data`

A real app's views often import from an out-of-tree **workspace package** (bun
links it as a symlink, and `bun test` realpaths its files *outside* the project
root — where tsconfig `paths` and the package's own node_modules can't resolve
`react`, `@z/runtime`, or the JSX runtime), or from the build-time
**`@z/site-data`** virtual module (which doesn't exist under plain `bun test`).
Both just work with one line in the app's `bunfig.toml`:

```toml
[test]
preload = ["@z/runtime/testing/preload"]
```

Before any test runs, the preload registers happy-dom as the global DOM, applies
the site's `z-runtime.config.json` `resolve` map as bun-test module overrides —
the exact registration the SSR sidecar uses, discovered by walking up from the
current working directory — so every import of `react`/`@z/runtime`/the JSX
runtime, from any file at any package depth, lands on the one shared runtime,
and provides `@z/site-data` fed from the same `data` map the build uses. A view
imported from an `islandImports.firstParty` workspace package, or one importing
`@z/site-data`, needs no per-app glue.

Per test, `mockSiteData` swaps the site data in place and returns a restore
function (restoring to the config-fed baseline, or to a loud-fail state when
the config has no `data` map):

```ts
import { renderForTest, mockSiteData } from "@z/runtime/testing";
import { Hours } from "@acme/shared"; // out-of-tree workspace package

test("renders mocked hours", () => {
  const restore = mockSiteData({ hours: { mon: "closed" } });
  expect(renderForTest(Hours)).toContain("closed");
  restore();
});
```

Note that a view destructuring site data at module scope captures values at
import time — mock before importing such a view, or read the data lazily.

### End-to-end artifact test

The example includes a comprehensive test:

**`examples/tsx-site/test/spa.sh`**

Run from the example directory to verify all artifacts are emitted with correct contents:

```bash
cd examples/tsx-site
bash test/spa.sh
```

This test asserts:
- Static shells exist (`app/index.html`, `app/booking/index.html`)
- Dynamic pattern shell exists (`app/club/_shell.html`) and not concrete IDs
- Bundle and runtime exist (`spa/app.js`, `zigapagos-runtime.js`)
- Manifest and host config exist and contain expected keys
- Shells contain skeleton markers, mount root, import map, preload hints, boot code
- No npm imports in SPA sources (via `lint-island-imports.ts`)

For soft-nav and hard-refresh e2e tests, see `examples/tsx-site/test/spa_playwright.py`.

## Example Project Structure

```
examples/tsx-site/
├── app/
│   ├── app.spa.tsx                  # SPA root: exports spa + routes + App component
│   └── views/
│       ├── AppShell.tsx
│       ├── Home.tsx
│       ├── Booking.tsx
│       ├── ClubDetail.tsx           # uses isServer() to render skeleton
│       ├── ClubSkeleton.tsx         # explicit skeleton component
│       ├── NotFound.tsx
│       └── index.ts                 # barrel export
├── build.zig                        # declares .spa with zigapagos.Spa struct
├── zigapagos.ziggy                 # sets deploy_target
└── test/
    ├── spa.sh                       # artifact + content assertions
    └── spa_playwright.py            # soft-nav + hard-refresh e2e
```

## Workflow

1. **Author** the `.spa.tsx` module with `export const spa` and `export const routes`.
2. **Declare** it in `build.zig` via a `zigapagos.Spa` entry; ensure `.base` matches.
3. **Set `deploy_target`** in `zigapagos.ziggy` (default `"zigbase"`).
4. **Run `zigapagos release`** to build: prerender shells, bundle, emit manifests and host configs.
5. **Deploy** the `zig-out/site/` output:
   - Copy HTML shells, static assets, JS bundle to your hosting layer.
   - If using **ZigBase** (≥ 0.10.0), the emitted `<base>/.spa` marker ships in the tree; the stock `zigbase serve` binary needs no further config. For dedicated per-route shells, compile the emitted `zigbase.static_routes.zig` snippet into a custom build.
   - If using **Nginx**, include the emitted `nginx.nginx.conf`.
   - If using **Apache**, place the emitted `.htaccess` in the SPA's base directory.
   - Ensure the universal `404.html` is configured as a fallback.

## Local Development (`zig build dev`)

The stock ZigBase binary is **the** server for local development — zigapagos does not
bundle its own HTTP serving. The `dev()` build step is the supported dev loop:

```zig
// opts must carry the SAME output_path as your website() call (and website()
// needs .force = true — the loop rebuilds into the same tree).
const dev_step = b.step("dev", "Serve the site with ZigBase, rebuilding on change");
dev_step.dependOn(&zigapagos.dev(b, .{ .output_path = "site" }, .{}).step);
```

`zig build dev` then:

1. **builds the site's RELEASE output** (the same `zig build` install tree production
   deploys — islands SSR'd, SPA shells prerendered, host-config emitted),
2. **boots the stock `zigbase` binary over that tree** (located like the e2e harness:
   `--zigbase=`/`DevOptions.zigbase_path` → PATH → the pinned release in the zigapagos
   cache; never downloaded behind your back) and waits for readiness. You get the real
   same-origin `/api`, the admin UI at `/_/`, and the `.spa`-marker fallback — **no
   `--proxy` shims, no CORS, no code differences between dev and prod**. The default
   invocation adds `--insecure-cookies` so ZigBase's Secure-flagged auth cookies
   round-trip over plain `http://127.0.0.1`,
3. **watches your inputs** — content/layouts/assets (from `zigapagos.ziggy`) plus the
   island/SPA source directories (derived from `Options.islands`/`spas`; add more via
   `DevOptions.extra_watch_dirs`) — and **re-runs `zig build` on change**. Rebuilds are
   incremental where the build graph allows it: island/runtime/SPA bundle steps carry
   depfiles and stay cached unless their TS sources changed; a content edit re-renders
   the site without re-bundling anything,
4. serves at a stable `http://127.0.0.1:1990/` by default (`DevOptions.host`/`port`;
   `port = 0` picks a free port and prints it).

**The ZigBase data dir is persistent.** It defaults to `.zigbase/` under the site root —
collections, auth state, and uploaded files **survive across dev sessions** (gitignore
the directory; delete it for a fresh backend, or point `DevOptions.data_dir` elsewhere).

**No live reload.** ZigBase serves the release tree verbatim, and zigapagos does not
inject reload scripts into release output — refresh the browser after the
`dev: rebuild OK` line. (A dev-only reload hook in `@z/runtime` is a possible follow-up.)

Notes:

- The route TABLE is part of the build, so added/removed SPA routes flow through on the
  next rebuild automatically (unlike the preview server, which needs a restart).
- Non-enumerated SPA deep links in dev use the `.spa` marker, which the host-config
  emitter plants for `deploy_target: "zigbase"` namespaces. If your production target is
  nginx/apache, enumerated shells still serve fine; wiring a dev-only
  `emit-host-config --target zigbase` pass into the rebuild is a follow-up.
- Direct CLI form (what `dev()` drives): `zigapagos dev --site=DIR [options] --
  REBUILD-CMD…` — see `zigapagos help`.

## Developing Against a Backend (`--proxy`) — preview server

> **Which loop:** `zig build dev` above is the recommended one for a site with a backend —
> it serves the real release tree from ZigBase, so `/api` is genuinely same-origin and no
> proxying is involved. `zigapagos serve` is the zero-setup preview: it needs no zigbase
> binary and no rebuild command, which is why it is still what `init` points a new site at,
> and `--proxy` is how it reaches a backend running elsewhere.

SPAs (and islands) call relative `/api/*`, which in production is routed to the backend on
the same origin by ZigBase/nginx. In development, `zigapagos serve` is otherwise static-only, so
point those calls at a running backend with the `--proxy` flag:

```sh
zigapagos serve --proxy /api=http://127.0.0.1:8090
```

Any request whose path matches the prefix (at a segment boundary — `/api` and `/api/...`
match, `/apiary` does not) is forwarded to the upstream **on the dev server's own origin**;
everything else is served static as usual. Because it is same-origin, relative `/api/*`
calls behave exactly as behind ZigBase/nginx in prod — **no CORS, no absolute URLs, no
code changes between dev and prod**. The flag is repeatable for multiple backends
(`--proxy /api=... --proxy /auth=...`); the longest matching prefix wins.

What is preserved end to end:

- **Cookies** relay verbatim in both directions — a session/login flow completes in the
  browser against the dev server, and the double-submit CSRF cookie round-trips (so
  cookie-auth-gated apps are developable locally).
- **Server-Sent Events** (`text/event-stream`) stream live — events reach the browser as
  they arrive, not buffered until the connection closes (so an `EventSource` against a live
  backend, e.g. live feature flags, works in dev).
- The original **percent-encoded** request target is forwarded unchanged; `X-Forwarded-For`
  / `-Proto` / `-Host` are added.

v1 scope: `http://` upstreams only; no path rewriting (the full path is forwarded); a
WebSocket upgrade returns `501` (SSE covers the live-flags need); an unreachable upstream
returns `502`. Planned v2 follow-ups: config-file form, WebSocket upgrades, keep-alive
pooling, TLS upstreams, and path rewrite.

### Calling the backend — `apiFetch`

`@z/runtime` exports `apiFetch(input, init?)`, a thin `fetch` wrapper for SPAs and islands that
bakes in the two things every ZigBase-backed call would otherwise repeat:

```tsx
import { apiFetch } from "@z/runtime";

// GET: session cookie rides along (credentials: "include") for same-origin.
const me = await (await apiFetch("/api/session")).json();

// Mutating same-origin request: the `zb_csrf` cookie is echoed as X-CSRF-Token
// (ZigBase's double-submit contract) automatically — no per-call-site wiring.
await apiFetch("/api/contact", { method: "POST", body: JSON.stringify(form) });
```

- **credentials** default to `"include"` for **same-origin** targets (caller-overridable);
  cross-origin requests keep the caller's own `credentials`.
- On a **non-GET/HEAD same-origin** request it copies the `zb_csrf` cookie into
  `X-CSRF-Token` (only if present and the caller hasn't set it).
- **Security:** the CSRF token and forced credentials are attached **only** for same-origin
  targets — a cross-origin request never receives `zb_csrf` (no token leak to third parties).
- A **same-origin 401/403** response additionally triggers the framework's
  [session-expiry policy](#session-expiry-automatic-guard-re-run-on-401) — the active route's
  guard re-runs once and its `{ redirect }` sends the visitor to login. The Response still
  reaches the caller unchanged.
- Pairs with `zig build dev` (a real same-origin ZigBase in development) — or the
  preview server's `--proxy` flag: relative `/api/*` behaves the same in dev and prod.

### Error reporting — `initErrorRelay` + `ErrorBoundary`

No third-party error SDK needed. `initErrorRelay({ endpoint })` installs a first-party pipe
that captures `window.onerror`, unhandled promise rejections, anything sent through
`host.reportError` (island errors), and render errors caught by `<ErrorBoundary>`, then batches
them and POSTs to a same-origin endpoint (via `apiFetch` — credentials + CSRF for free). Pairs
with the backend's own reporter (zigbase#244).

```tsx
import { initErrorRelay, ErrorBoundary } from "@z/runtime";

const stop = initErrorRelay({
  endpoint: "/api/client-errors",
  sampleRate: 0.25,                 // report a fraction (default 1 = all)
  context: () => ({ release: __BUILD__ }),
});

// Catch render errors in a subtree and keep the app alive:
<ErrorBoundary fallback={(err) => <p>Something broke.</p>}>
  <App />
</ErrorBoundary>
```

Each record carries `{ message, stack?, kind, pathname, ts, ...context() }`. Batches flush on a
timer, when full, and on page unload (`keepalive`). Handlers never throw, so a reporting failure
can't cascade into the app; `initErrorRelay` returns a teardown fn and is a no-op under SSR.

## End-to-End Testing (`zig build e2e`)

Verifying an SPA against a real backend used to mean hand-rolling orchestration: build,
boot the backend, start a static server, poll for readiness, hand the origin to a browser
driver, tear everything down. The `e2e()` build step is that workflow as one supported
step — and it is **production-faithful**: it serves the RELEASE output tree with the
**stock ZigBase binary** (real same-origin API, real `.spa`-marker SPA fallback), not the
dev server, so what the driver exercises is what production serves.

```zig
// build.zig — output_path must match your website() call: the harness
// serves that installed tree.
const e2e_step = b.step("e2e", "Run e2e tests against the served site");
const e2e_run = zigapagos.e2e(b, .{ .output_path = "site" }, .{});
e2e_step.dependOn(&e2e_run.step);
```

```sh
zig build e2e -- npx playwright test
```

The step:

1. **builds + installs** the full release output (it depends on the install step, so the
   SPA chunks and host-config artifacts — notably the `.spa` marker ZigBase reads — are
   on disk);
2. **locates ZigBase** and boots `zigbase serve` over the tree on a **free port** (no
   collisions, parallel-safe);
3. waits for **readiness = the first successful shell fetch** — `GET /` is polled until
   it returns 200, so drivers never hand-roll polling (override the probed path with
   `ready_path` when `/` isn't a page your site serves, e.g. `.ready_path = "/app/"`);
4. runs the command after `--` with the origin exported as **`ZIGAPAGOS_ORIGIN`**
   (e.g. `http://127.0.0.1:49213`), its output streaming through live;
5. **tears down and propagates**: ZigBase is killed and reaped on success, failure, or a
   terminal signal (it shares the process group) — no orphaned processes — and the
   command's exit code becomes the step result, so a failing test suite fails
   `zig build e2e`.

Because the app runs behind a real ZigBase, its relative `/api/*` calls, cookies, and
CSRF behave exactly as in prod — no proxies, no CORS, no code changes.

### Locating ZigBase (downloads only on explicit request)

The harness resolves the binary in this order and **never downloads anything
implicitly**:

1. an explicit path — `E2eOptions.zigbase_path` (CLI: `--zigbase=PATH`),
2. `zigbase` on your PATH,
3. the pinned release in the zigapagos cache:
   `~/.cache/zigapagos/zigbase/<pinned_version>/zigbase` (respects `XDG_CACHE_HOME`;
   `%LOCALAPPDATA%` on Windows). The pin is the `pinned_version` constant in
   `src/cli/zigbase.zig` (currently `v0.12.0`, the latest release; the `.spa`-marker
   contract needs ≥ 0.10.0).

When nothing is found, the step fails fast with these instructions — **unless** you
opted in with `E2eOptions.download_zigbase = true` (CLI: `--download-zigbase`), in which
case the harness fetches the pinned release tarball from
`github.com/valthon/zigbase/releases/download/<pin>/zigbase-<ver>-<target>.tar.gz`,
**verifies its SHA256 against the release's published SHA256SUMS**, and extracts the
binary into the cache path above for every future run to find.

### The ZigBase invocation (verified; configurable for embedder builds)

By default the harness runs the stock CLI, verified against the real parser
(zigbase `src/cli.zig`) and the release binary's own `zigbase serve --help`:

```
zigbase serve --http-host 127.0.0.1 --http-port {port} --data-dir {data} --serve-static {site}
```

Flag values are **space-separated tokens** (the real parser matches exact flag names and
takes the next argv token as the value — it does no `=` splitting, and unknown flags are
rejected). `--serve-static` is present in the stock/release binary (its static-files mode
is the default one). `{port}` (the free port), `{site}` (the installed output tree) and
`{data}` are substituted at run time. The data dir defaults to a **fresh temp dir per
run** (deleted on teardown, so runs are hermetic); point `E2eOptions.data_dir` at a
seeded directory to test against fixtures. If you run a custom ZigBase embedder build
that spells its flags differently (or compiles static serving out), override the whole
template — subcommand included, placeholders available — via `E2eOptions.zigbase_args`
(CLI: repeatable `--zigbase-arg=`):

```zig
.zigbase_args = &.{ "serve", "--listen", "127.0.0.1:{port}", "--static", "{site}" },
```

`E2eOptions` also takes `default_cmd` (used when no `-- <cmd>` is given) and
`timeout_ms` (readiness budget, default 120 s).

### Drivers: read `ZIGAPAGOS_ORIGIN`

Any browser driver (or plain `curl`) works — the whole contract is one env var.
Playwright, the blessed example:

```ts
// playwright.config.ts
import { defineConfig } from "@playwright/test";

export default defineConfig({
  use: { baseURL: process.env.ZIGAPAGOS_ORIGIN },
});
```

```ts
// tests/booking.spec.ts — relative paths resolve against the harness origin.
import { test, expect } from "@playwright/test";

test("booking flow against the real backend", async ({ page }) => {
  await page.goto("/app/booking/");           // prerendered shell, then hydration
  await page.getByRole("button", { name: "Book" }).click();
  await expect(page.getByText("Confirmed")).toBeVisible();  // same-origin /api, served by ZigBase
});
```

The same shape works CLI-only: `zigapagos e2e --site=zig-out/site -- <cmd>` (plus
`--data-dir=`, `--zigbase=`, `--zigbase-arg=`, `--ready-path=`, `--timeout-ms=`; see
`zigapagos help`). `tests/serve/e2e.sh` exercises the whole contract end to end against
a clearly-labeled stub server (`tests/serve/stub-zigbase.ts`) honoring the same
invocation, so it runs on machines without a real ZigBase.

## State-Preserving Dev Reload

> Applies to the `zigapagos serve` preview server only. `zig build dev`
> (the zigbase-backed dev loop) has no reload client — you refresh manually, and a manual
> refresh also fires no `zigapagos:beforereload`, so state restoration doesn't apply there.

When you edit a source file, `zigapagos serve`'s livereload client does a full `location.reload()`.
That already preserves the URL, so the **SPA route survives** (the router re-reads
`location.pathname` on mount). What it loses is **in-memory component state** — a half-filled
form, the current wizard step. `useRestorableState` restores that across the dev reload:

```tsx
import { useRestorableState } from "@z/runtime";

function Wizard() {
  // Like useState, but the value survives a `zigapagos serve` reload.
  const [name, setName] = useRestorableState<string>("wizard-name", "");
  const [step, setStep] = useRestorableState<number>("wizard-step", 1);
  return <input value={name} onInput={(e) => setName(e.currentTarget.value)} />;
}
```

How it works: immediately before each reload, the dev client dispatches a synchronous
`zigapagos:beforereload` window event. `useRestorableState` listens for it and stashes the current
value in `sessionStorage["z-reload:"+key]`; the next mount reads it **once**, restores it, and
clears the key (one-shot — a value is restored across a single reload, not indefinitely). Values
must be JSON-serializable.

**Prod-safe by construction:** the `zigapagos:beforereload` event is only ever dispatched by the dev
livereload client, which is not injected in production. With no event, nothing is written, so the
first mount reads nothing and the hook behaves **exactly** like `useState(initial)`. It is also
SSR-safe (plain state; never touches `window`/`sessionStorage` on the server) and never throws —
a malformed blob or unavailable storage falls back to `initial`.

For non-hook code, `onBeforeReload(cb)` is the lower-level primitive: it registers `cb` for the
`zigapagos:beforereload` event and returns an unsubscribe (client-only; a no-op under SSR).

True HMR (a targeted island/route swap that avoids the full reload entirely) is a separate,
future step; this v1 makes the unavoidable full reload non-destructive.

## Performance Notes

- **Prerendering skeletons at build time** avoids a render pass on the client. Skeletons are static HTML, so the page is interactive (buttons clickable, inputs focusable) immediately.
- **Soft navigation** (within `base`) avoids a full page reload; only the content changes, preserving browser state and scroll position.
- **External `@z/runtime`** means the shared runtime (router, Preact, host bindings) is bundled once, not once per SPA.
- **One-shot prerender + manifest** means the entire routing table is known at build time; no runtime path inference.

## Troubleshooting

- **No shells generated:** ensure the `.spa.tsx` exports are correctly named (`spa`, `routes`) and match the module's contract.
- **Mismatch between declared and exported `base`:** the build validates and fails if `build.zig`'s `.base` differs from `export const spa.base`.
- **Import lint failures:** SPA views can only import from `@z/runtime`, relative paths, web globals, and whatever the site's `z-runtime.config.json` opts into via `islandImports.firstParty`/`islandImports.npmCompat` — see [No-npm Guardrail](#no-npm-guardrail) above.
- **Skeleton doesn't match shell:** the `isServer()` branch or `skeleton` component is rendered at build time; ensure it doesn't reference client-only data (e.g., `useLocation()`, fetch calls). Skeletons should be pure loading UI.
- **Dynamic route gives 404:** ensure the route pattern in `routes` includes `:param` (e.g., `/club/:id`). If the pattern shell is not found, the server falls back to `/404.html`.
- **Build fails with a `staticPaths` error:** `staticPaths` on a route with no `:param`/`*` segment, or an enumerated entry missing a param the pattern requires, are both build errors by design — see [Per-entry prerendering](#per-entry-prerendering-staticpaths) above.
