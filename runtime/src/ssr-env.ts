// SSR-time page path, mirroring engine/src/host.zig's threadlocal ssr_pathname.
// The sidecar sets this before rendering each page's islands so host.pathname()
// agrees with the client's window.location.pathname.
let ssrPathname = "/";
let serverOverride: boolean | undefined;

export function isServer(): boolean {
  return serverOverride ?? (typeof window === "undefined");
}

// Test-only: force isServer() to a fixed value (true/false), or undefined to
// restore the default `typeof window === "undefined"` detection. Mirrors the
// __resetStoresForTest escape-hatch in host.ts.
export function __setServerForTest(v?: boolean): void {
  serverOverride = v;
}

export function setSsrPathname(path: string): void {
  ssrPathname = path || "/";
}

export function getSsrPathname(): string {
  return ssrPathname;
}

// The site's `url_path_prefix` (zigapagos.ziggy) — "" for a root-mounted site,
// else a normalized "/myrepo". It lives HERE, beside `ssrPathname`, because it
// is the same kind of value: one the two environments learn through different
// channels and must then agree on byte-for-byte. The build's SSR pass is told
// by the sidecar protocol (`runtime/sidecar/render.ts` writes it per render
// request); the browser reads it off the shell's hydration root
// (`data-z-prefix`, read in `mountSpa`).
//
// It is deliberately NOT folded into `currentPathname()`/`currentSearch()`:
// location-shaped values are always the FULL real pathname in both
// environments (the build now SSRs at the prefixed pathname too). The prefix's
// only consumer is `Router`, which composes it with `spa.base` to form the
// router's effective base — see router.ts. Composing it anywhere else would
// double-count it.
let urlPathPrefix = "";

/** Normalize to "" or "/segment[/segment…]" — one leading slash, no trailing
 * slash — so `urlPathPrefix + base` is a plain concatenation at the single
 * composition point in `Router`. Accepts the raw config spelling
 * ("myrepo", "/myrepo/", "/myrepo") because both writers pass through here. */
export function setUrlPathPrefix(prefix: string): void {
  const trimmed = (prefix || "").replace(/^\/+|\/+$/g, "");
  urlPathPrefix = trimmed.length === 0 ? "" : "/" + trimmed;
}

export function getUrlPathPrefix(): string {
  return urlPathPrefix;
}

/** The pathname component only — a query-carrying SSR pathname (a SPA
 * prerender or test may set one) is trimmed so this always agrees with
 * window.location.pathname, which never includes the query. */
export function currentPathname(): string {
  if (!isServer()) return window.location.pathname;
  const q = ssrPathname.indexOf("?");
  return q === -1 ? ssrPathname : ssrPathname.slice(0, q) || "/";
}

/** The current search string ("?a=b" or ""). Client: live window.location.
 * Server: parsed from the SSR pathname's query when the build threaded one,
 * else "" — a static build has no request URL, so islands must treat query
 * data as client-enriched (same rule as any hydration-only state). */
export function currentSearch(): string {
  if (isServer()) {
    const q = ssrPathname.indexOf("?");
    return q === -1 ? "" : ssrPathname.slice(q);
  }
  return window.location.search;
}

/** The current fragment ("#x" or ""). Always "" on the server — fragments
 * are never sent to a server, so there is no SSR equivalent to parse. */
export function currentHash(): string {
  return isServer() ? "" : window.location.hash;
}
