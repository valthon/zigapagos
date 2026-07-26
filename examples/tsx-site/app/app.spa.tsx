import { Router, host, lazy, type GuardResult } from "@z/runtime";
import {
  AppShell, Home, Booking, Wizard, ClubDetail, ClubSkeleton, NotFound,
  Secret, Login, GuardFallback,
  DashLayout, DashOverview, DashSettings,
  MembersArea, MembersProfile, MembersBilling,
  HeavySkeleton,
} from "./views/index.ts";

export const spa = {
  base: "/app",
  title: "pilot-site app",
  noindex: true,
  // Baked flag defaults: snapshotted into every shell as a
  // data-z-flags JSON data block; useFlag's first render sees these.
  flags: { bookAsGuest: true, promoBanner: false },
};

// Client-only auth gate. In a real app this hits a same-origin session-check
// endpoint; here it reads a cookie the browser sends, so the shell can be
// served statically to anyone while the actual gate runs after mount. Anon
// visitors are soft-redirected to /app/login; members see /app/secret.
// The redirect target is BASE-RELATIVE: "/login" resolves under spa.base.
const requireAuth = async (): Promise<GuardResult> =>
  host.cookies.get("z_session") === "ok" ? true : { redirect: "/login" };

// Client-only lifecycle hook: the browser entry calls this before
// the first render/hydration; the SSR sidecar never does. Module-load side
// effects (error relays, persisted-theme application, …) belong HERE — the
// module top level also executes under build-time SSR, so it must stay
// import-only. The marker below is asserted by spa_playwright.py (present in
// the browser) and spa_flags.sh (absent from the prerendered shells).
export function clientInit(): void {
  document.documentElement.setAttribute("data-client-init", "ran");
}

export const routes = [
  { path: "/", component: Home },
  // Declarative redirect: /home is an alias for the index route. The
  // target is BASE-RELATIVE ("/" -> /app/); the router renders the
  // target's view immediately (this entry's shell carries Home's SSR — no
  // throwaway frame) and replace-syncs the URL. The build validates the
  // target against this same route table.
  { path: "/home", redirect: "/" },
  { path: "/booking", component: Booking },
  { path: "/wizard", component: Wizard },
  { path: "/club/:id", component: ClubDetail, skeleton: ClubSkeleton,
    staticPaths: () => [{ id: "1" }, { id: "2" }] },
  { path: "/login", component: Login },
  { path: "/secret", component: Secret, guard: requireAuth },
  // Code-split route: Heavy loads as its own chunk on demand (kept out of the
  // entry bundle). HeavySkeleton shows on SSR + first client render.
  { path: "/heavy", component: lazy(() => import("./views/Heavy.tsx")), skeleton: HeavySkeleton },
  {
    path: "/dash", component: DashLayout, children: [
      { path: "/overview", component: DashOverview },
      { path: "/settings", component: DashSettings },
    ],
  },
  {
    // A GUARDED layout: the guard cascades to every child, so the members chrome
    // + tabs render only once authorized, and moving between the tabs keeps this
    // layout mounted (per-scope auth) — proven by test/spa_nested_guarded_playwright.py.
    path: "/members", component: MembersArea, guard: requireAuth, children: [
      { path: "/profile", component: MembersProfile },
      { path: "/billing", component: MembersBilling },
    ],
  },
];

export default function App() {
  return (
    <AppShell>
      <Router base={spa.base} routes={routes} notFound={NotFound} fallback={GuardFallback} />
    </AppShell>
  );
}
