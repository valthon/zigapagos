import { h, hydrate, render } from "./core.ts";
import type { VNode } from "./core.ts";
import { buildSlots, type Slots } from "./slots.ts";

/**
 * What was rendered into one island root — enough to RE-render it in place for
 * a dev hot-swap (hmr.ts) without re-reading the DOM. Kept per mounted root.
 */
export interface IslandRecord {
  /** The `data-z-module` URL the root booted from (no cache-bust query). */
  moduleUrl: string;
  props: Record<string, unknown>;
  children?: VNode;
  slots?: Slots;
  /** Aborted + replaced on a hot-swap; a seam for listener cleanup. */
  controller: AbortController;
}

// Live registry of mounted islands, keyed by their root element. hmr.ts reads
// this to find the roots a changed module maps to. bootIsland populates it;
// a hot-swap updates the record in place.
const mounted = new Map<HTMLElement, IslandRecord>();

/** Snapshot of the currently-mounted island records (for hmr.ts). */
export function mountedIslands(): ReadonlyMap<HTMLElement, IslandRecord> {
  return mounted;
}

/**
 * Drop registry entries whose root left the document — an SPA route change (or,
 * in tests, an unmount) can detach an island's DOM without going through here,
 * and a detached root must never be hot-swapped. hmr.ts calls this before a swap
 * so stale roots can't resurrect.
 */
export function forgetDetachedIslands(): void {
  for (const el of mounted.keys()) if (!el.isConnected) mounted.delete(el);
}

// Indirection so tests can feed a fake module (mirrors ssr-env's
// __setServerForTest). Production imports the real URL. bootIsland AND the dev
// hot-swap both go through here, so a test drives both deterministically.
let importModule: (url: string) => Promise<{ default: any }> = (url) => import(url);

/** Test-only: override the dynamic importer (undefined restores `import()`). */
export function __setIslandImporter(
  fn?: (url: string) => Promise<{ default: any }>,
): void {
  importModule = fn ?? ((url) => import(url));
}

// Read props + slots/children out of the sibling <script> tags the SSR pass
// emitted for a given island root.
function readInputs(rootEl: HTMLElement): {
  props: Record<string, unknown>;
  children?: VNode;
  slots?: Slots;
} {
  const propsEl = document.querySelector(`script[data-z-props="${rootEl.id}"]`);
  const props = propsEl?.textContent ? JSON.parse(propsEl.textContent) : {};
  const slotsEl = document.querySelector(`script[data-z-slots="${rootEl.id}"]`);
  const { children, slots } = slotsEl?.textContent
    ? buildSlots(JSON.parse(slotsEl.textContent))
    : {};
  return { props, children, slots };
}

// The single vnode an island root renders — shared by hydrate (boot) and
// render (hot-swap) so a swapped module rebuilds the identical shape.
function islandVNode(mod: { default: any }, rec: IslandRecord): VNode {
  return h(mod.default, rec.slots ? { ...rec.props, slots: rec.slots } : rec.props, rec.children);
}

export async function bootIsland(rootEl: HTMLElement): Promise<void> {
  if (rootEl.hasAttribute("data-z-hydrated")) return;
  const moduleUrl = rootEl.dataset.zModule;
  if (!moduleUrl) throw new Error(`island ${rootEl.id}: missing data-z-module`);

  // Prune registry entries whose root already left the document. Detaching a
  // root outside a full navigation (an SPA that adds/removes island DOM) never
  // routes through here otherwise, so in production the map would grow forever;
  // hmr.ts also calls this before a swap, so the dev path is unaffected.
  forgetDetachedIslands();

  const { props, children, slots } = readInputs(rootEl);
  const controller = new AbortController();
  const record: IslandRecord = { moduleUrl, props, children, slots, controller };
  mounted.set(rootEl, record);

  const mod = await importModule(moduleUrl);
  // Preact adopt-hydration: reuse the SSR DOM in place (no clear-and-remount).
  // When slots present, pass children (default slot) + slots (named) so Preact
  // rebuilds the same dangerouslySetInnerHTML VNodes as the sidecar SSR'd → byte-identical adopt.
  hydrate(islandVNode(mod, record), rootEl);
  rootEl.setAttribute("data-z-hydrated", "");
}

/**
 * Dev hot-swap (hmr.ts): re-import the island's module fresh and RE-RENDER it
 * into its existing root — no full-page navigation, the rest of the page (SPA
 * route, scroll, sibling islands) untouched. When the bundle was built with the
 * dev-only fast-refresh transform, the re-imported default is the
 * SAME stable proxy (hot-registry.ts) as long as the component's hook signature
 * is unchanged, so Preact keeps the mounted instance and plain `useState`/
 * `useReducer` state survives. Otherwise (untransformed module, or a changed
 * hook signature) the vnode type changes, Preact tears the old subtree down and
 * mounts the new one, and plain `useState` resets to its initial value; state
 * kept via `useRestorableState` survives either way because hmr.ts fires the
 * `zigapagos:beforereload` event (which stashes it) BEFORE calling this, and a
 * fresh mount restores it. `bust` cache-busts the dynamic import so the browser
 * fetches the rebuilt bytes rather than the cached module.
 *
 * Throws if the root isn't a mounted island — hmr.ts treats a throw as "couldn't
 * hot-swap" and falls back to a full reload (correctness over cleverness).
 */
export async function swapIsland(rootEl: HTMLElement, bust: string): Promise<void> {
  const record = mounted.get(rootEl);
  if (!record) throw new Error(`swapIsland: ${rootEl.id} is not a mounted island`);
  if (!rootEl.isConnected) { mounted.delete(rootEl); return; } // detached → nothing to swap

  // Fresh controller: abandon the previous mount's abort seam.
  record.controller.abort();
  record.controller = new AbortController();

  // Insert the cache-bust query BEFORE any #fragment (a query after a fragment
  // is invalid). Split the fragment off, splice `z-hmr=` in, re-append it.
  const hashIdx = record.moduleUrl.indexOf("#");
  const base = hashIdx === -1 ? record.moduleUrl : record.moduleUrl.slice(0, hashIdx);
  const frag = hashIdx === -1 ? "" : record.moduleUrl.slice(hashIdx);
  const sep = base.includes("?") ? "&" : "?";
  const mod = await importModule(base + sep + "z-hmr=" + bust + frag);
  // render (not hydrate): the root is already live DOM; diff the new module's
  // tree over it. A changed default-export type → Preact replaces the subtree.
  render(islandVNode(mod, record), rootEl);
}

export function initIslands(): void {
  for (const el of document.querySelectorAll<HTMLElement>("[data-z-island][data-z-client]")) {
    schedule(el);
  }
}

function schedule(el: HTMLElement): void {
  const run = () => bootIsland(el).catch((e) => console.error("zigapagos: hydrate error", el.id, e));
  switch (el.dataset.zClient) {
    case "load":
    case "only":
      run(); break;
    case "idle":
      if ("requestIdleCallback" in window) (window as any).requestIdleCallback(run);
      else setTimeout(run, 1);
      break;
    case "visible": {
      const io = new IntersectionObserver((entries, obs) => {
        for (const e of entries) if (e.isIntersecting) { obs.disconnect(); run(); break; }
      });
      io.observe(el); break;
    }
    case "media": {
      const mql = window.matchMedia(el.dataset.zMedia || "all");
      if (mql.matches) run();
      else {
        const onChange = () => { if (mql.matches) { mql.removeEventListener("change", onChange); run(); } };
        mql.addEventListener("change", onChange);
      }
      break;
    }
    default:
      run();
  }
}

// Auto-init as the page entry, unless a test opts out via <html data-z-manual>.
if (typeof document !== "undefined" && !document.documentElement.hasAttribute("data-z-manual")) {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initIslands);
  else queueMicrotask(initIslands);
}
