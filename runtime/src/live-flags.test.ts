import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { h, render } from "./core.ts";
import { initFlags, stopLiveFlags, useFlag } from "./flags.ts";
import { host, __resetStoresForTest } from "./host.ts";
import { __setServerForTest } from "./ssr-env.ts";
import { flush } from "./testing/flush.ts";

// ---------------------------------------------------------------------------
// harness
//
// initFlags({ live }) does two network-ish things:
//   1. the initial host.fetchShared → the RAW global `fetch`;
//   2. the live re-fetch → apiFetch → the RAW global `fetch`.
// Both are covered by mocking globalThis.fetch to serve `flagBody`/`flagStatus`
// (mutable so a test can change the served value between the initial load and a
// live signal). EventSource is stubbed with a recorder that lets a test dispatch
// a `__features` event, a default `message`, and an `onerror`.
// ---------------------------------------------------------------------------

const STATE_URL = "/api/flags/state";
const SSE_URL = "/api/realtime/sse";

let flagBody = "";
let flagStatus = 200;
let fetchCalls = 0;
let fetchReject = false; // simulate a network error (rejected promise)

const realFetch = globalThis.fetch;
const realEventSource = (globalThis as any).EventSource;

class MockEventSource {
  static instances: MockEventSource[] = [];
  url: string;
  withCredentials: boolean;
  closed = false;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;
  private listeners: Record<string, Array<(ev: Event) => void>> = {};

  constructor(url: string, init?: { withCredentials?: boolean }) {
    this.url = url;
    this.withCredentials = init?.withCredentials ?? false;
    MockEventSource.instances.push(this);
  }
  addEventListener(type: string, cb: (ev: Event) => void): void {
    (this.listeners[type] ??= []).push(cb);
  }
  removeEventListener(type: string, cb: (ev: Event) => void): void {
    const arr = this.listeners[type];
    if (arr) this.listeners[type] = arr.filter((f) => f !== cb);
  }
  close(): void { this.closed = true; }

  // --- test drivers ---
  emitFeatures(): void {
    for (const cb of this.listeners["__features"] ?? []) cb(new MessageEvent("__features"));
  }
  emitMessage(): void {
    this.onmessage?.(new MessageEvent("message"));
  }
  emitError(): void {
    this.onerror?.(new Event("error"));
  }
}

function only(): MockEventSource {
  expect(MockEventSource.instances.length).toBe(1);
  return MockEventSource.instances[0]!;
}

beforeEach(() => {
  __resetStoresForTest();
  MockEventSource.instances = [];
  flagBody = "";
  flagStatus = 200;
  fetchCalls = 0;
  fetchReject = false;
  (globalThis as any).EventSource = MockEventSource;
  globalThis.fetch = ((_input: any, _init?: any) => {
    fetchCalls++;
    if (fetchReject) return Promise.reject(new Error("network down"));
    return Promise.resolve(new Response(flagBody, { status: flagStatus }));
  }) as typeof fetch;
});

afterEach(() => {
  __setServerForTest(undefined);
  stopLiveFlags();
  globalThis.fetch = realFetch;
  (globalThis as any).EventSource = realEventSource;
  __resetStoresForTest();
});

const A = '{"flags":{"beta":false},"experiments":{}}';
const B = '{"flags":{"beta":true},"experiments":{}}';

describe("initFlags live (SSE)", () => {
  test("SSE __features signal → re-fetch → the flags store updates", async () => {
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();
    expect(host.store.getStr("flags")).toBe(A); // initial fetchShared

    const es = only();
    expect(es.url).toBe(SSE_URL);
    expect(es.withCredentials).toBe(true);

    flagBody = B; // backend flipped a kill-switch
    es.emitFeatures();
    await flush();
    expect(host.store.getStr("flags")).toBe(B); // store re-populated on signal
  });

  test("the default `message` channel also triggers a re-fetch (server variance)", async () => {
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();
    const es = only();

    flagBody = B;
    es.emitMessage();
    await flush();
    expect(host.store.getStr("flags")).toBe(B);
  });

  test("useFlag re-renders when a signal updates the store", async () => {
    flagBody = A; // beta:false
    initFlags(STATE_URL, { live: true });
    await flush();

    const seen: boolean[] = [];
    function Probe() { const on = useFlag("beta"); seen.push(on); return h("span", null, on ? "on" : "off"); }
    const container = document.createElement("div");
    document.body.appendChild(container);
    render(h(Probe, {}), container);
    await flush();
    expect(container.textContent).toBe("off");

    flagBody = B; // beta:true
    only().emitFeatures();
    await flush();
    expect(container.textContent).toBe("on");

    render(null as any, container);
    container.remove();
  });

  test("idempotent: two initFlags({live}) open exactly ONE EventSource", async () => {
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    initFlags(STATE_URL, { live: true });
    await flush();
    expect(MockEventSource.instances.length).toBe(1);
  });

  test("re-fetch HTTP error → reportError, no default written (loud-fail)", async () => {
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();
    expect(host.store.getStr("flags")).toBe(A);

    const errors: string[] = [];
    (window as any).zigapagosOnError = (m: string) => errors.push(m);

    flagStatus = 503;
    flagBody = "gateway blew up";
    only().emitFeatures();
    await flush();

    expect(host.store.getStr("flags")).toBe(A); // unchanged — never wrote a default
    expect(errors.some((m) => m.includes("HTTP 503"))).toBe(true);
    delete (window as any).zigapagosOnError;
  });

  test("re-fetch network error → reportError, store unchanged", async () => {
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();

    const errors: string[] = [];
    (window as any).zigapagosOnError = (m: string) => errors.push(m);

    fetchReject = true;
    only().emitFeatures();
    await flush();

    expect(host.store.getStr("flags")).toBe(A);
    expect(errors.some((m) => m.includes("network down"))).toBe(true);
    delete (window as any).zigapagosOnError;
  });
});

describe("initFlags live — fallback", () => {
  test("SSE onerror → EventSource closed + poll-on-nav engaged (silent)", async () => {
    flagBody = A;
    const errors: string[] = [];
    (window as any).zigapagosOnError = (m: string) => errors.push(m);

    initFlags(STATE_URL, { live: true });
    await flush();
    const es = only();

    es.emitError();
    expect(es.closed).toBe(true);
    // Silent: an SSE drop is a normal degraded state, not an error to report.
    expect(errors.length).toBe(0);

    // Fallback engaged: a popstate now re-fetches.
    flagBody = B;
    window.dispatchEvent(new Event("popstate"));
    await flush();
    expect(host.store.getStr("flags")).toBe(B);
    delete (window as any).zigapagosOnError;
  });

  test("no EventSource global → straight to poll-on-nav fallback", async () => {
    delete (globalThis as any).EventSource;
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();
    expect(MockEventSource.instances.length).toBe(0); // never constructed
    expect(host.store.getStr("flags")).toBe(A);

    flagBody = B;
    window.dispatchEvent(new Event("popstate"));
    await flush();
    expect(host.store.getStr("flags")).toBe(B);
  });

  test("visibilitychange→visible re-fetches; →hidden does not", async () => {
    // Force visibilityState deterministically — the ambient value can be left
    // "hidden" by other test files (errors.test.ts toggles it), so drive it here.
    const setVisibility = (v: string) =>
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => v });
    delete (globalThis as any).EventSource;
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();

    // Hidden → no re-fetch (only a return-to-visible should refresh).
    setVisibility("hidden");
    const before = fetchCalls;
    flagBody = B;
    document.dispatchEvent(new Event("visibilitychange"));
    await flush();
    expect(fetchCalls).toBe(before);
    expect(host.store.getStr("flags")).toBe(A);

    // Visible → re-fetch.
    setVisibility("visible");
    document.dispatchEvent(new Event("visibilitychange"));
    await flush();
    expect(host.store.getStr("flags")).toBe(B);
  });

  test("stopLiveFlags tears down: a later popstate does NOT re-fetch", async () => {
    delete (globalThis as any).EventSource;
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();

    stopLiveFlags();
    const callsAfterStop = fetchCalls;
    flagBody = B;
    window.dispatchEvent(new Event("popstate"));
    await flush();
    expect(fetchCalls).toBe(callsAfterStop); // no extra fetch
    expect(host.store.getStr("flags")).toBe(A);
  });
});

describe("initFlags back-compat + SSR", () => {
  test("initFlags() with no opts opens NO EventSource (just fetchShared)", async () => {
    flagBody = A;
    initFlags();
    await flush();
    expect(MockEventSource.instances.length).toBe(0);
    expect(host.store.getStr("flags")).toBe(A);
  });

  test("initFlags(url) with no opts opens NO EventSource", async () => {
    flagBody = A;
    initFlags("/custom/flags");
    await flush();
    expect(MockEventSource.instances.length).toBe(0);
    expect(host.store.getStr("flags")).toBe(A);
  });

  test("isServer → live branch is a no-op (no EventSource, no fetch)", async () => {
    __setServerForTest(true);
    flagBody = A;
    initFlags(STATE_URL, { live: true });
    await flush();
    expect(MockEventSource.instances.length).toBe(0);
    expect(fetchCalls).toBe(0); // fetchShared also no-ops on the server
    expect(host.store.getStr("flags")).toBe(""); // store never populated
  });
});
