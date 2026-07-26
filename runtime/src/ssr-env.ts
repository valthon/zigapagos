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
