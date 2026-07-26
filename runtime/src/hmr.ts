// ---------------------------------------------------------------------------
// Dev-only, state-preserving hot-module replacement for islands.
//
// The `zigapagos dev` loop (src/cli/reload.zig) holds an SSE side channel open to
// every browser and, on a rebuild, broadcasts EITHER a plain full-reload signal
// OR — when only island bundles changed — a per-module message
//   data: {"kind":"island","modules":["/islands/Counter.island.js", …]}
// The injected client snippet routes an "island" message here via the global
// `window.__zigapagos_hmr`; everything else (HTML/CSS/layout/unknown/parse
// failure) is a full `location.reload()`.
//
// applyIslandUpdate re-imports each changed module and RE-RENDERS the matching
// island root(s) in place (islands.ts#swapIsland) — no page navigation, so the
// SPA route, scroll and sibling islands are untouched. State survives two ways:
//   - `useRestorableState` values: we fire `zigapagos:beforereload` (the seam
//     the dev-reload helpers already listen on) BEFORE swapping, so each hook
//     stashes its current value and a fresh mount restores it;
//   - plain `useState`/`useReducer`: when the bundle was built with
//     the dev-only fast-refresh transform (bundle-island.ts `hot`), the module's
//     components are stable proxies from hot-registry.ts, so the re-import swaps
//     implementations in place and Preact keeps the mounted instance. A changed
//     hook signature — or an untransformed module — falls back to the in-place
//     remount (where only restorable state survives).
//
// CORRECTNESS OVER CLEVERNESS: any module we can't confidently swap — no
// matching mounted root, or an import/render error — makes applyIslandUpdate
// return false, and the client snippet falls back to a full reload. A missed
// hot-swap costs a reload; a bad one would corrupt state, which is worse.
//
// PROD-SAFE: `installHmr` only assigns a global; the machinery runs solely when
// the dev-only snippet calls it, which never exists in a release build.
// ---------------------------------------------------------------------------

import { isServer } from "./ssr-env.ts";
import { mountedIslands, swapIsland, forgetDetachedIslands } from "./islands.ts";

const BEFORE_RELOAD_EVENT = "zigapagos:beforereload";

/** The property `installHmr` publishes and the client snippet calls. */
export interface HmrGlobal {
  /** Hot-swap the given island module URLs; resolves false ⇒ caller full-reloads. */
  applyIsland(modules: string[]): Promise<boolean>;
}

// Compare module identity by pathname only: the SSE payload carries the plain
// `data-z-module` URL, and a mounted root's URL never has a query — but stay
// robust to either side gaining a cache-bust suffix by trimming ?…/#… .
function moduleKey(url: string): string {
  const q = url.search(/[?#]/);
  return q === -1 ? url : url.slice(0, q);
}

/**
 * Apply an island hot-swap for the changed module URLs. Returns true only when
 * EVERY changed module that is present on the page swapped cleanly; false (⇒
 * full reload) when nothing on the page matched or any swap threw.
 */
export async function applyIslandUpdate(modules: string[]): Promise<boolean> {
  if (isServer() || !Array.isArray(modules) || modules.length === 0) return false;

  forgetDetachedIslands(); // never resurrect a root that left the DOM
  const wanted = new Set(modules.map(moduleKey));
  const targets: HTMLElement[] = [];
  for (const [rootEl, rec] of mountedIslands()) {
    if (wanted.has(moduleKey(rec.moduleUrl))) targets.push(rootEl);
  }
  // Nothing on THIS page uses the changed module → let the caller full-reload.
  // (Island bundles are self-contained per-entry, so a module absent here means
  // the edit doesn't affect the current page; a reload is the safe fallback.)
  if (targets.length === 0) return false;

  // Stash restorable state once for the whole batch, exactly as a full reload
  // would (the dev-reload hooks listen on this event).
  try {
    window.dispatchEvent(new CustomEvent(BEFORE_RELOAD_EVENT));
  } catch {
    return false; // if we can't stash, don't risk a lossy swap — reload instead
  }

  const bust = String(Date.now());
  try {
    // Swap sequentially so a mid-batch failure leaves the rest untouched and we
    // bail to a full reload (a consistent whole-page state beats a half-applied one).
    for (const rootEl of targets) await swapIsland(rootEl, bust);
    return true;
  } catch (e) {
    console.error("zigapagos: island hot-swap failed; falling back to full reload", e);
    return false;
  }
}

/**
 * Publish `window.__zigapagos_hmr` so the dev reload snippet can hand island
 * messages to the runtime. Client-only and idempotent; a no-op on the server.
 */
export function installHmr(): void {
  if (isServer()) return;
  const api: HmrGlobal = { applyIsland: applyIslandUpdate };
  (window as unknown as { __zigapagos_hmr?: HmrGlobal }).__zigapagos_hmr = api;
}
