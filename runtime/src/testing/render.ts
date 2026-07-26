import { h, render, hydrate, renderToString, type ComponentType } from "../core.ts";
import { setSsrPathname, getSsrPathname, __setServerForTest } from "../ssr-env.ts";
import { host } from "../host.ts";
import { provideGuardData } from "../router.ts";
import { flush } from "./flush.ts";
import { mockHost, type MockHost, type MockHostConfig } from "./mock-host.ts";

export type RenderMode = "hydrate" | "render" | "ssr";

let islandSeq = 0;

function isMockHost(x: unknown): x is MockHost {
  return !!x && typeof (x as MockHost).install === "function" && typeof (x as MockHost).restore === "function";
}

export function ssrIsland<P>(C: ComponentType<P>, props: P = {} as P, opts: { pathname?: string } = {}): string {
  const prevPath = getSsrPathname();
  if (opts.pathname) setSsrPathname(opts.pathname);
  __setServerForTest(true);
  try {
    return renderToString(h(C as any, props as any));
  } finally {
    __setServerForTest(undefined);
    setSsrPathname(prevPath);
  }
}

// --- renderForTest — unit-test a single view/island -------------------------

export interface RenderForTestOptions<P> {
  /** Props the Router/parent would pass to the view. Default `{}`. */
  props?: P;
  /**
   * Guard data the NEAREST enclosing route guard would have returned via
   * `{ ok: true, data }`. Surfaces to the view (and anything it renders)
   * through `useGuardData()`. Omit for an unguarded view.
   */
  guardData?: unknown;
  /**
   * Baked feature-flag defaults the prerendered shell would have
   * snapshotted into `data-z-flags`. The view sees them through `useFlag()` on
   * its very first render — no false-while-loading window, matching the sidecar.
   */
  flags?: Record<string, boolean>;
  /** Experiment variant assignments the view reads via `useVariant()`. */
  experiments?: Record<string, string>;
  /** SSR pathname (`host.pathname()` / `useLocation()`); default `"/"`. */
  pathname?: string;
}

/**
 * Render a view/island to its SSR HTML STRING with injected inputs — props,
 * guard data, and baked flags/experiments — then assert on the result. No
 * browser, no Router, no full build: a thin, in-process wrapper over the exact
 * `renderToString` path the Bun SSR sidecar (`runtime/sidecar/render.ts`) runs
 * at build time, with `isServer() === true`. It is the fast, browser-free way
 * to unit-test a single view's render logic — the same seams the sidecar uses
 * (SSR pathname, the flags store, the guard-data context) wired up in isolation.
 *
 * ```ts
 * import { renderForTest } from "@z/runtime/testing";
 * import { Dashboard } from "./Dashboard.tsx";
 *
 * const html = renderForTest(Dashboard, {
 *   props: { title: "Home" },
 *   guardData: { user: { name: "Ada" } }, // what the route guard returned
 *   flags: { promoBanner: true },
 *   pathname: "/app/dashboard",
 * });
 * expect(html).toContain("Ada");
 * ```
 *
 * State injection is fully scoped: the SSR pathname and the page-global flags
 * store are saved and restored around the render, so calls don't bleed into one
 * another (mirroring the sidecar's per-request seed/clear of `spa.flags`).
 */
export function renderForTest<P>(
  View: ComponentType<P>,
  opts: RenderForTestOptions<P> = {},
): string {
  const prevPath = getSsrPathname();
  const prevFlags = host.store.getStr("flags");
  setSsrPathname(opts.pathname ?? "/");
  __setServerForTest(true);
  host.store.setStr(
    "flags",
    JSON.stringify({ flags: opts.flags ?? {}, experiments: opts.experiments ?? {} }),
  );
  try {
    const view = h(View as any, (opts.props ?? {}) as any);
    return renderToString(provideGuardData(opts.guardData, view));
  } finally {
    __setServerForTest(undefined);
    setSsrPathname(prevPath);
    host.store.setStr("flags", prevFlags); // restore (clears when it was empty)
  }
}

export interface RenderResult<P> {
  container: HTMLElement;
  html(): string;
  host: MockHost;
  get(sel: string): HTMLElement;
  query(sel: string): HTMLElement | null;
  getAll(sel: string): HTMLElement[];
  text(sel?: string): string;
  rerender(props: P): Promise<void>;
  unmount(): void;
}

export function renderIsland<P>(
  Component: ComponentType<P>,
  props: P = {} as P,
  opts: { host?: MockHost | MockHostConfig; mode?: RenderMode; pathname?: string } = {},
): RenderResult<P> {
  const mh: MockHost = isMockHost(opts.host) ? opts.host : mockHost(opts.host as MockHostConfig | undefined);
  mh.install();
  if (opts.pathname) setSsrPathname(opts.pathname);

  const container = document.createElement("div");
  container.setAttribute("data-z-island", "");
  container.id = `z-island-test-${islandSeq++}`;
  document.body.appendChild(container);

  const mode = opts.mode ?? "hydrate";
  if (mode === "hydrate") {
    __setServerForTest(true);
    try {
      container.innerHTML = renderToString(h(Component as any, props as any));
    } finally {
      __setServerForTest(undefined);
    }
    hydrate(h(Component as any, props as any), container);
  } else if (mode === "render") {
    render(h(Component as any, props as any), container);
  } else {
    container.innerHTML = ssrIsland(Component, props, { pathname: opts.pathname });
  }

  const get = (sel: string): HTMLElement => {
    const all = container.querySelectorAll<HTMLElement>(sel);
    if (all.length === 0) throw new Error(`get(${JSON.stringify(sel)}): no match`);
    if (all.length > 1) throw new Error(`get(${JSON.stringify(sel)}): ${all.length} matches`);
    return all[0];
  };
  const query = (sel: string) => container.querySelector<HTMLElement>(sel);
  const getAll = (sel: string) => Array.from(container.querySelectorAll<HTMLElement>(sel));
  const text = (sel?: string) => ((sel ? get(sel) : container).textContent ?? "").trim();

  return {
    container,
    host: mh,
    html: () => container.innerHTML,
    get, query, getAll, text,
    rerender: async (next: P) => { render(h(Component as any, next as any), container); await flush(); },
    unmount: () => { render(null as any, container); container.remove(); mh.restore(); },
  };
}

export async function act(fn?: () => void | Promise<void>): Promise<void> {
  if (fn) await fn();
  await flush();
}
export async function click(el: Element): Promise<void> { (el as HTMLElement).click(); await flush(); }
export async function type(el: HTMLInputElement, value: string): Promise<void> {
  el.value = value;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  await flush();
}
