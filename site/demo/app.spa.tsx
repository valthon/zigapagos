import { Router, host, type GuardResult } from "@z/runtime";
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

// `base` is just `spa.base`. The site's `url_path_prefix` ("zigapagos") is
// composed onto it INSIDE <Router> (issue #26): the build now SSRs each route
// at the prefixed pathname and bakes the prefix into the shell's
// `data-z-prefix`, so the server and the first client render compute the same
// effective base — and the prerendered nav hrefs are the real
// "/zigapagos/demos/app/…" addresses, which work without JavaScript. This file
// used to carry an `isServer() ? spa.base : "/zigapagos" + spa.base` hack for
// exactly this; it is gone because the framework now owns the composition, and
// re-adding it here would double-count the prefix.
export default function App() {
  // build.zig's `.not_found = "app"` makes this SPA's own "/" shell the
  // site-wide 404.html — the marketing site overrides that with its own
  // content/404.smd (aliased onto /404.html, written after the SPA
  // prerender pass), so a mistyped URL lands on the real 404 page, not
  // here. A future route added to this table without `staticPaths` still
  // deep-links fine (the client router picks it up after boot); it's only
  // the pre-hydration fallback for an UNMATCHED path that the site 404
  // owns instead of this SPA.
  return <Router base={spa.base} routes={routes} notFound={NotFound} fallback={GuardFallback} />;
}
