import { Router, host, isServer, type GuardResult } from "@z/runtime";
import {
  AppShell, Home, GuidesLayout, GuidesIndex, Guide, GuideSkeleton,
  Account, Denied, NotFound, GuardFallback,
} from "./views.tsx";

export const spa = {
  base: "/demos/app",
  title: "Zigapagos SPA demo",
  // Shells otherwise carry only the import map + boot script — no stylesheet
  // — so without this hook the demo reached from the homepage CTA would
  // render unstyled. Hrefs are prefixed (url_path_prefix = "zigapagos" in
  // zigapagos.ziggy): `spa.head` emits the href VERBATIM into the shell, it
  // only strips the prefix to resolve the local file for the staging check,
  // so an unprefixed href here would 404 on Pages the same way an unprefixed
  // bundle/runtime URL would.
  head: [
    { rel: "stylesheet", href: "/zigapagos/tokens.css" },
    { rel: "stylesheet", href: "/zigapagos/style.css" },
  ],
};

// Client-only gate. The shell is served statically to anyone; the check runs
// after mount, which is what lets a guarded route still be a static file.
const requireSession = async (): Promise<GuardResult> =>
  host.cookies.get("zp_demo_session") === "ok" ? true : { redirect: "/denied" };

// AppShell is itself a layout rung (not a JSX wrapper around <Router>): a
// component rendered outside the Router's own tree never sees router
// context, so a Link there can't resolve a base-relative href or intercept
// its click (see AppShell's doc comment in views.tsx). Making it the root
// route and giving it an <Outlet/> puts its nav inside the routed tree,
// where Router's context provider actually reaches it.
export const routes = [
  {
    path: "/", component: AppShell, children: [
      { path: "/", component: Home },
      {
        path: "/guides", component: GuidesLayout, children: [
          { path: "/", component: GuidesIndex },
          { path: "/:slug", component: Guide, skeleton: GuideSkeleton, staticPaths: () => [{ slug: "islands" }] },
        ],
      },
      { path: "/denied", component: Denied },
      { path: "/account", component: Account, guard: requireSession },
    ],
  },
];

// @z/runtime's Router has no built-in notion of the site's `url_path_prefix`
// — AUDF-005 (src/spa.zig) only prefixes the shell's ASSET urls
// (bundle/runtime/chunk); the client router's own `base` is untouched. The
// build's SSR pass simulates each route at a pathname built from the
// module's raw `spa.base` (src/spa.zig's `ssr_pathname`, e.g.
// "/demos/app/guides" — unprefixed, per its own tests), but the deployed
// BROWSER's `window.location.pathname` always carries the prefix: GitHub
// Pages serves this project under /zigapagos/, and `zigapagos serve`'s
// url_path_prefix strip (src/cli/serve.zig) mirrors that for local preview
// too, so it's never actually unprefixed in a real request. One literal
// can't satisfy both matches, so `isServer()` — the framework's own hook for
// exactly this SSR/client split — picks the right one per environment; both
// branches resolve to the SAME logical route, so the matched CONTENT (the
// SSR'd skeleton and the first client render) still agree — hydration-safe.
//
// KNOWN LIMITATION: the nav's <a href> ATTRIBUTE values are a different
// story. They're computed from this same `base` inside <Link>, so they
// legitimately differ between the SSR'd shell (unprefixed) and the first
// client render (prefixed) — and Preact's hydrate() does not diff element
// attributes on that first pass (docs/spa.md's "Caveat (dynamic layouts)"
// documents the same constraint for a param bound to an attribute). So the
// visible href in the static shell — and in the DOM, indefinitely, since a
// value that never changes again across renders never gets rediffed either —
// stays at the unprefixed form. Clicking still soft-navigates correctly (the
// onClick closure captures the freshly-resolved, correctly-prefixed target
// each render, independent of the stale attribute) — verified against real
// Chromium by site/test/spa_playwright.py (Task 12's Playwright smoke),
// which drives a click and confirms both the URL change and that
// window.__zp_marker survives, i.e. no full reload. What's for certain
// either way: "view source" or "copy link" on the nav shows an address one
// segment short of the real one.
// Fixing that for real needs the framework to learn `url_path_prefix`
// (nothing in `@z/runtime` exposes it today), which is out of scope for this
// SPA's own source.
export default function App() {
  const routerBase = isServer() ? spa.base : "/zigapagos" + spa.base;
  // build.zig's `.not_found = "app"` makes this SPA's own "/" shell the
  // site-wide 404.html — the marketing site overrides that with its own
  // content/404.smd (aliased onto /404.html, written after the SPA
  // prerender pass), so a mistyped URL lands on the real 404 page, not
  // here. A future route added to this table without `staticPaths` still
  // deep-links fine (the client router picks it up after boot); it's only
  // the pre-hydration fallback for an UNMATCHED path that the site 404
  // owns instead of this SPA.
  return <Router base={routerBase} routes={routes} notFound={NotFound} fallback={GuardFallback} />;
}
