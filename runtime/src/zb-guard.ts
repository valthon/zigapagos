// ---------------------------------------------------------------------------
// zbGuard — the ZigBase deploy-target's built-in auth guard
// factory. A gated SPA deployed against ZigBase shouldn't hand-roll a session
// probe against "some authed endpoint it happens to have": ZigBase's
// PocketBase-lineage API has a canonical session-introspection route per auth
// collection — `POST /api/collections/{collection}/auth-refresh` — which
// validates the current cookie session and returns the authenticated identity.
//
//   guard: zbGuard({ collection: "_superusers", redirect: "/login" })
//
// `redirect` is BASE-RELATIVE, like every guard redirect: it is handed
// verbatim to the Router, whose navigate() resolves it under spa.base — so
// "/login" in an SPA mounted at /admin lands on /admin/login.
//
// Fail-closed BY CONSTRUCTION: any network error or non-OK response resolves
// `{ redirect }` (never throws into the Router, never authorizes on doubt).
// On success it resolves `{ ok: true, data: identity }`, so the identity slots
// straight into guard data (useGuardData) — and because the probe goes
// through apiFetch (same-origin credentials + CSRF echo), it composes with the
// session-expiry policy: a mid-session 401 re-runs this guard, which
// then issues the redirect. (The Router's in-flight suppression keeps the
// probe's own 401 from recursing.)
// ---------------------------------------------------------------------------

import { apiFetch } from "./api.ts";
import type { GuardLocation, GuardResult } from "./router.ts";

export type ZbGuardOptions = {
  /** The ZigBase auth collection to introspect (e.g. "_superusers", "customers"). */
  collection: string;
  /**
   * Where to send an unauthenticated (or unverifiable) visitor. BASE-RELATIVE
   * (resolved under `spa.base` by the Router's navigate, like every guard
   * redirect): `"/login"`, not `"/admin/login"`.
   */
  redirect: string;
};

/**
 * Build a route/Router guard that authenticates against the ZigBase backend
 * the site is deployed on. `T` is the identity's shape (the auth record); it
 * is what `useGuardData<T>()` returns under the guarded scope.
 */
export function zbGuard<T = Record<string, unknown>>(
  opts: ZbGuardOptions,
): (loc: GuardLocation) => Promise<GuardResult<T>> {
  const url = `/api/collections/${encodeURIComponent(opts.collection)}/auth-refresh`;
  return async (_loc: GuardLocation): Promise<GuardResult<T>> => {
    try {
      const res = await apiFetch(url, { method: "POST" });
      if (!res.ok) return { redirect: opts.redirect };
      // Authenticated. The auth-refresh envelope is `{ token, record }`; the
      // guarded subtree wants the identity, so unwrap `record` when present
      // (a non-enveloped body is passed through as-is). A 200 with an
      // unparseable body still authorizes — the endpoint accepted the session;
      // only the identity payload is missing (data = undefined).
      let body: unknown;
      try { body = await res.json(); } catch { body = undefined; }
      const identity = body && typeof body === "object" && "record" in (body as Record<string, unknown>)
        ? (body as { record: unknown }).record
        : body;
      return { ok: true, data: identity as T };
    } catch {
      // Network error / offline / CORS failure → fail CLOSED.
      return { redirect: opts.redirect };
    }
  };
}
