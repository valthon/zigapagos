import { host } from "./host.ts";
import { notifyUnauthorizedResponse } from "./session.ts";

// ---------------------------------------------------------------------------
// apiFetch — same-origin-aware fetch wrapper for SPAs / islands.
//
// A thin wrapper over the browser `fetch` global that bakes in the two things
// every ZigBase-backed call site would otherwise hand-write:
//   1. credentials: "include" — so the session cookie rides along, but ONLY
//      for same-origin targets. Cross-origin requests get the caller's own
//      init.credentials passed through unchanged (never forced to "include").
//   2. the CSRF double-submit echo — on a mutating (non-GET/HEAD) same-origin
//      request, copy the `zb_csrf` cookie into an `X-CSRF-Token` header.
//
// SECURITY: the CSRF token and forced credentials are attached ONLY when the
// target is same-origin. A cross-origin request never receives the zb_csrf
// value (that would leak the token to a third party) and is never forced to
// send cookies. Same-origin is the whole point; cross-origin stays conservative.
//
// Client-only: `fetch` is a browser global. `host.cookies.get` already returns
// "" under isServer(), so the CSRF echo degrades to a no-op on the server.
// ---------------------------------------------------------------------------

// Resolve the request target to a URL string. A Request normalizes its own
// url to an absolute string; a URL exposes .href; a string is used verbatim.
function targetUrl(input: string | URL | Request): string {
  if (input instanceof Request) return input.url;
  if (input instanceof URL) return input.href;
  return input;
}

// Same-origin iff the target resolves (against the current document URL) to the
// same origin as the page. A relative URL ("/api/x", "api/x") always resolves
// same-origin; an absolute URL is compared by origin. Unparseable / no-window
// (server) → treated as same-origin, where the CSRF/credentials additions are
// harmless no-ops anyway.
function sameOrigin(url: string): boolean {
  if (typeof window === "undefined") return true;
  try {
    return new URL(url, window.location.href).origin === window.location.origin;
  } catch {
    return false;
  }
}

export function apiFetch(input: string | URL | Request, init?: RequestInit): Promise<Response> {
  const url = targetUrl(input);
  const isSameOrigin = sameOrigin(url);
  const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
  const isMutating = method !== "GET" && method !== "HEAD";

  // Build a fresh Headers so the caller's object is never mutated. Start from
  // the Request's own headers (if any), then overlay init.headers (any of the
  // three HeadersInit shapes: Headers | record | array-of-pairs).
  const headers = new Headers(input instanceof Request ? input.headers : undefined);
  if (init?.headers) new Headers(init.headers).forEach((v, k) => headers.set(k, v));

  const out: RequestInit = { ...init };

  if (isSameOrigin) {
    // Cookies ride along by default; caller can still override via init.
    out.credentials = init?.credentials ?? "include";
    // CSRF echo: only on a mutating request, only if the caller hasn't already
    // set the header, only if the cookie is actually present.
    if (isMutating && !headers.has("X-CSRF-Token")) {
      const token = host.cookies.get("zb_csrf");
      if (token) headers.set("X-CSRF-Token", token);
    }
  }
  // Cross-origin: out.credentials stays whatever the caller passed (possibly
  // undefined → browser default), and no CSRF header is ever attached.

  out.headers = headers;
  const promise = fetch(input, out);
  if (!isSameOrigin) return promise;
  // Session-expiry policy: a SAME-ORIGIN 401/403 means the cookie
  // session this wrapper exists for is no longer accepted — notify the Router
  // so it re-runs the active route's guard (whose `{ redirect }` then does the
  // right thing). Cross-origin responses never trigger it (their auth isn't
  // our session), and the caller still receives the Response unchanged.
  return promise.then((res) => {
    if (res.status === 401 || res.status === 403) notifyUnauthorizedResponse();
    return res;
  });
}
