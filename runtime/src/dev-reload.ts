// ---------------------------------------------------------------------------
// State-preserving dev reload — a prod-SAFE bridge over the dev server's
// full-page reload.
//
// `zigapagos serve` injects a livereload client (src/cli/serve/zigapagos-reload.js) that
// calls location.reload() when a source file changes. That preserves the URL
// (so the SPA route survives) but wipes all in-memory component state — form
// inputs, wizard steps, etc. Just before it reloads, the dev client dispatches
// a `zigapagos:beforereload` window event; the helpers here listen for it and stash
// the current value in sessionStorage, then restore it once on the next mount.
//
// Prod-safety is the hard requirement: `@z/runtime` ships to production, where
// that event NEVER fires (the dev client is not injected). With no event,
// nothing is ever written, so the first mount reads nothing and the hook
// behaves exactly like `useState(initial)`. SSR-safe too: on the server we
// return plain state and never touch window/sessionStorage. Nothing here ever
// throws — a bad blob or unavailable storage falls back to the initial value.
// ---------------------------------------------------------------------------

import { useState, useEffect, useRef } from "./core.ts";
import { isServer } from "./ssr-env.ts";

// Namespaced so a restorable key can't collide with unrelated sessionStorage.
const STORAGE_PREFIX = "z-reload:";
// The event the dev client dispatches synchronously before location.reload().
const BEFORE_RELOAD_EVENT = "zigapagos:beforereload";

/** The [value, setValue] tuple useRestorableState returns. */
export type RestorableState<T> = [T, (value: T) => void];

/**
 * Register `cb` to run just before a dev reload (on the `zigapagos:beforereload`
 * event). Returns an unsubscribe. Client-only: on the server it installs
 * nothing and the unsubscribe is a no-op. In production the event never fires,
 * so `cb` never runs.
 */
export function onBeforeReload(cb: () => void): () => void {
  if (isServer()) return () => {};
  window.addEventListener(BEFORE_RELOAD_EVENT, cb);
  return () => window.removeEventListener(BEFORE_RELOAD_EVENT, cb);
}

// Read + CONSUME a persisted value (one-shot restore). Removes the key BEFORE
// parsing so restore is one-shot even when the blob is malformed. Any failure
// (storage unavailable, non-JSON) falls back to `initial`, never throws.
function readOnce<T>(storageKey: string, initial: T): T {
  try {
    const raw = window.sessionStorage.getItem(storageKey);
    if (raw == null) return initial;
    window.sessionStorage.removeItem(storageKey); // consume: restore is one-shot
    return JSON.parse(raw) as T;
  } catch {
    return initial;
  }
}

// Persist the current value. Swallows storage/serialization failures — a
// reporting failure must never cascade into the app.
function writeSafely<T>(storageKey: string, value: T): void {
  try {
    window.sessionStorage.setItem(storageKey, JSON.stringify(value));
  } catch {
    /* storage full/unavailable or value not JSON-serializable — skip */
  }
}

/**
 * Like `useState`, but the value survives a dev-server reload.
 *
 *  - On the FIRST mount, reads `sessionStorage["z-reload:"+key]` exactly once;
 *    if present it is JSON.parsed as the initial value and the key is deleted
 *    (one-shot restore — a value is restored across a single reload, not again).
 *    With no key it uses `initial`.
 *  - While mounted, a `zigapagos:beforereload` listener writes the CURRENT value to
 *    that key just before the reload; the listener is removed on unmount.
 *
 * Values must be JSON-serializable. In production the dev event never fires, so
 * nothing is ever written and this behaves exactly like `useState(initial)`.
 * On the server it returns plain state and touches no browser globals.
 */
export function useRestorableState<T>(key: string, initial: T): RestorableState<T> {
  // Server render: plain state, no window/sessionStorage. isServer() is stable
  // for the whole of a given environment's render, so the hook count never
  // differs within either the server or the client tree.
  if (isServer()) {
    return useState<T>(initial);
  }

  const storageKey = STORAGE_PREFIX + key;

  // useState's initializer runs once per mount, so the read+consume happens
  // exactly once — a second mount (post-reload, key already consumed) sees
  // `initial`.
  const [value, setValue] = useState<T>(() => readOnce(storageKey, initial));

  // Keep the latest value in a ref so the (once-registered) beforereload
  // listener always persists the CURRENT value, not the value at registration.
  const latest = useRef<T>(value);
  latest.current = value;

  useEffect(() => {
    return onBeforeReload(() => writeSafely(storageKey, latest.current));
  }, [storageKey]);

  return [value, setValue];
}
