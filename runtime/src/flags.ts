import { useSyncExternalStore, h, Fragment } from "./core.ts";
import type { ComponentChildren } from "./core.ts";
import { host } from "./host.ts";
import { apiFetch } from "./api.ts";
import { isServer } from "./ssr-env.ts";

export type ResolvedState = { flags: Record<string, boolean>; experiments: Record<string, string> };

export type InitFlagsOptions = { live?: boolean; sseUrl?: string };

// ---------------------------------------------------------------------------
// initFlags — populate the "flags" store, and (opt-in) keep it live.
//
// Back-compat: initFlags() / initFlags(url) with no opts is byte-behaviour
// identical to before — a single once-per-store host.fetchShared. Only the
// { live: true } opt-in wires up the SSE subscription + poll-on-nav fallback,
// and only on the client (SSR is a no-op).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Baked flag defaults.
//
// The prerender pass (src/spa.zig renderShell) inlines the SPA's declared
// `spa.flags` defaults into each shell as a JSON DATA BLOCK:
//
//   <script type="application/json" data-z-flags>
//     {"flags":{"bookAsGuest":true},"experiments":{}}
//   </script>
//
// The client boot (mountSpa, router.ts) calls seedFlagsFromShell() BEFORE
// hydration, so `useFlag`'s very first render already sees the declared
// default — there is no false-while-loading window for declared flags. The
// snapshot is shaped exactly like the /api/flags/state payload and lands in
// the same "flags" store, so the real state (initFlags' fetchShared, or an
// SSE-triggered re-fetch) reconciles over it through the normal subscription
// path — fetchShared dedupes on fetchStarted, not on store contents, so
// seeding never suppresses the real fetch.
// ---------------------------------------------------------------------------

/**
 * Seed the "flags" store from the shell's `data-z-flags` JSON snapshot, if one
 * is present and the store hasn't already been populated (real fetched state,
 * or an earlier seed, always wins). Client-only; called by `mountSpa` before
 * hydration. A malformed snapshot is reported loudly and skipped — an empty
 * store (flags unresolved) beats a store that poisons every getJson reader.
 */
export function seedFlagsFromShell(): void {
  if (isServer() || typeof document === "undefined") return;
  if (host.store.getStr("flags")) return; // resolved state already present
  const el = document.querySelector('script[type="application/json"][data-z-flags]');
  if (!el) return;
  const text = (el.textContent ?? "").trim();
  if (!text) return;
  try {
    JSON.parse(text); // validate; store keeps the raw string (see useResolved)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    host.reportError(`zigapagos: malformed data-z-flags snapshot: ${msg}`);
    return;
  }
  host.store.setStr("flags", text);
}

export function initFlags(url = "/api/flags/state", opts?: InitFlagsOptions): void {
  host.fetchShared(url, "flags");
  if (opts?.live && !isServer()) {
    startLiveFlags(url, opts.sseUrl ?? "/api/realtime/sse");
  }
}

// ---------------------------------------------------------------------------
// Live flags — re-fetch the flag state on a backend signal so a kill-switch
// flip propagates to already-open tabs.
//
// The initial load uses fetchShared (once-per-store), which by design will NOT
// re-fetch. So the live update goes through apiFetch (same-origin
// credentials) + host.store.setStr("flags", …) directly, re-populating the
// store and re-rendering every useResolved subscriber with the new flags.
//
// Failure policy:
//   - Re-fetch failure (HTTP or network) is LOUD (host.reportError) and never
//     writes a default — a stale-but-real value beats a fabricated one.
//   - SSE unavailability (endpoint absent / connection dropped) is SILENT: a
//     missing realtime endpoint is a normal dev/degraded state, so we quietly
//     fall back to poll-on-nav rather than spamming errors.
//
// All state is module-global (matching the page-global store). Idempotent:
// two initFlags({ live }) calls open exactly ONE EventSource / one listener set.
// ---------------------------------------------------------------------------

let liveEs: EventSource | null = null;
let liveStarted = false; // guards against opening a second EventSource
let pollActive = false;  // guards against double-installing the fallback listeners
let liveUrl = "/api/flags/state"; // the flag-state URL the fallback re-fetches

// LOUD-FAIL re-fetch: apiFetch → text → store.setStr. On any HTTP/network
// error, report it; never write a default into the store.
function refetchFlags(url: string): void {
  apiFetch(url)
    .then((res) => {
      if (!res.ok) {
        host.reportError(`refetchFlags(${url}) failed: HTTP ${res.status}`);
        return;
      }
      return res.text().then((text) => host.store.setStr("flags", text));
    })
    .catch((err) => {
      host.reportError(`refetchFlags(${url}) failed: ${(err as Error).message}`);
    });
}

// Poll-on-nav fallback listeners. Re-fetch on back/forward (popstate) and when
// the tab becomes visible again (visibilitychange). Soft-nav (pushState) flag
// refresh relies on the SSE path — there is deliberately no router coupling.
function onPollNav(): void { refetchFlags(liveUrl); }
function onVisibility(): void {
  if (document.visibilityState === "visible") refetchFlags(liveUrl);
}

function engagePollFallback(): void {
  if (pollActive) return; // idempotent install
  pollActive = true;
  window.addEventListener("popstate", onPollNav);
  document.addEventListener("visibilitychange", onVisibility);
}

// startLiveFlags — client-only, idempotent. Opens ONE EventSource on sseUrl and
// re-fetches url on the __features signal; degrades silently to poll-on-nav when
// SSE is unavailable.
export function startLiveFlags(url: string, sseUrl: string): void {
  if (isServer()) return;      // SSR: no EventSource / window
  if (liveStarted) return;     // idempotent: never open a second subscription
  liveStarted = true;
  liveUrl = url;

  // No EventSource (older/degraded environment) → poll-on-nav directly.
  if (typeof EventSource === "undefined") {
    engagePollFallback();
    return;
  }

  const es = new EventSource(sseUrl, { withCredentials: true });
  liveEs = es;
  const onSignal = () => refetchFlags(url);
  // Servers vary: some emit a named `__features` event, some use the default
  // `message` channel. Per the SSE spec these are mutually exclusive per event
  // (a named event never triggers onmessage), so listening to both is safe.
  es.addEventListener("__features", onSignal);
  es.onmessage = onSignal;
  es.onerror = () => {
    // SILENT-fail: a missing / dropped SSE endpoint is a normal degraded state.
    // Close this stream and engage the poll-on-nav fallback without reporting.
    es.close();
    if (liveEs === es) liveEs = null;
    engagePollFallback();
  };
}

// stopLiveFlags — teardown for tab close + tests. Closes the EventSource,
// removes the fallback listeners, and resets the idempotency flags so a later
// startLiveFlags can subscribe afresh.
export function stopLiveFlags(): void {
  if (liveEs) { liveEs.close(); liveEs = null; }
  if (pollActive) {
    window.removeEventListener("popstate", onPollNav);
    document.removeEventListener("visibilitychange", onVisibility);
    pollActive = false;
  }
  liveStarted = false;
}

// Module-scope so the reference is stable across renders — a new subscribe
// reference each render would make useSyncExternalStore churn unsub/resub.
function flagsSubscribe(cb: () => void): () => void {
  const ctrl = new AbortController();
  host.store.subscribe("flags", cb, ctrl.signal);
  return () => ctrl.abort();
}

function useResolved(): ResolvedState | null {
  // Snapshot is the raw string (a stable primitive) so useSyncExternalStore's
  // identity check is correct; parse lazily. Empty string → not resolved yet.
  // preact/compat's useSyncExternalStore takes (subscribe, getSnapshot) — no
  // getServerSnapshot arg. On the server getSnapshot returns "" (empty store),
  // which is exactly the unresolved skeleton we want, so no third arg is needed.
  const raw = useSyncExternalStore(flagsSubscribe, () => host.store.getStr("flags"));
  if (!raw) return null;
  return host.store.getJson<ResolvedState>("flags"); // loud-fail on malformed
}

export function useFlag(name: string): boolean {
  const state = useResolved();
  return state ? state.flags[name] === true : false;
}

export function useVariant(name: string): string {
  const state = useResolved();
  return state ? (state.experiments[name] ?? "") : "";
}

export function FeatureFlag(props: { name: string; children?: ComponentChildren; skeleton?: ComponentChildren }) {
  if (useFlag(props.name)) return h(Fragment, null, props.children);
  return props.skeleton != null ? h(Fragment, null, props.skeleton) : null;
}

export function Experiment(props: { name: string; variant: string; children: ComponentChildren }) {
  return useVariant(props.name) === props.variant ? h(Fragment, null, props.children) : null;
}
