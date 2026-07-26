// ---------------------------------------------------------------------------
// Session-expiry seam. `apiFetch` SEES a mid-session 401/403; the
// Router OWNS the guard that decides what to do about it. This module is the
// tiny internal channel between them (kept separate so api.ts and router.ts
// never import each other): apiFetch calls `notifyUnauthorizedResponse()` on a
// same-origin 401/403, and a mounted Router subscribes via
// `onUnauthorizedResponse()` to re-run the active route's guard pipeline —
// whose `{ redirect }` verdict then navigates away.
//
// NOT part of the public @z/runtime surface: the whole point of the policy is
// that a gated SPA needs zero per-site wiring (no onUnauthorized callback to
// remember to register). Loop prevention lives on the Router side (in-flight
// suppression + cooldown; see router.ts).
// ---------------------------------------------------------------------------

type UnauthorizedListener = () => void;

const listeners = new Set<UnauthorizedListener>();

/** Subscribe to unauthorized (401/403) apiFetch responses. Returns an unsubscribe. */
export function onUnauthorizedResponse(listener: UnauthorizedListener): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/**
 * Fan a same-origin 401/403 out to the subscribed Router(s). A throwing
 * listener must NEVER break the fetch path — the caller still gets its
 * Response — so every listener is isolated in its own try/catch.
 */
export function notifyUnauthorizedResponse(): void {
  for (const listener of [...listeners]) {
    try { listener(); } catch { /* never break the fetch path */ }
  }
}
