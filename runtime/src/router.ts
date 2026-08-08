import type { ComponentType, VNode } from "./core.ts";

// ---------------------------------------------------------------------------
// Lazy (code-split) route components. `lazy(() => import("./views/Heavy"))`
// wraps a dynamic-import loader; the bundler splits the imported module into its
// own chunk, and the Router loads it client-side AFTER hydration (its content is
// never in the SSR shell). A lazy route MUST declare a `skeleton` — that's what
// SSR and the first client render show until the chunk resolves.
// ---------------------------------------------------------------------------
type LazyState = {
  loader: () => Promise<{ default: ComponentType<any> }>;
  comp?: ComponentType<any>; // resolved module default, cached across the app
  failed?: boolean; // loader rejected — stay on the skeleton, never retry-loop
  // In-flight/settled loader call, shared between the real navigation load
  // (below) and a hover/viewport prefetch (issue #128's `RouterCtx.prefetch`)
  // — so a prefetch that starts the fetch and a navigation that follows
  // share the SAME network request instead of double-fetching the chunk.
  // Cleared (not left rejected) on a PREFETCH failure so a transient
  // hover-time error never blocks the real navigation load — see
  // `startLazyLoad`'s callers.
  promise?: Promise<{ default: ComponentType<any> }>;
};
/** The marker the Router recognizes on a lazy route's `component`. */
const LAZY = "__zLazy" as const;
type LazyComponent = ComponentType<any> & { [LAZY]: LazyState };

function lazyStateOf(c: ComponentType<any> | undefined): LazyState | undefined {
  return c ? (c as Partial<LazyComponent>)[LAZY] : undefined;
}

/**
 * Start (or reuse) a lazy route's chunk load. `??=` means a concurrent
 * navigation-load and prefetch — or two prefetches — share one in-flight
 * request rather than each calling `loader()` (a fresh dynamic `import()`)
 * independently. Callers each attach their own `.then`/`.catch` to the
 * returned promise; a REJECTED promise stays cached here (so a second
 * caller doesn't retry a load that's already known to fail) — a
 * prefetch-only failure clears it back to `undefined` instead (see the
 * `prefetch` implementation below), specifically so the real navigation
 * load gets a fresh attempt rather than inheriting a stale rejection.
 */
function startLazyLoad(lz: LazyState): Promise<{ default: ComponentType<any> }> {
  return (lz.promise ??= lz.loader());
}

/**
 * Mark a route component as lazily code-split: `component: lazy(() =>
 * import("./views/Heavy"))`. The loader's imported module becomes its own chunk;
 * the Router shows the route's `skeleton` on SSR + the first client render, then
 * loads the chunk post-hydration and flips to its `default` export (a normal
 * non-hydrating flip — composes with the two-phase hydration and guard-scope
 * machinery). A rejected loader is reported and leaves the skeleton in place.
 */
export function lazy(loader: () => Promise<{ default: ComponentType<any> }>): ComponentType<any> {
  // The Router keys off the LAZY marker and renders the resolved component or the
  // route's `skeleton` — it NEVER renders this placeholder on the happy path
  // (post-hydration falls back to `lz.comp ?? skeleton ?? EmptyView`). The marker
  // is only ever rendered directly in two misuse cases, and BOTH must be LOUD (a
  // silent empty render is a debugging trap):
  //   1. a lazy ROUTE with no `skeleton` is SSR'd (`skeleton ?? component` -> the
  //      marker) — the route is misconfigured (rejected up front by the build's
  //      describe pass, and dev-warned on the client as defense in depth);
  //   2. an npm component's React.lazy() is used — via the compat bridge React.lazy
  //      resolves to THIS `lazy` (one shared runtime, one `lazy`), and rendering the
  //      returned component invokes the marker. React.lazy is not supported through
  //      the bridge; the route must be wrapped with zigapagos `lazy()` instead.
  const marker = (() => {
    throw new Error(
      "zigapagos: a lazy() component was rendered directly. lazy() marks a code-split " +
        "ROUTE component that the Router swaps for its `skeleton` (SSR + first paint) then " +
        "its loaded chunk — so give the route a `skeleton`. If this came from an npm " +
        "component's React.lazy(), that is not supported through the compat bridge — wrap " +
        "the route with zigapagos `lazy()` instead.",
    );
  }) as unknown as LazyComponent;
  marker[LAZY] = { loader };
  return marker;
}

/** Where a guard runs. Params come from the matched route's `:seg` captures. */
export type GuardLocation = { pathname: string; params: Record<string, string> };

/**
 * A guard's verdict: `true` or `{ ok: true, data? }` authorizes the route;
 * `{ redirect }` sends the visitor elsewhere (a soft-nav, no gated paint).
 * The `{ ok: true, data }` form additionally carries the object the guard
 * fetched to decide (the session, the current user) — the guarded subtree
 * reads it with {@link useGuardData} instead of smuggling it through a module
 * singleton. `true` stays valid and is equivalent to `{ ok: true }` (data =
 * undefined). Guards are async and CLIENT-ONLY — they never run during
 * build-time SSR.
 */
export type GuardResult<T = unknown> = true | { redirect: string } | { ok: true; data?: T };

/**
 * A parsed guard verdict. Any shape that is none of `true` / `{ redirect }` /
 * `{ ok: true }` is a misconfiguration and THROWS — the Router's guard runner
 * catches it, reports it, and stays gated (fail-closed), exactly like a guard
 * that rejects.
 */
function parseGuardResult(res: GuardResult<unknown>):
  | { authorized: true; data: unknown }
  | { authorized: false; redirect: string } {
  if (res === true) return { authorized: true, data: undefined };
  if (res && typeof res === "object") {
    if ("redirect" in res && typeof (res as { redirect: unknown }).redirect === "string") {
      return { authorized: false, redirect: (res as { redirect: string }).redirect };
    }
    if ("ok" in res && (res as { ok: unknown }).ok === true) {
      return { authorized: true, data: (res as { data?: unknown }).data };
    }
  }
  // The diagnostic must never mask itself: JSON.stringify throws on a circular
  // value (and returns undefined for some non-serializable ones), which would
  // replace the real "invalid guard result" message with a TypeError. Guard it
  // and fall back to String(res).
  let got: string;
  try {
    got = JSON.stringify(res) ?? String(res);
  } catch {
    got = String(res);
  }
  throw new Error(
    "zigapagos: invalid guard result — a guard must resolve `true`, `{ redirect }`, or `{ ok: true, data? }` " +
      `(got ${got})`,
  );
}

export type StaticPathsInit =
  | Array<Record<string, string>>
  | (() => Array<Record<string, string>> | Promise<Array<Record<string, string>>>);

export type RouteDef = {
  path: string;
  /** The view for this route. Required — unless the entry is a `redirect`. */
  component?: ComponentType<any>;
  /**
   * Loading state for two-phase hydration: SSR and the first client render
   * show `skeleton` (when present), the real `component` renders post-mount.
   * A DYNAMIC leaf (any `:param`/`*` segment in its full path) MUST declare
   * one — its SSR pathname substitutes params with `_`, so rendering
   * `component` on both passes mismatches and breaks hydration; the build's
   * describe pass enforces this. The explicit opt-out
   * `skeleton: false` means "I promise this component is hydration-stable
   * (renders identically on SSR and the first client render, params or
   * not)" and suppresses the build error; the router then treats it exactly
   * like an absent skeleton. Layouts never render a skeleton (they render
   * their real `component` on both passes), so declare it on the LEAF.
   * A `redirect` entry never renders (and never hydrates), so the rule does
   * not apply to it.
   */
  skeleton?: ComponentType<any> | false;
  /**
   * Optional per-route auth gate. Runs client-side after mount (and on every
   * navigation to this route); until it resolves `true` / `{ ok: true }`, the
   * router renders the Router-level `fallback` instead of `component`, so no
   * gated content is painted or shipped in the prerendered shell. A guard may
   * resolve `{ ok: true, data }` to hand the object it fetched (session, user)
   * to the guarded subtree — read it with {@link useGuardData}.
   */
  guard?: (loc: GuardLocation) => Promise<GuardResult<any>>;
  /**
   * Nested child routes. A route with `children` is a **layout route**: it
   * receives its matched child route as `children` (`<div>{children}</div>`
   * renders shared chrome around it), and `<Outlet/>` is the IDENTICAL
   * explicit form — `children` literally IS an `<Outlet/>`, there is no
   * second mechanism to keep in sync. Render exactly ONE of the two: using
   * both mounts the matched child twice (warned once per layout path in the
   * browser); using neither means the matched child never renders (warned the
   * same way, since it silently produces an empty layout with dead route
   * components behind it). Both checks run in mount effects, so they are
   * client-only — SSR never executes them.
   * A child `path` is relative to the parent (`/dash` + `/settings` ->
   * `/dash/settings`); a child with `path: "/"` is the index route shown
   * when only the layout's path matches.
   */
  children?: RouteDef[];
  /**
   * Astro-getStaticPaths-style enumeration for a DYNAMIC route: the param
   * sets to prerender as real static pages at build time (`/club/:id` +
   * `[{id:"1"}]` -> a prerendered `/club/1/index.html`), on top of the
   * pattern's `_shell.html` fallback that keeps serving every OTHER param.
   * An array, or a sync/async function returning one — resolved once, in
   * the sidecar's `describe`, never in the browser.
   */
  staticPaths?: StaticPathsInit;
  /**
   * Declarative redirect: `{ path: "/", redirect: "/dashboard" }`. The
   * router resolves the redirect BEFORE rendering (SSR included), so the
   * TARGET's view renders immediately — no throwaway frame — and the browser
   * URL is replace-synced to the target. The target is a concrete
   * BASE-RELATIVE in-app pathname (no query/hash), consistent with
   * `navigate()`/`Link`; the current location's query and hash are
   * preserved across the redirect. Mutually exclusive with `component`,
   * `children`, and `staticPaths`. At build time every target is validated
   * against the same SPA's route table — a miss fails the build.
   */
  redirect?: string;
};
/**
 * One rung of a matched route chain: the route plus params accumulated from the
 * chain root down to (and including) this rung.
 */
export type Match = { route: RouteDef; params: Record<string, string> };

function splitSegs(p: string): string[] {
  return p.replace(/^\/+|\/+$/g, "").split("/").filter(Boolean);
}

/**
 * Percent-decode ONE path segment, falling back to the raw segment when it is
 * not valid percent-encoding.
 *
 * `decodeURIComponent("100%")` throws a `URIError`, and this runs inside the
 * render path (`Router` → `resolveRedirects` → `matchChain`) with nothing
 * catching it: a single pasted/truncated URL like `/search/100%` would take the
 * whole SPA down — `hydrate()` throws, the page freezes on its prerendered
 * skeleton, and every later navigation re-throws on the same path. A
 * raw-looking param is cosmetic; a throw is a dead app. The fallback is total
 * (always a usable string), which is why the `catch` carries no handling.
 */
function decodeSegment(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s; // malformed escape: the raw segment is the best available value
  }
}

// ---------------------------------------------------------------------------
// Base-relative navigation. Router-internal paths — `<Link href>`,
// `navigate(to)`, guard `{ redirect }` targets, and route `redirect` entries —
// resolve RELATIVE to `spa.base`, so the base is a single point of
// configuration: moving an SPA between mount points touches `spa.base` only,
// never the call sites. Absolute URLs (scheme or protocol-relative `//host`)
// are external — never resolved, never soft-navigated — and a plain `<a>`
// remains the other escape hatch for cross-SPA/full-page navigation.
// ---------------------------------------------------------------------------
const SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;

/**
 * True when `to` targets another document/origin outright: it carries a URL
 * scheme (`https:`, `mailto:`, …) or is protocol-relative (`//host/…`).
 * External targets are never base-resolved and never soft-navigated.
 */
export function isExternalHref(to: string): boolean {
  return SCHEME_RE.test(to) || to.startsWith("//");
}

/**
 * Resolve a navigation target against the SPA `base`:
 *   - an external URL (see {@link isExternalHref}) is returned unchanged;
 *   - a root-relative path (`"/login"`) is prefixed with the base, trailing
 *     slashes trimmed (`"/app" + "/login"` → `"/app/login"`; base `""`/`"/"`
 *     → the path unchanged; `"/"` → the base itself with a trailing slash);
 *   - anything else (a bare relative `"settings"`, `"?q=1"`, `"#top"`) is
 *     returned unchanged for the browser's usual relative resolution.
 *
 * Resolution is ALWAYS applied — an already-base-prefixed path is NOT deduped
 * (`resolveHref("/app/x", "/app")` → `"/app/app/x"`), because `/app/x` may be
 * a legitimate in-app path. Author base-relative paths everywhere.
 */
export function resolveHref(to: string, base: string): string {
  if (isExternalHref(to) || !to.startsWith("/")) return to;
  return base.replace(/\/+$/g, "") + to;
}

// The mounted Router's base, registered at render (and UN-registered on
// unmount by the Router's mount-effect cleanup) so the module-level
// `navigate()` resolves base-relative targets. One SPA (one Router) per
// document is the deployment model; with no mounted Router the base is "",
// which makes resolution a no-op (verbatim paths).
let routerBase = "";
// Test-only: pin/reset the registered base without mounting a Router.
export function __setRouterBaseForTest(base: string): void { routerBase = base; }

/** Strip the SPA `base` prefix off an absolute pathname; returns the in-app path. */
export function stripBase(pathname: string, base: string): string {
  const b = base.replace(/\/+$/g, "");
  if (b && (pathname === b || pathname.startsWith(b + "/"))) {
    return pathname.slice(b.length) || "/";
  }
  return pathname;
}

/**
 * A route's renderable skeleton, normalizing the `skeleton: false` opt-out to
 * "no skeleton". Never use `route.skeleton ?? x` directly:
 * `??` only falls through on null/undefined, so a `false` would win the
 * coalesce and be rendered as a component.
 */
function skeletonOf(route: RouteDef): ComponentType<any> | undefined {
  return route.skeleton === false ? undefined : route.skeleton;
}

type ChainNode = { route: RouteDef; params: Record<string, string> };

/**
 * Recursively match `segs` (the base-stripped path segments) against `routes`,
 * first match wins at every level. Returns the matched chain outermost→leaf
 * (each node carrying only its OWN captures), or null.
 *
 * A route's pattern matches a PREFIX of `segs`; a **leaf** route (no children)
 * must then consume every remaining segment, while a **layout** route (with
 * children) hands the remainder to its children — matching a child, or, when
 * nothing remains, the layout alone (index-less layout: renders an empty
 * outlet). A `:seg` captures one segment; a trailing `*` captures the rest.
 *
 * Captures are percent-decoded PER SEGMENT ({@link decodeSegment}) for both
 * shapes, so `/files/:name` and `/files/*` agree on `/files/my%20doc.pdf`
 * ("my doc.pdf") instead of the old asymmetry (`*` handed back the raw
 * `my%20doc.pdf`). The `*` capture is decoded segment-by-segment before the
 * join, so one malformed escape degrades only its own segment rather than
 * leaving the whole rest-of-path encoded.
 */
function matchInto(routes: RouteDef[], segs: string[]): ChainNode[] | null {
  for (const route of routes) {
    const pat = splitSegs(route.path);
    const params: Record<string, string> = {};
    let ok = true;
    let catchAll = false;
    let consumed = 0;
    for (let i = 0; i < pat.length; i++) {
      const p = pat[i];
      if (p === "*") {
        params["*"] = segs.slice(i).map(decodeSegment).join("/");
        catchAll = true;
        consumed = segs.length;
        break;
      }
      const s = segs[i];
      if (s === undefined) { ok = false; break; }
      if (p.startsWith(":")) params[p.slice(1)] = decodeSegment(s);
      else if (p !== s) { ok = false; break; }
      consumed = i + 1;
    }
    if (!ok) continue;
    const rest = segs.slice(consumed);
    if (route.children && route.children.length) {
      const childChain = matchInto(route.children, rest);
      if (childChain) return [{ route, params }, ...childChain];
      // No child matched. If the layout consumed the whole path, it matches on
      // its own (empty <Outlet/>); otherwise there are leftover segments this
      // subtree can't place — try the next sibling.
      if (rest.length === 0) return [{ route, params }];
      continue;
    }
    // Leaf: only a match if it consumed every remaining segment.
    if (catchAll || rest.length === 0) return [{ route, params }];
  }
  return null;
}

/**
 * Match `pathname` against `routes`, returning the matched chain outermost→leaf
 * with params ACCUMULATED down the chain (each node's `params` includes every
 * ancestor's captures). First match wins at each level, so list specific routes
 * before catch-alls. Returns null when nothing matches.
 */
export function matchChain(
  routes: RouteDef[],
  pathname: string,
  base = "",
): Match[] | null {
  const chain = matchInto(routes, splitSegs(stripBase(pathname, base)));
  if (!chain) return null;
  let acc: Record<string, string> = {};
  return chain.map((n) => { acc = { ...acc, ...n.params }; return { route: n.route, params: acc }; });
}

/**
 * Back-compat single-match accessor: the LEAF of {@link matchChain} (its
 * accumulated params), or null. Flat (non-nested) route arrays yield a
 * length-1 chain, so this returns exactly what the pre-nesting `matchRoute`
 * did. `spa.zig`-facing behavior and existing callers are unchanged.
 */
export function matchRoute(
  routes: RouteDef[],
  pathname: string,
  base = "",
): Match | null {
  const chain = matchChain(routes, pathname, base);
  return chain ? chain[chain.length - 1] : null;
}

// --- Declarative redirect resolution ---------------------------------------
const MAX_REDIRECT_HOPS = 10;
// Dev-warn once per originating pathname for a broken redirect (cycle or
// unmatched target) — the build-time validation catches these, so at runtime
// they only occur with a stale bundle or a hand-driven Router.
const warnedRedirects = new Set<string>();

/**
 * Match `pathname` and FOLLOW any `redirect` leaves to the final,
 * renderable chain — each hop's target resolved against `base` exactly like
 * `navigate()`. Returns the effective pathname (what the URL should
 * be), the final matched chain, and whether any redirect was taken. A cycle
 * (more than {@link MAX_REDIRECT_HOPS} hops) or a target matching no route
 * yields a null chain (rendered as notFound) with `redirected: false`, so the
 * caller never replace-navigates onto a broken target.
 */
function resolveRedirects(
  routes: RouteDef[],
  pathname: string,
  base: string,
): { pathname: string; chain: Match[] | null; redirected: boolean } {
  let p = pathname;
  let chain = matchChain(routes, p, base);
  let redirected = false;
  for (let hops = 0; chain; hops++) {
    const target = chain[chain.length - 1].route.redirect;
    if (target === undefined) break;
    if (hops >= MAX_REDIRECT_HOPS) {
      if (!warnedRedirects.has(pathname)) {
        warnedRedirects.add(pathname);
        console.warn(
          `zigapagos: redirect chain from ${JSON.stringify(pathname)} exceeded ` +
            `${MAX_REDIRECT_HOPS} hops (a cycle?) — rendering notFound`,
        );
      }
      return { pathname, chain: null, redirected: false };
    }
    p = resolveHref(target, base);
    chain = matchChain(routes, p, base);
    redirected = true;
    if (!chain) {
      if (!warnedRedirects.has(pathname)) {
        warnedRedirects.add(pathname);
        console.warn(
          `zigapagos: redirect target ${JSON.stringify(target)} (from ${JSON.stringify(pathname)}) ` +
            "matches no route — rendering notFound",
        );
      }
      return { pathname, chain: null, redirected: false };
    }
  }
  return { pathname: p, chain, redirected };
}

/**
 * One prerenderable leaf: its full path + whether it's dynamic / has a skeleton,
 * plus the optional `staticPaths` — the leaf's resolved concrete pages (present
 * only for a dynamic leaf that declared a `staticPaths` hook).
 */
export type LeafRouteMeta = {
  path: string; dynamic: boolean; hasSkeleton: boolean; staticPaths?: string[];
  /** Declarative redirect target (base-relative in-app path), when the leaf is a redirect entry. */
  redirect?: string;
};

/** Join a parent full-path with a child's relative path ("/dash" + "/settings" -> "/dash/settings"; "/dash" + "/" -> "/dash"). */
function joinRoutePath(parent: string, child: string): string {
  return "/" + [...splitSegs(parent), ...splitSegs(child)].join("/");
}

/** Flatten to leaves, keeping the RouteDef ref (describeRoutes needs `staticPaths`). */
function flattenLeaves(routes: RouteDef[], prefix = ""): Array<{ full: string; route: RouteDef }> {
  const out: Array<{ full: string; route: RouteDef }> = [];
  for (const r of routes) {
    const full = joinRoutePath(prefix, r.path);
    if (r.children && r.children.length) out.push(...flattenLeaves(r.children, full));
    else out.push({ full, route: r });
  }
  return out;
}

/**
 * Flatten a (possibly nested) route tree into the flat list of PRERENDERABLE
 * leaves the SSG consumes. A layout route (one with `children`) contributes no
 * entry of its own — only its leaves do, each carrying the FULL path (parent +
 * child segments joined). `dynamic` = any segment of the full path is a
 * `:param`/`*`; `hasSkeleton` reflects the leaf's own skeleton. The sidecar's
 * `describe` returns this so `sidecar.zig`/`spa.zig` stay unchanged — they see a
 * flat list of leaf pathnames to SSR and write `<base>/<path>/index.html` for.
 */
export function flattenLeafPaths(routes: RouteDef[], prefix = ""): LeafRouteMeta[] {
  return flattenLeaves(routes, prefix).map(({ full, route }) => ({
    path: full, dynamic: /[:*]/.test(full), hasSkeleton: !!route.skeleton,
    ...(route.redirect !== undefined ? { redirect: route.redirect } : {}),
  }));
}

/**
 * Validate one resolved path segment (a `:param` value, or one segment of a `*`
 * catch-all) as a safe, literal on-disk/URL path segment. Throws (message
 * mentions "staticPaths") when the value is:
 *   - `""`, `"."`, or `".."` — these would clobber the SPA root shell or escape
 *     the output dir entirely (`encodeURIComponent` passes `.`/`..` through, so
 *     `{ id: ".." }` -> `/club/..` -> `app/club/../index.html`);
 *   - not URL-safe (`encodeURIComponent(seg) !== seg`) — an encoded directory
 *     like `a%20b` is written encoded to disk, but a host (e.g. nginx) decodes
 *     `$uri` before `try_files`, so the prerendered page silently never serves.
 *     Requiring URL-safe values and failing the build loudly is the consistent
 *     v1 stance (rather than encoding-and-emitting a path that won't resolve).
 */
function assertSafeStaticSegment(value: string, pattern: string): void {
  if (value === "" || value === "." || value === "..") {
    throw new Error(
      `staticPaths: resolved path segment ${JSON.stringify(value)} for pattern ${JSON.stringify(pattern)} ` +
        `is not a valid path segment ("", "." and ".." would clobber the SPA root or escape the output directory)`,
    );
  }
  if (encodeURIComponent(value) !== value) {
    throw new Error(
      `staticPaths: resolved path segment ${JSON.stringify(value)} for pattern ${JSON.stringify(pattern)} ` +
        `is not URL-safe (a staticPaths value must be a percent-encoding-stable path segment; ` +
        `encoding it would write a directory a decoding host never serves)`,
    );
  }
}

/**
 * Substitute concrete `params` into a route pattern: each `:seg` gets its param
 * value verbatim; a trailing `*` gets `params["*"]` with its slashes kept as
 * path segments. Every resolved segment is VALIDATED (not encoded) via
 * {@link assertSafeStaticSegment}: it must be a URL-safe, non-`""`/`"."`/`".."`
 * path segment, else the build fails loudly. Also throws on a missing param —
 * an enumerated entry that can't produce a concrete path is a build error, not
 * a page to skip silently.
 */
export function substituteRouteParams(pattern: string, params: Record<string, string>): string {
  const out: string[] = [];
  for (const seg of splitSegs(pattern)) {
    if (seg === "*") {
      const v = params["*"];
      if (v === undefined) throw new Error(`staticPaths: missing param "*" for pattern ${JSON.stringify(pattern)}`);
      // Split on "/" (NOT splitSegs, which would silently drop empty segments):
      // an empty/`.`/`..` segment must be REJECTED, not collapsed away. An
      // all-empty/whitespace catch-all yields no usable segment and must throw
      // rather than produce the bare pattern dir.
      const catchSegs = v.split("/");
      if (catchSegs.length === 0) throw new Error(`staticPaths: catch-all "*" resolved to no path segments for pattern ${JSON.stringify(pattern)}`);
      for (const cs of catchSegs) {
        assertSafeStaticSegment(cs, pattern);
        out.push(cs);
      }
    } else if (seg.startsWith(":")) {
      const v = params[seg.slice(1)];
      if (v === undefined) throw new Error(`staticPaths: missing param ${JSON.stringify(seg.slice(1))} for pattern ${JSON.stringify(pattern)}`);
      assertSafeStaticSegment(v, pattern);
      out.push(v);
    } else {
      out.push(seg);
    }
  }
  return "/" + out.join("/");
}

/**
 * Walk the route tree and throw (message mentions "staticPaths") if any LAYOUT
 * route (one with non-empty `children`) declares `staticPaths`. Such a route
 * prerenders no page of its own, so its `staticPaths` would be silently
 * ignored — a build error the author must fix by moving the hook to the leaf.
 * Does not touch `flattenLeaves`/`flattenLeafPaths`, so other callers are
 * unchanged.
 */
function assertNoLayoutStaticPaths(routes: RouteDef[], prefix = ""): void {
  for (const r of routes) {
    if (r.children && r.children.length) {
      const full = joinRoutePath(prefix, r.path);
      if (r.staticPaths !== undefined) {
        throw new Error(
          `staticPaths declared on layout route ${JSON.stringify(full)} (a route with children) — ` +
            `a layout prerenders no page of its own, so declare staticPaths on the leaf route that renders the dynamic page`,
        );
      }
      assertNoLayoutStaticPaths(r.children, full);
    }
  }
}

/**
 * Walk the route tree and throw on a malformed `redirect` entry or a
 * route that declares nothing to render. A `redirect` route is a pure alias:
 *   - `redirect` + `component` / `children` / `staticPaths` is contradictory
 *     (the redirect never renders, never lays out, never enumerates);
 *   - the target must be a plain, CONCRETE, BASE-RELATIVE in-app pathname —
 *     root-relative, no scheme//host, no query/hash (the redirect preserves
 *     the CURRENT location's query/hash instead), and no `:param`/`*`/`.`/
 *     `..` segment (same concreteness rule as src/spa.zig's
 *     `validateConcretePath` — the two validators must agree);
 *   - and every non-redirect route must declare a `component`.
 * Target-vs-route-table validation happens Zig-side (`src/spa.zig`), which
 * alone can name the offending SPA; this walk validates shape only.
 */
function assertValidRedirects(routes: RouteDef[], prefix = ""): void {
  for (const r of routes) {
    const full = joinRoutePath(prefix, r.path);
    if (r.redirect !== undefined) {
      const clash = r.component !== undefined ? "component"
        : r.children && r.children.length ? "children"
        : r.staticPaths !== undefined ? "staticPaths" : null;
      if (clash) {
        throw new Error(
          `route ${JSON.stringify(full)} declares both \`redirect\` and \`${clash}\` — ` +
            "a redirect entry is a pure alias and renders nothing of its own",
        );
      }
      // Mirrors src/spa.zig's `validateConcretePath` (which re-checks this
      // build-side as defense-in-depth): a target must be a CONCRETE
      // root-relative pathname — a `:param`/`*` segment has nothing to
      // substitute it at navigation time, and a `.`/`..` segment is a
      // traversal, not a route path. Empty segments (`//`) are tolerated
      // like everywhere else in the router (segment splitting skips them).
      const nonConcreteSeg = r.redirect.split("/").find(
        (seg) => seg.startsWith(":") || seg === "*" || seg === "." || seg === "..",
      );
      if (isExternalHref(r.redirect) || !r.redirect.startsWith("/") || /[?#]/.test(r.redirect) || nonConcreteSeg !== undefined) {
        throw new Error(
          `route ${JSON.stringify(full)} redirect target ${JSON.stringify(r.redirect)} must be a ` +
            "concrete root-relative in-app pathname (base-relative; no scheme/host, no query/hash — " +
            "the current location's query and hash are preserved automatically — and no " +
            "`:param`/`*`/`.`/`..` segment)",
        );
      }
    } else if (r.component === undefined) {
      throw new Error(`route ${JSON.stringify(full)} declares neither \`component\` nor \`redirect\``);
    }
    if (r.children && r.children.length) assertValidRedirects(r.children, full);
  }
}

/**
 * The BASE-RELATIVE pathname the build's SSR pass uses for a dynamic route's
 * full path: every `:param`/`*` segment substituted with `"_"`, independent of
 * any real params (mirrors `substituteParams` in `src/spa.zig`, which prepends
 * the SPA's `base` — unknown here, hence "base-relative"). Used only to NAME
 * the pathname in the no-skeleton diagnostic below, so an author sees the URL
 * the build will actually SSR instead of re-deriving it from the substitution
 * rule in their head.
 */
function ssrPathnameFor(full: string): string {
  return "/" + splitSegs(full).map((seg) => (seg === "*" || seg.startsWith(":")) ? "_" : seg).join("/");
}

/**
 * The async superset of `flattenLeafPaths` the sidecar's `describe` calls:
 * flattens the route tree AND resolves each dynamic leaf's `staticPaths`
 * hook into concrete in-app paths. `staticPaths` on a static route is a
 * config error (there is nothing to enumerate) and throws — surfaced by
 * describe's loud-fail path so the SSG reports it.
 */
export async function describeRoutes(routes: RouteDef[]): Promise<LeafRouteMeta[]> {
  // A LAYOUT route (one with children) contributes no shell of its own, so a
  // `staticPaths` declared on it would be silently ignored — only leaves
  // prerender. Fail loudly and tell the author to move it to the leaf.
  assertNoLayoutStaticPaths(routes);
  // Redirect entries must be well-shaped before they ship to the build;
  // the build then validates every target against this SPA's route table.
  assertValidRedirects(routes);
  const out: LeafRouteMeta[] = [];
  for (const { full, route } of flattenLeaves(routes)) {
    const dynamic = /[:*]/.test(full);
    // A lazy() leaf is stricter than the dynamic rule below: its `component`
    // is a code-split marker that CANNOT render until its chunk loads (the
    // marker throws when rendered directly), so SSR and the first client
    // render must show a real `skeleton` — even on a STATIC path, and
    // `skeleton: false`'s "my component is hydration-stable" promise is
    // impossible to keep for a component that doesn't exist yet. Without
    // this check the misconfiguration surfaces late and badly: the SSR pass
    // throws the marker's generic "rendered directly" error (or, under a
    // guard whose fallback covers the SSR pass, nothing renders at runtime
    // until the chunk loads).
    if (lazyStateOf(route.component) !== undefined && (route.skeleton == null || route.skeleton === false)) {
      throw new Error(
        `lazy route ${JSON.stringify(full)} ${route.skeleton === false ? "declares skeleton: false" : "declares no skeleton"} — ` +
          `a lazy() route's component is a code-split marker that cannot render until its chunk ` +
          `loads, so SSR and the first client render need a real skeleton (this applies to static ` +
          `paths too, and skeleton: false is not allowed: its hydration-stability promise cannot ` +
          `hold for a component that hasn't loaded). Give the route a \`skeleton\` component.`,
      );
    }
    // The docs' skeleton rule, enforced: a dynamic leaf's SSR
    // pathname substitutes every `:param`/`*` with "_", so its SSR output
    // differs from the first client render unless the route has a
    // param-independent `skeleton` — a hydration breaker that surfaces as
    // subtly-wrong DOM at runtime, not as an error at the failure site.
    // Only the LEAF's own skeleton counts: layouts render their real
    // `component` on both passes and never a skeleton (see renderChainNode),
    // so there is no inheritance to honor. `skeleton: false` is the explicit
    // opt-out: the author asserts the component is hydration-stable.
    // A `redirect` entry is exempt: it has no component and never
    // renders/hydrates anything of its own — the Router resolves it BEFORE
    // rendering, so both SSR and the first client render show the TARGET's
    // chain (whose own leaf is held to this rule instead).
    if (dynamic && route.skeleton == null && route.redirect === undefined) {
      throw new Error(
        `dynamic route ${JSON.stringify(full)} declares no skeleton — the build SSRs its shell at ` +
          `the base-relative path ${JSON.stringify(ssrPathnameFor(full))} (every :param and * ` +
          `segment substituted with "_"), so its SSR output differs from the first client render, ` +
          `which breaks hydration. Give the route a param-independent \`skeleton\` component, or ` +
          `set \`skeleton: false\` to assert the component is hydration-stable without one.`,
      );
    }
    const meta: LeafRouteMeta = { path: full, dynamic, hasSkeleton: !!route.skeleton };
    if (route.redirect !== undefined) meta.redirect = route.redirect;
    if (route.staticPaths !== undefined) {
      if (!dynamic) throw new Error(`staticPaths declared on static route ${JSON.stringify(full)} — only dynamic routes (:param / *) can enumerate pages`);
      const entries = typeof route.staticPaths === "function" ? await route.staticPaths() : route.staticPaths;
      meta.staticPaths = entries.map((p) => substituteRouteParams(full, p));
    }
    out.push(meta);
  }
  return out;
}

import {
  h, createContext, useContext, useState, useEffect, useRef, hydrate,
  useSyncExternalStore, useMemo, useCallback,
} from "./core.ts";
import { isServer, currentPathname, currentSearch, getUrlPathPrefix, setUrlPathPrefix } from "./ssr-env.ts";
import { host } from "./host.ts";
import { onUnauthorizedResponse } from "./session.ts";
import { seedFlagsFromShell } from "./flags.ts";

type RouterCtx = {
  base: string;
  pathname: string;
  params: Record<string, string>;
  navigate: (to: string, opts?: { replace?: boolean; external?: boolean }) => void;
  /**
   * Issue #128: start a lazy leaf's chunk load early, from a hover/focus/
   * touch or a viewport intersection on a `<Link>` — NOT from a real
   * navigation (that path is the lazy-load effect above, which shares the
   * same in-flight promise via `startLazyLoad`). `resolvedHref` is already
   * base-resolved (same value `<Link>` uses for its actual `href`). A no-op
   * for a non-lazy target, an external href, or when the connection is
   * data-saver/slow (`prefetchAllowed`).
   */
  prefetch: (resolvedHref: string) => void;
};
const Ctx = createContext<RouterCtx | null>(null);

/**
 * The Astro-standard data-saver guard: skip prefetching when the browser
 * reports the user opted into reduced data usage, or is on a very slow
 * connection. `navigator.connection` (Network Information API) is
 * Chromium-only and experimental — absent everywhere else, where this
 * simply returns `true` (prefetch allowed; matches the feature being
 * Chromium-first the same way Speculation Rules is, see docs/islands.md).
 */
function prefetchAllowed(): boolean {
  const conn = (navigator as any)?.connection;
  if (!conn) return true;
  if (conn.saveData === true) return false;
  if (typeof conn.effectiveType === "string" && conn.effectiveType.includes("2g")) return false;
  return true;
}
export function __prefetchAllowedForTest(): boolean { return prefetchAllowed(); }

// The matched chain + the current rung's depth, threaded down so each layout's
// <Outlet/> knows which nested route to render next. `gateDepth` is the depth of
// the first UNAUTHORIZED guarded rung (or -1 when the whole chain is authorized):
// at that depth the neutral `fallback` renders in place of the rung and its
// subtree, so authorized ancestor layouts stay mounted above it.
type OutletCtx = {
  chain: Match[]; depth: number; hydrated: boolean;
  gateDepth: number; fallback: VNode<any> | null;
  /** depth → the guard data of the guarded rung at that depth (authorized rungs only). */
  guardData: ReadonlyMap<number, unknown>;
  /**
   * Live `<Outlet/>` instances currently mounted under THIS rung (registered
   * by `Outlet`'s mount effect, unregistered on cleanup) — the misuse
   * detector for issue #22 (`children` IS an `<Outlet/>`, so rendering both
   * the `children` prop AND an explicit `<Outlet/>` mounts two, and rendering
   * neither mounts zero). Owned by the `RouteRung` wrapper via `useRef` so it
   * is stable across that rung's re-renders — a Set built fresh per
   * `renderChainNode` call would make detection order-dependent.
   */
  live: Set<object>;
};
const OutletContext = createContext<OutletCtx | null>(null);

// Dev-warn (once per layout route path) when BOTH channels are used —
// `{children}` (an implicit Outlet) and an explicit `<Outlet/>` — which
// mounts the matched child twice. Never suppress the second instance instead
// of warning: which one "wins" would depend on render order, and silently
// picking one would make SSR (which has no such ordering concept) diverge
// from the client.
const warnedDoubleOutlet = new Set<string>();
// Dev-warn (once per layout route path) when NEITHER channel is used — the
// original trap this issue was filed for: the layout compiles, SSRs, and
// renders a plausible-looking (but silently empty) container, with its
// matched child component never invoked.
const warnedNoOutlet = new Set<string>();

// The value the NEAREST enclosing guard provided via `{ ok: true, data }`.
// Each guarded rung (and a Router-level guard) wraps its subtree in a fresh
// provider, so nesting gives natural nearest-guard-wins semantics.
const GuardDataContext = createContext<unknown>(undefined);

/**
 * The data returned by the NEAREST enclosing guard (`{ ok: true, data }` — see
 * {@link GuardResult}). Nested guards shadow: a component under both a guarded
 * layout and a guarded leaf sees the LEAF guard's data; an unguarded child under
 * a guarded layout sees the layout guard's data. `undefined` when the nearest
 * guard returned plain `true` / `{ ok: true }` with no data, or outside any
 * guarded scope (including SSR, where guards never run). Re-renders with fresh
 * data whenever the guard re-validates.
 */
export function useGuardData<T = unknown>(): T | undefined {
  return useContext(GuardDataContext) as T | undefined;
}

/**
 * TEST PRIMITIVE. Wrap `vnode` in the guard-data context so a view
 * rendered in ISOLATION (no Router, no live guard) sees `data` from
 * {@link useGuardData} — exactly what its nearest enclosing route guard would
 * have provided at runtime via `{ ok: true, data }`. This is the single seam
 * the `@z/runtime/testing` `renderForTest` helper needs to inject guard data;
 * app code has no reason to call it (the Router wires the real provider itself
 * in `renderChainNode`).
 */
export function provideGuardData(data: unknown, vnode: VNode<any>): VNode<any> {
  return h(GuardDataContext.Provider, { value: data }, vnode);
}

const EMPTY_GUARD_DATA: ReadonlyMap<number, unknown> = new Map();

/**
 * One rung's OutletContext.Provider + component, as a real component (not an
 * inline `h()` call) so its `live` Set — the Outlet-misuse detector — is
 * owned via `useRef` and stable across this rung's re-renders. Given directly
 * to `h(comp, { children: h(Outlet, {}) })`: `children` IS an `<Outlet/>`,
 * for every rung (leaves included — a leaf component simply never reads
 * `children`, and `Outlet` itself renders `null` at a leaf depth, see below).
 *
 * For a non-leaf (layout) rung only, an effect with NO dependency array
 * fires after every render/re-render and checks `live.size`. It reads a
 * settled value because Preact flushes CHILD effects before the PARENT's —
 * `Outlet`'s own registration effect (a child of this component, however
 * deep inside `comp`'s tree it's mounted) has already run by the time this
 * one does. `live.size === 0` after that means neither `{children}` nor an
 * `<Outlet/>` rendered — the matched child route never renders (issue #22's
 * original trap: no error, just a silently empty layout). `live.size > 1`
 * means BOTH channels rendered, mounting the matched child twice; that
 * detection lives in `Outlet` itself (see below), since a layout with a
 * DEEPLY nested `<Outlet/>` needs the same check regardless of whether that
 * `<Outlet/>` runs before or after this component's own effect.
 */
function RouteRung(props: {
  chain: Match[]; depth: number; hydrated: boolean;
  gateDepth: number; fallback: VNode<any> | null;
  guardData: ReadonlyMap<number, unknown>;
  comp: ComponentType<any>; isLeaf: boolean;
}): VNode<any> {
  const { chain, depth, hydrated, gateDepth, fallback, guardData, comp, isLeaf } = props;
  const liveRef = useRef<Set<object> | null>(null);
  if (!liveRef.current) liveRef.current = new Set();
  const live = liveRef.current;
  useEffect(() => {
    if (isLeaf) return;
    // Deferred to a MICROTASK, not checked synchronously in this effect body:
    // Preact flushes one commit's effects in a single synchronous pass, but
    // NOT reliably children-before-parent on a rung's very first mount — this
    // rung's own effect can run before a freshly-mounted nested <Outlet/>'s
    // own mount effect has registered, which would false-positive "neither
    // channel used" on a perfectly correct layout. `queueMicrotask` defers
    // the actual check past the CURRENT synchronous flush entirely, so every
    // effect scheduled in this commit — this rung's and any nested Outlet's,
    // regardless of which one Preact happened to run first — has already
    // executed by the time it runs. `cancelled` guards against a rung that
    // unmounts before its deferred check fires.
    let cancelled = false;
    queueMicrotask(() => {
      if (cancelled || live.size > 0) return;
      const path = chain[depth].route.path;
      if (warnedNoOutlet.has(path)) return;
      warnedNoOutlet.add(path);
      console.warn(
        `zigapagos: layout route ${JSON.stringify(path)} rendered neither {children} nor an ` +
          "<Outlet/> — its matched child route never renders.",
      );
    });
    return () => { cancelled = true; };
  });
  return h(
    OutletContext.Provider,
    { value: { chain, depth, hydrated, gateDepth, fallback, guardData, live } },
    h(comp, { children: h(Outlet, {}) }),
  );
}

/**
 * Render the chain rung at `depth`. If `depth === gateDepth` the guard for this
 * scope hasn't authorized yet, so render the neutral `fallback` here in place of
 * the rung and its subtree (fail-closed) — authorized ancestor layouts above it
 * still render (and stay mounted). Otherwise the rung's component is wrapped
 * (via `RouteRung`) in an OutletContext, with `children: <Outlet/>` — the ONE
 * channel by which the next rung renders, whether the component reads it via
 * the `children` prop or an explicit `<Outlet/>` placement (they are the same
 * element). The LEAF rung follows the two-phase-hydration rule (`skeleton ??
 * component` on SSR + first client render, the real `component` once
 * `hydrated`); layout rungs render their (static-chrome) `component`
 * identically on both passes.
 *
 * NB: a layout rung renders its REAL component on the hydrate pass, so a layout
 * component must not bind a dynamic path param to an ATTRIBUTE — text children
 * self-heal on hydrate, attributes do not. (Docs cover this; see spa.md.)
 */
function renderChainNode(
  chain: Match[], depth: number, hydrated: boolean,
  gateDepth: number, fallback: VNode<any> | null,
  guardData: ReadonlyMap<number, unknown>,
): VNode<any> {
  if (depth === gateDepth) return fallback as VNode<any>;
  const node = chain[depth];
  const isLeaf = depth === chain.length - 1;
  // The Router resolves `redirect` entries before rendering, so a rendered
  // rung always has a `component` in a well-formed route table; the EmptyView
  // fallbacks below only guard a malformed table (which describeRoutes
  // rejects at build time).
  let comp: ComponentType<any>;
  if (!isLeaf) {
    comp = node.route.component ?? EmptyView; // layout: static chrome, same on both passes
  } else if (isServer() || !hydrated) {
    comp = skeletonOf(node.route) ?? node.route.component ?? EmptyView; // two-phase: skeleton first
  } else {
    // Post-hydration leaf. A lazy route renders its resolved chunk once loaded,
    // else keeps its skeleton (the loader is kicked by the Router effect); the
    // flip to the resolved component is a normal non-hydrating re-render.
    const lz = lazyStateOf(node.route.component);
    comp = lz ? (lz.comp ?? skeletonOf(node.route) ?? EmptyView) : (node.route.component ?? EmptyView);
  }
  let vnode: VNode<any> = h(RouteRung, { chain, depth, hydrated, gateDepth, fallback, guardData, comp, isLeaf });
  // A guarded rung provides ITS guard's data to itself + its subtree; nesting
  // shadows the outer provider (nearest guard wins). Provided even when the
  // data is undefined so an inner `true`-guard correctly shadows an outer
  // data-carrying guard rather than leaking it.
  if (node.route.guard) {
    vnode = h(GuardDataContext.Provider, { value: guardData.get(depth) }, vnode);
  }
  return vnode;
}

function EmptyView(): VNode<any> | null { return null; }

/**
 * Placed inside a layout route's `component`, renders the next matched route in
 * the chain (the child that matched under this layout). Renders nothing when
 * this layout is the leaf (an index-less layout matched on its own).
 *
 * `children` IS an `<Outlet/>` (see `RouteRung`/`renderChainNode`): every
 * rung's component is called with `{ children: h(Outlet, {}) }`, so a layout
 * that renders `{children}` and one that renders `<Outlet/>` explicitly go
 * through this exact function — there is no second, divergent code path.
 * That also means an explicit `<Outlet/>` placed ALONGSIDE `{children}`
 * mounts a second live instance; each instance registers itself into the
 * enclosing rung's `live` set on mount (unregistering on cleanup) and warns
 * once per layout path the first time it finds itself sharing that set.
 */
export function Outlet(): VNode<any> | null {
  const oc = useContext(OutletContext);
  const idRef = useRef<object | null>(null);
  if (idRef.current === null) idRef.current = {};
  useEffect(() => {
    if (!oc) return;
    const id = idRef.current!;
    const live = oc.live;
    live.add(id);
    if (live.size > 1) {
      const path = oc.chain[oc.depth].route.path;
      if (!warnedDoubleOutlet.has(path)) {
        warnedDoubleOutlet.add(path);
        console.warn(
          `zigapagos: layout route ${JSON.stringify(path)} renders both {children} and <Outlet/> — ` +
            "they are the same channel (children IS an <Outlet/>), so the matched child renders " +
            "twice. Render exactly one.",
        );
      }
    }
    return () => { live.delete(id); };
  }, [oc]);
  if (!oc) return null;
  const next = oc.depth + 1;
  if (next >= oc.chain.length) return null;
  return renderChainNode(oc.chain, next, oc.hydrated, oc.gateDepth, oc.fallback, oc.guardData);
}

// Module-level location listeners so navigate()/popstate can re-render every
// Router AND every useSearchParams()/location subscriber (query-only nav
// included — the Router itself bails on an unchanged pathname).
const listeners = new Set<() => void>();
function emit(): void { for (const l of listeners) l(); }

// Subscribe to location changes (reused by useSyncExternalStore hooks). Binds
// the single shared popstate listener; returns an unsubscribe.
function subscribeLocation(cb: () => void): () => void {
  bindPopstate();
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}

// ---------------------------------------------------------------------------
// Scroll restoration. On PUSH → scroll to top after the route renders; on
// BACK/FORWARD → restore the position saved for the target history entry. The
// position is keyed to the history ENTRY (a monotonic id kept in
// `history.state.__zScrollId`), NOT the pathname — the same path can appear
// multiple times in history. Client-only; on by default.
// ---------------------------------------------------------------------------
type ScrollPos = { x: number; y: number };
let scrollRestorationOn = true;
const scrollPositions = new Map<number, ScrollPos>();
let scrollSeq = 0;
let currentScrollId = -1;

// Cap the saved-position map so a long-lived tab that soft-navigates thousands
// of times can't grow it without bound (AUDF-018). Entries are evicted in
// least-recently-saved order: `saveScrollPos` re-inserts a revisited entry at
// the newest slot, so Map iteration order tracks recency (LRU). Pruning the
// oldest keeps the entries nearest the user's current position — the ones still
// reachable through the browser's Back/Forward stack — and the entry currently
// on top is never evicted even if it is otherwise the least recent. (A plain
// `scrollSeq - MAX` id threshold could prune the immediate parent right after a
// deep Back followed by a PUSH, losing its scroll on the next Back.)
const MAX_SCROLL_POSITIONS = 128;
function saveScrollPos(id: number, pos: ScrollPos): void {
  // delete-before-set so insertion order reflects recency: a revisited entry
  // moves to the newest slot instead of keeping its original position.
  scrollPositions.delete(id);
  scrollPositions.set(id, pos);
}
function pruneScrollPositions(): void {
  if (scrollPositions.size <= MAX_SCROLL_POSITIONS) return;
  for (const key of scrollPositions.keys()) {
    if (key === currentScrollId) continue; // never evict the current entry
    scrollPositions.delete(key);
    if (scrollPositions.size <= MAX_SCROLL_POSITIONS) break;
  }
}

/** Save `pos` for the entry being LEFT, mint + adopt a new entry id (PUSH). */
function scrollOnPush(pos: ScrollPos): number {
  if (currentScrollId !== -1) saveScrollPos(currentScrollId, pos);
  currentScrollId = scrollSeq++;
  pruneScrollPositions();
  return currentScrollId;
}
/** Save leaving `pos`, adopt the target entry's id, return its saved position (POP). */
function scrollOnPop(pos: ScrollPos, targetId: number | undefined): ScrollPos {
  if (currentScrollId !== -1) saveScrollPos(currentScrollId, pos);
  currentScrollId = typeof targetId === "number" ? targetId : scrollSeq++;
  const saved = scrollPositions.get(currentScrollId) ?? { x: 0, y: 0 };
  pruneScrollPositions();
  return saved;
}
function readScroll(): ScrollPos {
  return { x: window.scrollX || window.pageXOffset || 0, y: window.scrollY || window.pageYOffset || 0 };
}
function afterRender(fn: () => void): void {
  // Preact commits on a microtask; a rAF tick runs after that, so the target
  // route's DOM exists by the time we scroll.
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => fn());
  else queueMicrotask(fn);
}

// A BACK/FORWARD restore can outrun the content: a guarded scope first renders
// the neutral fallback, and a `lazy()` leaf the skeleton, so the tall real
// content mounts only after that async work resolves — several frames after the
// single post-render rAF. Restoring against the short placeholder clamps the
// target Y to 0 and, since `scrollRestoration` is forced `manual`, the browser
// won't retry either. So retry across a bounded number of frames until the page
// is tall enough to hold the saved Y (or we run out of frames) — AUDF-017.
const SCROLL_RESTORE_MAX_FRAMES = 20;
/** The furthest the window can scroll vertically given the current layout. */
function maxScrollY(): number {
  if (isServer() || typeof document === "undefined") return 0;
  const doc = document.documentElement;
  const scrollHeight = Math.max(doc?.scrollHeight ?? 0, document.body?.scrollHeight ?? 0);
  const viewport = window.innerHeight || doc?.clientHeight || 0;
  return Math.max(0, scrollHeight - viewport);
}
/**
 * Should the pop scroll-restore retry on the next frame? True only while the
 * saved Y still can't be reached (async guard/lazy content is still mounting)
 * AND frames remain. Pure so the frame-budget/height logic is unit-testable
 * (happy-dom's scroll is a no-op). Exported for tests.
 */
export function __scrollRestoreShouldRetry(targetY: number, reachableY: number, framesLeft: number): boolean {
  // 1px slack for sub-pixel layout rounding; y<=0 needs no retry (always reachable).
  return targetY > 0 && framesLeft > 0 && reachableY < targetY - 1;
}

// Monotonic id of the navigation that currently OWNS the viewport, bumped by
// every PUSH and every POP. A retrying restore captures it when it starts and
// gives up the moment it changes: the retry budget (20 frames ≈ 330ms) easily
// outlives a fast Back-then-Link, and on the newly-pushed SHORT page the saved
// Y is permanently unreachable, so an un-scoped loop would re-scroll to the
// bottom of the wrong page every frame until its budget ran out. Never reset —
// monotonic ids can't alias, so a stale loop can never look current again.
let navSeq = 0;
/** Test-only: the nav id a restore started now would capture. */
export function __navSeqForTest(): number { return navSeq; }
function restoreScrollWithRetry(pos: ScrollPos, framesLeft: number, nav: number): void {
  if (nav !== navSeq) return; // superseded: `pos` belongs to a page that is gone
  window.scrollTo(pos.x, pos.y);
  if (__scrollRestoreShouldRetry(pos.y, maxScrollY(), framesLeft)) {
    afterRender(() => restoreScrollWithRetry(pos, framesLeft - 1, nav));
  }
}

/**
 * Should a POP restore a saved scroll position at all?
 *
 * A history entry the router never stamped (`__zScrollId` absent) is one the
 * BROWSER created — the documented plain `<a href="#pricing">` fragment escape
 * hatch — so there is no position saved for it and `scrollOnPop` hands back its
 * `{x:0,y:0}` default. Applying that on Back/Forward across a fragment
 * teleports the visitor to the TOP of the document instead of the anchor, and
 * because `history.scrollRestoration` is forced `"manual"` the browser cannot
 * put it right. When the URL carries a fragment, leave the scroll alone and let
 * the fragment win. Pure so it is unit-testable (happy-dom's scroll is a
 * no-op). Exported for tests.
 */
export function __shouldRestoreOnPop(hasStampedEntry: boolean, hash: string): boolean {
  return hasStampedEntry || hash === "";
}
function scrollStateFor(id: number | null): unknown {
  return id === null ? null : { __zScrollId: id };
}
/** Adopt or assign an id for the current (initial) history entry; take manual control. */
function initScrollRestoration(): void {
  if (!scrollRestorationOn || currentScrollId !== -1 || isServer()) return;
  try { history.scrollRestoration = "manual"; } catch { /* unsupported: ignore */ }
  const st = history.state as { __zScrollId?: number } | null;
  if (st && typeof st.__zScrollId === "number") {
    currentScrollId = st.__zScrollId;
    if (currentScrollId >= scrollSeq) scrollSeq = currentScrollId + 1;
  } else {
    currentScrollId = scrollSeq++;
    try { history.replaceState({ ...(st ?? {}), __zScrollId: currentScrollId }, ""); } catch { /* ignore */ }
  }
}

let popstateBound = false;
function bindPopstate(): void {
  if (popstateBound || isServer()) return;
  popstateBound = true;
  initScrollRestoration();
  window.addEventListener("popstate", onPopstate);
}

// ---------------------------------------------------------------------------
// View transitions. Opt-in (`spa.viewTransitions: true` via mountSpa, or the
// escape hatch `setViewTransitions()` for a hand-mounted Router) wraps a route
// flip in `document.startViewTransition()`. Off by default and
// feature-detected, so an unsupported browser (or the opt-in never set) gets
// today's instant flip — progressive enhancement, no polyfill. This is the
// ONE seam both the push path (`navigateResolved`) and `onPopstate` go
// through, so there is no second, divergent flip path to keep in sync.
// ---------------------------------------------------------------------------
let viewTransitionsOn = false;
/** Opt in to (or back out of) wrapping route flips in document.startViewTransition().
 *  Off by default; usually driven by `spa.viewTransitions` via mountSpa. */
export function setViewTransitions(on: boolean): void { viewTransitionsOn = on; }

type ViewTransitionLike = { ready?: Promise<void>; updateCallbackDone?: Promise<void> };
/**
 * The feature-detected `document.startViewTransition`, bound to `document`,
 * or null when transitions are off or unsupported. Typed via a local cast —
 * this does not depend on lib.dom declaring `ViewTransition`.
 */
function viewTransitionApi(): ((cb: () => Promise<void>) => ViewTransitionLike | undefined) | null {
  if (!viewTransitionsOn || typeof document === "undefined") return null;
  const f = (document as { startViewTransition?: (cb: () => Promise<void>) => ViewTransitionLike }).startViewTransition;
  return f ? f.bind(document) : null;
}

/**
 * Resolve after the CURRENT commit flushes. The browser snapshots the NEW
 * state when the transition's update-callback promise settles; Preact
 * schedules its re-render flush on a microtask created during `emit()`
 * (inside the callback), and microtasks are FIFO, so a microtask queued
 * AFTER the flip runs after Preact's commit.
 *
 * Deliberately NOT `afterRender`/rAF: rendering is suppressed while the
 * capture is pending, so a rAF tick may never fire while the browser waits —
 * that would stall the navigation until the spec's ~4s timeout instead of
 * completing in a microtask. Do not "simplify" this to rAF.
 */
function afterCommit(): Promise<void> {
  return new Promise((r) => queueMicrotask(r));
}

/**
 * Run a route flip, inside a view transition when opted-in + supported.
 * `settle` (a scroll adjustment) runs after the flip's Preact commit and
 * BEFORE the browser captures the new state, so the snapshot is coherent; on
 * the plain (no-transition) path it keeps today's `afterRender` timing
 * exactly. The one seam used by both `navigateResolved`'s push branch and
 * `onPopstate` — replace navigation and query/hash-only navigation never call
 * this (see their call sites).
 */
function flipWithTransition(flip: () => void, settle?: () => void): void {
  const vt = viewTransitionApi();
  if (!vt) {
    flip();
    if (settle) afterRender(settle);
    return;
  }
  const t = vt(() => {
    flip();
    return afterCommit().then(settle);
  });
  // A transition skipped by a rapid follow-up navigation rejects `ready` —
  // normal flow, not an error; leave it unhandled-but-caught. A rejected
  // `updateCallbackDone` means OUR flip (or `settle`) threw, which without a
  // transition would have surfaced synchronously — route it to
  // host.reportError so it stays loud instead of a silent unhandledrejection.
  t?.ready?.catch(() => {});
  t?.updateCallbackDone?.catch((err) => host.reportError(err));
}

function onPopstate(): void {
  if (!scrollRestorationOn) {
    flipWithTransition(() => emit());
    return;
  }
  const st = history.state as { __zScrollId?: number } | null;
  const targetId = st && typeof st.__zScrollId === "number" ? st.__zScrollId : undefined;
  // In manual mode the browser hasn't moved the scroll yet, so `readScroll()`
  // is still the LEAVING entry's position — save it, then restore the target's.
  const pos = scrollOnPop(readScroll(), targetId);
  const nav = ++navSeq; // this POP now owns the viewport
  // A browser-created fragment entry keeps its fragment position (see
  // __shouldRestoreOnPop); the bookkeeping above still ran, so the entry we
  // LEFT keeps its saved position and a later stamped POP restores normally.
  const restore = __shouldRestoreOnPop(targetId !== undefined, window.location.hash)
    ? () => restoreScrollWithRetry(pos, SCROLL_RESTORE_MAX_FRAMES, nav)
    : undefined;
  flipWithTransition(() => emit(), restore);
}

/**
 * Programmatic navigation. `to` is resolved against the mounted Router's
 * `base` (see {@link resolveHref}): `navigate("/login")` under base `/app`
 * soft-navigates to `/app/login`. An absolute URL — or `{ external: true }` —
 * performs a FULL-PAGE navigation (`window.location`), leaving the SPA; use it
 * (or a plain `<a>`) for cross-SPA/external targets.
 */
export function navigate(to: string, opts: { replace?: boolean; external?: boolean } = {}): void {
  if (isServer()) return;
  if (opts.external || isExternalHref(to)) {
    // Full-page navigation: leaves the SPA entirely (history API can't cross
    // origins, and an explicit `external` means "no soft-nav" even in-origin).
    if (opts.replace) window.location.replace(to);
    else window.location.assign(to);
    return;
  }
  navigateResolved(resolveHref(to, routerBase), opts);
}

/**
 * The soft-navigation core: pushes/replaces `to` VERBATIM (no base
 * resolution). Internal call sites that already hold a fully-resolved
 * pathname (Link's resolved href, useSearchParams' same-pathname query swap,
 * the redirect-entry URL sync) come here directly so the base can never be
 * applied twice.
 */
function navigateResolved(to: string, opts: { replace?: boolean } = {}): void {
  if (isServer()) return;
  initScrollRestoration();
  if (opts.replace) {
    // Replace keeps the current entry (and its scroll id); no scroll change.
    // Deliberately NOT a new `navSeq`: a replace doesn't move the history
    // cursor, so an in-flight restore (a redirect entry syncing its URL right
    // after a Back, say) is still restoring the entry the visitor is on.
    history.replaceState(scrollStateFor(scrollRestorationOn ? currentScrollId : null), "", to);
    emit();
    return;
  }
  // Read the CURRENT pathname before pushState overwrites it: a query/hash-only
  // navigation (`setSearchParams` from a filter box, once per keystroke) must
  // keep the viewport where it is instead of yanking it to the top of the page
  // away from the input.
  const samePathname = targetPathname(to) === window.location.pathname;
  const newId = scrollRestorationOn ? scrollOnPush(readScroll()) : null;
  navSeq++; // this PUSH now owns the viewport; any in-flight restore is stale
  const flip = () => { history.pushState(scrollStateFor(newId), "", to); emit(); };
  // Query/hash-only nav (a filter box setting a param per keystroke) never
  // transitions and never scrolls — the viewport must stay exactly where it
  // is, so this bypasses flipWithTransition entirely rather than passing an
  // undefined settle through it.
  if (samePathname) { flip(); return; }
  flipWithTransition(flip, scrollRestorationOn ? () => window.scrollTo(0, 0) : undefined);
}

/**
 * The pathname of an already-resolved in-app navigation target
 * (`"/app/x?q=1#top"` → `"/app/x"`). A query/hash-only target (`"?q=1"`) has no
 * pathname of its own: it stays on the current one.
 */
function targetPathname(to: string): string {
  const cut = to.search(/[?#]/);
  const p = cut === -1 ? to : to.slice(0, cut);
  return p === "" ? window.location.pathname : p;
}

/** Opt out of (or back into) automatic scroll restoration. On by default. */
export function setScrollRestoration(on: boolean): void {
  scrollRestorationOn = on;
}

// Test-only: reset the scroll bookkeeping between cases.
export function __resetScrollForTest(): void {
  scrollPositions.clear();
  scrollSeq = 0;
  currentScrollId = -1;
  scrollRestorationOn = true;
}
// Test-only: inspect the scroll bookkeeping.
export function __scrollStateForTest(): { positions: Map<number, ScrollPos>; currentId: number; seq: number } {
  return { positions: scrollPositions, currentId: currentScrollId, seq: scrollSeq };
}
export const __scrollBookkeepingForTest = {
  onPush: scrollOnPush,
  onPop: scrollOnPop,
  restoreWithRetry: restoreScrollWithRetry,
};

function DefaultNotFound(): VNode<any> {
  return h("div", { "data-z-notfound": "" }, "Not found");
}

// Dev-warn (once per route path) when a guarded route has no `fallback` to
// hold. Without one the router fails CLOSED — it renders a neutral empty
// placeholder, never `skeleton ?? component` — so a misconfigured guard can't
// leak gated content into the shell; the warning nudges the author to supply a
// proper loading state.
const warnedNoFallback = new Set<string>();
// Dev-warn (once per route path) when a lazy route has no `skeleton` to show
// until its chunk resolves.
const warnedLazyNoSkeleton = new Set<string>();

// ---------------------------------------------------------------------------
// Session-expiry policy. When apiFetch sees a same-origin 401/403,
// the Router re-runs the ACTIVE route's guard pipeline once — the guard is
// already the single source of truth for "who may be here", so its
// `{ redirect }` verdict navigates the visitor to the login route with zero
// per-site wiring. Loop prevention is two-layered:
//   1. IN-FLIGHT suppression — no re-run starts while a guard run is already
//      running, so a guard's OWN probe 401ing can't recurse into itself;
//   2. a COOLDOWN between 401-triggered re-runs — when the guard keeps saying
//      `true` while some endpoint keeps 401ing (an endpoint-specific 403, a
//      server disagreement), the re-run rate is bounded instead of looping
//      with every failed request. A later real expiry (past the cooldown)
//      still triggers a fresh re-run, so long-lived pages stay covered.
// ---------------------------------------------------------------------------
const UNAUTHORIZED_RERUN_COOLDOWN_MS = 3_000;
let unauthorizedReRunCooldownMs = UNAUTHORIZED_RERUN_COOLDOWN_MS;
/** Test-only: override (or, with no arg, restore) the 401-re-run cooldown. */
export function __setUnauthorizedReRunCooldownForTest(ms?: number): void {
  unauthorizedReRunCooldownMs = ms ?? UNAUTHORIZED_RERUN_COOLDOWN_MS;
}

// Authorization is tracked per guard SCOPE, not per pathname, so intra-scope
// navigation (sibling tabs under a guarded layout) keeps the authorized
// ancestor mounted instead of dropping the whole chain to the fallback.
// The Router-level `guard` gates the whole SPA base — one fixed scope key.
const ROUTER_SCOPE = "\0router";

/**
 * Stable authorization key for the guarded rung at `upto` in a matched chain:
 * the CONCRETE path prefix up to and including that rung (each rung's `:param`/
 * `*` substituted with its accumulated capture). Two navigations within the same
 * guarded scope share the key (e.g. `/app/dash` for a guarded layout across its
 * tabs); changing a param or the route changes it (`/app/club/42` vs `/43`),
 * which re-gates that scope.
 */
function scopeKey(chain: Match[], upto: number, base: string): string {
  const params = chain[upto].params; // accumulated up to and including this rung
  const segs: string[] = [];
  for (let j = 0; j <= upto; j++) {
    for (const seg of splitSegs(chain[j].route.path)) {
      if (seg === "*") segs.push(params["*"] ?? "*");
      else if (seg.startsWith(":")) segs.push(params[seg.slice(1)] ?? seg);
      else segs.push(seg);
    }
  }
  const b = base.replace(/\/+$/g, "");
  return (b + "/" + segs.join("/")).replace(/\/{2,}/g, "/");
}

export function Router(
  props: {
    base?: string;
    routes: RouteDef[];
    notFound?: ComponentType<any>;
    /** Neutral loading UI shown while a guard is pending (required for guarded routes). */
    fallback?: ComponentType<any>;
    /** Namespace-wide guard: runs before the matched route's guard on every navigation. */
    guard?: (loc: GuardLocation) => Promise<GuardResult<any>>;
  },
): VNode<any> {
  // THE single composition point for the site's `url_path_prefix`. The
  // router's effective base is `url_path_prefix + spa.base`, composed here and
  // never by the author: everything downstream flows from this one variable —
  // `routerBase` for the module-level `navigate()`, `matchChain`/`stripBase`,
  // `ctx.base` for `<Link>`, the redirect URL-sync, and guard `scopeKey`.
  //
  // It has to be a BUILD-TIME constant threaded in, not something detected at
  // runtime: Preact's `hydrate()` does not diff element attributes on its first
  // pass, so an `<a href>` that the SSR pass and the first client render
  // disagree about is left wrong in the DOM permanently (the same constraint
  // the dynamic-layout caveat in docs/spa.md documents). Detecting the prefix
  // client-side — import map, `document.baseURI`, a `<base>` tag — could never
  // fix the prerendered markup either. So the prefix reaches the SSR pass over
  // the sidecar protocol and the browser over the shell's `data-z-prefix`, and
  // both compute the identical string here.
  //
  // With no prefix (`getUrlPathPrefix() === ""`) this is `props.base ?? ""`
  // exactly as before — byte-for-byte unchanged for a root-mounted site.
  const base = getUrlPathPrefix() + (props.base ?? "");
  // Register the base for the module-level `navigate()`: guard
  // redirects, `useNavigate()`, and direct `navigate()` calls all resolve
  // base-relative targets through it. One Router per document.
  routerBase = base;
  bindPopstate();
  const [pathname, setPathname] = useState(currentPathname());
  // The currently-authorized guard SCOPE keys (see `scopeKey`), each mapped to
  // the data its guard returned (`{ ok: true, data }`; undefined for plain
  // `true`). Key presence = authorized; the value feeds useGuardData().
  // Authorization is keyed to the scope, not the pathname: moving between
  // sibling tabs under an already-authorized guarded layout retains that
  // layout's key, so it stays rendered (mounted) instead of dropping the whole
  // chain to the fallback. But navigating OUT of a scope EVICTS its key (see the
  // guard effect's evict-on-leave prune), so re-entering it later re-gates from
  // the fallback rather than flashing stale content before the guard
  // re-validates. On SSR and the first client render this set is empty, so the
  // outermost guarded rung shows the fallback (fail-closed; unchanged shell
  // output). The guard effect re-validates on every navigation, adding each
  // scope's key as it passes.
  const [authedScopes, setAuthedScopes] = useState<Map<string, unknown>>(() => new Map());
  const authorize = (key: string, data: unknown) =>
    setAuthedScopes((prev) => {
      if (prev.has(key) && prev.get(key) === data) return prev; // same → no re-render
      const next = new Map(prev);
      next.set(key, data);
      return next;
    });
  // Two-phase hydration: Preact's hydrate() does NOT diff element
  // ATTRIBUTES on its initial pass (children ARE reconciled) — it trusts
  // the SSR markup's attributes verbatim and only attaches listeners. So
  // the very first *client* render must reproduce exactly what the server
  // rendered (skeleton ?? component); if it renders the real component
  // straight away, a dynamic route's real DOM (different attrs than its
  // skeleton) gets silently, incorrectly half-merged into the SSR'd tree —
  // children flip to the real content but stale attributes are left behind
  // and never repaired, because Preact records the (unapplied) real props
  // as if they'd already been set, so later re-renders see no attribute
  // diff (verified via the SPA Playwright e2e: hard-refreshing a dynamic
  // route left a stale `data-view="…-skeleton"` attribute on a node whose
  // children had already flipped to the real content). `hydrated` starts
  // false so the first client render matches the server; the effect below
  // flips it to true post-mount, and THAT state update is a normal
  // (non-hydrating) re-render, so Preact correctly diffs the swap to the
  // real component.
  const [hydrated, setHydrated] = useState(false);
  // Session-expiry policy plumbing (see the module comment above): bumping
  // `guardTick` re-runs the guard effect for the CURRENT pathname; the refs
  // implement in-flight suppression + the cooldown.
  const [guardTick, setGuardTick] = useState(0);
  const guardRunsInFlight = useRef(0);
  const lastUnauthorizedReRunAt = useRef(0);
  useEffect(() => {
    if (isServer()) return;
    return onUnauthorizedResponse(() => {
      if (guardRunsInFlight.current > 0) return; // a run will settle this; don't recurse
      const now = Date.now();
      if (now - lastUnauthorizedReRunAt.current < unauthorizedReRunCooldownMs) return;
      lastUnauthorizedReRunAt.current = now;
      setGuardTick((t) => t + 1); // re-run the guard pipeline at the current pathname
    });
  }, []);
  useEffect(() => {
    setHydrated(true);
    const on = () => {
      // Re-render at the new pathname. Guard authorization is per-scope (not
      // cleared here), so an already-authorized layout stays mounted while its
      // guard re-validates in the background (see the guard effect); only a
      // never-authorized scope (a new area, or a changed dynamic param) gates.
      setPathname(window.location.pathname);
    };
    listeners.add(on);
    on(); // sync in case navigation happened between render and effect
    return () => {
      listeners.delete(on);
      // Un-register the base on unmount: a later navigate()/resolveHref call
      // with NO mounted Router must resolve verbatim, not against this (now
      // stale) Router's base. Render re-registers it, so a remount is fine.
      routerBase = "";
    };
  }, []);

  // Declarative `redirect` entries resolve BEFORE rendering: `chain` is
  // the redirect TARGET's chain, so the target's view renders on the very
  // first frame (SSR included — the prerendered shell carries the target's
  // skeleton) with no throwaway frame. `effectivePathname` is what the URL
  // should read; when a redirect was taken, the sync effect below REPLACES
  // the browser URL (keeping the current query/hash and the history entry —
  // the redirecting path never lands in history).
  const { pathname: effectivePathname, chain, redirected } =
    resolveRedirects(props.routes, pathname, base);
  const leaf = chain ? chain[chain.length - 1] : null;
  useEffect(() => {
    if (isServer() || !redirected) return;
    if (window.location.pathname === effectivePathname) return;
    // Runs BEFORE the guard effect (declaration order), so guards observe the
    // final URL. Already fully resolved — navigateResolved, never navigate.
    navigateResolved(effectivePathname + window.location.search + window.location.hash, { replace: true });
  }, [pathname]);

  // Guard phase (CLIENT-ONLY). Collect the guards along the matched chain
  // (outermost layout → leaf) plus the Router-level guard; run the Router-level
  // one first, then the chain outermost→innermost, on every navigation. The
  // first non-`true` result wins (redirect short-circuits) — a guarded
  // LAYOUT thereby gates its whole subtree. A result is applied only if it's
  // still for the current (post-redirect-resolution) pathname — a navigation
  // that fired while a guard was in flight cancels the stale run (both via
  // `cancelled` and the live `window.location.pathname` recheck), so a
  // resolved-for-a-stale-path verdict is ignored. A thrown/rejected guard =
  // NOT authorized: stay on the fallback and report it; never paint the
  // guarded subtree.
  // The guarded rungs of the matched chain, each with its stable scope key.
  const guardedRungs = chain
    ? chain.flatMap((n, i) =>
        n.route.guard ? [{ depth: i, key: scopeKey(chain, i, base), guard: n.route.guard }] : [])
    : [];
  const isGuarded = !!props.guard || guardedRungs.length > 0;
  useEffect(() => {
    if (isServer()) return;
    // Evict-on-leave (runs on EVERY navigation, guarded route or not): drop any
    // authorized scope key that is NOT a guarded scope of the newly-matched
    // chain. So navigating OUT of a guarded scope forgets its authorization —
    // re-entering it later re-gates from the fallback (fail-closed) instead of
    // optimistically flashing its content before the guard re-validates. Keys
    // for scopes still in the chain (sibling-tab nav) are retained, so the
    // keep-mounted win is unchanged. Must run before the `!isGuarded` return so
    // leaving a guarded area for an UNGUARDED route still evicts.
    const liveScopes = new Set<string>();
    if (props.guard) liveScopes.add(ROUTER_SCOPE);
    for (const rung of guardedRungs) liveScopes.add(rung.key);
    setAuthedScopes((prev) => {
      let stale = false;
      for (const k of prev.keys()) if (!liveScopes.has(k)) { stale = true; break; }
      if (!stale) return prev; // no change → same reference → no re-render
      const next = new Map<string, unknown>();
      for (const [k, v] of prev) if (liveScopes.has(k)) next.set(k, v);
      return next;
    });

    if (!isGuarded) return;
    let cancelled = false;
    const loc: GuardLocation = { pathname: effectivePathname, params: leaf?.params ?? {} };
    // A result is applied only while it's still for the current pathname — a
    // navigation that fired mid-flight cancels the stale run (via `cancelled`
    // and the live `window.location.pathname` recheck), so a stale-path verdict
    // is ignored and there's no setState-after-unmount. A thrown/never-resolving
    // guard = NOT authorized: its scope stays gated (fail-closed). Run the
    // Router-level guard first, then the chain's guards outermost→innermost,
    // authorizing each scope as it passes; the first non-`true` redirects.
    const current = () => !cancelled && window.location.pathname === effectivePathname;
    // The in-flight counter (session-expiry policy): while ANY guard run is
    // pending, a 401-triggered re-run request is ignored — so a guard whose own
    // probe 401s (through apiFetch) can't recurse into a second run. A counter
    // (not a boolean) because a cancelled run's guards may still be settling
    // when the next run starts.
    guardRunsInFlight.current++;
    (async () => {
      try {
        if (props.guard) {
          const res = parseGuardResult(await props.guard(loc));
          if (!current()) return;
          // Replace, not push: the denied gated URL must not stay a reachable
          // history entry (matching the declarative-redirect semantics at the
          // `redirected` sync effect above). A PUSH here traps Back — popping to
          // the gated path re-runs the guard and re-redirects, bouncing the user
          // between the gated route and the login target forever (AUDF-007).
          if (!res.authorized) { navigate(res.redirect, { replace: true }); return; }
          authorize(ROUTER_SCOPE, res.data);
        }
        for (const rung of guardedRungs) {
          const res = parseGuardResult(await rung.guard(loc));
          if (!current()) return;
          // Replace, not push (see the Router-level guard above): AUDF-007.
          if (!res.authorized) { navigate(res.redirect, { replace: true }); return; }
          authorize(rung.key, res.data);
        }
      } catch (err) {
        if (cancelled) return;
        host.reportError(err);
      } finally {
        guardRunsInFlight.current--;
      }
    })();
    return () => { cancelled = true; };
    // Keyed on the EFFECTIVE pathname (a redirect's URL sync re-renders at the
    // same effective path, so guards run once per rendered route, not once per
    // pre-redirect URL spelling) + `guardTick` (the session-expiry policy's
    // 401-triggered re-run at the current location).
  }, [effectivePathname, guardTick]);

  // Lazy-route loading (CLIENT-ONLY). When the matched leaf is a lazy route
  // whose chunk hasn't resolved, load it post-hydration; the resolved module is
  // cached on the marker so it loads once app-wide. On resolve, bump a tick to
  // flip the skeleton to the real component — a normal non-hydrating re-render,
  // the same shape as the dynamic-route flip, composing with two-phase +
  // guard-scope gating. A rejected loader is reported and leaves the skeleton
  // in place (never crashes the app; never retries into a loop).
  const [, setLazyTick] = useState(0);
  const leafLazy = leaf ? lazyStateOf(leaf.route.component) : undefined;
  if (leafLazy && leaf && !leaf.route.skeleton && !warnedLazyNoSkeleton.has(leaf.route.path)) {
    warnedLazyNoSkeleton.add(leaf.route.path);
    console.warn(
      `zigapagos: lazy route ${JSON.stringify(leaf.route.path)} has no \`skeleton\` — ` +
        "nothing renders until its chunk loads. Add a skeleton for a proper loading state.",
    );
  }
  // What THIS render actually painted. `leafLazy.comp` is no longer set only
  // from inside the effect below: a hover/viewport `prefetch` resolves out of
  // band (issue #128), and Preact flushes `useEffect` a whole frame after the
  // render, so a chunk can land in between. Capturing the render's own view of
  // it is what lets the effect tell "already resolved when we rendered" from
  // "resolved behind our back" — see the `leafLazy.comp` branch below.
  const renderedLazyComp = leafLazy?.comp;
  useEffect(() => {
    if (isServer() || !leafLazy || leafLazy.failed) return;
    if (leafLazy.comp) {
      // Resolved between the render and this effect (a prefetch's `.then`).
      // The render still painted the skeleton and nothing else will ever flip
      // it — the load is finished, so no further `.then` is coming. Tick.
      if (!renderedLazyComp) setLazyTick((t) => t + 1);
      return;
    }
    let cancelled = false;
    // `startLazyLoad`, not `leafLazy.loader()` directly: reuses an in-flight
    // (or already-settled) promise a hover/viewport `prefetch()` may have
    // already started for this same route, so the two never double-fetch
    // the chunk (issue #128).
    startLazyLoad(leafLazy).then((mod) => {
      if (cancelled) return;
      leafLazy.comp = mod.default;
      setLazyTick((t) => t + 1);
    }).catch((err) => {
      if (cancelled) return;
      leafLazy.failed = true; // stay on the skeleton; don't retry-loop
      host.reportError(err);
    });
    return () => { cancelled = true; };
  }, [effectivePathname]);

  // Issue #128: hover/viewport chunk prefetch. Closes over `props.routes` and
  // `base` (the SAME effective base every other resolution in this component
  // uses — see the comment above `const base = …`). Defined with `useCallback`
  // so `<Link>`'s effect deps (viewport mode) get a stable reference across
  // re-renders instead of re-observing on every render.
  const prefetch = useCallback((resolvedHref: string) => {
    if (isServer() || !prefetchAllowed()) return;
    // Strip query/hash — route matching is path-only, exactly like
    // `currentPathname()`'s contract elsewhere in this file.
    const pathname = resolvedHref.replace(/[?#].*$/, "");
    // `resolveRedirects`, not `matchChain` directly: a `<Link>` to a
    // `redirect` alias must prefetch the TARGET's chunk (what a real
    // navigation actually loads), exactly like the render path above does.
    const { chain } = resolveRedirects(props.routes, pathname, base);
    if (!chain) return;
    const leafNode = chain[chain.length - 1];
    const lz = lazyStateOf(leafNode.route.component);
    if (!lz || lz.comp || lz.failed) return;
    const p = startLazyLoad(lz);
    p.then((mod) => {
      // Primes the real navigation: a later render reads `comp` and shows the
      // real component with no skeleton frame at all. When the navigation
      // render already happened and read `comp` as unset, the lazy-load effect
      // above notices and ticks — that is the ONLY thing that repaints, so
      // this assignment is never the last word on its own.
      lz.comp = mod.default;
    }).catch(() => {
      // A prefetch-time failure (offline hover, flaky network) must NEVER
      // set `failed` — that would permanently strand the route on its
      // skeleton (`failed` short-circuits the real load effect above,
      // which never retries). Clear the cached promise instead, so the
      // real navigation's `startLazyLoad` gets a fresh `loader()` call
      // (and thus its own error-report-on-reject path) rather than
      // inheriting this rejection silently. Deliberately no
      // `host.reportError` here — a hover that never becomes a
      // navigation is not a user-facing failure.
      // Identity-checked: two prefetches share one promise, so both
      // catches run back to back. Without this a second catch could
      // clear a promise a THIRD prefetch had already installed, orphaning
      // that in-flight load into a duplicate fetch later.
      if (lz.promise === p) lz.promise = undefined;
    });
  }, [props.routes, base]);

  // ctx.pathname is the EFFECTIVE pathname (the rendered route), so
  // useLocation() reports the redirect TARGET during the pre-sync frame too.
  const ctx: RouterCtx = { base, pathname: effectivePathname, params: leaf?.params ?? {}, navigate, prefetch };
  let view: VNode<any>;
  if (!chain) {
    view = h(props.notFound ?? DefaultNotFound, {});
  } else {
    // Walk the chain top-down for the FIRST guarded scope not yet authorized.
    // Rungs ABOVE it render normally (authorized ancestor layouts stay mounted);
    // at its depth the neutral fallback renders in place of it + its subtree. On
    // SSR and the first client render `authedScopes` is empty, so the outermost
    // guarded rung shows the fallback (fail-closed; unchanged shell output). The
    // Router-level guard, if any, gates the whole chain (depth 0) until authorized.
    let gateDepth = -1;
    if (props.guard && !authedScopes.has(ROUTER_SCOPE)) {
      gateDepth = 0;
    } else {
      for (const rung of guardedRungs) {
        if (!authedScopes.has(rung.key)) { gateDepth = rung.depth; break; }
      }
    }
    let fallback: VNode<any> | null = null;
    if (gateDepth !== -1) {
      if (props.fallback) {
        fallback = h(props.fallback, {});
      } else {
        // FAIL CLOSED: a guarded route with no `fallback` must NOT fall through
        // to the layout/leaf (that would bake gated content into the shell and
        // flash it). Render a neutral empty placeholder; warn once per leaf.
        const key = leaf!.route.path;
        if (!warnedNoFallback.has(key)) {
          warnedNoFallback.add(key);
          console.warn(
            `zigapagos: guarded route ${JSON.stringify(key)} has no Router \`fallback\` — ` +
              "rendering an empty placeholder while unauthorized. Supply a `fallback` for a proper loading state.",
          );
        }
        fallback = h("div", { "data-z-guard-pending": "" });
      }
    }
    // depth → the guard data of each AUTHORIZED guarded rung, threaded down so
    // renderChainNode can provide it (useGuardData) at exactly its rung.
    let guardDataByDepth: ReadonlyMap<number, unknown> = EMPTY_GUARD_DATA;
    if (guardedRungs.length) {
      const m = new Map<number, unknown>();
      for (const rung of guardedRungs) {
        if (authedScopes.has(rung.key)) m.set(rung.depth, authedScopes.get(rung.key));
      }
      guardDataByDepth = m;
    }
    // Unguarded (gateDepth -1, fallback null) reproduces the flat-route / nested
    // behavior exactly; a length-1 chain is the pre-nesting flat-route path.
    view = renderChainNode(chain, 0, hydrated, gateDepth, fallback, guardDataByDepth);
  }
  // A Router-level guard's data is the OUTERMOST provider — any guarded rung
  // nests inside it and shadows it (nearest guard wins).
  if (props.guard) {
    view = h(GuardDataContext.Provider, { value: authedScopes.get(ROUTER_SCOPE) }, view);
  }
  return h(Ctx.Provider, { value: ctx }, view);
}

// Client-tier warn-once keys for `<Link>` rendered with no router context.
const warnedNoRouterLink = new Set<string>();

/**
 * A `<Link>` was rendered with no enclosing `<Router>`. Loud on the server,
 * survivable on the client — deliberately asymmetric:
 *
 * - **SSR (the build's prerender pass) throws.** The prerendered shell is the
 *   artifact that actually ships the dead href, and it is produced by
 *   `renderToString` in `runtime/sidecar/render.ts`. A throw there propagates
 *   through the sidecar's catch as `{error, stack}`, `src/islands/sidecar.zig`
 *   turns it into a structured `RenderError`, and `src/spa.zig` fatals with the
 *   JS message and a source-mapped stack attributed to the `.spa.tsx` and
 *   route. There is no dev/release distinction to make: a shell with dead nav
 *   is defective in both, and the SPA prerender deliberately runs before the
 *   page pass, so the fatal is minimally destructive. Warning instead was tried
 *   by this codebase's own history and failed — the marketing site shipped a
 *   demo whose every nav link was dead, through a green build.
 * - **The client warns once per href and renders the anchor anyway.** Throwing
 *   during hydration would unmount the whole subtree, which is strictly worse
 *   than one link that does a full page load. This tier is defense in depth
 *   (shells built by an older zigapagos, client-only render paths); it matches
 *   the existing `warnedRedirects`/`warnedNoFallback` precedent — a module-level
 *   Set and an unconditional `console.warn`, since no dev-vs-release runtime
 *   split exists here and inventing one for a single warning is not worth it.
 */
function noRouterLink(href: string): void {
  if (isServer()) {
    throw new Error(
      `zigapagos: <Link href="${href}"> rendered outside a <Router>. Without router context the ` +
        "href cannot resolve against the SPA base and the anchor never soft-navigates — the " +
        "prerendered shell would ship a dead link. Put app chrome in a layout route inside the " +
        "Router, or use a plain <a> for a non-router anchor.",
    );
  }
  if (warnedNoRouterLink.has(href)) return;
  warnedNoRouterLink.add(href);
  console.warn(
    `zigapagos: <Link href="${href}"> rendered outside a <Router> — it degrades to a plain ` +
      "anchor (unresolved href, no soft navigation). Move it inside the Router or use <a>.",
  );
}

/**
 * An in-SPA anchor. A root-relative `href` is ROUTER-INTERNAL: it resolves
 * against the Router's `base` (`<Link href="/booking">` under base
 * `/app` renders `<a href="/app/booking">`) and clicks soft-navigate. An
 * absolute/protocol-relative URL renders a plain anchor with the href
 * untouched — the escape hatch for cross-SPA/external targets (as is any
 * plain `<a>`).
 *
 * **Outside a Router there is no context, so nothing can be resolved.** That is
 * never intentional — `Link` is router-internal, and `<a>` is the escape hatch
 * — so it is a hard error on the SERVER (the build's SSR pass, where the
 * defective shell is actually produced) and a warn-once on the CLIENT (throwing
 * during hydration would kill the whole subtree, which is worse than one
 * degraded link). See the two branches below.
 *
 * A caller-supplied `onClick` is CHAINED, never substituted: it runs first
 * (the close-the-nav-drawer pattern — `<Link href="/x" onClick={() => setOpen(false)}>`)
 * and the router's soft-navigation runs after it, unless the handler cancelled
 * the click with `preventDefault()`.
 */
export function Link(
  props: {
    href: string;
    children?: any;
    onClick?: (e: any) => void;
    /**
     * When to prefetch the target's lazy chunk (issue #128), default
     * `"hover"`. `"viewport"` prefetches once the link scrolls into view
     * instead; `false` disables prefetching for this Link entirely.
     * Destructured out below — it MUST NOT reach the rendered `<a>` (a
     * `prefetch` DOM attribute would churn the SSR shell's bytes, which
     * every strict-CSP hash and the "byte-identical shells" guarantee in
     * docs/spa.md depend on staying stable).
     */
    prefetch?: "hover" | "viewport" | false;
    [k: string]: any;
  },
): VNode<any> {
  const {
    href, children, onClick: callerOnClick,
    prefetch: prefetchMode = "hover",
    onMouseEnter: callerOnMouseEnter, onFocus: callerOnFocus, onTouchStart: callerOnTouchStart,
    ...rest
  } = props;
  const ctx = useContext(Ctx);
  if (!ctx) noRouterLink(href);
  const internal = !!ctx && href.startsWith("/") && !isExternalHref(href);
  const resolved = internal ? resolveHref(href, ctx!.base) : href;
  const onClick = (e: any) => {
    // Chained, not spread over: a caller's handler that replaced this one would
    // drop the preventDefault() below, turning every such Link into a REAL
    // navigation — full document reload, all SPA state lost.
    if (callerOnClick) callerOnClick(e);
    if (!internal) return;
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    navigateResolved(resolved); // already base-resolved — never resolve twice
  };
  // No context (outside a Router) or a non-internal target (external/bare
  // relative): prefetch is a no-op either way — `ctx.prefetch` itself
  // no-ops on a non-matching/non-lazy target, but skipping the call here
  // avoids touching `ctx` at all when it may be null.
  const doPrefetch = () => { if (internal) ctx!.prefetch(resolved); };
  // Hover/focus/touch prefetch — chained AFTER any caller-supplied handler
  // of the same name, same pattern as `onClick` above, so a caller's own
  // `onMouseEnter` keeps firing. Only wired when `prefetchMode === "hover"`
  // (the default); `"viewport"` and `false` leave these exactly as the
  // caller passed them (possibly undefined).
  const onMouseEnter = prefetchMode === "hover"
    ? (e: any) => { if (callerOnMouseEnter) callerOnMouseEnter(e); doPrefetch(); }
    : callerOnMouseEnter;
  const onFocus = prefetchMode === "hover"
    ? (e: any) => { if (callerOnFocus) callerOnFocus(e); doPrefetch(); }
    : callerOnFocus;
  const onTouchStart = prefetchMode === "hover"
    ? (e: any) => { if (callerOnTouchStart) callerOnTouchStart(e); doPrefetch(); }
    : callerOnTouchStart;

  // Viewport-mode prefetch: observe the rendered <a>, prefetch once on first
  // intersection, then stop observing (a link that's been visible has had
  // its one shot; re-scrolling it into view should not re-fire). Guarded on
  // `IntersectionObserver` existing (SSR has no DOM at all — `useEffect`
  // itself never runs there — and this also degrades harmlessly on an
  // ancient/non-browser client).
  const anchorRef = useRef<HTMLAnchorElement | null>(null);
  useEffect(() => {
    if (prefetchMode !== "viewport") return;
    if (typeof IntersectionObserver === "undefined") return;
    const el = anchorRef.current;
    if (!el) return;
    const obs = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          doPrefetch();
          obs.disconnect();
          break;
        }
      }
    });
    obs.observe(el);
    return () => obs.disconnect();
  }, [prefetchMode, resolved]);
  // `onClick`/`ref` LAST so `rest` can never clobber the router's handlers.
  // (`ref` can't be in `rest` anyway — `h()` strips it into the vnode before a
  // component ever sees its props — which is also why there is nothing to
  // chain here: a caller's `ref` on a `<Link>` never reaches this function.)
  return h(
    "a",
    { href: resolved, ...rest, onClick, onMouseEnter, onFocus, onTouchStart, ref: anchorRef },
    children,
  );
}

export function useParams<T = Record<string, string>>(): T {
  return (useContext(Ctx)?.params ?? {}) as T;
}

/**
 * `{ pathname, search }` for the current route. `pathname` prefers the
 * Router's own matched-chain pathname (set from `currentPathname()` at mount
 * and on every navigation); outside a Router it falls back to
 * `currentPathname()` directly. `search` always goes through `currentSearch()`
 * — the single hardened SSR-vs-client read ssr-env.ts centralizes (client:
 * `window.location.search`; server: parsed from the SSR pathname's query if
 * the build threaded one, else ""). Not reactive to a query-only navigation;
 * use `useSearchParams()` for that.
 */
export function useLocation(): { pathname: string; search: string } {
  const ctx = useContext(Ctx);
  const pathname = ctx?.pathname ?? currentPathname();
  const search = currentSearch();
  return { pathname, search };
}

export function useNavigate(): (to: string, opts?: { replace?: boolean; external?: boolean }) => void {
  return navigate;
}

export type SearchParamsInit = URLSearchParams | Record<string, string> | string;
export type SetSearchParams = (next: SearchParamsInit, opts?: { replace?: boolean }) => void;

function toSearchString(next: SearchParamsInit): string {
  const sp = next instanceof URLSearchParams ? next
    : typeof next === "string" ? new URLSearchParams(next.replace(/^\?/, ""))
    : new URLSearchParams(next);
  const s = sp.toString();
  return s ? "?" + s : "";
}

/**
 * React-Router-shaped parsed, REACTIVE search params. Returns
 * `[URLSearchParams, setSearchParams]`. The getter reflects the live
 * `window.location.search` and re-renders on navigation (query-only nav
 * included) via the shared location subscription — so unlike
 * `useLocation().search` (a raw, non-reactive string) it updates when only the
 * query changes. The setter navigates to the SAME pathname (and hash) with the
 * new query (default push; `{ replace }` for replaceState). Because the
 * pathname is unchanged, the push does NOT scroll to the top — a filter box
 * that sets a param on every keystroke keeps the viewport (and the focused
 * input) exactly where it is. Values are decoded by URLSearchParams.
 * SSR-safe: the getter reads through ssr-env's hardened
 * `currentSearch()`, so on the server the params come from the SSR pathname's
 * query when the build threaded one, else empty.
 */
export function useSearchParams(): [URLSearchParams, SetSearchParams] {
  // Preact's useSyncExternalStore is (subscribe, getSnapshot); `currentSearch`
  // itself returns the SSR value under isServer(), so no getServerSnapshot arg.
  const search = useSyncExternalStore(subscribeLocation, currentSearch);
  const params = useMemo(() => new URLSearchParams(search), [search]);
  const setSearchParams = useCallback<SetSearchParams>((next, opts) => {
    if (isServer()) return;
    // window.location.pathname is already the FULL (base-prefixed) path, so
    // this must bypass base resolution (navigateResolved, not navigate).
    navigateResolved(window.location.pathname + toSearchString(next) + window.location.hash, opts);
  }, []);
  return [params, setSearchParams];
}

/** The optional client-only lifecycle surface of a `.spa.tsx` module.
 * The shell bootstrap passes the whole module namespace, so a missing
 * `clientInit` export is simply `undefined` — no ESM link error. */
export type SpaModuleHooks = {
  clientInit?: () => void;
  /** The module's `export const spa`; mountSpa reads its client-relevant fields (viewTransitions). */
  spa?: { viewTransitions?: boolean };
};

/** Client boot: hydrate the SPA App into its prerendered shell root.
 *
 * Before the first render it:
 *   1. seeds the flags store from the shell's `data-z-flags` snapshot,
 *      so `useFlag`'s first render is the baked default —
 *      never false-while-loading;
 *   2. calls the module's optional client-only `clientInit()` hook —
 *      module-load side effects (error relays, persisted-theme
 *      application, …) belong there instead of at the module top level,
 *      which also executes under build-time SSR and would need a
 *      `typeof document` guard per init function.
 *
 * The SSR sidecar never runs this path (it seeds its own flag store from
 * `spa.flags` directly and never calls `clientInit`). A throwing
 * `clientInit` is reported loudly but does not abort hydration — a broken
 * init must not dead-page the app. */
export function mountSpa(
  App: ComponentType<any>,
  selector = "#z-spa-root",
  mod?: SpaModuleHooks,
): void {
  if (typeof document === "undefined") return;
  const root = document.querySelector(selector);
  // The site's `url_path_prefix`, baked into the shell by `src/spa.zig`. Read
  // FIRST — before `clientInit` (which may `navigate()`) and before the first
  // render — because `Router` composes it into its base and the first client
  // render must reproduce the SSR'd hrefs exactly (hydrate() does not repair
  // attributes). The attribute rides on the hydration ROOT precisely because
  // hydration renders INTO that element, so its own attributes are never
  // diffed; and putting it there leaves the inline boot script byte-unchanged,
  // so a strict-CSP `script-src` hash does not churn. Absent (unprefixed site)
  // → "", which makes the composition a no-op.
  setUrlPathPrefix(root?.getAttribute("data-z-prefix") ?? "");
  seedFlagsFromShell();
  // Applied unconditionally (explicit `false` on absence) BEFORE clientInit,
  // which may itself call `navigate()` — so a `spa.viewTransitions: true`
  // module's very first navigation is already wrapped, and a subsequent
  // mountSpa() call (or the two-arg back-compat call) never inherits a
  // PREVIOUS module's setting.
  setViewTransitions(mod?.spa?.viewTransitions === true);
  if (typeof mod?.clientInit === "function") {
    try {
      mod.clientInit();
    } catch (err) {
      host.reportError(err);
    }
  }
  if (root) hydrate(h(App, {}), root as any);
}
