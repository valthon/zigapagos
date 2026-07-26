// ---------------------------------------------------------------------------
// First-class client observability — structured, source-map-aware error and
// perf reporting for @z/runtime.
//
// `initObservability()` is the richer sibling of `initErrorRelay` (errors.ts):
// where the relay POSTs a flat batch to one same-origin endpoint, this layer
// produces STRUCTURED payloads (parsed stack frames + a release stamp), applies
// SAMPLING and DEDUP so a broken page can't flood the sink, optionally
// SYMBOLICATES frames client-side against the source maps a release build emits,
// optionally captures PERF / nav-timing (FCP, LCP, long tasks), and dispatches
// everything through a pluggable ADAPTER so an app can point it at its own
// backend or a provider (Sentry, etc.) instead of the built-in HTTP sink.
//
// Design invariants (shared with errors.ts):
//  - Client-only: isServer() → no-op teardown, no window/document touched.
//  - Handlers NEVER throw — a reporting failure must not cascade into the app.
//  - Additive listeners, and the manual `window.zigapagosOnError` hook is
//    CHAINED (never clobbered); teardown restores exactly the prior hook.
//  - ErrorBoundary catches arrive via errors.ts's `__registerErrorSink` seam,
//    so a boundary fallback reports here without either pipe stealing the other.
//
// Symbolication is source-map aware in two composable ways:
//  1. The payload always ships the parsed RAW frames + `release`, so a backend
//     or provider can symbolicate server-side from the uploaded/emitted maps
//     (the industry-standard path — no maps shipped to every browser).
//  2. With `symbolicate: true`, frames are additionally mapped CLIENT-SIDE by
//     fetching each script's `.map` (served next to the bundle) and rewriting
//     the frame to its original source/line/column/function before dispatch.
// ---------------------------------------------------------------------------

import { isServer, currentPathname } from "./ssr-env.ts";
import { apiFetch } from "./api.ts";
import { __registerErrorSink, type ErrorKind, type ErrorInput } from "./errors.ts";
import { SourceMapConsumer, type RawSourceMap } from "./source-map.ts";

// --- Public payload shapes -------------------------------------------------

export interface StackFrame {
  /** Function/method name, when the stack line carried one. */
  function?: string;
  /** Script URL (or original source path once symbolicated). */
  filename?: string;
  /** 1-based line. */
  lineno?: number;
  /** 1-based column. */
  colno?: number;
}

export interface ErrorPayload {
  type: "error";
  kind: ErrorKind;
  message: string;
  /** Error constructor name (e.g. "TypeError"), when known. */
  name?: string;
  /** The raw stack string, retained as a fallback for consumers. */
  stack?: string;
  /** Parsed (and, with `symbolicate`, source-mapped) frames. */
  frames: StackFrame[];
  pathname: string;
  ts: number;
  /** Build/release identifier for correlating server-side symbolication. */
  release?: string;
  /** Dedup key: kind + message + top frame. */
  fingerprint: string;
  /** Extra fields from the `context()` option. */
  context?: Record<string, unknown>;
}

export interface PerfPayload {
  type: "perf";
  /** "FCP" | "LCP" | "longtask" (extensible). */
  metric: string;
  /** Metric value in ms (a duration, or a time-from-nav for paint metrics). */
  value: number;
  pathname: string;
  ts: number;
  release?: string;
  context?: Record<string, unknown>;
}

export type ObservabilityEvent = ErrorPayload | PerfPayload;

// --- Adapter interface -----------------------------------------------------

export interface ObservabilityAdapter {
  /** Deliver one structured event. The adapter owns transport and batching. */
  handle(event: ObservabilityEvent): void;
  /** Optional: flush any buffered events. Called on pagehide / visibility-hidden
   *  (keepalive=true, a last-gasp send) and on teardown (keepalive=false). */
  flush?(keepalive: boolean): void;
  /** Optional: release resources (timers, observers). Called on teardown. */
  dispose?(): void;
}

// --- Options ---------------------------------------------------------------

export interface InitObservabilityOptions {
  /** Convenience: when set (and no `adapter`), a default batching HTTP adapter
   *  POSTing `{ events }` to this same-origin URL via apiFetch is used. */
  endpoint?: string;
  /** A custom sink (a provider or your own backend). Overrides `endpoint`. */
  adapter?: ObservabilityAdapter;
  /** Report only this fraction of events (0..1, default 1). */
  sampleRate?: number;
  /** Build/release identifier stamped into every payload. */
  release?: string;
  /** Extra fields merged into every payload's `context`. */
  context?: () => Record<string, unknown>;
  /** Capture FCP, LCP and long tasks via PerformanceObserver (default off). */
  perf?: boolean;
  /** Symbolicate frames client-side against served `.map` files (default off). */
  symbolicate?: boolean;
  /** Test/override seam: fetch+parse a source map for a script URL's `.map`. */
  fetchSourceMap?: (mapUrl: string) => Promise<RawSourceMap | null>;
  /** Suppress an identical error (same fingerprint) seen again within this many
   *  ms (default 5000; 0 disables dedup). */
  dedupWindowMs?: number;
  /** Test seam for deterministic sampling (default Math.random). */
  random?: () => number;
  /** Test seam for the clock used by `ts` and the dedup window (default Date.now). */
  now?: () => number;
}

function debug(...args: unknown[]): void {
  try {
    if (typeof console !== "undefined") console.debug("[zigapagos observability]", ...args);
  } catch { /* never throw from the error path */ }
}

// --- Stack parsing ---------------------------------------------------------

// V8 (Chrome/Node/Edge): "    at fn (url:line:col)" or "    at url:line:col",
// with an optional "async " prefix and eval wrappers we ignore.
function parseV8(line: string): StackFrame | null {
  if (!line.startsWith("at ")) return null;
  let rest = line.slice(3).trim().replace(/^async\s+/, "");
  let fn: string | undefined;
  let loc: string;
  if (rest.endsWith(")")) {
    const open = rest.lastIndexOf("(");
    if (open === -1) return null;
    fn = rest.slice(0, open).trim() || undefined;
    loc = rest.slice(open + 1, -1);
  } else {
    loc = rest;
  }
  const m = /^(.*):(\d+):(\d+)$/.exec(loc);
  if (!m) return null;
  return { ...(fn ? { function: fn } : {}), filename: m[1], lineno: Number(m[2]), colno: Number(m[3]) };
}

// SpiderMonkey/JSC (Firefox/Safari): "fn@url:line:col" or "@url:line:col" or
// "url:line:col".
function parseSpiderMonkey(line: string): StackFrame | null {
  let fn: string | undefined;
  let loc = line;
  const at = line.indexOf("@");
  if (at !== -1) {
    fn = line.slice(0, at) || undefined;
    loc = line.slice(at + 1);
  }
  const m = /^(.*):(\d+):(\d+)$/.exec(loc);
  if (!m) return null;
  return { ...(fn ? { function: fn } : {}), filename: m[1], lineno: Number(m[2]), colno: Number(m[3]) };
}

/** Parse a browser stack string into structured frames (V8 + Firefox/Safari
 *  formats). Lines that don't parse (e.g. the leading message) are skipped. */
export function parseStack(stack: string | undefined): StackFrame[] {
  if (!stack) return [];
  const frames: StackFrame[] = [];
  for (const raw of stack.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    const f = parseV8(line) ?? parseSpiderMonkey(line);
    if (f) frames.push(f);
  }
  return frames;
}

function fingerprintOf(kind: ErrorKind, message: string, frames: StackFrame[]): string {
  const top = frames[0];
  const site = top ? `${top.filename ?? ""}:${top.lineno ?? ""}:${top.colno ?? ""}` : "";
  return `${kind}|${message}|${site}`;
}

/** Extract message/stack/name from a thrown value. Error instances expose them
 *  directly; a thrown non-Error (plain object/string) may still carry own
 *  `message`/`stack`/`name` properties worth preserving before falling back to
 *  `String(err)` — which otherwise collapses an object to "[object Object]". */
function extractError(err: unknown): { message: string; stack?: string; name?: string } {
  if (err instanceof Error) {
    return {
      message: err.message,
      ...(err.stack ? { stack: err.stack } : {}),
      ...(err.name ? { name: err.name } : {}),
    };
  }
  if (err !== null && typeof err === "object") {
    const o = err as Record<string, unknown>;
    return {
      message: typeof o.message === "string" ? o.message : String(err),
      ...(typeof o.stack === "string" ? { stack: o.stack } : {}),
      ...(typeof o.name === "string" ? { name: o.name } : {}),
    };
  }
  return { message: String(err) };
}

// --- Client-side symbolicator ----------------------------------------------

/** Build the `.map` URL for a script URL. The `.map` suffix appends to the PATH
 *  only — a cache-busted `app.js?v=1.2.3` (or `app.js#hash`) must resolve to
 *  `app.js.map`, not `app.js?v=1.2.3.map` (which 404s). */
function mapUrlFor(scriptUrl: string): string {
  return scriptUrl.replace(/[?#].*$/, "") + ".map";
}

/** Rewrite frames to their original positions by fetching each script's source
 *  map. Maps are cached per URL (including negative caches) so a flood of frames
 *  from one file fetches its map at most once. A frame whose map is missing or
 *  whose position doesn't map is passed through UNCHANGED. */
function createSymbolicator(fetchMap?: (mapUrl: string) => Promise<RawSourceMap | null>) {
  const fetcher = fetchMap ?? defaultFetchSourceMap;
  const cache = new Map<string, Promise<SourceMapConsumer | null>>();

  const consumerFor = (scriptUrl: string): Promise<SourceMapConsumer | null> => {
    let p = cache.get(scriptUrl);
    if (!p) {
      p = fetcher(mapUrlFor(scriptUrl))
        .then((m) => (m && m.mappings != null ? new SourceMapConsumer(m) : null))
        .catch(() => null);
      cache.set(scriptUrl, p);
    }
    return p;
  };

  const symbolicate = async (frames: StackFrame[]): Promise<StackFrame[]> => {
    return Promise.all(
      frames.map(async (f): Promise<StackFrame> => {
        if (!f.filename || f.lineno == null || f.colno == null) return f;
        try {
          const consumer = await consumerFor(f.filename);
          if (!consumer) return f;
          const pos = consumer.originalPositionFor(f.lineno, f.colno - 1);
          if (!pos || pos.source == null) return f;
          return {
            function: pos.name ?? f.function,
            filename: pos.source,
            lineno: pos.line,
            colno: pos.column,
          };
        } catch {
          return f; // symbolication is best-effort; never drop the frame
        }
      }),
    );
  };

  return { symbolicate };
}

function defaultFetchSourceMap(mapUrl: string): Promise<RawSourceMap | null> {
  if (typeof fetch === "undefined") return Promise.resolve(null);
  return fetch(mapUrl)
    .then((r) => (r.ok ? (r.json() as Promise<RawSourceMap>) : null))
    .catch(() => null);
}

// --- Default HTTP adapter --------------------------------------------------

export interface HttpAdapterOptions {
  /** Same-origin URL the batch POSTs to (`{ events: [...] }`). */
  endpoint: string;
  /** Flush once the buffer reaches this many events (default 20). */
  maxBatch?: number;
  /** Also flush on this interval in ms (default 5000; 0 disables the timer). */
  flushIntervalMs?: number;
}

/** The built-in adapter: buffers events and POSTs `{ events }` to a same-origin
 *  endpoint via apiFetch (same-origin credentials + CSRF echo for free). The
 *  buffer is emptied BEFORE the POST so a slow/failed request never double-sends;
 *  POST failures are swallowed (a reporting failure must not cascade). */
export function httpAdapter(opts: HttpAdapterOptions): ObservabilityAdapter {
  const endpoint = opts.endpoint;
  const maxBatch = opts.maxBatch ?? 20;
  const flushIntervalMs = opts.flushIntervalMs ?? 5000;
  let buffer: ObservabilityEvent[] = [];
  let intervalId: ReturnType<typeof setInterval> | undefined;

  const send = (keepalive: boolean): void => {
    if (buffer.length === 0) return;
    const events = buffer;
    buffer = [];
    try {
      const init: RequestInit = {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ events }),
      };
      if (keepalive) init.keepalive = true;
      apiFetch(endpoint, init).catch((err) => debug("POST failed", err));
    } catch (err) {
      debug("adapter flush failed", err);
    }
  };

  if (flushIntervalMs > 0 && typeof setInterval !== "undefined") {
    intervalId = setInterval(() => send(false), flushIntervalMs);
  }

  return {
    handle(event) {
      buffer.push(event);
      if (buffer.length >= maxBatch) send(false);
    },
    flush(keepalive) {
      send(keepalive);
    },
    dispose() {
      if (intervalId !== undefined) clearInterval(intervalId);
    },
  };
}

// --- initObservability -----------------------------------------------------

/** Hard cap on the error-dedup map (see `seen` below). A dashboard SPA that
 *  stays open for days mints a NEW fingerprint for every distinct error, and
 *  fingerprints routinely embed variable data ("Failed to fetch
 *  /api/orders/48213"), so an unbounded map grows forever — the same leak
 *  `MAX_SCROLL_POSITIONS` bounds in the router. */
const MAX_SEEN_FINGERPRINTS = 512;

/** Evict oldest-first until the dedup map is back within `max`. Insertion order
 *  IS expiry order (every entry gets the same window), so the oldest key is
 *  always the one closest to expiry — no scan for the minimum is needed. */
function pruneSeen(seen: Map<string, number>, max: number): void {
  for (const fingerprint of seen.keys()) {
    if (seen.size <= max) break;
    seen.delete(fingerprint);
  }
}

export function initObservability(opts: InitObservabilityOptions = {}): () => void {
  if (isServer()) return () => {};

  const adapter = opts.adapter ?? (opts.endpoint ? httpAdapter({ endpoint: opts.endpoint }) : null);
  if (!adapter) {
    throw new Error("initObservability: provide `endpoint` or a custom `adapter`");
  }

  const now = opts.now ?? Date.now;
  const random = opts.random ?? Math.random;
  const sampleRate = opts.sampleRate ?? 1;
  const dedupWindowMs = opts.dedupWindowMs ?? 5000;
  const symbolicator = opts.symbolicate ? createSymbolicator(opts.fetchSourceMap) : null;

  // fingerprint -> expiry timestamp; a repeat before expiry is suppressed.
  // BOUNDED: expired entries are deleted on read and the map is capped at
  // MAX_SEEN_FINGERPRINTS with oldest-first eviction (see pruneSeen).
  const seen = new Map<string, number>();

  // Set once the page starts going away (pagehide / visibility-hidden). While
  // unloading, async source-map fetches can be aborted mid-flight, so an error
  // firing here must dispatch SYNCHRONOUSLY (raw frames) rather than be lost.
  let isUnloading = false;

  // Sampling + (for errors) dedup gate. Returns true when the event should ship.
  const gate = (fingerprint: string | null): boolean => {
    if (fingerprint !== null && dedupWindowMs > 0) {
      const t = now();
      const exp = seen.get(fingerprint);
      if (exp !== undefined) {
        if (t < exp) return false; // deduped
        // Expired: DELETE rather than read past it, so the re-inserted entry
        // lands in the newest slot and insertion order stays recency order.
        seen.delete(fingerprint);
      }
      seen.set(fingerprint, t + dedupWindowMs);
      if (seen.size > MAX_SEEN_FINGERPRINTS) pruneSeen(seen, MAX_SEEN_FINGERPRINTS);
    }
    return random() < sampleRate;
  };

  const contextOf = (): Record<string, unknown> | undefined => {
    if (!opts.context) return undefined;
    try {
      return opts.context();
    } catch (err) {
      debug("context() threw", err);
      return undefined;
    }
  };

  const reportError = (input: ErrorInput): void => {
    try {
      const frames = parseStack(input.stack);
      const fingerprint = fingerprintOf(input.kind, input.message, frames);
      if (!gate(fingerprint)) return; // sampled out / deduped — before symbolication
      const ctx = contextOf();
      const base: ErrorPayload = {
        type: "error",
        kind: input.kind,
        message: input.message,
        frames,
        pathname: currentPathname(),
        ts: now(),
        fingerprint,
        ...(input.name ? { name: input.name } : {}),
        ...(input.stack ? { stack: input.stack } : {}),
        ...(opts.release ? { release: opts.release } : {}),
        ...(ctx ? { context: ctx } : {}),
      };
      if (symbolicator && !isUnloading) {
        symbolicator
          .symbolicate(frames)
          .then((mapped) => adapter.handle({ ...base, frames: mapped }))
          .catch(() => adapter.handle(base));
      } else {
        // No symbolicator, or the page is unloading (an async fetch would be
        // aborted before it could dispatch): ship the raw frames synchronously.
        adapter.handle(base);
      }
    } catch (err) {
      debug("reportError failed", err);
    }
  };

  const reportPerf = (metric: string, value: number): void => {
    try {
      if (!gate(null)) return; // sampling only — perf is not deduped
      const ctx = contextOf();
      adapter.handle({
        type: "perf",
        metric,
        value,
        pathname: currentPathname(),
        ts: now(),
        ...(opts.release ? { release: opts.release } : {}),
        ...(ctx ? { context: ctx } : {}),
      });
    } catch (err) {
      debug("reportPerf failed", err);
    }
  };

  // --- window/document listeners (additive) ---
  const onError = (ev: ErrorEvent) => {
    const info = ev.error != null ? extractError(ev.error) : null;
    reportError({
      message: ev.message || info?.message || "error",
      kind: "error",
      ...(info?.stack ? { stack: info.stack } : {}),
      ...(info?.name ? { name: info.name } : {}),
    });
  };
  const onRejection = (ev: PromiseRejectionEvent) => {
    const info = extractError(ev.reason);
    reportError({
      message: info.message,
      kind: "unhandledrejection",
      ...(info.stack ? { stack: info.stack } : {}),
      ...(info.name ? { name: info.name } : {}),
    });
  };
  const onPageHide = () => { isUnloading = true; adapter.flush?.(true); };
  const onVisibility = () => { if (document.visibilityState === "hidden") { isUnloading = true; adapter.flush?.(true); } };

  // Chain the manual hook (host.reportError → window.zigapagosOnError) so a
  // manual report feeds INTO this pipe without stealing an existing consumer.
  const prevHook = (window as any).zigapagosOnError;
  const hook = (msg: unknown) => {
    reportError({ message: String(msg), kind: "manual" });
    if (typeof prevHook === "function") {
      try { prevHook(msg); } catch (err) { debug("prior hook threw", err); }
    }
  };
  (window as any).zigapagosOnError = hook;

  window.addEventListener("error", onError);
  window.addEventListener("unhandledrejection", onRejection);
  window.addEventListener("pagehide", onPageHide);
  document.addEventListener("visibilitychange", onVisibility);

  // ErrorBoundary catches arrive through this seam (errors.ts).
  const unregisterSink = __registerErrorSink(reportError);

  // --- perf / nav-timing (opt-in, best-effort) ---
  const perfObservers: PerformanceObserver[] = [];
  if (opts.perf) setupPerf(reportPerf, perfObservers);

  return () => {
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onRejection);
    window.removeEventListener("pagehide", onPageHide);
    document.removeEventListener("visibilitychange", onVisibility);
    unregisterSink();
    for (const obs of perfObservers) {
      try { obs.disconnect(); } catch { /* ignore */ }
    }
    // Restore the prior hook only if nobody replaced ours in the meantime.
    if ((window as any).zigapagosOnError === hook) {
      (window as any).zigapagosOnError = prevHook;
    }
    adapter.flush?.(false);
    adapter.dispose?.();
  };
}

// Install PerformanceObservers for FCP, LCP and long tasks. Each is independent
// and feature-detected, so a browser missing an entry type just skips it; the
// whole block is wrapped so a missing PerformanceObserver never throws.
function setupPerf(report: (metric: string, value: number) => void, sink: PerformanceObserver[]): void {
  if (typeof PerformanceObserver === "undefined") return;

  const observe = (type: string, cb: (entry: any) => void): void => {
    try {
      const obs = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) cb(entry);
      });
      // `buffered` replays entries that fired before we subscribed (e.g. FCP).
      obs.observe({ type, buffered: true } as PerformanceObserverInit);
      sink.push(obs);
    } catch { /* unsupported entry type — skip */ }
  };

  observe("paint", (e) => { if (e.name === "first-contentful-paint") report("FCP", e.startTime); });
  // LCP fires repeatedly; the LAST value before the page is backgrounded is the
  // real one, so we report each candidate and let the sink keep the latest.
  observe("largest-contentful-paint", (e) => report("LCP", e.startTime));
  observe("longtask", (e) => report("longtask", e.duration));
}
