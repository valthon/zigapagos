import { expect, test, describe, afterEach } from "bun:test";
import { matchRoute, matchChain, flattenLeafPaths, substituteRouteParams, describeRoutes, resolveHref, type RouteDef } from "./router.ts";

const C = () => null; // stand-in component
const routes: RouteDef[] = [
  { path: "/", component: C },
  { path: "/booking", component: C },
  { path: "/club/:id", component: C, skeleton: C },
  { path: "/admin/users", component: C },
  { path: "/admin/*", component: C },
];

// --- Base-relative navigation ----------------------------------------------
// Router-internal paths (`<Link href>`, `navigate(to)`, guard `{ redirect }`
// targets) resolve RELATIVE to `spa.base`. Absolute URLs (a scheme or a
// protocol-relative `//host`) are external and never resolved; a bare relative
// path is left for the browser to resolve.
describe("resolveHref (base-relative resolution)", () => {
  test("resolves a router-internal path under the base", () => {
    expect(resolveHref("/booking", "/app")).toBe("/app/booking");
    expect(resolveHref("/club/42", "/app")).toBe("/app/club/42");
  });
  test("the SPA root resolves to the base with a trailing slash", () => {
    expect(resolveHref("/", "/app")).toBe("/app/");
  });
  test("a root-mounted base ('' or '/') resolves to the path unchanged", () => {
    expect(resolveHref("/booking", "")).toBe("/booking");
    expect(resolveHref("/booking", "/")).toBe("/booking");
    expect(resolveHref("/", "")).toBe("/");
    expect(resolveHref("/", "/")).toBe("/");
  });
  test("a trailing-slash base does not double the slash", () => {
    expect(resolveHref("/booking", "/app/")).toBe("/app/booking");
  });
  test("query and hash ride along untouched", () => {
    expect(resolveHref("/login?next=%2Fx#top", "/app")).toBe("/app/login?next=%2Fx#top");
  });
  test("an absolute or protocol-relative URL is external: returned unchanged", () => {
    expect(resolveHref("https://example.com/x", "/app")).toBe("https://example.com/x");
    expect(resolveHref("mailto:x@example.com", "/app")).toBe("mailto:x@example.com");
    expect(resolveHref("//cdn.example.com/x", "/app")).toBe("//cdn.example.com/x");
  });
  test("an already-base-prefixed path is NOT deduped — paths are ALWAYS base-relative", () => {
    // Migration footgun pinned on purpose: `/app/booking` under base `/app`
    // now means the in-app path `/app/booking`, i.e. `/app/app/booking`.
    expect(resolveHref("/app/booking", "/app")).toBe("/app/app/booking");
  });
  test("a bare relative path is returned unchanged (browser-relative)", () => {
    expect(resolveHref("settings", "/app")).toBe("settings");
    expect(resolveHref("?q=1", "/app")).toBe("?q=1");
    expect(resolveHref("#top", "/app")).toBe("#top");
  });
});

describe("matchRoute", () => {
  test("matches the index route", () => {
    expect(matchRoute(routes, "/app/", "/app")?.route.path).toBe("/");
    expect(matchRoute(routes, "/app", "/app")?.route.path).toBe("/");
  });
  test("matches a static route under base", () => {
    expect(matchRoute(routes, "/app/booking", "/app")?.route.path).toBe("/booking");
  });
  test("captures a :param", () => {
    const m = matchRoute(routes, "/app/club/42", "/app");
    expect(m?.route.path).toBe("/club/:id");
    expect(m?.params.id).toBe("42");
  });
  test("decodes an encoded :param", () => {
    expect(matchRoute(routes, "/app/club/a%20b", "/app")?.params.id).toBe("a b");
  });
  // A malformed percent-escape must NEVER throw out of matching: matchInto runs
  // inside the render path (Router -> resolveRedirects -> matchChain), so a
  // URIError there kills hydrate() and every later navigation on that path —
  // the SPA freezes on its prerendered skeleton for good.
  test("a malformed percent-escape in a :param falls back to the raw segment (never throws)", () => {
    expect(() => matchRoute(routes, "/app/club/100%", "/app")).not.toThrow();
    expect(matchRoute(routes, "/app/club/100%", "/app")?.params.id).toBe("100%");
    expect(matchRoute(routes, "/app/club/a%zz", "/app")?.params.id).toBe("a%zz");
    // A lone high surrogate is well-formed URI syntax but not decodable either.
    expect(matchRoute(routes, "/app/club/%ED%A0%80", "/app")?.params.id).toBe("%ED%A0%80");
  });
  test("catch-all captures the rest into '*'", () => {
    const m = matchRoute(routes, "/app/admin/roles/edit", "/app");
    expect(m?.route.path).toBe("/admin/*");
    expect(m?.params["*"]).toBe("roles/edit");
  });
  // The `*` capture is decoded exactly like a `:param` — the two route shapes
  // must agree on the same URL.
  test("catch-all decodes each captured segment, like :param", () => {
    expect(matchRoute(routes, "/app/admin/my%20doc.pdf", "/app")?.params["*"]).toBe("my doc.pdf");
    expect(matchRoute(routes, "/app/admin/a%20b/c%20d", "/app")?.params["*"]).toBe("a b/c d");
  });
  test("a malformed escape degrades only its own catch-all segment (never throws)", () => {
    expect(() => matchRoute(routes, "/app/admin/100%/a%20b", "/app")).not.toThrow();
    expect(matchRoute(routes, "/app/admin/100%/a%20b", "/app")?.params["*"]).toBe("100%/a b");
  });
  test("prefers an exact static route over the catch-all (array order)", () => {
    expect(matchRoute(routes, "/app/admin/users", "/app")?.route.path).toBe("/admin/users");
  });
  test("returns null when nothing matches", () => {
    expect(matchRoute(routes, "/app/nope/deep", "/app")).toBeNull();
  });
  test("works with an empty base", () => {
    expect(matchRoute(routes, "/booking", "")?.route.path).toBe("/booking");
  });
});

const nestedRoutes: RouteDef[] = [
  { path: "/", component: C },
  {
    path: "/dash", component: C, children: [
      { path: "/", component: C },          // index
      { path: "/overview", component: C },
      { path: "/team/:id", component: C },
      { path: "/*", component: C },         // catch-all child
    ],
  },
  {
    path: "/org/:org", component: C, children: [
      { path: "/repo/:repo", component: C },
    ],
  },
];

describe("matchChain (nested routes)", () => {
  test("returns the outermost→leaf chain for a nested match", () => {
    const c = matchChain(nestedRoutes, "/app/dash/overview", "/app");
    expect(c?.map((n) => n.route.path)).toEqual(["/dash", "/overview"]);
  });
  test("accumulates params down the chain (layout param + child param)", () => {
    const c = matchChain(nestedRoutes, "/app/org/acme/repo/zigapagos", "/app");
    expect(c?.map((n) => n.route.path)).toEqual(["/org/:org", "/repo/:repo"]);
    expect(c?.[c.length - 1].params).toEqual({ org: "acme", repo: "zigapagos" });
  });
  test("an index child ('/') matches when only the layout path is present", () => {
    const c = matchChain(nestedRoutes, "/app/dash", "/app");
    expect(c?.map((n) => n.route.path)).toEqual(["/dash", "/"]);
  });
  test("first-match at each level: a concrete child beats the catch-all", () => {
    const c = matchChain(nestedRoutes, "/app/dash/team/42", "/app");
    expect(c?.map((n) => n.route.path)).toEqual(["/dash", "/team/:id"]);
    expect(c?.[1].params.id).toBe("42");
  });
  test("a catch-all child captures the leftover under the layout", () => {
    const c = matchChain(nestedRoutes, "/app/dash/reports/q3/deep", "/app");
    expect(c?.map((n) => n.route.path)).toEqual(["/dash", "/*"]);
    expect(c?.[1].params["*"]).toBe("reports/q3/deep");
  });
  test("a flat route still yields a length-1 chain (back-compat)", () => {
    const c = matchChain(nestedRoutes, "/app/", "/app");
    expect(c?.map((n) => n.route.path)).toEqual(["/"]);
  });
  test("matchRoute returns the LEAF of the chain with accumulated params", () => {
    const m = matchRoute(nestedRoutes, "/app/org/acme/repo/zigapagos", "/app");
    expect(m?.route.path).toBe("/repo/:repo");
    expect(m?.params).toEqual({ org: "acme", repo: "zigapagos" });
  });
  test("returns null when a nested path has leftover segments nothing places", () => {
    expect(matchChain(nestedRoutes, "/app/org/acme/nope/deep", "/app")).toBeNull();
  });
});

describe("flattenLeafPaths (describe flattening)", () => {
  const Sk = () => null;
  test("flattens a nested tree to leaf full-paths, layouts contribute no entry", () => {
    const flat = flattenLeafPaths([
      { path: "/", component: C },
      {
        path: "/dash", component: C, children: [
          { path: "/overview", component: C, skeleton: Sk },
          { path: "/settings", component: C },
        ],
      },
    ]);
    expect(flat).toEqual([
      { path: "/", dynamic: false, hasSkeleton: false },
      { path: "/dash/overview", dynamic: false, hasSkeleton: true },
      { path: "/dash/settings", dynamic: false, hasSkeleton: false },
    ]);
  });
  test("a dynamic-nested leaf ('/club/:id/details') flattens to a dynamic full-path", () => {
    const flat = flattenLeafPaths([
      { path: "/club/:id", component: C, children: [{ path: "/details", component: C }] },
    ]);
    expect(flat).toEqual([{ path: "/club/:id/details", dynamic: true, hasSkeleton: false }]);
  });
  test("an index child ('/') flattens to the layout's own path", () => {
    const flat = flattenLeafPaths([
      { path: "/dash", component: C, children: [{ path: "/", component: C }] },
    ]);
    expect(flat).toEqual([{ path: "/dash", dynamic: false, hasSkeleton: false }]);
  });
  test("a flat array is unchanged (back-compat)", () => {
    const flat = flattenLeafPaths([
      { path: "/", component: C },
      { path: "/booking", component: C },
      { path: "/club/:id", component: C, skeleton: Sk },
    ]);
    expect(flat).toEqual([
      { path: "/", dynamic: false, hasSkeleton: false },
      { path: "/booking", dynamic: false, hasSkeleton: false },
      { path: "/club/:id", dynamic: true, hasSkeleton: true },
    ]);
  });
});

import {
  Router, Link, navigate, useParams, useLocation, mountSpa, Outlet, useSearchParams, lazy,
  useGuardData, setViewTransitions, setScrollRestoration,
  __resetScrollForTest, __scrollStateForTest, __scrollBookkeepingForTest,
  __scrollRestoreShouldRetry, __shouldRestoreOnPop, __navSeqForTest,
  __setRouterBaseForTest, __prefetchAllowedForTest,
  type GuardResult,
} from "./router.ts";
import { h, type ComponentType } from "./core.ts";
import { useEffect } from "./core.ts";
import { ssrIsland, renderIsland, click, flush } from "@z/runtime/testing";
import { setLocationPathname } from "@z/runtime/testing/parity";
import { setSsrPathname, setUrlPathPrefix, getUrlPathPrefix } from "@z/runtime/ssr-env";

const Home = () =>
  h("div", { "data-view": "home" },
    "home",
    // Router-internal hrefs are base-relative — "/booking", not "/app/booking".
    h(Link, { href: "/booking", "data-testid": "go" }, "booking"),
    // The cross-SPA/external escape hatch is an absolute URL (or a plain <a>).
    h(Link, { href: "http://localhost/other", "data-testid": "go-out" }, "external"));
const Booking = () => h("div", { "data-view": "booking" }, "booking");
const ClubSkeleton = () => h("div", { "data-view": "club-skeleton" }, "loading club…");
const ClubDetail = () => {
  const { id } = useParams<{ id: string }>();
  return h("div", { "data-view": "club", "data-id": id }, "club " + id);
};
const appRoutes = [
  { path: "/", component: Home },
  { path: "/booking", component: Booking },
  { path: "/club/:id", component: ClubDetail, skeleton: ClubSkeleton },
];
const App = () =>
  h(Router, { base: "/app", routes: appRoutes, notFound: () => h("div", { "data-view": "nf" }, "nf") });

// Links carrying the CALLER's own onClick (the close-the-nav-drawer pattern):
// one that just runs a side effect, one that cancels the navigation outright.
let handlerClicks = 0;
const HandlerHome = () =>
  h("div", { "data-view": "home" },
    "home",
    h(Link, { href: "/booking", "data-testid": "go-handler", onClick: () => { handlerClicks++; } }, "booking"),
    h(Link, { href: "/booking", "data-testid": "go-cancel", onClick: (e: any) => e.preventDefault() }, "cancel"));
const HandlerApp = () =>
  h(Router, { base: "/app", routes: [{ path: "/", component: HandlerHome }, { path: "/booking", component: Booking }] });

describe("Router SSR", () => {
  test("SSRs the skeleton for a dynamic route pattern", () => {
    const html = ssrIsland(App, {}, { pathname: "/app/club/_" });
    expect(html).toContain('data-view="club-skeleton"');
    expect(html).not.toContain('data-view="club"');
  });
  test("SSRs the matching static route", () => {
    expect(ssrIsland(App, {}, { pathname: "/app/booking" })).toContain('data-view="booking"');
  });
  test("SSRs notFound for an unmatched path", () => {
    expect(ssrIsland(App, {}, { pathname: "/app/zzz/qq" })).toContain('data-view="nf"');
  });
  test("skeleton: false renders the COMPONENT on the SSR pass (the opt-out is not a crash)", () => {
    // `false ?? component` would yield `false` (?? only falls through on
    // null/undefined), so the router must explicitly treat `false` as
    // "no skeleton" and render the component itself on both passes.
    const Stable = () => h("div", { "data-view": "stable" }, "stable");
    const routes = [{ path: "/stable/:id", component: Stable, skeleton: false as const }];
    const A = () => h(Router, { base: "/app", routes });
    const html = ssrIsland(A, {}, { pathname: "/app/stable/_" });
    expect(html).toContain('data-view="stable"');
  });
});

describe("Router client", () => {
  test("renders the real component + params on the client", async () => {
    setLocationPathname("/app/club/42");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/club/42" });
    await flush();
    expect(r.html()).toContain('data-view="club"');
    expect(r.html()).toContain('data-id="42"');
    r.unmount();
  });

  test("Link resolves a base-relative href and soft-navigates without reload", async () => {
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(r.html()).toContain('data-view="home"');
    // The rendered anchor carries the RESOLVED href (base + path), so the SSR
    // shell / no-JS anchors point at the real URL.
    expect((r.get('[data-testid="go"]') as HTMLAnchorElement).getAttribute("href")).toBe("/app/booking");
    await click(r.get('[data-testid="go"]'));
    await flush();
    expect(window.location.pathname).toBe("/app/booking");
    expect(r.html()).toContain('data-view="booking"');
    r.unmount();
  });

  test("Link falls back to a native anchor for an absolute-URL href (no soft-nav)", async () => {
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(r.html()).toContain('data-view="home"');
    const anchor = r.get('[data-testid="go-out"]') as HTMLAnchorElement;
    // An absolute URL must render as a plain anchor with the href untouched
    // (never base-prefixed): onClick must not call preventDefault/navigate(),
    // so happy-dom performs the anchor's *real* navigation (location flips to
    // the raw href) instead of a soft-nav. Since that's a real navigation (not
    // history.pushState() followed by our popstate-driven re-render), the
    // router never sees a popstate/emit() and its rendered view is untouched.
    expect(anchor.getAttribute("href")).toBe("http://localhost/other");
    await click(anchor);
    await flush();
    expect(window.location.pathname).toBe("/other");
    expect(r.html()).toContain('data-view="home"');
    expect(r.html()).not.toContain('data-view="booking"');
    r.unmount();
    setLocationPathname("/app/"); // don't leak the native navigation into later tests
  });

  // A caller-supplied onClick must be CHAINED with the router's, never
  // substituted for it: a Link whose handler replaced the router's would lose
  // the preventDefault() and perform a REAL navigation — full document reload,
  // all SPA state lost. (`<Link onClick={() => setMenuOpen(false)}>` is the
  // near-universal close-the-nav-drawer pattern.)
  test("Link chains a caller's onClick and still soft-navigates", async () => {
    setLocationPathname("/app/");
    const r = renderIsland(HandlerApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    handlerClicks = 0;
    await click(r.get('[data-testid="go-handler"]'));
    await flush();
    expect(handlerClicks).toBe(1);                          // the caller's handler ran
    expect(window.location.pathname).toBe("/app/booking");  // soft-nav still happened
    expect(r.html()).toContain('data-view="booking"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a caller's onClick can cancel the soft-nav with preventDefault()", async () => {
    setLocationPathname("/app/");
    const r = renderIsland(HandlerApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    await click(r.get('[data-testid="go-cancel"]'));
    await flush();
    // The handler prevented the default, so neither the router nor the browser
    // navigates: the view is untouched.
    expect(window.location.pathname).toBe("/app/");
    expect(r.html()).toContain('data-view="home"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("navigate() resolves its target relative to the mounted Router's base", async () => {
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" });
    await flush();
    navigate("/club/7");
    await flush();
    expect(window.location.pathname).toBe("/app/club/7");
    expect(r.html()).toContain('data-id="7"');
    // Back to the SPA root: "/" resolves to the base itself.
    navigate("/");
    await flush();
    expect(window.location.pathname).toBe("/app/");
    expect(r.html()).toContain('data-view="home"');
    r.unmount();
  });

  test("unmounting the Router un-registers its base — no stale resolution afterwards", async () => {
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" });
    await flush();
    navigate("/booking");
    await flush();
    expect(window.location.pathname).toBe("/app/booking"); // resolved while mounted
    r.unmount();
    await flush();
    // With no mounted Router the base is un-registered: navigate() must
    // resolve verbatim, NOT against the unmounted Router's stale "/app".
    navigate("/other-spa/x");
    await flush();
    expect(window.location.pathname).toBe("/other-spa/x");
    setLocationPathname("/app/");
  });
});

describe("Router hydration (real Preact hydrate())", () => {
  test("two-phase hydrate on a dynamic route: matches the SSR skeleton on the initial hydrate() pass, then flips to the real component with no stale skeleton attribute", async () => {
    setLocationPathname("/app/club/42");
    const r = renderIsland(App, {}, { mode: "hydrate", pathname: "/app/club/42" });

    // Immediately after Preact's hydrate() call (before the post-mount effect
    // fires), the client's first render must reproduce the SSR'd skeleton
    // verbatim — hydrate() does not diff element attributes on this pass, so
    // rendering anything else here would desync from the markup it's adopting.
    expect(r.html()).toContain('data-view="club-skeleton"');
    expect(r.html()).not.toContain('data-view="club"');

    await flush(); // let the post-mount useEffect flip `hydrated` -> true

    // That flip triggers a normal (non-hydrating) re-render, which Preact
    // fully diffs — so the skeleton attribute must be completely gone (not
    // just shadowed by new children) and the real component's own attributes
    // must be present. Pre-fix, rendering the real component straight away
    // during hydrate() left `data-view="club-skeleton"` permanently stuck
    // (Preact never re-diffs attributes it believes already match) while the
    // children/text had already flipped to the real content — this is the
    // exact regression this test pins.
    expect(r.html()).toContain('data-view="club"');
    expect(r.html()).toContain('data-id="42"');
    expect(r.html()).not.toContain('data-view="club-skeleton"');

    r.unmount();
    setLocationPathname("/app/");
  });
});

// --- Route guards ---------------------------------------------------------
// A guarded route renders the neutral `fallback` on SSR + every client render
// until its guard resolves `true` for the current pathname, then flips to the
// real component (or the guard redirects). The gated component carries a
// distinctive `data-gated` marker that must NEVER appear until authorized.

const GuardFallback = () => h("div", { "data-view": "guard-fallback" }, "loading…");
const Secret = () => h("div", { "data-view": "secret", "data-gated": "secret" }, "TOP SECRET");
const LoginView = () => h("div", { "data-view": "login" }, "login");

// The route guard indirects through a mutable holder so each test can swap in
// the verdict (or a deferred promise) it wants to exercise.
let secretGuard: (loc: { pathname: string; params: Record<string, string> }) => Promise<GuardResult> =
  async () => true;
const gatedRoutes = [
  { path: "/", component: Home },
  { path: "/secret", component: Secret, guard: (loc: any) => secretGuard(loc) },
  { path: "/login", component: LoginView },
];
const GatedApp = () =>
  h(Router, {
    base: "/app",
    routes: gatedRoutes,
    fallback: GuardFallback,
    notFound: () => h("div", { "data-view": "nf" }, "nf"),
  });

function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

describe("Router guards", () => {
  test("SSRs the neutral fallback for a guarded route — no gated content in the shell", () => {
    const html = ssrIsland(GatedApp, {}, { pathname: "/app/secret" });
    expect(html).toContain('data-view="guard-fallback"');
    expect(html).not.toContain('data-gated="secret"');
    expect(html).not.toContain("TOP SECRET");
  });

  test("guard resolves true → flips from fallback to the real gated component", async () => {
    secretGuard = async () => true;
    setLocationPathname("/app/secret");
    const r = renderIsland(GatedApp, {}, { mode: "render", pathname: "/app/secret" });
    // first render is the neutral fallback (guard pending)
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-gated="secret"');
    await flush();
    expect(r.html()).toContain('data-gated="secret"');
    expect(r.html()).not.toContain('data-view="guard-fallback"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("guard returns a redirect → navigates away, never renders the gated component", async () => {
    secretGuard = async () => ({ redirect: "/login" }); // base-relative
    setLocationPathname("/app/secret");
    const r = renderIsland(GatedApp, {}, { mode: "render", pathname: "/app/secret" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).toContain('data-view="login"');
    expect(r.html()).not.toContain('data-gated="secret"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a guard result for a stale pathname is ignored (navigation invalidates it)", async () => {
    const d = deferred<GuardResult>();
    secretGuard = () => d.promise; // never resolves until we say so
    setLocationPathname("/app/secret");
    const r = renderIsland(GatedApp, {}, { mode: "render", pathname: "/app/secret" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    // Navigate away BEFORE the guard resolves.
    navigate("/");
    await flush();
    expect(window.location.pathname).toBe("/app/");
    // The in-flight guard now resolves — for the stale /app/secret path — asking
    // to redirect to /app/login. Because we've navigated away it must be ignored.
    d.resolve({ redirect: "/login" });
    await flush();
    expect(window.location.pathname).toBe("/app/"); // NOT /app/login
    expect(r.html()).toContain('data-view="home"');
    expect(r.html()).not.toContain('data-gated="secret"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("guard redirect REPLACES the gated URL so Back isn't trapped (AUDF-007)", async () => {
    secretGuard = async () => ({ redirect: "/login" });
    setLocationPathname("/app/");
    const r = renderIsland(GatedApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(window.location.pathname).toBe("/app/"); // on home, ungated
    const len0 = window.history.length;
    navigate("/secret"); // PUSHes /app/secret (+1); its guard then redirects
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    // The gated /app/secret entry is REPLACED by /app/login, not pushed on top —
    // exactly ONE net new entry. A PUSH would add two, leaving /app/secret in
    // history where Back re-runs the guard and re-redirects forever.
    expect(window.history.length).toBe(len0 + 1);
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a thrown guard is treated as unauthorized: stays on the fallback, never paints the component", async () => {
    secretGuard = async () => { throw new Error("session check failed"); };
    setLocationPathname("/app/secret");
    const r = renderIsland(GatedApp, {}, { mode: "render", pathname: "/app/secret" });
    await flush();
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-gated="secret"');
    expect(window.location.pathname).toBe("/app/secret"); // no redirect
    r.unmount();
    setLocationPathname("/app/");
  });
});

describe("Router guards fail closed on misconfiguration", () => {
  // A guarded route whose author forgot BOTH `fallback` (Router prop) and
  // `skeleton` (route). The old code fell through to `skeleton ?? component`
  // and rendered the real gated component — leaking it into the SSR shell and
  // flashing it on first client render. It must instead render a neutral empty
  // placeholder and NEVER the component while unauthorized.
  const misconfiguredRoutes = [
    { path: "/", component: Home },
    { path: "/secret", component: Secret, guard: async () => true as GuardResult },
  ];
  const MisconfiguredApp = () =>
    h(Router, { base: "/app", routes: misconfiguredRoutes }); // no fallback, no skeleton

  test("SSR of a guarded route with no fallback/skeleton renders a neutral placeholder, NOT the gated component", () => {
    const html = ssrIsland(MisconfiguredApp, {}, { pathname: "/app/secret" });
    expect(html).toContain("data-z-guard-pending");
    expect(html).not.toContain('data-gated="secret"');
    expect(html).not.toContain("TOP SECRET");
  });

  test("first client render (pre-auth) also shows the neutral placeholder, then flips once the guard resolves", async () => {
    setLocationPathname("/app/secret");
    const r = renderIsland(MisconfiguredApp, {}, { mode: "hydrate", pathname: "/app/secret" });
    // hydrate() first pass reproduces the SSR placeholder — no gated content.
    expect(r.html()).toContain("data-z-guard-pending");
    expect(r.html()).not.toContain('data-gated="secret"');
    await flush(); // guard resolves true → now it may paint the real component
    expect(r.html()).toContain('data-gated="secret"');
    r.unmount();
    setLocationPathname("/app/");
  });
});

describe("Router guard hydration (real Preact hydrate())", () => {
  test("a guarded route hydrates its neutral fallback (no mismatch), then flips cleanly to the gated component", async () => {
    secretGuard = async () => true;
    setLocationPathname("/app/secret");
    const r = renderIsland(GatedApp, {}, { mode: "hydrate", pathname: "/app/secret" });

    // Initial hydrate() pass must reproduce the SSR'd fallback verbatim — no
    // gated content, matching the shell markup being adopted.
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-gated="secret"');

    await flush(); // post-mount effects: hydrated -> true, guard resolves -> authed

    // The flip is a normal (non-hydrating) re-render → fully diffed: the
    // fallback marker is gone and the gated component's attrs are present.
    expect(r.html()).toContain('data-gated="secret"');
    expect(r.html()).not.toContain('data-view="guard-fallback"');

    r.unmount();
    setLocationPathname("/app/");
  });
});

// --- Nested / layout routes -----------------------------------------------
// A layout route renders shared chrome once + an <Outlet/> where the matched
// child renders. Soft-nav between siblings must keep the SAME layout instance
// (only the Outlet content swaps). A guarded layout gates its whole subtree.

// Monotonic mount counter: only ever increments (no decrement on cleanup), so a
// value of 1 after a sibling soft-nav proves the layout was NOT re-created.
let layoutMountCount = 0;
const Layout = () => {
  useEffect(() => { layoutMountCount++; }, []);
  return h("div", { "data-view": "layout" },
    h("header", { "data-layout-chrome": "" }, "CHROME"),
    h(Outlet, {}));
};
const OverviewSkeleton = () => h("div", { "data-view": "overview-skeleton" }, "loading overview…");
const Overview = () => h("div", { "data-view": "overview" }, "overview");
const Settings = () => h("div", { "data-view": "settings" }, "settings");

const nestedAppRoutes: RouteDef[] = [
  { path: "/", component: Home },
  {
    path: "/dash", component: Layout, children: [
      { path: "/overview", component: Overview, skeleton: OverviewSkeleton },
      { path: "/settings", component: Settings },
    ],
  },
];
const NestedApp = () =>
  h(Router, { base: "/app", routes: nestedAppRoutes, notFound: () => h("div", { "data-view": "nf" }, "nf") });

describe("Router nested/layout routes", () => {
  test("SSRs the layout chrome + the matched child (leaf skeleton) together", () => {
    const html = ssrIsland(NestedApp, {}, { pathname: "/app/dash/overview" });
    expect(html).toContain("data-layout-chrome");
    expect(html).toContain('data-view="overview-skeleton"'); // leaf two-phase: skeleton on SSR
    expect(html).not.toContain('data-view="overview"');
  });

  test("renders the child inside the layout on the client, and swaps siblings without remounting the layout", async () => {
    layoutMountCount = 0;
    setLocationPathname("/app/dash/overview");
    const r = renderIsland(NestedApp, {}, { mode: "render", pathname: "/app/dash/overview" });
    await flush();
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="overview"');
    expect(layoutMountCount).toBe(1);

    // Soft-nav to the sibling: Outlet content swaps, layout chrome persists,
    // and the layout effect did NOT run again (same instance).
    navigate("/dash/settings");
    await flush();
    expect(window.location.pathname).toBe("/app/dash/settings");
    expect(r.html()).toContain('data-view="settings"');
    expect(r.html()).not.toContain('data-view="overview"');
    expect(r.html()).toContain("data-layout-chrome");
    expect(layoutMountCount).toBe(1); // layout instance preserved across sibling nav

    r.unmount();
    setLocationPathname("/app/");
  });

  test("two-phase hydrate of a layout+child: SSR skeleton hydrates cleanly, then the leaf flips (layout not remounted)", async () => {
    layoutMountCount = 0;
    setLocationPathname("/app/dash/overview");
    const r = renderIsland(NestedApp, {}, { mode: "hydrate", pathname: "/app/dash/overview" });
    // Initial hydrate() pass reproduces the SSR'd layout + leaf skeleton.
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="overview-skeleton"');
    expect(r.html()).not.toContain('data-view="overview"');

    await flush(); // post-mount: hydrated -> true, leaf flips skeleton -> real

    expect(r.html()).toContain('data-view="overview"');
    expect(r.html()).not.toContain('data-view="overview-skeleton"');
    expect(r.html()).toContain("data-layout-chrome");
    expect(layoutMountCount).toBe(1); // the flip re-rendered but did not remount the layout

    r.unmount();
    setLocationPathname("/app/");
  });
});

// --- Layout routes receive `children` as an <Outlet/> (issue #22) ---------
// `<Outlet/>` and `{children}` are the SAME channel: renderChainNode always
// calls a rung's component as `h(comp, { children: h(Outlet, {}) })`, so a
// layout written `<div>{children}</div>` (never mentioning Outlet at all)
// must work identically to one that renders `<Outlet/>` explicitly — and
// using both, or neither, must be caught (dev-only) rather than silently
// producing a duplicated or permanently-empty outlet.
function spyConsoleWarn(): { warnings: string[]; restore: () => void } {
  const warnings: string[] = [];
  const orig = console.warn;
  console.warn = ((...args: unknown[]) => { warnings.push(String(args[0])); }) as typeof console.warn;
  return { warnings, restore: () => { console.warn = orig; } };
}

let childrenLayoutMountCount = 0;
const ChildrenLayout = (props: { children?: any }) => {
  useEffect(() => { childrenLayoutMountCount++; }, []);
  return h("div", { "data-view": "children-layout" },
    h("header", { "data-layout-chrome": "" }, "CHROME"),
    props.children); // the implicit-Outlet channel — no <Outlet/> in sight
};
const childrenLayoutRoutes: RouteDef[] = [
  { path: "/", component: C },
  {
    path: "/dash-children", component: ChildrenLayout, children: [
      { path: "/overview", component: Overview, skeleton: OverviewSkeleton },
      { path: "/settings", component: Settings },
    ],
  },
];
const ChildrenLayoutApp = () =>
  h(Router, { base: "/app", routes: childrenLayoutRoutes, notFound: () => h("div", { "data-view": "nf" }, "nf") });

describe("Router layout children channel (issue #22)", () => {
  test("a {children} layout SSRs chrome + the leaf skeleton together", () => {
    const html = ssrIsland(ChildrenLayoutApp, {}, { pathname: "/app/dash-children/overview" });
    expect(html).toContain("data-layout-chrome");
    expect(html).toContain('data-view="overview-skeleton"');
    expect(html).not.toContain('data-view="overview"');
  });

  test("a {children} layout client-renders the child and survives sibling soft-nav without remounting", async () => {
    childrenLayoutMountCount = 0;
    setLocationPathname("/app/dash-children/overview");
    const r = renderIsland(ChildrenLayoutApp, {}, { mode: "render", pathname: "/app/dash-children/overview" });
    await flush();
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="overview"');
    expect(childrenLayoutMountCount).toBe(1);

    navigate("/dash-children/settings");
    await flush();
    expect(window.location.pathname).toBe("/app/dash-children/settings");
    expect(r.html()).toContain('data-view="settings"');
    expect(r.html()).not.toContain('data-view="overview"');
    expect(r.html()).toContain("data-layout-chrome");
    expect(childrenLayoutMountCount).toBe(1); // same layout instance across sibling nav

    r.unmount();
    setLocationPathname("/app/");
  });

  test("two-phase hydrate of a {children} layout: SSR skeleton hydrates cleanly, then the leaf flips", async () => {
    childrenLayoutMountCount = 0;
    setLocationPathname("/app/dash-children/overview");
    const r = renderIsland(ChildrenLayoutApp, {}, { mode: "hydrate", pathname: "/app/dash-children/overview" });
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="overview-skeleton"');
    expect(r.html()).not.toContain('data-view="overview"');

    await flush();

    expect(r.html()).toContain('data-view="overview"');
    expect(r.html()).not.toContain('data-view="overview-skeleton"');
    expect(r.html()).toContain("data-layout-chrome");
    expect(childrenLayoutMountCount).toBe(1);

    r.unmount();
    setLocationPathname("/app/");
  });

  test("both {children} and <Outlet/> ⇒ the matched child renders TWICE and the double-render warning fires once", async () => {
    const BothChannelsLayout = (props: { children?: any }) =>
      h("div", { "data-view": "both-layout" },
        h("header", { "data-layout-chrome": "" }, "CHROME"),
        props.children, // channel 1
        h(Outlet, {})); // channel 2 — same channel, rendered twice
    const routes: RouteDef[] = [
      { path: "/", component: C },
      { path: "/dash-both", component: BothChannelsLayout, children: [{ path: "/overview", component: Overview }] },
    ];
    const BothApp = () => h(Router, { base: "/app", routes });
    const { warnings, restore } = spyConsoleWarn();
    setLocationPathname("/app/dash-both/overview");
    const r = renderIsland(BothApp, {}, { mode: "render", pathname: "/app/dash-both/overview" });
    await flush();
    try {
      expect(r.getAll('[data-view="overview"]').length).toBe(2); // duplicated
      const doubleWarnings = warnings.filter((w) => w.includes("renders both {children} and <Outlet/>"));
      expect(doubleWarnings.length).toBe(1);
      expect(doubleWarnings[0]).toContain('"/dash-both"');
    } finally {
      restore();
      r.unmount();
      setLocationPathname("/app/");
    }
  });

  test("neither {children} nor <Outlet/> ⇒ the matched child never renders and the no-outlet warning fires", async () => {
    const NoOutletLayout = () =>
      h("div", { "data-view": "no-outlet-layout" },
        h("header", { "data-layout-chrome": "" }, "CHROME")); // renders neither channel
    const routes: RouteDef[] = [
      { path: "/", component: C },
      { path: "/dash-neither", component: NoOutletLayout, children: [{ path: "/overview", component: Overview }] },
    ];
    const NeitherApp = () => h(Router, { base: "/app", routes });
    const { warnings, restore } = spyConsoleWarn();
    setLocationPathname("/app/dash-neither/overview");
    const r = renderIsland(NeitherApp, {}, { mode: "render", pathname: "/app/dash-neither/overview" });
    await flush();
    try {
      expect(r.query('[data-view="overview"]')).toBeNull(); // the matched child never rendered
      const noOutletWarnings = warnings.filter((w) => w.includes("rendered neither {children} nor an <Outlet/>"));
      expect(noOutletWarnings.length).toBe(1);
      expect(noOutletWarnings[0]).toContain('"/dash-neither"');
    } finally {
      restore();
      r.unmount();
      setLocationPathname("/app/");
    }
  });
});

describe("Router nested guard cascade", () => {
  const DashChild = () => h("div", { "data-view": "dash-overview", "data-gated": "dash" }, "GATED DASH");
  let dashGuard: () => Promise<GuardResult> = async () => true;
  const guardedNestedRoutes: RouteDef[] = [
    { path: "/", component: Home },
    { path: "/login", component: LoginView },
    {
      path: "/dash", component: Layout, guard: () => dashGuard(), children: [
        { path: "/overview", component: DashChild },
      ],
    },
  ];
  const GuardedNestedApp = () =>
    h(Router, {
      base: "/app", routes: guardedNestedRoutes, fallback: GuardFallback,
      notFound: () => h("div", { "data-view": "nf" }, "nf"),
    });

  test("SSR of a guarded layout renders the fallback — no layout chrome, no gated child", () => {
    const html = ssrIsland(GuardedNestedApp, {}, { pathname: "/app/dash/overview" });
    expect(html).toContain('data-view="guard-fallback"');
    expect(html).not.toContain("data-layout-chrome");
    expect(html).not.toContain('data-gated="dash"');
  });

  test("authorized → layout chrome + gated child appear after the guard resolves", async () => {
    dashGuard = async () => true;
    setLocationPathname("/app/dash/overview");
    const r = renderIsland(GuardedNestedApp, {}, { mode: "render", pathname: "/app/dash/overview" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-gated="dash"');
    await flush();
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-gated="dash"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("anon → the layout guard redirects; the gated child never paints", async () => {
    dashGuard = async () => ({ redirect: "/login" });
    setLocationPathname("/app/dash/overview");
    const r = renderIsland(GuardedNestedApp, {}, { mode: "render", pathname: "/app/dash/overview" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).toContain('data-view="login"');
    expect(r.html()).not.toContain('data-gated="dash"');
    expect(r.html()).not.toContain("data-layout-chrome");
    r.unmount();
    setLocationPathname("/app/");
  });
});

// --- Guarded-layout scope persistence (review fix) ------------------------
// A guarded LAYOUT with sibling children: once authorized, moving between the
// tabs must keep the SAME layout instance (no remount / no state loss) and must
// NOT re-flash the fallback — authorization is per SCOPE, not per pathname.
describe("Router guarded-layout scope persistence", () => {
  let areaGuard: () => Promise<GuardResult> = async () => true;
  const Tab1 = () => h("div", { "data-view": "tab1" }, "t1");
  const Tab2 = () => h("div", { "data-view": "tab2" }, "t2");
  const guardedLayoutRoutes: RouteDef[] = [
    { path: "/", component: Home },
    { path: "/login", component: LoginView },
    {
      path: "/area", component: Layout, guard: () => areaGuard(), children: [
        { path: "/tab1", component: Tab1 },
        { path: "/tab2", component: Tab2 },
      ],
    },
  ];
  const AreaApp = () =>
    h(Router, {
      base: "/app", routes: guardedLayoutRoutes, fallback: GuardFallback,
      notFound: () => h("div", { "data-view": "nf" }, "nf"),
    });

  test("authorized sibling nav keeps the guarded layout MOUNTED with no fallback re-flash", async () => {
    areaGuard = async () => true;
    layoutMountCount = 0;
    setLocationPathname("/app/area/tab1");
    const r = renderIsland(AreaApp, {}, { mode: "render", pathname: "/app/area/tab1" });
    // First render: the /area scope isn't authorized yet → fallback (no chrome).
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain("data-layout-chrome");
    await flush();
    // Authorized: layout chrome + tab1; layout mounted exactly once.
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="tab1"');
    expect(layoutMountCount).toBe(1);

    // Sibling soft-nav within the SAME guarded scope: no fallback, tab swaps,
    // layout instance preserved (count stays 1 — a fallback replacing the layout
    // would have unmounted it, bumping the monotonic mount counter to 2).
    navigate("/area/tab2");
    await flush();
    expect(window.location.pathname).toBe("/app/area/tab2");
    expect(r.html()).toContain('data-view="tab2"');
    expect(r.html()).not.toContain('data-view="tab1"');
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).not.toContain('data-view="guard-fallback"');
    expect(layoutMountCount).toBe(1);

    r.unmount();
    setLocationPathname("/app/");
  });

  test("anon → the layout guard redirects; no layout chrome, no child painted", async () => {
    areaGuard = async () => ({ redirect: "/login" });
    layoutMountCount = 0;
    setLocationPathname("/app/area/tab1");
    const r = renderIsland(AreaApp, {}, { mode: "render", pathname: "/app/area/tab1" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).toContain('data-view="login"');
    expect(r.html()).not.toContain("data-layout-chrome");
    expect(r.html()).not.toContain('data-view="tab1"');
    expect(layoutMountCount).toBe(0); // the guarded layout never mounted
    r.unmount();
    setLocationPathname("/app/");
  });

  test("two-phase hydrate of a guarded layout: fallback hydrates cleanly, then flips to layout+child", async () => {
    areaGuard = async () => true;
    layoutMountCount = 0;
    setLocationPathname("/app/area/tab1");
    const r = renderIsland(AreaApp, {}, { mode: "hydrate", pathname: "/app/area/tab1" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain("data-layout-chrome");
    await flush();
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="tab1"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("changing a guarded dynamic param re-gates that scope (fallback while re-validating)", async () => {
    const club43 = deferred<GuardResult>();
    const clubGuard = (loc: { pathname: string }) =>
      loc.pathname === "/app/club/42" ? Promise.resolve(true as GuardResult) : club43.promise;
    const ClubView = () => {
      const { id } = useParams<{ id: string }>();
      return h("div", { "data-view": "club", "data-id": id }, "club " + id);
    };
    const clubRoutes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/club/:id", component: ClubView, guard: clubGuard },
    ];
    const ClubApp = () => h(Router, { base: "/app", routes: clubRoutes, fallback: GuardFallback });

    setLocationPathname("/app/club/42");
    const r = renderIsland(ClubApp, {}, { mode: "render", pathname: "/app/club/42" });
    await flush();
    expect(r.html()).toContain('data-id="42"');

    // Navigate to a different :id → a NEW scope key (/app/club/43) not yet
    // authorized → the fallback re-shows while its guard (still pending) runs.
    navigate("/club/43");
    await flush();
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-id="42"');
    expect(r.html()).not.toContain('data-id="43"');

    // Resolve the new id's guard → it authorizes and paints club 43.
    club43.resolve(true);
    await flush();
    expect(r.html()).toContain('data-id="43"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("evict-on-leave: a de-authorized scope re-gates on re-entry (no stale content flash)", async () => {
    layoutMountCount = 0;
    areaGuard = async () => true;
    setLocationPathname("/app/area/tab1");
    const r = renderIsland(AreaApp, {}, { mode: "render", pathname: "/app/area/tab1" });
    await flush();
    expect(r.html()).toContain("data-layout-chrome");
    expect(r.html()).toContain('data-view="tab1"'); // authorized this session

    // Leave the guarded scope entirely (to the unguarded home). The prune must
    // evict the /app/area key even though home has no guards.
    navigate("/");
    await flush();
    expect(r.html()).toContain('data-view="home"');

    // Session expires: re-entering must now re-validate, and the guard fails.
    const reentry = deferred<GuardResult>();
    areaGuard = () => reentry.promise;

    // Re-enter the scope. Because the key was evicted on leave, this re-gates
    // from the fallback — the layout chrome / tab content must NOT flash while
    // the (still-pending) guard re-validates.
    navigate("/area/tab1");
    await flush();
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-view="tab1"');
    expect(r.html()).not.toContain("data-layout-chrome");

    // The re-validation fails → redirect; the gated content never painted.
    reentry.resolve({ redirect: "/login" });
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).not.toContain('data-view="tab1"');
    r.unmount();
    setLocationPathname("/app/");
  });
});

// --- useSearchParams ------------------------------------------------------
const SearchProbe = () => {
  const [params, setParams] = useSearchParams();
  return h("div", { "data-view": "sp", "data-q": params.get("q") ?? "(none)", "data-n": params.get("n") ?? "(none)" },
    h("button", { "data-testid": "set-push", onClick: () => setParams({ q: "hello world" }) }, "push"),
    h("button", { "data-testid": "set-replace", onClick: () => setParams("n=2", { replace: true }) }, "replace"));
};

describe("useSearchParams", () => {
  test("parses the current query, decoded", () => {
    window.history.replaceState(null, "", "/app/?q=a%20b&n=2");
    const r = renderIsland(SearchProbe, {}, { mode: "render", pathname: "/app/" });
    expect(r.get('[data-view="sp"]').getAttribute("data-q")).toBe("a b");
    expect(r.get('[data-view="sp"]').getAttribute("data-n")).toBe("2");
    r.unmount();
  });

  test("is reactive to a query-only navigation (pathname unchanged)", async () => {
    window.history.replaceState(null, "", "/app/?q=first");
    const r = renderIsland(SearchProbe, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(r.get('[data-view="sp"]').getAttribute("data-q")).toBe("first");
    // Same pathname, only the query changes — useLocation().search would NOT
    // re-render here; useSearchParams must. (No Router is mounted in this
    // test, so navigate() resolves verbatim: the full /app/ path.)
    navigate("/app/?q=second");
    await flush();
    expect(window.location.pathname).toBe("/app/");
    expect(r.get('[data-view="sp"]').getAttribute("data-q")).toBe("second");
    r.unmount();
  });

  test("setter pushes a new query (default) with encoded values, decoded on read", async () => {
    window.history.replaceState(null, "", "/app/");
    const r = renderIsland(SearchProbe, {}, { mode: "render", pathname: "/app/" });
    await flush();
    const len0 = window.history.length;
    await click(r.get('[data-testid="set-push"]'));
    expect(window.location.search).toBe("?q=hello+world");
    expect(r.get('[data-view="sp"]').getAttribute("data-q")).toBe("hello world");
    expect(window.history.length).toBe(len0 + 1); // pushed a new entry
    r.unmount();
  });

  test("setter with {replace} replaces the entry (no new history entry)", async () => {
    window.history.replaceState(null, "", "/app/?q=keep");
    const r = renderIsland(SearchProbe, {}, { mode: "render", pathname: "/app/" });
    await flush();
    const len0 = window.history.length;
    await click(r.get('[data-testid="set-replace"]'));
    expect(window.location.search).toBe("?n=2");
    expect(window.history.length).toBe(len0); // replaced, no new entry
    r.unmount();
  });

  test("SSR: empty when no query, parsed from the SSR pathname's query when present", () => {
    expect(ssrIsland(SearchProbe, {}, { pathname: "/app/" })).toContain('data-q="(none)"');
    const html = ssrIsland(SearchProbe, {}, { pathname: "/app/?q=srv" });
    expect(html).toContain('data-q="srv"');
  });
});

// --- useLocation (consolidated onto ssr-env's hardened helpers) ------------
const LocationProbe = () => {
  const { pathname, search } = useLocation();
  // preact-render-to-string drops a plain "" attribute value entirely (no
  // `data-search=""` in the markup) — wrap so an empty search still serializes
  // as a quoted, assertable attribute.
  return h("div", { "data-view": "loc", "data-pathname": pathname, "data-search": search || "(none)" });
};

describe("useLocation", () => {
  test("SSR: pathname is the SSR pathname with any query trimmed off", () => {
    const html = ssrIsland(LocationProbe, {}, { pathname: "/app/club/1?tab=events" });
    expect(html).toContain('data-pathname="/app/club/1"');
  });

  test("SSR: search is parsed from the SSR pathname's query when the build threaded one", () => {
    expect(ssrIsland(LocationProbe, {}, { pathname: "/app/club/1?tab=events" }))
      .toContain('data-search="?tab=events"');
    expect(ssrIsland(LocationProbe, {}, { pathname: "/app/club/1" }))
      .toContain('data-search="(none)"');
  });

  test("client (no Router context): pathname/search fall back to window.location", () => {
    window.history.replaceState(null, "", "/app/club/2?tab=chat");
    const r = renderIsland(LocationProbe, {}, { mode: "render" });
    expect(r.get('[data-view="loc"]').getAttribute("data-pathname")).toBe("/app/club/2");
    expect(r.get('[data-view="loc"]').getAttribute("data-search")).toBe("?tab=chat");
    r.unmount();
    window.history.replaceState(null, "", "/app/"); // reset
  });

  test("inside a Router: pathname comes from the matched-chain context, not window.location directly", () => {
    const routes: RouteDef[] = [{ path: "/loc", component: LocationProbe }];
    setLocationPathname("/app/loc?tab=chat");
    const App = () => h(Router, { base: "/app", routes });
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/loc" });
    // ctx.pathname is the FULL window.location.pathname (un-stripped of base) —
    // matches docs/spa.md's documented useLocation() contract.
    expect(r.get('[data-view="loc"]').getAttribute("data-pathname")).toBe("/app/loc");
    expect(r.get('[data-view="loc"]').getAttribute("data-search")).toBe("?tab=chat");
    r.unmount();
    setLocationPathname("/app/");
  });
});

// --- Scroll restoration bookkeeping ----------------------------------------
// happy-dom scroll is a no-op, so we assert the per-history-entry key/save/
// restore logic directly (a real-scroll Playwright check is a bonus, not here).
describe("scroll restoration bookkeeping", () => {
  const { onPush, onPop } = __scrollBookkeepingForTest;

  test("push mints monotonic ids and saves the LEAVING entry's scroll", () => {
    __resetScrollForTest();
    expect(onPush({ x: 0, y: 0 })).toBe(0); // first entry: nothing to save yet
    expect(onPush({ x: 0, y: 150 })).toBe(1); // leaving entry 0 at y=150
    const st = __scrollStateForTest();
    expect(st.positions.get(0)).toEqual({ x: 0, y: 150 });
    expect(st.currentId).toBe(1);
  });

  test("pop saves the leaving position and restores the target entry's saved position", () => {
    __resetScrollForTest();
    onPush({ x: 0, y: 0 });    // entry 0
    onPush({ x: 0, y: 200 });  // save 0->200, now on entry 1
    const restore = onPop({ x: 0, y: 50 }, 0); // leave entry1@50, back to entry0
    expect(restore).toEqual({ x: 0, y: 200 }); // entry 0's saved position
    expect(__scrollStateForTest().positions.get(1)).toEqual({ x: 0, y: 50 });
    expect(__scrollStateForTest().currentId).toBe(0);
  });

  test("keyed by history ENTRY id, not pathname (a repeated path keeps distinct positions)", () => {
    __resetScrollForTest();
    onPush({ x: 0, y: 0 });    // entry 0 == "/a"
    onPush({ x: 0, y: 100 });  // save 0->100, entry 1 == "/a" again
    const restore = onPop({ x: 0, y: 300 }, 0); // back to entry 0
    expect(restore).toEqual({ x: 0, y: 100 }); // entry 0's 100, NOT entry 1's 300
  });

  test("pop to an entry with no saved position restores (0,0)", () => {
    __resetScrollForTest();
    onPush({ x: 0, y: 0 });
    expect(onPop({ x: 0, y: 80 }, undefined)).toEqual({ x: 0, y: 0 });
  });

  // AUDF-018: the map must not grow without bound over a long-lived tab.
  test("saved-position map is bounded — ancient entries are pruned (AUDF-018)", () => {
    __resetScrollForTest();
    onPush({ x: 0, y: 0 }); // entry 0
    for (let i = 1; i <= 5000; i++) onPush({ x: 0, y: i });
    const { positions, currentId } = __scrollStateForTest();
    expect(positions.size).toBeLessThanOrEqual(128);
    expect(positions.has(0)).toBe(false); // the ancient orphan is gone
    expect(positions.has(currentId - 1)).toBe(true); // recent entries survive
  });

  test("pruning never evicts the entry currently on top (AUDF-018)", () => {
    __resetScrollForTest();
    onPush({ x: 0, y: 0 });
    for (let i = 1; i <= 5000; i++) onPush({ x: 0, y: i });
    // Pop all the way back to entry 0 (below the prune threshold) then keep
    // pushing: the current entry is preserved across prunes, so its saved
    // position remains restorable.
    onPop({ x: 0, y: 9 }, 0);
    for (let i = 0; i < 300; i++) onPush({ x: 0, y: 1000 + i });
    expect(__scrollStateForTest().positions.size).toBeLessThanOrEqual(128);
  });

  test("eviction is recency-ordered: the immediate parent survives a deep Back then PUSH (AUDF-018)", () => {
    // Regression for the id-threshold pruning bug: after navigating far Back and
    // then pushing a new entry, the entry we just left (the new page's parent)
    // must keep its saved scroll — LRU eviction moves it to the newest slot on
    // save, so it is never pruned as "ancient" by its low id.
    __resetScrollForTest();
    onPush({ x: 0, y: 0 });                              // entry 0
    for (let i = 1; i <= 5000; i++) onPush({ x: 0, y: i }); // deep history
    onPop({ x: 0, y: 0 }, 3);                            // Back to a low-id entry (3)
    const parent = __scrollStateForTest().currentId;     // == 3
    onPush({ x: 0, y: 777 });                            // PUSH: saves parent(3)=777, mints a new id
    const { positions } = __scrollStateForTest();
    expect(positions.size).toBeLessThanOrEqual(128);
    expect(positions.get(parent)).toEqual({ x: 0, y: 777 }); // parent's scroll retained
  });
});

// AUDF-017: the pop scroll-restore retries across frames until the async
// guard/lazy content is tall enough to hold the saved Y (or frames run out).
// happy-dom's scroll is a no-op, so we assert the pure retry decision directly.
describe("scroll restore retry (AUDF-017)", () => {
  test("retries while the saved Y still can't be reached and frames remain", () => {
    expect(__scrollRestoreShouldRetry(1200, 0, 20)).toBe(true);   // fallback still short
    expect(__scrollRestoreShouldRetry(1200, 400, 20)).toBe(true); // skeleton still short
  });
  test("stops once the page is tall enough to hold the saved Y", () => {
    expect(__scrollRestoreShouldRetry(1200, 1200, 20)).toBe(false);
    expect(__scrollRestoreShouldRetry(1200, 5000, 20)).toBe(false);
  });
  test("stops when the frame budget is exhausted (bounded, never loops)", () => {
    expect(__scrollRestoreShouldRetry(1200, 0, 0)).toBe(false);
  });
  test("y<=0 never retries (the top is always reachable)", () => {
    expect(__scrollRestoreShouldRetry(0, 0, 20)).toBe(false);
  });
});

/** Record every window.scrollTo while `fn` runs, then put the real one back. */
async function withScrollSpy(fn: (scrolls: Array<[number, number]>) => Promise<void>): Promise<void> {
  const scrolls: Array<[number, number]> = [];
  const real = window.scrollTo;
  (window as any).scrollTo = (x: number, y: number) => { scrolls.push([x, y]); };
  try {
    await fn(scrolls);
  } finally {
    (window as any).scrollTo = real;
  }
}

/**
 * Run `fn` with `requestAnimationFrame` replaced by a manual queue, so a test
 * can interleave a navigation BETWEEN two retry frames. `flush()` drains the
 * whole retry budget in one go, which would hide exactly the bug under test.
 */
async function withManualFrames(
  fn: (step: () => void) => Promise<void>,
): Promise<void> {
  const queued: Array<() => void> = [];
  const real = window.requestAnimationFrame;
  (window as any).requestAnimationFrame = (cb: () => void) => { queued.push(cb); return queued.length; };
  const step = () => { for (const cb of queued.splice(0)) cb(); };
  try {
    await fn(step);
  } finally {
    (window as any).requestAnimationFrame = real;
  }
}

// A retry budget of 20 frames (~330ms) easily outlives a fast Back-then-click,
// so the retry must be bound to the navigation that started it.
describe("scroll restore is scoped to its navigation", () => {
  test("a later PUSH aborts an in-flight Back restore instead of yanking the new page", async () => {
    __resetScrollForTest();
    __setRouterBaseForTest("");
    setLocationPathname("/app/long");
    await withScrollSpy(async (scrolls) => {
      await withManualFrames(async (step) => {
        // Back into a long list: the saved Y is unreachable on the page as it
        // stands (happy-dom reports maxScrollY 0), so the restore re-arms.
        __scrollBookkeepingForTest.restoreWithRetry({ x: 0, y: 5000 }, 20, __navSeqForTest());
        expect(scrolls).toEqual([[0, 5000]]);
        step();
        expect(scrolls).toEqual([[0, 5000], [0, 5000]]); // it really is retrying
        // …then a Link click to a SHORT page, with 18 frames still budgeted.
        // That PUSH owns the viewport now; re-applying y=5000 would scroll the
        // visitor to the bottom of the WRONG page on every remaining frame.
        navigate("/app/short");
        const afterPush = scrolls.length;
        step();
        step();
        step();
        expect(scrolls.slice(afterPush).some(([, y]) => y === 5000)).toBe(false);
      });
    });
    setLocationPathname("/app/");
  });
});

// A history entry the ROUTER never stamped is one the browser created — the
// documented plain `<a href="#pricing">` fragment escape hatch.
describe("scroll restore on a browser-created fragment entry", () => {
  test("__shouldRestoreOnPop skips only an unstamped entry that carries a fragment", () => {
    expect(__shouldRestoreOnPop(false, "#pricing")).toBe(false); // fragment wins
    expect(__shouldRestoreOnPop(false, "")).toBe(true);          // pre-router entry: unchanged
    expect(__shouldRestoreOnPop(true, "#pricing")).toBe(true);   // our entry: our saved position
    expect(__shouldRestoreOnPop(true, "")).toBe(true);
  });

  test("Back/Forward across a fragment entry does not teleport to the top", async () => {
    __resetScrollForTest();
    __setRouterBaseForTest("");
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" }); // binds popstate
    await flush();
    await withScrollSpy(async (scrolls) => {
      // The browser's own fragment entry: state null, URL carries the hash.
      window.history.replaceState(null, "", "/app/#pricing");
      window.dispatchEvent(new PopStateEvent("popstate", { state: null }));
      await flush();
      // scrollRestoration is "manual", so a scrollTo(0,0) here would strand the
      // visitor at the top with no way for the browser to put it right.
      expect(scrolls).toEqual([]);
      // Control: an unstamped entry with NO fragment still restores as before.
      window.history.replaceState(null, "", "/app/");
      window.dispatchEvent(new PopStateEvent("popstate", { state: null }));
      await flush();
      expect(scrolls).toEqual([[0, 0]]);
    });
    r.unmount();
    setLocationPathname("/app/");
  });
});

// setSearchParams() defaults to a PUSH, and a filter box calls it on every
// keystroke — scrolling to the top each time would yank the viewport away from
// the input the visitor is typing into.
describe("query-only navigation preserves the scroll position", () => {
  test("a push with an unchanged pathname does not scroll to the top", async () => {
    __resetScrollForTest();
    __setRouterBaseForTest("");
    setLocationPathname("/app/filter");
    await withScrollSpy(async (scrolls) => {
      navigate("/app/filter?q=a");
      await flush();
      navigate("/app/filter?q=ab");
      await flush();
      navigate("/app/filter?q=abc#results");
      await flush();
      expect(scrolls).toEqual([]);
      // A real route change still scrolls to the top.
      navigate("/app/other");
      await flush();
      expect(scrolls).toEqual([[0, 0]]);
    });
    setLocationPathname("/app/");
  });
});

// --- View transitions --------------------------------------------------------
// document.startViewTransition() wraps a route flip when opted in
// (setViewTransitions(true), normally driven by `spa.viewTransitions` via
// mountSpa) AND supported (feature-detected). happy-dom has no
// startViewTransition, so a test that needs one installs a stub on `document`;
// the block's afterEach removes it and resets the other module-globals.
describe("view transitions", () => {
  function installVTStub(): Array<() => Promise<void> | void> {
    const calls: Array<() => Promise<void> | void> = [];
    (document as any).startViewTransition = (cb: () => Promise<void> | void) => {
      calls.push(cb);
      // The stub runs the callback INLINE, which a real browser does not: it
      // screenshots the old state first and calls the callback at the next
      // rendering opportunity. Running it inline only keeps these tests
      // deterministic under `await flush()`; the `calls.length` assertions
      // below pin that `startViewTransition` is CALLED synchronously by
      // navigate(), never that the flip has already happened when it returns
      // (no router code may assume that).
      const p = Promise.resolve(cb());
      return { ready: p.catch(() => {}), updateCallbackDone: p };
    };
    return calls;
  }

  // Every knob these tests turn is MODULE-global: a failed assertion aborts the
  // test body, so per-test cleanup at the bottom would leave the opt-in on and
  // the stub installed for the rest of the file, turning one red test into a
  // cascade of unrelated ones. Reset here instead — it always runs.
  afterEach(() => {
    delete (document as any).startViewTransition;
    setViewTransitions(false);
    setScrollRestoration(true);
    delete (window as any).zigapagosOnError;
    setLocationPathname("/app/");
  });

  test("a pathname-changing navigate() wraps the flip in startViewTransition exactly once; the DOM shows the target route once the callback's promise settles (fails without the fix)", async () => {
    setViewTransitions(true);
    const calls = installVTStub();
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" });
    await flush();
    navigate("/booking");
    // Wrapped SYNCHRONOUSLY as part of navigate() — a refactor that emits
    // outside the callback (or doesn't wrap at all) fails this.
    expect(calls.length).toBe(1);
    await flush();
    expect(window.location.pathname).toBe("/app/booking");
    expect(r.html()).toContain('data-view="booking"');
    r.unmount();
  });

  test("opt-in guard: setViewTransitions left off — navigate() still flips but never touches the stub", async () => {
    const calls = installVTStub();
    __setRouterBaseForTest("");
    setLocationPathname("/app/x");
    navigate("/app/y");
    await flush();
    expect(calls.length).toBe(0);
    expect(window.location.pathname).toBe("/app/y");
  });

  test("feature-detection fallback: opted in with NO document.startViewTransition still flips and still scrolls to top (fails without feature detection)", async () => {
    setViewTransitions(true);
    __setRouterBaseForTest("");
    setLocationPathname("/app/x");
    await withScrollSpy(async (scrolls) => {
      navigate("/app/y");
      await flush();
      expect(scrolls).toEqual([[0, 0]]); // non-VT path unchanged
    });
    expect(window.location.pathname).toBe("/app/y");
  });

  test("a query-only navigation never transitions (fails without the samePathname gate)", async () => {
    setViewTransitions(true);
    const calls = installVTStub();
    __setRouterBaseForTest("");
    setLocationPathname("/app/filter");
    navigate("/app/filter?q=a");
    await flush();
    expect(calls.length).toBe(0);
  });

  test("a replace navigation never transitions", async () => {
    setViewTransitions(true);
    const calls = installVTStub();
    __setRouterBaseForTest("");
    setLocationPathname("/app/x");
    navigate("/app/y", { replace: true });
    await flush();
    expect(calls.length).toBe(0);
    expect(window.location.pathname).toBe("/app/y");
  });

  test("popstate wraps the flip too (fails without fix); route re-renders after the callback settles", async () => {
    setViewTransitions(true);
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" }); // binds popstate
    await flush();
    const calls = installVTStub();
    window.history.pushState(null, "", "/app/club/9");
    window.dispatchEvent(new Event("popstate"));
    await flush();
    expect(calls.length).toBe(1);
    expect(r.html()).toContain('data-id="9"');
    r.unmount();
  });

  // The fragment-entry exemption (__shouldRestoreOnPop) is orthogonal to
  // transitions — it decides whether `settle` restores scroll, not whether
  // the flip is wrapped — and is already pinned by "scroll restore on a
  // browser-created fragment entry" above; this just confirms popstate still
  // reaches emit() (via flipWithTransition) when scrollRestorationOn is off.
  test("popstate still flips when scroll restoration is off (the early-return branch)", async () => {
    setViewTransitions(true);
    setScrollRestoration(false);
    setLocationPathname("/app/");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/" });
    await flush();
    const calls = installVTStub();
    window.history.pushState(null, "", "/app/club/11");
    window.dispatchEvent(new Event("popstate"));
    await flush();
    expect(calls.length).toBe(1);
    expect(r.html()).toContain('data-id="11"');
    r.unmount();
  });

  test("a rejected updateCallbackDone (our flip threw) is routed to host.reportError, staying loud", async () => {
    setViewTransitions(true);
    const err = new Error("boom in transition");
    (document as any).startViewTransition = (cb: () => Promise<void> | void) => {
      cb();
      return { ready: Promise.resolve(), updateCallbackDone: Promise.reject(err) };
    };
    const reported: unknown[] = [];
    (window as any).zigapagosOnError = (msg: string) => reported.push(msg);
    __setRouterBaseForTest("");
    setLocationPathname("/app/x");
    navigate("/app/y");
    await flush();
    await flush(); // let the rejected updateCallbackDone's .catch handler run
    expect(reported.length).toBeGreaterThan(0);
    expect(String(reported[0])).toContain("boom in transition");
  });

  // A transition SKIPPED by a rapid follow-up navigation rejects `ready` —
  // normal flow, not an error. Without the wrapper's no-op `.catch()` this
  // would surface as unhandledrejection console noise.
  test("a rejected `ready` (skipped transition) is swallowed, not reported", async () => {
    setViewTransitions(true);
    (document as any).startViewTransition = (cb: () => Promise<void> | void) => {
      const p = Promise.resolve(cb());
      return { ready: Promise.reject(new Error("transition skipped")), updateCallbackDone: p };
    };
    const reported: unknown[] = [];
    (window as any).zigapagosOnError = (msg: string) => reported.push(msg);
    __setRouterBaseForTest("");
    setLocationPathname("/app/x");
    navigate("/app/y");
    await flush();
    await flush();
    expect(reported.length).toBe(0); // the skip is swallowed, not surfaced as an app error
  });
});

// --- Lazy (code-split) routes ---------------------------------------------
const HeavySkeleton = () => h("div", { "data-view": "heavy-skeleton" }, "loading heavy…");
const Heavy = () => h("div", { "data-view": "heavy", "data-heavy": "yes" }, "HEAVY CONTENT");

describe("Router lazy routes", () => {
  test("SSR renders the skeleton for a lazy route (chunk content never in the shell)", () => {
    const routes: RouteDef[] = [{ path: "/heavy", component: lazy(() => Promise.resolve({ default: Heavy })), skeleton: HeavySkeleton }];
    const App = () => h(Router, { base: "/app", routes });
    const html = ssrIsland(App, {}, { pathname: "/app/heavy" });
    expect(html).toContain('data-view="heavy-skeleton"');
    expect(html).not.toContain('data-heavy="yes"');
  });

  test("shows the skeleton until the chunk resolves, then flips to the loaded component", async () => {
    const d = deferred<{ default: ComponentType<any> }>();
    const routes: RouteDef[] = [{ path: "/", component: Home }, { path: "/heavy", component: lazy(() => d.promise), skeleton: HeavySkeleton }];
    const App = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/heavy");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/heavy" });
    await flush();
    expect(r.html()).toContain('data-view="heavy-skeleton"');
    expect(r.html()).not.toContain('data-heavy="yes"');
    d.resolve({ default: Heavy });
    await flush();
    expect(r.html()).toContain('data-heavy="yes"');
    expect(r.html()).not.toContain('data-view="heavy-skeleton"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a rejected loader keeps the skeleton and never crashes", async () => {
    const routes: RouteDef[] = [{ path: "/heavy", component: lazy(() => Promise.reject(new Error("chunk 404"))), skeleton: HeavySkeleton }];
    const App = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/heavy");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/heavy" });
    await flush();
    expect(r.html()).toContain('data-view="heavy-skeleton"');
    expect(r.html()).not.toContain('data-heavy="yes"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("two-phase hydrate: the skeleton hydrates cleanly, then flips to the chunk", async () => {
    const d = deferred<{ default: ComponentType<any> }>();
    const routes: RouteDef[] = [{ path: "/heavy", component: lazy(() => d.promise), skeleton: HeavySkeleton }];
    const App = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/heavy");
    const r = renderIsland(App, {}, { mode: "hydrate", pathname: "/app/heavy" });
    expect(r.html()).toContain('data-view="heavy-skeleton"');
    expect(r.html()).not.toContain('data-heavy="yes"');
    await flush(); // hydrated flips true; chunk still pending → still skeleton
    expect(r.html()).toContain('data-view="heavy-skeleton"');
    d.resolve({ default: Heavy });
    await flush();
    expect(r.html()).toContain('data-heavy="yes"');
    expect(r.html()).not.toContain('data-view="heavy-skeleton"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("composes with a guard scope: gated → fallback, authorized → skeleton → chunk", async () => {
    let verdict: GuardResult = true;
    const d = deferred<{ default: ComponentType<any> }>();
    const routes: RouteDef[] = [
      { path: "/login", component: LoginView },
      { path: "/heavy", component: lazy(() => d.promise), skeleton: HeavySkeleton, guard: async () => verdict },
    ];
    const App = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/heavy");
    const r = renderIsland(App, {}, { mode: "render", pathname: "/app/heavy" });
    // Gated first: the guard fallback, NOT the skeleton or chunk.
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-heavy="yes"');
    await flush(); // guard authorizes → skeleton (chunk still pending)
    expect(r.html()).toContain('data-view="heavy-skeleton"');
    expect(r.html()).not.toContain('data-heavy="yes"');
    d.resolve({ default: Heavy });
    await flush();
    expect(r.html()).toContain('data-heavy="yes"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("the lazy() marker THROWS when rendered directly (React.lazy misuse is loud, not silently empty)", () => {
    // Via the compat bridge an npm component's React.lazy resolves to THIS lazy
    // (one shared runtime, one `lazy`). Rendering the returned component invokes
    // the marker — which must throw a helpful error, not render nothing.
    const C = lazy(() => Promise.resolve({ default: Heavy })) as (p: any) => unknown;
    expect(() => C({})).toThrow(/lazy\(\) component was rendered directly/);
  });

  test("SSR of a lazy route with NO skeleton throws (misconfig is loud, not an empty shell)", () => {
    // `skeleton ?? component` falls through to the lazy marker when no skeleton is
    // declared; that used to SSR an empty node silently. It now throws loudly.
    const routes: RouteDef[] = [{ path: "/heavy", component: lazy(() => Promise.resolve({ default: Heavy })) }];
    const App = () => h(Router, { base: "/app", routes });
    expect(() => ssrIsland(App, {}, { pathname: "/app/heavy" })).toThrow(/lazy\(\) component was rendered directly/);
  });
});

// --- Hover/viewport lazy-chunk prefetch (issue #128) ------------------------
// `<Link>` starts a lazy leaf's chunk load early (default: on hover/focus/
// touchstart) via `RouterCtx.prefetch`, sharing the in-flight promise with the
// real navigation load (`startLazyLoad`) so the two never double-fetch.
// A minimal fake `IntersectionObserver`: happy-dom's real one never fires on
// its own (no actual layout/viewport), so `prefetch="viewport"` tests install
// this in its place, capture the callback per instance, and `fire()` it by
// hand — mirroring the plan's "stub a global IntersectionObserver capturing
// observe/callback" approach.
class FakeIntersectionObserver {
  static instances: FakeIntersectionObserver[] = [];
  callback: IntersectionObserverCallback;
  observed: Element[] = [];
  disconnected = false;
  constructor(cb: IntersectionObserverCallback) {
    this.callback = cb;
    FakeIntersectionObserver.instances.push(this);
  }
  observe(el: Element) { this.observed.push(el); }
  unobserve(_el: Element) {}
  disconnect() { this.disconnected = true; }
  takeRecords(): IntersectionObserverEntry[] { return []; }
  fire(isIntersecting: boolean) {
    this.callback(
      this.observed.map((target) => ({ isIntersecting, target }) as IntersectionObserverEntry),
      this as unknown as IntersectionObserver,
    );
  }
}

describe("Router prefetch", () => {
  const hover = async (el: Element) => {
    el.dispatchEvent(new Event("mouseenter", { bubbles: true }));
    await flush();
  };

  test("hover prefetches a lazy route's chunk without navigating", async () => {
    let calls = 0;
    const d = deferred<{ default: ComponentType<any> }>();
    const loader = () => { calls++; return d.promise; };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(calls).toBe(0); // no fetch just from rendering the Link
    await hover(r.get('[data-testid="go"]'));
    expect(calls).toBe(1);
    expect(window.location.pathname).toBe("/app/"); // hover never navigates
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a second hover does not re-invoke the loader (in-flight promise is cached), and navigating after resolve renders the real component with no further loader call", async () => {
    let calls = 0;
    const d = deferred<{ default: ComponentType<any> }>();
    const loader = () => { calls++; return d.promise; };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    const link = r.get('[data-testid="go"]');
    await hover(link);
    await hover(link); // second hover — same in-flight promise, no second loader call
    expect(calls).toBe(1);
    d.resolve({ default: Heavy });
    await flush();
    await click(link); // real navigation
    expect(window.location.pathname).toBe("/app/heavy");
    expect(r.html()).toContain('data-heavy="yes"');
    expect(calls).toBe(1); // still just the one prefetch call — navigation reused it
    r.unmount();
    setLocationPathname("/app/");
  });

  test("hover on a non-lazy target is a no-op (no loader to call, nothing throws)", async () => {
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/booking", "data-testid": "go" }, "booking") },
      { path: "/booking", component: Booking },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    await hover(r.get('[data-testid="go"]')); // must not throw
    expect(window.location.pathname).toBe("/app/");
    r.unmount();
    setLocationPathname("/app/");
  });

  test("hover on an external href is a no-op", async () => {
    let calls = 0;
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "http://localhost/other", "data-testid": "go" }, "out") },
      { path: "/heavy", component: lazy(() => { calls++; return Promise.resolve({ default: Heavy }); }), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    await hover(r.get('[data-testid="go"]'));
    expect(calls).toBe(0);
    r.unmount();
    setLocationPathname("/app/");
  });

  test("prefetch={false} disables hover prefetch", async () => {
    let calls = 0;
    const loader = () => { calls++; return Promise.resolve({ default: Heavy }); };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", prefetch: false, "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    await hover(r.get('[data-testid="go"]'));
    expect(calls).toBe(0);
    r.unmount();
    setLocationPathname("/app/");
  });

  test('prefetch="viewport" fires the loader once on first intersection, and disconnects the observer', async () => {
    let calls = 0;
    const loader = () => { calls++; return Promise.resolve({ default: Heavy }); };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", prefetch: "viewport", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");

    const realIO = (globalThis as any).IntersectionObserver;
    FakeIntersectionObserver.instances = [];
    (globalThis as any).IntersectionObserver = FakeIntersectionObserver;
    try {
      const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
      await flush();
      expect(FakeIntersectionObserver.instances.length).toBe(1);
      const io = FakeIntersectionObserver.instances[0];
      expect(io.observed.length).toBe(1);
      expect(calls).toBe(0); // observing alone doesn't prefetch
      io.fire(true);
      await flush();
      expect(calls).toBe(1);
      expect(io.disconnected).toBe(true); // one-shot: disconnects itself after firing
      // A second (spurious) intersection callback must not re-fire the loader.
      io.fire(true);
      await flush();
      expect(calls).toBe(1);
      r.unmount();
    } finally {
      (globalThis as any).IntersectionObserver = realIO;
      setLocationPathname("/app/");
    }
  });

  test('prefetch="viewport" disconnects its observer on unmount even if never intersected', async () => {
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", prefetch: "viewport", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(() => Promise.resolve({ default: Heavy })), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");

    const realIO = (globalThis as any).IntersectionObserver;
    FakeIntersectionObserver.instances = [];
    (globalThis as any).IntersectionObserver = FakeIntersectionObserver;
    try {
      const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
      await flush();
      expect(FakeIntersectionObserver.instances[0].disconnected).toBe(false);
      r.unmount();
      expect(FakeIntersectionObserver.instances[0].disconnected).toBe(true);
    } finally {
      (globalThis as any).IntersectionObserver = realIO;
      setLocationPathname("/app/");
    }
  });

  test("the Astro-standard save-data guard suppresses prefetching (navigator.connection.saveData)", async () => {
    let calls = 0;
    const loader = () => { calls++; return Promise.resolve({ default: Heavy }); };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const prevConn = (navigator as any).connection;
    (navigator as any).connection = { saveData: true };
    try {
      const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
      await flush();
      await hover(r.get('[data-testid="go"]'));
      expect(calls).toBe(0);
      r.unmount();
    } finally {
      (navigator as any).connection = prevConn;
      setLocationPathname("/app/");
    }
  });

  test("a saveData=false / no-connection environment still prefetches (default posture)", () => {
    const prevConn = (navigator as any).connection;
    delete (navigator as any).connection;
    try {
      expect(__prefetchAllowedForTest()).toBe(true);
      (navigator as any).connection = { saveData: false, effectiveType: "4g" };
      expect(__prefetchAllowedForTest()).toBe(true);
      (navigator as any).connection = { effectiveType: "slow-2g" };
      expect(__prefetchAllowedForTest()).toBe(false);
    } finally {
      (navigator as any).connection = prevConn;
    }
  });

  test("a TRANSIENT prefetch failure does not set `failed` — the real navigation load gets a fresh attempt and succeeds", async () => {
    let calls = 0;
    const d2 = deferred<{ default: ComponentType<any> }>();
    const loader = () => {
      calls++;
      if (calls === 1) return Promise.reject(new Error("offline hover"));
      return d2.promise;
    };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    await hover(r.get('[data-testid="go"]')); // call #1 — rejects
    expect(calls).toBe(1);
    // Navigate for real; the lazy-load effect must get its OWN fresh attempt
    // (call #2), not inherit the prefetch's rejection.
    await click(r.get('[data-testid="go"]'));
    await flush();
    expect(calls).toBe(2);
    expect(r.html()).toContain('data-view="heavy-skeleton"'); // still pending
    d2.resolve({ default: Heavy });
    await flush();
    expect(r.html()).toContain('data-heavy="yes"'); // succeeded — `failed` was never latched
    r.unmount();
    setLocationPathname("/app/");
  });

  test("hovering a Link to a `redirect` entry prefetches the TARGET's lazy chunk", async () => {
    let calls = 0;
    const loader = () => { calls++; return Promise.resolve({ default: Heavy }); };
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/old", "data-testid": "go" }, "old") },
      { path: "/old", redirect: "/heavy" },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    await hover(r.get('[data-testid="go"]'));
    expect(calls).toBe(1); // the redirect TARGET's chunk, not a no-op
    r.unmount();
    setLocationPathname("/app/");
  });

  test("prefetch wiring chains, never clobbers, a caller's own hover handlers", async () => {
    // The hover/focus/touch handlers are Link-internal now; a consumer passing
    // their own must keep getting called, or their code breaks with no error
    // anywhere.
    let calls = 0;
    let callerHovers = 0;
    let callerFocuses = 0;
    const loader = () => { calls++; return Promise.resolve({ default: Heavy }); };
    const routes: RouteDef[] = [
      {
        path: "/",
        component: () =>
          h(Link, {
            href: "/heavy",
            "data-testid": "go",
            onMouseEnter: () => { callerHovers++; },
            onFocus: () => { callerFocuses++; },
          }, "heavy"),
      },
      { path: "/heavy", component: lazy(loader), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    const link = r.get('[data-testid="go"]');
    link.dispatchEvent(new Event("focusin", { bubbles: true }));
    await flush();
    expect(callerFocuses).toBe(1);
    await hover(link);
    expect(callerHovers).toBe(1); // caller handler still fired
    expect(calls).toBe(1); // and the prefetch still happened (once)
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a prefetch that resolves BETWEEN the navigation render and its lazy effect still flips off the skeleton", async () => {
    // Preact renders on a microtask but flushes `useEffect` after paint, so
    // there is a whole frame in which a hover-started chunk can resolve after
    // the navigation render has already read `lz.comp` as unset. If the
    // prefetch's resolve is the one that populates `lz.comp`, the lazy-load
    // effect's `leafLazy.comp` early-return fires and NOTHING re-renders --
    // the route is stranded on its skeleton forever.
    const d = deferred<{ default: ComponentType<any> }>();
    const routes: RouteDef[] = [
      { path: "/", component: () => h(Link, { href: "/heavy", "data-testid": "go" }, "heavy") },
      { path: "/heavy", component: lazy(() => d.promise), skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(PfApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    const link = r.get('[data-testid="go"]');
    await hover(link); // prefetch in flight
    (link as HTMLElement).click(); // navigate -- render is a microtask, effects are post-paint
    await Promise.resolve();
    await Promise.resolve();
    d.resolve({ default: Heavy }); // lands in the render->effect window
    await flush();
    expect(r.html()).toContain('data-heavy="yes"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("SSR byte-stability: a default-prefetch Link renders identical anchor markup — no `prefetch` attribute leaks", () => {
    const LinkOnly = () => h(Link, { href: "/heavy", "data-testid": "go" }, "heavy");
    const routes: RouteDef[] = [
      { path: "/", component: LinkOnly },
      { path: "/heavy", component: Heavy, skeleton: HeavySkeleton },
    ];
    const PfApp = () => h(Router, { base: "/app", routes });
    const html = ssrIsland(PfApp, {}, { pathname: "/app/" });
    expect(html).toContain('<a href="/app/heavy" data-testid="go">heavy</a>');
  });
});

// --- Declarative redirect routes --------------------------------------------
// `{ path: "/", redirect: "/dashboard" }`: the router resolves the redirect
// BEFORE rendering (SSR included), so the target's view renders immediately —
// no throwaway frame — and the browser URL is replace-synced to the target
// (base-relative, consistent with `navigate()`).
describe("declarative redirect routes", () => {
  const Dashboard = () => h("div", { "data-view": "dashboard" }, "dash");
  const redirRoutes: RouteDef[] = [
    { path: "/", redirect: "/dashboard" },
    { path: "/dashboard", component: Dashboard },
    { path: "/login", component: LoginView },
    { path: "/legacy", redirect: "/" }, // a chain: /legacy -> / -> /dashboard
    { path: "/gone", redirect: "/nowhere" }, // target matches no route
    { path: "/loop-a", redirect: "/loop-b" },
    { path: "/loop-b", redirect: "/loop-a" }, // a cycle
  ];
  const RedirApp = () =>
    h(Router, { base: "/app", routes: redirRoutes, notFound: () => h("div", { "data-view": "nf" }, "nf") });

  test("SSR of a redirect route renders the TARGET's view (the shell carries real content)", () => {
    const html = ssrIsland(RedirApp, {}, { pathname: "/app/" });
    expect(html).toContain('data-view="dashboard"');
  });

  test("client initial load on a redirect route: target renders on the FIRST frame, URL replace-syncs", async () => {
    setLocationPathname("/app/");
    const len0 = window.history.length;
    const r = renderIsland(RedirApp, {}, { mode: "render", pathname: "/app/" });
    // The very first render is already the target — never a throwaway frame.
    expect(r.html()).toContain('data-view="dashboard"');
    await flush();
    expect(window.location.pathname).toBe("/app/dashboard");
    expect(window.history.length).toBe(len0); // replace, not push
    expect(r.html()).toContain('data-view="dashboard"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("soft-nav to a redirect route lands on the target via a replace", async () => {
    setLocationPathname("/app/dashboard");
    const r = renderIsland(RedirApp, {}, { mode: "render", pathname: "/app/dashboard" });
    await flush();
    navigate("/login");
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    const len0 = window.history.length;
    navigate("/"); // pushes /app/, which the redirect entry replaces with /app/dashboard
    await flush();
    expect(window.location.pathname).toBe("/app/dashboard");
    expect(window.history.length).toBe(len0 + 1); // ONE new entry (the push), replaced in place
    expect(r.html()).toContain('data-view="dashboard"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a redirect chain follows to the final target", async () => {
    setLocationPathname("/app/legacy");
    const r = renderIsland(RedirApp, {}, { mode: "render", pathname: "/app/legacy" });
    expect(r.html()).toContain('data-view="dashboard"');
    await flush();
    expect(window.location.pathname).toBe("/app/dashboard");
    r.unmount();
    setLocationPathname("/app/");
  });

  test("the query string is preserved across the redirect", async () => {
    window.history.replaceState(null, "", "/app/?tab=x");
    const r = renderIsland(RedirApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(window.location.pathname).toBe("/app/dashboard");
    expect(window.location.search).toBe("?tab=x");
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a redirect to an unmatched target renders notFound and leaves the URL alone", async () => {
    setLocationPathname("/app/gone");
    const r = renderIsland(RedirApp, {}, { mode: "render", pathname: "/app/gone" });
    await flush();
    expect(r.html()).toContain('data-view="nf"');
    expect(window.location.pathname).toBe("/app/gone");
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a redirect cycle renders notFound instead of looping", async () => {
    setLocationPathname("/app/loop-a");
    const r = renderIsland(RedirApp, {}, { mode: "render", pathname: "/app/loop-a" });
    await flush();
    expect(r.html()).toContain('data-view="nf"');
    expect(window.location.pathname).toBe("/app/loop-a");
    r.unmount();
    setLocationPathname("/app/");
  });
});

describe("describeRoutes redirect entries", () => {
  const C = () => null;
  test("ships the redirect target on the leaf meta (and prerenders the entry)", async () => {
    const metas = await describeRoutes([
      { path: "/", redirect: "/dashboard" },
      { path: "/dashboard", component: C },
    ]);
    expect(metas[0]).toMatchObject({ path: "/", dynamic: false, hasSkeleton: false, redirect: "/dashboard" });
    expect(metas[1].redirect).toBeUndefined();
  });
  test("a DYNAMIC redirect entry is exempt from the skeleton rule (nothing of its own hydrates)", async () => {
    // The dynamic-leaf skeleton enforcement must skip redirect
    // entries: they have no component, and both SSR and the first client
    // render show the TARGET's chain — there is nothing of the redirect
    // route's own to hydrate. Without the exemption this would throw
    // "dynamic route declares no skeleton".
    const metas = await describeRoutes([
      { path: "/old/:id", redirect: "/dashboard" },
      { path: "/dashboard", component: C },
    ]);
    expect(metas[0]).toMatchObject({ path: "/old/:id", dynamic: true, hasSkeleton: false, redirect: "/dashboard" });
  });
  test("throws when a route declares both redirect and component", async () => {
    await expect(describeRoutes([
      { path: "/", redirect: "/dashboard", component: C },
      { path: "/dashboard", component: C },
    ])).rejects.toThrow(/redirect/);
  });
  test("throws when a redirect is declared on a layout route (children present)", async () => {
    await expect(describeRoutes([
      { path: "/dash", redirect: "/x", children: [{ path: "/x", component: C }] },
    ])).rejects.toThrow(/redirect/);
  });
  test("throws when a route declares both redirect and staticPaths", async () => {
    await expect(describeRoutes([
      { path: "/old/:id", redirect: "/dashboard", staticPaths: [{ id: "1" }] },
      { path: "/dashboard", component: C },
    ])).rejects.toThrow(/redirect/);
  });
  test("throws when a redirect target is not a plain CONCRETE root-relative pathname", async () => {
    // Mirrors the Zig-side concreteness cases (src/spa.zig, `validateConcretePath`
    // + "a non-concrete target … is flagged"): the TS shape validator and the
    // build validator must agree on what a valid target is.
    for (const target of [
      "dashboard", "https://example.com/x", "//x/y", "/dash?tab=1", "/dash#top",
      "/club/:id", "/files/*", "/a/./b", "/a/../b",
    ]) {
      await expect(describeRoutes([
        { path: "/", redirect: target },
        { path: "/dashboard", component: C },
        { path: "/club/:id", component: C, skeleton: C },
      ])).rejects.toThrow(/redirect/);
    }
  });
  test("throws when a route has neither component nor redirect", async () => {
    await expect(describeRoutes([
      { path: "/" } as RouteDef,
    ])).rejects.toThrow(/component|redirect/);
  });
});

test("mountSpa is exported and callable", () => {
  expect(typeof mountSpa).toBe("function");
  setSsrPathname("/"); // reset shared SSR pathname for later tests
  window.history.replaceState(null, "", "/app/"); // reset search for later tests
});

import * as barrel from "./index.ts";

test("router symbols are re-exported from the @z/runtime barrel", () => {
  for (const sym of ["Router", "Link", "Outlet", "lazy", "useParams", "useLocation", "useNavigate", "useSearchParams", "setScrollRestoration", "setViewTransitions", "navigate", "matchChain", "matchRoute", "mountSpa", "isServer"]) {
    expect(typeof (barrel as any)[sym]).toBe("function");
  }
});

// --- staticPaths (getStaticPaths-style enumeration) ----------------------
describe("substituteRouteParams", () => {
  test("substitutes URL-safe :param values verbatim", () => {
    expect(substituteRouteParams("/club/:id", { id: "42" })).toBe("/club/42");
    expect(substituteRouteParams("/club/:id/tab/:tab", { id: "a-b", tab: "x_y" }))
      .toBe("/club/a-b/tab/x_y");
  });
  test("substitutes a trailing * from params['*'], keeping its slashes as segments", () => {
    expect(substituteRouteParams("/docs/*", { "*": "guide/intro" })).toBe("/docs/guide/intro");
  });
  test("throws on a missing param", () => {
    expect(() => substituteRouteParams("/club/:id", {})).toThrow(/missing param/);
  });
  test("throws (not encodes) on a non-URL-safe :param value", () => {
    // Previously encoded to /club/a%20b — that directory is written encoded to
    // disk but a decoding host never serves it, so the build must fail loudly.
    expect(() => substituteRouteParams("/club/:id", { id: "a b" })).toThrow(/staticPaths.*URL-safe/s);
    expect(() => substituteRouteParams("/club/:id", { id: "x/y" })).toThrow(/staticPaths.*URL-safe/s);
  });
  test("throws (not encodes) on a non-URL-safe catch-all segment", () => {
    expect(() => substituteRouteParams("/docs/*", { "*": "a b" })).toThrow(/staticPaths.*URL-safe/s);
  });
  test('rejects "..", "." and "" :param values (would clobber the root shell / escape the output dir)', () => {
    expect(() => substituteRouteParams("/club/:id", { id: ".." })).toThrow(/staticPaths/);
    expect(() => substituteRouteParams("/club/:id", { id: "." })).toThrow(/staticPaths/);
    expect(() => substituteRouteParams("/club/:id", { id: "" })).toThrow(/staticPaths/);
  });
  test('rejects a catch-all containing a ".." segment (would escape the output dir)', () => {
    expect(() => substituteRouteParams("/docs/*", { "*": "../../../x" })).toThrow(/staticPaths/);
  });
  test("rejects an empty/whitespace catch-all rather than producing the bare pattern dir", () => {
    expect(() => substituteRouteParams("/docs/*", { "*": "" })).toThrow(/staticPaths/);
    expect(() => substituteRouteParams("/docs/*", { "*": "   " })).toThrow(/staticPaths/);
  });
});

describe("describeRoutes", () => {
  const C = () => null;
  const Sk = () => null;
  test("resolves staticPaths (array form) into concrete paths on the dynamic leaf", async () => {
    const metas = await describeRoutes([
      { path: "/", component: C },
      { path: "/club/:id", component: C, skeleton: Sk, staticPaths: [{ id: "1" }, { id: "2" }] },
    ]);
    expect(metas[0].staticPaths).toBeUndefined();
    expect(metas[1]).toMatchObject({ path: "/club/:id", dynamic: true, staticPaths: ["/club/1", "/club/2"] });
  });
  test("resolves staticPaths (async function form)", async () => {
    const metas = await describeRoutes([
      { path: "/club/:id", component: C, skeleton: Sk, staticPaths: async () => [{ id: "9" }] },
    ]);
    expect(metas[0].staticPaths).toEqual(["/club/9"]);
  });
  test("nested routes: staticPaths substitutes into the FULL joined path", async () => {
    const metas = await describeRoutes([
      { path: "/dash", component: C, children: [
        { path: "/club/:id", component: C, skeleton: Sk, staticPaths: [{ id: "3" }] },
      ]},
    ]);
    expect(metas[0].staticPaths).toEqual(["/dash/club/3"]);
  });
  test("throws when staticPaths is declared on a static route (a config error, not a silent no-op)", async () => {
    await expect(describeRoutes([
      { path: "/about", component: C, staticPaths: [{}] },
    ])).rejects.toThrow(/staticPaths/);
  });
  test("throws when staticPaths is declared on a LAYOUT route (children present) — must be on the leaf", async () => {
    await expect(describeRoutes([
      { path: "/dash", component: C, staticPaths: [{ id: "1" }], children: [
        { path: "/club/:id", component: C, skeleton: Sk },
      ]},
    ])).rejects.toThrow(/staticPaths/);
  });

  // --- the docs' skeleton rule, enforced. A dynamic leaf (any
  // `:param`/`*` segment in its FULL path) whose SSR pathname substitutes
  // params with "_" renders differently on the first client render — a
  // hydration breaker unless the route has a param-independent `skeleton`
  // (or explicitly promises stability with `skeleton: false`). ---
  test("throws when a dynamic route (:param) lacks a skeleton, naming the route", async () => {
    await expect(describeRoutes([
      { path: "/", component: C },
      { path: "/club/:id", component: C },
    ])).rejects.toThrow(/"\/club\/:id".*skeleton/);
  });
  test("throws for a `*` catch-all route without a skeleton (same SSR-differs logic as :param)", async () => {
    await expect(describeRoutes([
      { path: "/docs/*", component: C },
    ])).rejects.toThrow(/"\/docs\/\*".*skeleton/);
  });
  test("a static child under a dynamic layout is a dynamic FULL path — the LEAF needs its own skeleton (layouts never render one)", async () => {
    await expect(describeRoutes([
      { path: "/club/:id", component: C, skeleton: Sk, children: [
        { path: "/details", component: C },
      ]},
    ])).rejects.toThrow(/"\/club\/:id\/details".*skeleton/);
  });
  test("skeleton: false is the explicit opt-out — the author asserts the component is hydration-stable", async () => {
    const metas = await describeRoutes([
      { path: "/club/:id", component: C, skeleton: false },
      { path: "/docs/*", component: C, skeleton: false },
    ]);
    expect(metas).toEqual([
      { path: "/club/:id", dynamic: true, hasSkeleton: false },
      { path: "/docs/*", dynamic: true, hasSkeleton: false },
    ]);
  });
  test("static routes never require a skeleton", async () => {
    const metas = await describeRoutes([
      { path: "/", component: C },
      { path: "/booking", component: C },
    ]);
    expect(metas.map((m) => m.path)).toEqual(["/", "/booking"]);
  });

  // --- lazy() routes are stricter (review follow-up): the marker component
  // cannot render until its chunk loads, so a lazy leaf needs a REAL
  // skeleton even on a static path, and skeleton: false (an impossible
  // hydration-stability promise for a not-yet-loaded component) is
  // rejected rather than honored as an opt-out. ---
  const lazyC = () => lazy(() => Promise.resolve({ default: C }));
  test("throws for a STATIC lazy route with no skeleton (would otherwise crash in SSR with the marker error)", async () => {
    await expect(describeRoutes([
      { path: "/heavy", component: lazyC() },
    ])).rejects.toThrow(/lazy route "\/heavy".*skeleton/);
  });
  test("throws for a lazy route with skeleton: false — the opt-out promise cannot hold for an unloaded component", async () => {
    await expect(describeRoutes([
      { path: "/heavy/:id", component: lazyC(), skeleton: false },
    ])).rejects.toThrow(/lazy route "\/heavy\/:id".*skeleton: false/);
    await expect(describeRoutes([
      { path: "/heavy", component: lazyC(), skeleton: false },
    ])).rejects.toThrow(/lazy route "\/heavy".*skeleton: false/);
  });
  test("a lazy route with a real skeleton passes (static and dynamic)", async () => {
    const metas = await describeRoutes([
      { path: "/heavy", component: lazyC(), skeleton: Sk },
      { path: "/heavy/:id", component: lazyC(), skeleton: Sk },
    ]);
    expect(metas).toEqual([
      { path: "/heavy", dynamic: false, hasSkeleton: true },
      { path: "/heavy/:id", dynamic: true, hasSkeleton: true },
    ]);
  });
});

// --- Guard data (useGuardData) ---------------------------------------------
// A guard may resolve `{ ok: true, data }` — authorized, carrying the object it
// fetched to decide (the session, the user). Anything under the guarded scope
// reads it with useGuardData(); nested guards: the NEAREST guarded ancestor
// wins. `true` stays valid (data = undefined).

describe("Router guard data (useGuardData)", () => {
  type User = { name: string; role?: string };

  const WhoAmI = () => {
    const user = useGuardData<User>();
    return h("div", { "data-view": "whoami", "data-user": user?.name ?? "(none)" }, user?.name ?? "anon");
  };

  test("a guard resolving { ok: true, data } authorizes AND surfaces the data via useGuardData", async () => {
    let dataGuard: () => Promise<GuardResult<User>> = async () => ({ ok: true, data: { name: "ada" } });
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/me", component: WhoAmI, guard: () => dataGuard() },
    ];
    const DataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/me");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/me" });
    expect(r.html()).toContain('data-view="guard-fallback"'); // pending → fallback
    await flush();
    expect(r.html()).toContain('data-user="ada"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a guard resolving plain `true` still authorizes; useGuardData is undefined", async () => {
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/me", component: WhoAmI, guard: async () => true },
    ];
    const DataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/me");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/me" });
    await flush();
    expect(r.html()).toContain('data-user="(none)"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("{ ok: true } with no data authorizes with undefined data", async () => {
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/me", component: WhoAmI, guard: async () => ({ ok: true as const }) },
    ];
    const DataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/me");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/me" });
    await flush();
    expect(r.html()).toContain('data-user="(none)"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("useGuardData outside any guarded scope is undefined", async () => {
    const routes: RouteDef[] = [{ path: "/", component: WhoAmI }];
    const DataApp = () => h(Router, { base: "/app", routes });
    setLocationPathname("/app/");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(r.html()).toContain('data-user="(none)"');
    r.unmount();
  });

  test("nested guards: the NEAREST guarded ancestor wins; the layout still sees ITS OWN guard's data", async () => {
    const OuterChrome = () => {
      const outer = useGuardData<User>();
      return h("div", { "data-view": "outer-chrome", "data-outer": outer?.name ?? "(none)" },
        h(Outlet, {}));
    };
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      {
        path: "/area", component: OuterChrome,
        guard: async () => ({ ok: true, data: { name: "outer-session" } }),
        children: [
          { path: "/me", component: WhoAmI, guard: async () => ({ ok: true, data: { name: "inner-user" } }) },
        ],
      },
    ];
    const NestedDataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/area/me");
    const r = renderIsland(NestedDataApp, {}, { mode: "render", pathname: "/app/area/me" });
    await flush();
    expect(r.html()).toContain('data-outer="outer-session"'); // layout: its own guard's data
    expect(r.html()).toContain('data-user="inner-user"');     // leaf: nearest (inner) guard wins
    r.unmount();
    setLocationPathname("/app/");
  });

  test("under a guarded layout, an UNGUARDED child sees the layout guard's data (nearest ancestor)", async () => {
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      {
        path: "/area", component: Layout,
        guard: async () => ({ ok: true, data: { name: "layout-user" } }),
        children: [{ path: "/me", component: WhoAmI }],
      },
    ];
    const NestedDataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/area/me");
    const r = renderIsland(NestedDataApp, {}, { mode: "render", pathname: "/app/area/me" });
    await flush();
    expect(r.html()).toContain('data-user="layout-user"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a Router-level guard's data reaches the whole matched tree", async () => {
    const routes: RouteDef[] = [{ path: "/me", component: WhoAmI }];
    const RouterGuardApp = () =>
      h(Router, {
        base: "/app", routes, fallback: GuardFallback,
        guard: async () => ({ ok: true as const, data: { name: "router-user" } }),
      });
    setLocationPathname("/app/me");
    const r = renderIsland(RouterGuardApp, {}, { mode: "render", pathname: "/app/me" });
    expect(r.html()).toContain('data-view="guard-fallback"');
    await flush();
    expect(r.html()).toContain('data-user="router-user"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a malformed guard result fails CLOSED: stays on the fallback, never paints", async () => {
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/me", component: WhoAmI, guard: (async () => ({ ok: false })) as any },
    ];
    const DataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/me");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/me" });
    await flush();
    expect(r.html()).toContain('data-view="guard-fallback"');
    expect(r.html()).not.toContain('data-view="whoami"');
    expect(window.location.pathname).toBe("/app/me"); // no redirect either
    r.unmount();
    setLocationPathname("/app/");
  });

  test("a CIRCULAR malformed guard result still fails closed with the real diagnostic (stringify guarded)", async () => {
    // A circular value would make an unguarded JSON.stringify in the error
    // path throw TypeError — masking the actual "invalid guard result"
    // message. The reported error must be the real diagnostic.
    const circular: any = { ok: false };
    circular.self = circular;
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/me", component: WhoAmI, guard: (async () => circular) as any },
    ];
    const DataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/me");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/me" });
    await flush();
    expect(r.html()).toContain('data-view="guard-fallback"'); // fail-closed, no crash
    expect(r.html()).not.toContain('data-view="whoami"');
    expect(r.host.errors.length).toBe(1);
    expect(r.host.errors[0]).toContain("invalid guard result"); // the REAL message…
    expect(r.host.errors[0]).not.toContain("circular");         // …not JSON.stringify's TypeError
    r.unmount();
    setLocationPathname("/app/");
  });

  test("{ redirect } keeps working alongside the data form", async () => {
    const routes: RouteDef[] = [
      { path: "/", component: Home },
      { path: "/login", component: LoginView },
      { path: "/me", component: WhoAmI, guard: async () => ({ redirect: "/login"  /* base-relative */ }) },
    ];
    const DataApp = () => h(Router, { base: "/app", routes, fallback: GuardFallback });
    setLocationPathname("/app/me");
    const r = renderIsland(DataApp, {}, { mode: "render", pathname: "/app/me" });
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).toContain('data-view="login"');
    r.unmount();
    setLocationPathname("/app/");
  });

  test("useGuardData is re-exported from the @z/runtime barrel", () => {
    expect(typeof (barrel as any).useGuardData).toBe("function");
  });
});

// --- Session-expiry policy (guard re-run on 401) ----------------------------
// While a guarded scope is active, a same-origin 401/403 seen by apiFetch
// re-runs the active route's guard pipeline ONCE — whose `{ redirect }`
// verdict then navigates away. Re-entrancy-safe: no re-run while a guard run
// is already in flight (so a guard's OWN probe 401ing can't recurse), and a
// cooldown stops a component that keeps 401ing from hammering the guard.

import { notifyUnauthorizedResponse } from "./session.ts";
import { __setUnauthorizedReRunCooldownForTest } from "./router.ts";
import { apiFetch } from "./api.ts";

describe("Router session-expiry (guard re-run on 401)", () => {
  type SessionGuard = () => Promise<GuardResult<any>>;
  let sessionGuard: SessionGuard = async () => true;
  let guardCalls = 0;
  const SecretView = () => h("div", { "data-view": "secret", "data-gated": "s" }, "S");
  const sessionRoutes: RouteDef[] = [
    { path: "/", component: Home },
    { path: "/login", component: LoginView },
    { path: "/secret", component: SecretView, guard: () => { guardCalls++; return sessionGuard(); } },
  ];
  const SessionApp = () =>
    h(Router, { base: "/app", routes: sessionRoutes, fallback: GuardFallback });

  const mountSecret = () => {
    setLocationPathname("/app/secret");
    return renderIsland(SessionApp, {}, { mode: "render", pathname: "/app/secret" });
  };

  test("a 401 notification re-runs the active guard; its { redirect } verdict navigates away", async () => {
    __setUnauthorizedReRunCooldownForTest(0);
    guardCalls = 0;
    sessionGuard = async () => true;
    const r = mountSecret();
    await flush();
    expect(r.html()).toContain('data-gated="s"');
    expect(guardCalls).toBe(1);

    // The session expires server-side; the next apiFetch 401s → policy fires.
    sessionGuard = async () => ({ redirect: "/login"  /* base-relative */ });
    notifyUnauthorizedResponse();
    await flush();
    expect(guardCalls).toBe(2);
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).toContain('data-view="login"');
    expect(r.html()).not.toContain('data-gated="s"');
    r.unmount();
    setLocationPathname("/app/");
    __setUnauthorizedReRunCooldownForTest();
  });

  test("a guard re-run verdict landing AFTER unmount neither navigates nor resolves against a stale base", async () => {
    __setUnauthorizedReRunCooldownForTest(0);
    guardCalls = 0;
    sessionGuard = async () => true;
    const r = mountSecret();
    await flush();
    expect(r.html()).toContain('data-gated="s"');

    // A 401 starts a re-run whose verdict is still pending when the Router
    // unmounts. The late { redirect } must be IGNORED (cancelled run) — and
    // because unmount also un-registers routerBase, nothing
    // after this point may resolve against the stale "/app".
    const d = deferred<GuardResult>();
    sessionGuard = () => d.promise;
    notifyUnauthorizedResponse();
    await flush();
    expect(guardCalls).toBe(2); // the re-run is in flight
    r.unmount();
    d.resolve({ redirect: "/login" });
    await flush();
    expect(window.location.pathname).toBe("/app/secret"); // no post-unmount navigation
    // And the module-level base really is un-registered: a direct navigate()
    // now resolves verbatim, not under the unmounted Router's "/app".
    navigate("/standalone");
    await flush();
    expect(window.location.pathname).toBe("/standalone");
    setLocationPathname("/app/");
    __setUnauthorizedReRunCooldownForTest();
  });

  test("no re-run while a guard run is already in flight (a guard's own 401 probe can't recurse)", async () => {
    __setUnauthorizedReRunCooldownForTest(0);
    guardCalls = 0;
    const d = deferred<GuardResult>();
    sessionGuard = () => d.promise;
    const r = mountSecret();
    expect(r.html()).toContain('data-view="guard-fallback"');
    await flush();
    expect(guardCalls).toBe(1); // initial run, still pending

    // The guard's own probe 401s mid-flight → must NOT start a second run.
    notifyUnauthorizedResponse();
    notifyUnauthorizedResponse();
    await flush();
    expect(guardCalls).toBe(1);

    d.resolve(true);
    await flush();
    expect(r.html()).toContain('data-gated="s"');
    expect(guardCalls).toBe(1);
    r.unmount();
    setLocationPathname("/app/");
    __setUnauthorizedReRunCooldownForTest();
  });

  test("the cooldown suppresses a second 401-triggered re-run (no loop when the guard keeps saying true)", async () => {
    __setUnauthorizedReRunCooldownForTest(60_000);
    guardCalls = 0;
    sessionGuard = async () => true;
    const r = mountSecret();
    await flush();
    expect(guardCalls).toBe(1);

    notifyUnauthorizedResponse(); // → one re-run
    await flush();
    expect(guardCalls).toBe(2);

    notifyUnauthorizedResponse(); // inside the cooldown window → suppressed
    notifyUnauthorizedResponse();
    await flush();
    expect(guardCalls).toBe(2);
    expect(r.html()).toContain('data-gated="s"'); // still authorized, still painted
    r.unmount();
    setLocationPathname("/app/");
    __setUnauthorizedReRunCooldownForTest();
  });

  test("a 401 on an UNGUARDED route is a no-op (policy applies inside guarded subtrees only)", async () => {
    __setUnauthorizedReRunCooldownForTest(0);
    guardCalls = 0;
    sessionGuard = async () => true;
    setLocationPathname("/app/");
    const r = renderIsland(SessionApp, {}, { mode: "render", pathname: "/app/" });
    await flush();
    expect(guardCalls).toBe(0);
    notifyUnauthorizedResponse();
    await flush();
    expect(guardCalls).toBe(0);
    expect(window.location.pathname).toBe("/app/");
    expect(r.html()).toContain('data-view="home"');
    r.unmount();
    __setUnauthorizedReRunCooldownForTest();
  });

  test("end-to-end: an apiFetch that 401s (same-origin) triggers the redirect", async () => {
    __setUnauthorizedReRunCooldownForTest(0);
    guardCalls = 0;
    sessionGuard = async () => true;
    const r = mountSecret();
    await flush();
    expect(r.html()).toContain('data-gated="s"');

    sessionGuard = async () => ({ redirect: "/login"  /* base-relative */ });
    const realFetch = globalThis.fetch;
    globalThis.fetch = (() => Promise.resolve(new Response("no", { status: 401 }))) as unknown as typeof fetch;
    try {
      const res = await apiFetch("/api/data"); // a component's data fetch
      expect(res.status).toBe(401);
    } finally {
      globalThis.fetch = realFetch;
    }
    await flush();
    expect(window.location.pathname).toBe("/app/login");
    expect(r.html()).toContain('data-view="login"');
    r.unmount();
    setLocationPathname("/app/");
    __setUnauthorizedReRunCooldownForTest();
  });
});

// ---------------------------------------------------------------------------
// Issue #23 — <Link> outside a <Router> is a build error, not a dead anchor.
// ---------------------------------------------------------------------------

describe("Link outside a Router (#23)", () => {
  test("SSR throws, naming the href and the escape hatch", () => {
    // The prerendered shell is the artifact that would ship the dead href, so
    // the build's SSR pass is where this has to fail.
    expect(() => ssrIsland(() => h(Link, { href: "/guides" }, "guides"), {}))
      .toThrow(/outside a <Router>/);
  });

  test("the client still renders the anchor, but warns exactly once per href", async () => {
    // Throwing during hydration would unmount the whole subtree — worse than
    // one link that does a full page load. Warn, render, carry on.
    const Bare = () => h("div", null, h(Link, { href: "/warn-once-href", "data-testid": "bare" }, "x"));
    const { warnings, restore } = spyConsoleWarn();
    const r = renderIsland(Bare, {}, { mode: "render", pathname: "/app/" });
    try {
      await flush();
      await r.rerender({} as any); // a second render of the same href must not re-warn
      expect(r.get('[data-testid="bare"]').getAttribute("href")).toBe("/warn-once-href");
      const outside = warnings.filter((w) => w.includes("rendered outside a <Router>"));
      expect(outside.length).toBe(1);
      expect(outside[0]).toContain("/warn-once-href");
    } finally {
      restore();
      r.unmount();
    }
  });
});

// ---------------------------------------------------------------------------
// Issue #26 — the site's url_path_prefix composes into the Router's base.
//
// The build SSRs at the PREFIXED pathname and the shell carries the prefix on
// its hydration root, so both environments compute the same effective base and
// the prerendered <a href> is the real, deployable URL. Preact's hydrate() does
// not diff attributes, so anything less leaves the wrong href stuck in the DOM.
// ---------------------------------------------------------------------------

describe("url_path_prefix composition (#26)", () => {
  test("setUrlPathPrefix normalizes every spelling of the config value", () => {
    setUrlPathPrefix("myrepo");
    expect(getUrlPathPrefix()).toBe("/myrepo");
    setUrlPathPrefix("/myrepo/");
    expect(getUrlPathPrefix()).toBe("/myrepo");
    setUrlPathPrefix("/myrepo");
    expect(getUrlPathPrefix()).toBe("/myrepo");
    setUrlPathPrefix("");
    expect(getUrlPathPrefix()).toBe("");
  });

  test("SSR: the prefix reaches <Link> hrefs and the route still matches", () => {
    setUrlPathPrefix("/myrepo");
    try {
      const html = ssrIsland(App, {}, { pathname: "/myrepo/app/" });
      // Matched at the FULL pathname the browser will actually have...
      expect(html).toContain('data-view="home"');
      // ...and the anchor is the real deployable URL, not "/app/booking".
      expect(html).toContain('href="/myrepo/app/booking"');
      expect(html).not.toContain('href="/app/booking"');
    } finally {
      setUrlPathPrefix("");
    }
  });

  test("SSR with no prefix is unchanged", () => {
    setUrlPathPrefix("");
    const html = ssrIsland(App, {}, { pathname: "/app/" });
    expect(html).toContain('href="/app/booking"');
    expect(html).not.toContain("/myrepo");
  });

  test("client: a soft-nav pushes the PREFIXED url, so a hard refresh still resolves", async () => {
    setUrlPathPrefix("/myrepo");
    setLocationPathname("/myrepo/app/");
    try {
      const r = renderIsland(App, {}, { mode: "render", pathname: "/myrepo/app/" });
      await flush();
      expect(r.html()).toContain('data-view="home"');
      expect((r.get('[data-testid="go"]') as HTMLAnchorElement).getAttribute("href"))
        .toBe("/myrepo/app/booking");
      await click(r.get('[data-testid="go"]'));
      await flush();
      expect(window.location.pathname).toBe("/myrepo/app/booking");
      expect(r.html()).toContain('data-view="booking"');
      r.unmount();
    } finally {
      setUrlPathPrefix("");
      setLocationPathname("/app/");
    }
  });

  test("mountSpa reads the prefix off the shell's hydration root", () => {
    setUrlPathPrefix("");
    const root = document.createElement("div");
    root.id = "z-spa-root-prefix-probe";
    root.setAttribute("data-z-prefix", "/myrepo");
    document.body.appendChild(root);
    try {
      mountSpa(() => h("div", null, "x"), "#z-spa-root-prefix-probe");
      expect(getUrlPathPrefix()).toBe("/myrepo");
    } finally {
      root.remove();
      setUrlPathPrefix("");
    }
  });

  test("mountSpa on a shell with no data-z-prefix clears a stale prefix", () => {
    setUrlPathPrefix("/stale");
    const root = document.createElement("div");
    root.id = "z-spa-root-noprefix-probe";
    document.body.appendChild(root);
    try {
      mountSpa(() => h("div", null, "x"), "#z-spa-root-noprefix-probe");
      expect(getUrlPathPrefix()).toBe("");
    } finally {
      root.remove();
      setUrlPathPrefix("");
    }
  });
});
