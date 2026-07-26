// ---------------------------------------------------------------------------
// Browser error relay — a first-party error-reporting pipe for @z/runtime.
//
// initErrorRelay() installs window "error"/"unhandledrejection" listeners
// (additive — never clobbering existing handlers), routes them plus any
// host.reportError() call into a batched, sampled POST to a same-origin
// endpoint via apiFetch (same-origin credentials + CSRF echo for free).
// The backend (zigbase#244) relays these into its own error pipe.
//
// Design notes:
//  - Client-only: isServer() → initErrorRelay is a no-op returning a noop
//    teardown. No window/document is touched on the server.
//  - The enqueue sink is a module singleton. It no-ops until initErrorRelay
//    wires it, so ErrorBoundary can enqueue whether or not the relay is up:
//    pre-init, a boundary still renders its fallback; the report is simply
//    dropped until initErrorRelay() runs. (Documented, intentional.)
//  - Handlers NEVER throw — a reporting failure must not cascade into the app.
//    enqueue() and flush() swallow their own errors (console.debug at most).
// ---------------------------------------------------------------------------

import { Component, h, Fragment } from "./core.ts";
import type { VNode, ComponentChildren } from "./core.ts";
import { isServer, currentPathname } from "./ssr-env.ts";
import { apiFetch } from "./api.ts";

export type ErrorKind = "error" | "unhandledrejection" | "boundary" | "manual";

export interface ErrorRecord {
  message: string;
  stack?: string;
  kind: ErrorKind;
  pathname: string;
  ts: number;
  [key: string]: unknown;
}

export interface InitErrorRelayOptions {
  /** Same-origin URL the batch POSTs to. */
  endpoint: string;
  /** Report only this fraction of events (0..1, default 1). */
  sampleRate?: number;
  /** Flush once the batch reaches this many records (default 20). */
  maxBatch?: number;
  /** Also flush on this interval in ms (default 5000). */
  flushIntervalMs?: number;
  /** Extra fields merged into every record. */
  context?: () => Record<string, unknown>;
  /** Test seam for deterministic sampling (default Math.random). */
  random?: () => number;
}

// The one input a handler/boundary hands to enqueue; pathname/ts/context are
// filled in by enqueue itself. `name` (the error constructor name) is optional
// and unused by the legacy relay, but carried so richer sinks (observability)
// can read it.
export type ErrorInput = { message: string; stack?: string; kind: ErrorKind; name?: string };

interface RelayState {
  endpoint: string;
  sampleRate: number;
  maxBatch: number;
  context?: () => Record<string, unknown>;
  random: () => number;
  batch: ErrorRecord[];
  intervalId: ReturnType<typeof setInterval> | undefined;
}

// Module singleton. null until initErrorRelay wires the sink; enqueue no-ops
// while null, so a stray boundary/report before init is silently dropped.
let state: RelayState | null = null;

function debug(...args: unknown[]): void {
  try {
    if (typeof console !== "undefined") console.debug("[zigapagos error relay]", ...args);
  } catch { /* never throw from the error path */ }
}

// ---------------------------------------------------------------------------
// Secondary error sinks — the seam the first-class observability layer
// (observability.ts) subscribes to so an ErrorBoundary catch reaches it too,
// without either pipe stealing the other. `initErrorRelay` (the legacy relay)
// keeps its own module-singleton `enqueue`; `initObservability` registers a
// sink here. A boundary catch fans out to BOTH — whichever is active consumes
// it (the inactive one no-ops), and the rare both-active case simply reports to
// each, so the integration is order-independent.
// ---------------------------------------------------------------------------

const secondarySinks = new Set<(input: ErrorInput) => void>();

/** Register a sink to receive every ErrorBoundary catch. Returns an unregister
 *  fn. Internal seam for observability.ts — not part of the public API. */
export function __registerErrorSink(fn: (input: ErrorInput) => void): () => void {
  secondarySinks.add(fn);
  return () => { secondarySinks.delete(fn); };
}

// Fan a boundary catch out to the legacy relay's enqueue AND every registered
// secondary sink. A throwing sink is swallowed (never cascade from the error path).
function dispatchBoundary(input: ErrorInput): void {
  enqueue(input);
  for (const fn of secondarySinks) {
    try { fn(input); } catch (err) { debug("error sink threw", err); }
  }
}

// Build the full record, apply per-record sampling, batch, and flush at cap.
// Wrapped so nothing here can ever escape into a window handler.
function enqueue(input: ErrorInput): void {
  const s = state;
  if (!s) return; // relay not initialized — drop (see module header).
  try {
    if (s.random() >= s.sampleRate) return; // sampled out
    const record: ErrorRecord = {
      message: input.message,
      kind: input.kind,
      pathname: currentPathname(),
      ts: Date.now(),
      ...(input.stack ? { stack: input.stack } : {}),
      ...(s.context ? s.context() : {}),
    };
    s.batch.push(record);
    if (s.batch.length >= s.maxBatch) flush(s, false);
  } catch (err) {
    debug("enqueue failed", err);
  }
}

// POST the current batch and clear it. The batch is emptied BEFORE the POST so
// a slow/failed request never causes the same records to be sent twice. POST
// failures are swallowed (a reporting failure must not cascade).
function flush(s: RelayState, keepalive: boolean): void {
  if (s.batch.length === 0) return;
  const errors = s.batch;
  s.batch = [];
  try {
    const init: RequestInit = {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ errors }),
    };
    if (keepalive) init.keepalive = true;
    apiFetch(s.endpoint, init).catch((err) => debug("POST failed", err));
  } catch (err) {
    debug("flush failed", err);
  }
}

export function initErrorRelay(opts: InitErrorRelayOptions): () => void {
  if (isServer()) return () => {};

  const s: RelayState = {
    endpoint: opts.endpoint,
    sampleRate: opts.sampleRate ?? 1,
    maxBatch: opts.maxBatch ?? 20,
    context: opts.context,
    random: opts.random ?? Math.random,
    batch: [],
    intervalId: undefined,
  };
  state = s;

  const onError = (ev: ErrorEvent) => {
    const err = ev.error;
    enqueue({
      message: ev.message || (err != null ? String(err) : "error"),
      stack: err instanceof Error ? err.stack : undefined,
      kind: "error",
    });
  };
  const onRejection = (ev: PromiseRejectionEvent) => {
    const reason = ev.reason;
    enqueue({
      message: reason instanceof Error ? reason.message : String(reason),
      stack: reason instanceof Error ? reason.stack : undefined,
      kind: "unhandledrejection",
    });
  };
  const onPageHide = () => flush(s, true);
  const onVisibility = () => { if (document.visibilityState === "hidden") flush(s, true); };

  // Chain any previously-installed hook so host.reportError feeds INTO the relay
  // without stealing an existing consumer. Teardown restores exactly this prior.
  const prevHook = (window as any).zigapagosOnError;
  const hook = (msg: unknown) => {
    enqueue({ message: String(msg), kind: "manual" });
    if (typeof prevHook === "function") {
      try { prevHook(msg); } catch (err) { debug("prior hook threw", err); }
    }
  };
  (window as any).zigapagosOnError = hook;

  window.addEventListener("error", onError);
  window.addEventListener("unhandledrejection", onRejection);
  window.addEventListener("pagehide", onPageHide);
  document.addEventListener("visibilitychange", onVisibility);

  s.intervalId = setInterval(() => flush(s, false), opts.flushIntervalMs ?? 5000);

  return () => {
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onRejection);
    window.removeEventListener("pagehide", onPageHide);
    document.removeEventListener("visibilitychange", onVisibility);
    if (s.intervalId !== undefined) clearInterval(s.intervalId);
    // Restore the prior hook only if nobody replaced ours in the meantime.
    if ((window as any).zigapagosOnError === hook) {
      (window as any).zigapagosOnError = prevHook;
    }
    // Flush whatever is still pending, then detach the sink.
    flush(s, false);
    if (state === s) state = null;
  };
}

// ---------------------------------------------------------------------------
// ErrorBoundary — a Preact class component that catches a throwing subtree,
// reports it (kind:"boundary", with the component stack when present), and
// renders `fallback` (a node or `(error) => node`) instead of crashing.
//
// It enqueues via the SAME module-singleton sink initErrorRelay wires, so the
// fallback renders whether or not the relay is initialized; when it is not, the
// report is dropped (the boundary still keeps the app alive).
// ---------------------------------------------------------------------------

type Fallback = ComponentChildren | ((error: unknown) => ComponentChildren);

export interface ErrorBoundaryProps {
  fallback?: Fallback;
  children?: ComponentChildren;
}

interface ErrorBoundaryState {
  error: unknown;
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null };

  componentDidCatch(error: unknown, info: { componentStack?: string }): void {
    const err = error as Error | unknown;
    dispatchBoundary({
      message: err instanceof Error ? err.message : String(err),
      stack: info?.componentStack ?? (err instanceof Error ? err.stack : undefined),
      kind: "boundary",
      ...(err instanceof Error && err.name ? { name: err.name } : {}),
    });
    this.setState({ error });
  }

  render(): VNode | null {
    if (this.state.error != null) {
      const fb = this.props.fallback;
      const node = typeof fb === "function" ? fb(this.state.error) : fb;
      return node != null ? h(Fragment, null, node) : null;
    }
    return h(Fragment, null, this.props.children);
  }
}
