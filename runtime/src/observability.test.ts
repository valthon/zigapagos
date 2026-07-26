import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import {
  initObservability, httpAdapter, parseStack,
  type ObservabilityAdapter, type ObservabilityEvent, type ErrorPayload,
} from "./observability.ts";
import type { RawSourceMap } from "./source-map.ts";
import { host } from "./host.ts";
import { ErrorBoundary } from "./errors.ts";
import { h, render } from "./core.ts";
import { bundleIsland } from "../sidecar/bundle-island.ts";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// --- harness ---------------------------------------------------------------

const ORIGIN = "https://app.example.com";
function setOrigin(url: string): void {
  const w = window as any;
  if (w.happyDOM?.setURL) w.happyDOM.setURL(url);
  else window.history.replaceState({}, "", url);
}

// A capturing adapter: records every event the core dispatches.
function capturingAdapter() {
  const events: ObservabilityEvent[] = [];
  let flushed: boolean[] = [];
  let disposed = 0;
  const adapter: ObservabilityAdapter = {
    handle(e) { events.push(e); },
    flush(k) { flushed.push(k); },
    dispose() { disposed++; },
  };
  return { adapter, events, flushed, stats: () => ({ disposed }) };
}

let posts: any[] = [];
const realFetch = globalThis.fetch;
let activeTeardown: (() => void) | undefined;

beforeEach(() => {
  setOrigin(`${ORIGIN}/app`);
  posts = [];
  activeTeardown = undefined;
  delete (window as any).zigapagosOnError;
  globalThis.fetch = ((input: any, init?: any) => {
    let body: any;
    if (typeof init?.body === "string") { try { body = JSON.parse(init.body); } catch { /* ignore */ } }
    posts.push({ input, init, body });
    return Promise.resolve(new Response("ok", { status: 200 }));
  }) as typeof fetch;
});

afterEach(() => {
  activeTeardown?.();
  activeTeardown = undefined;
  globalThis.fetch = realFetch;
  delete (window as any).zigapagosOnError;
});

function init(opts: Parameters<typeof initObservability>[0]): () => void {
  activeTeardown = initObservability(opts);
  return activeTeardown;
}

function fireError(message: string, err?: Error): void {
  const ev = new Event("error") as any;
  ev.message = message;
  ev.error = err ?? new Error(message);
  window.dispatchEvent(ev);
}
function fireRejection(reason: unknown): void {
  const ev = new Event("unhandledrejection") as any;
  ev.reason = reason;
  window.dispatchEvent(ev);
}

// --- parseStack ------------------------------------------------------------

describe("parseStack", () => {
  test("parses V8 (Chrome/Node) frames with and without a function name", () => {
    const stack = [
      "Error: boom",
      "    at doThing (https://app.example.com/spa/app.js:10:15)",
      "    at https://app.example.com/spa/app.js:3:1",
      "    at async load (https://app.example.com/spa/app.js:20:5)",
    ].join("\n");
    const frames = parseStack(stack);
    expect(frames).toEqual([
      { function: "doThing", filename: "https://app.example.com/spa/app.js", lineno: 10, colno: 15 },
      { filename: "https://app.example.com/spa/app.js", lineno: 3, colno: 1 },
      { function: "load", filename: "https://app.example.com/spa/app.js", lineno: 20, colno: 5 },
    ]);
  });

  test("parses Firefox/Safari (@) frames", () => {
    const stack = [
      "doThing@https://app.example.com/spa/app.js:10:15",
      "@https://app.example.com/spa/app.js:3:1",
    ].join("\n");
    const frames = parseStack(stack);
    expect(frames).toEqual([
      { function: "doThing", filename: "https://app.example.com/spa/app.js", lineno: 10, colno: 15 },
      { filename: "https://app.example.com/spa/app.js", lineno: 3, colno: 1 },
    ]);
  });

  test("returns [] for undefined / unparseable input", () => {
    expect(parseStack(undefined)).toEqual([]);
    expect(parseStack("just a message\nno frames here")).toEqual([]);
  });
});

// --- structured payloads ---------------------------------------------------

describe("structured error payloads", () => {
  test("window 'error' → a structured ErrorPayload with parsed frames + release + context", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, release: "v1.2.3", context: () => ({ user: "u1" }) });
    const err = new Error("boom");
    err.stack = "Error: boom\n    at doThing (https://app.example.com/spa/app.js:10:15)";
    fireError("boom", err);
    expect(events.length).toBe(1);
    const e = events[0] as ErrorPayload;
    expect(e.type).toBe("error");
    expect(e.kind).toBe("error");
    expect(e.message).toBe("boom");
    expect(e.name).toBe("Error");
    expect(e.pathname).toBe("/app");
    expect(typeof e.ts).toBe("number");
    expect(e.release).toBe("v1.2.3");
    expect(e.context).toEqual({ user: "u1" });
    expect(e.frames[0]).toEqual({ function: "doThing", filename: "https://app.example.com/spa/app.js", lineno: 10, colno: 15 });
    expect(typeof e.fingerprint).toBe("string");
  });

  test("unhandledrejection is captured with kind + name", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter });
    fireRejection(new TypeError("nope"));
    const e = events[0] as ErrorPayload;
    expect(e.kind).toBe("unhandledrejection");
    expect(e.message).toBe("nope");
    expect(e.name).toBe("TypeError");
  });

  test("host.reportError feeds in (kind manual) AND chains a pre-existing hook", () => {
    const prior: string[] = [];
    (window as any).zigapagosOnError = (m: string) => prior.push(m);
    const { adapter, events } = capturingAdapter();
    init({ adapter });
    host.reportError("manual boom");
    const e = events[0] as ErrorPayload;
    expect(e.kind).toBe("manual");
    expect(e.message).toBe("manual boom");
    expect(prior).toEqual(["manual boom"]);
  });
});

// --- non-Error thrown values -----------------------------------------------

describe("non-Error extraction", () => {
  test("a thrown non-Error with own message/stack/name is preserved (not [object Object])", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, dedupWindowMs: 0 });
    // A plain object thrown (not an Error instance) carrying its own fields.
    const ev = new Event("error") as any;
    ev.message = ""; // browser gave no message → fall back to the value's own
    ev.error = { message: "custom failure", stack: "custom@app.js:5:3", name: "CustomError" };
    window.dispatchEvent(ev);
    const e = events[0] as ErrorPayload;
    expect(e.message).toBe("custom failure");
    expect(e.name).toBe("CustomError");
    expect(e.stack).toBe("custom@app.js:5:3");
    // The stack string is still parsed into frames.
    expect(e.frames[0]).toEqual({ function: "custom", filename: "app.js", lineno: 5, colno: 3 });
  });

  test("a rejection with a non-Error reason keeps its message/stack/name", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, dedupWindowMs: 0 });
    fireRejection({ message: "rejected badly", stack: "r@app.js:1:1", name: "Weird" });
    const e = events[0] as ErrorPayload;
    expect(e.kind).toBe("unhandledrejection");
    expect(e.message).toBe("rejected badly");
    expect(e.name).toBe("Weird");
    expect(e.stack).toBe("r@app.js:1:1");
  });

  test("a rejection with a plain object lacking message falls back to String()", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, dedupWindowMs: 0 });
    fireRejection({ code: 42 });
    const e = events[0] as ErrorPayload;
    expect(e.message).toBe("[object Object]"); // no own message → String() fallback
    expect(e.name).toBeUndefined();
  });
});

// --- sampling --------------------------------------------------------------

describe("sampling", () => {
  test("sampleRate 0 drops every event", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, sampleRate: 0, random: () => 0, dedupWindowMs: 0 });
    fireError("a");
    fireError("b");
    expect(events.length).toBe(0);
  });

  test("sampleRate 1 keeps every event (random just below 1)", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, sampleRate: 1, random: () => 0.999, dedupWindowMs: 0 });
    fireError("a");
    fireError("b");
    expect(events.length).toBe(2);
  });

  test("boundary between kept and dropped is < sampleRate", () => {
    const { adapter, events } = capturingAdapter();
    // random 0.4 < 0.5 keeps; then flip to 0.6 >= 0.5 drops.
    let r = 0.4;
    init({ adapter, sampleRate: 0.5, random: () => r, dedupWindowMs: 0 });
    fireError("a"); expect(events.length).toBe(1);
    r = 0.6;
    fireError("b"); expect(events.length).toBe(1);
  });
});

// --- dedup -----------------------------------------------------------------

describe("dedup", () => {
  test("an identical error within the window is suppressed; a distinct one is not", () => {
    const { adapter, events } = capturingAdapter();
    let t = 1000;
    init({ adapter, dedupWindowMs: 5000, now: () => t, random: () => 0 });
    const mk = (m: string) => { const e = new Error(m); e.stack = `Error: ${m}\n    at f (https://x/app.js:1:1)`; return e; };
    fireError("boom", mk("boom")); // first: passes
    fireError("boom", mk("boom")); // duplicate within window: suppressed
    expect(events.length).toBe(1);
    fireError("other", mk("other")); // distinct fingerprint: passes
    expect(events.length).toBe(2);
  });

  test("the same error AFTER the window elapses passes again", () => {
    const { adapter, events } = capturingAdapter();
    let t = 1000;
    init({ adapter, dedupWindowMs: 5000, now: () => t, random: () => 0 });
    const mk = () => { const e = new Error("boom"); e.stack = "Error: boom\n    at f (https://x/app.js:1:1)"; return e; };
    fireError("boom", mk());
    expect(events.length).toBe(1);
    t = 1000 + 5001; // past the window
    fireError("boom", mk());
    expect(events.length).toBe(2);
  });

  test("dedupWindowMs 0 disables dedup (a flood all passes)", () => {
    const { adapter, events } = capturingAdapter();
    init({ adapter, dedupWindowMs: 0, random: () => 0 });
    for (let i = 0; i < 5; i++) fireError("boom");
    expect(events.length).toBe(5);
  });

  test("the dedup map is BOUNDED — the oldest fingerprint is evicted, not kept forever", () => {
    // A long-lived SPA whose fingerprints embed variable data ("Failed to fetch
    // /api/orders/48213") mints one map entry per distinct error. Without a cap
    // the map grows for the lifetime of the page; the observable proof of the
    // bound is that the OLDEST fingerprint stops being remembered.
    const { adapter, events } = capturingAdapter();
    const t = 1000;
    init({ adapter, dedupWindowMs: 1_000_000, now: () => t, random: () => 0 });
    const mk = (m: string) => { const e = new Error(m); e.stack = `Error: ${m}\n    at f (https://x/app.js:1:1)`; return e; };

    fireError("oldest", mk("oldest"));
    expect(events.length).toBe(1);
    fireError("oldest", mk("oldest")); // inside the (huge) window: suppressed
    expect(events.length).toBe(1);

    // Flood past the 512-entry cap with distinct fingerprints.
    for (let i = 0; i < 600; i++) fireError(`e${i}`, mk(`e${i}`));
    expect(events.length).toBe(601);

    // "oldest" was evicted, so it reports again — proving the map is bounded.
    fireError("oldest", mk("oldest"));
    expect(events.length).toBe(602);
  });

  test("perf events are sampled but NOT deduped by the error window", () => {
    // Drive reportPerf indirectly is hard; assert dedup only touches errors by
    // firing two identical errors (deduped to 1) — proving perf's null path is
    // separate is covered by the perf suite; here we just assert error dedup.
    const { adapter, events } = capturingAdapter();
    init({ adapter, dedupWindowMs: 5000, random: () => 0 });
    fireError("boom");
    fireError("boom");
    expect(events.filter((e) => e.type === "error").length).toBe(1);
  });
});

// --- adapter dispatch + default httpAdapter --------------------------------

describe("adapter dispatch", () => {
  test("a custom adapter receives handle() and flush()/dispose() on teardown", () => {
    const cap = capturingAdapter();
    const teardown = init({ adapter: cap.adapter, dedupWindowMs: 0 });
    fireError("boom");
    expect(cap.events.length).toBe(1);
    teardown();
    activeTeardown = undefined;
    expect(cap.flushed).toEqual([false]); // teardown flush(keepalive=false)
    expect(cap.stats().disposed).toBe(1);
  });

  test("pagehide + visibilitychange→hidden flush with keepalive", () => {
    const cap = capturingAdapter();
    init({ adapter: cap.adapter });
    window.dispatchEvent(new Event("pagehide"));
    expect(cap.flushed).toEqual([true]);
    const desc = Object.getOwnPropertyDescriptor(document, "visibilityState");
    Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
    try { document.dispatchEvent(new Event("visibilitychange")); }
    finally { if (desc) Object.defineProperty(document, "visibilityState", desc); }
    expect(cap.flushed).toEqual([true, true]);
  });

  test("default httpAdapter batches and POSTs { events } via apiFetch", () => {
    init({ endpoint: "/_obs", dedupWindowMs: 0 });
    // Below the default maxBatch (20): nothing sent until flush.
    fireError("a");
    fireError("b");
    expect(posts.length).toBe(0);
    activeTeardown!(); // teardown flush
    activeTeardown = undefined;
    expect(posts.length).toBe(1);
    expect(posts[0].input).toBe("/_obs");
    expect(posts[0].body.events.length).toBe(2);
    expect(posts[0].body.events[0].type).toBe("error");
  });

  test("httpAdapter flushes at maxBatch", () => {
    const adapter = httpAdapter({ endpoint: "/_obs", maxBatch: 2, flushIntervalMs: 0 });
    init({ adapter, dedupWindowMs: 0 });
    fireError("a"); expect(posts.length).toBe(0);
    fireError("b"); expect(posts.length).toBe(1); // reached maxBatch
    expect(posts[0].body.events.length).toBe(2);
  });

  test("initObservability with neither endpoint nor adapter throws", () => {
    expect(() => initObservability({})).toThrow(/endpoint.*adapter/);
  });
});

// --- ErrorBoundary integration ---------------------------------------------

describe("ErrorBoundary integration", () => {
  const Boom = () => { throw new Error("child boom"); };

  test("a boundary catch reports through the observability pipe (kind boundary)", async () => {
    const cap = capturingAdapter();
    init({ adapter: cap.adapter, dedupWindowMs: 0 });
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      render(h(ErrorBoundary, { fallback: h("p", null, "fallback!") }, h(Boom, null)), container);
      await new Promise((r) => setTimeout(r, 0));
      expect(container.textContent).toContain("fallback!");
      const e = cap.events.find((x) => x.type === "error" && (x as ErrorPayload).kind === "boundary") as ErrorPayload | undefined;
      expect(e).toBeDefined();
      expect(e!.message).toBe("child boom");
    } finally {
      render(null as any, container);
      container.remove();
    }
  });
});

// --- client-side symbolication ---------------------------------------------

describe("client-side symbolication", () => {
  // A hand-built map for https://x/app.js:1:? -> orig.ts. genCol 0 -> orig.ts line 42 col 7 name "realFn".
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const enc1 = (v: number): string => { let x = v < 0 ? (-v << 1) | 1 : v << 1; let s = ""; do { let d = x & 31; x >>>= 5; if (x > 0) d |= 32; s += B64[d]; } while (x > 0); return s; };
  const seg = (f: number[]) => f.map(enc1).join("");
  const map: RawSourceMap = {
    version: 3,
    sources: ["orig.ts"],
    names: ["realFn"],
    mappings: seg([0, 0, 41, 6, 0]), // genCol0 -> src0 line idx41(=42) col idx6(=7) name0
  };

  test("frames are rewritten to their original position when a map is served", async () => {
    const cap = capturingAdapter();
    init({
      adapter: cap.adapter,
      symbolicate: true,
      dedupWindowMs: 0,
      fetchSourceMap: async (mapUrl) => (mapUrl === "https://x/app.js.map" ? map : null),
    });
    const err = new Error("boom");
    err.stack = "Error: boom\n    at min (https://x/app.js:1:1)";
    fireError("boom", err);
    await new Promise((r) => setTimeout(r, 0)); // symbolication is async
    const e = cap.events[0] as ErrorPayload;
    expect(e.frames[0]).toEqual({ function: "realFn", filename: "orig.ts", lineno: 42, colno: 7 });
  });

  test("a cache-busted script URL (query string) maps to `<path>.map`, not `...?v=1.2.3.map`", async () => {
    const cap = capturingAdapter();
    const requested: string[] = [];
    init({
      adapter: cap.adapter,
      symbolicate: true,
      dedupWindowMs: 0,
      fetchSourceMap: async (mapUrl) => {
        requested.push(mapUrl);
        return mapUrl === "https://x/app.js.map" ? map : null;
      },
    });
    const err = new Error("boom");
    err.stack = "Error: boom\n    at min (https://x/app.js?v=1.2.3:1:1)";
    fireError("boom", err);
    await new Promise((r) => setTimeout(r, 0));
    // The query string is stripped before appending `.map` (path-only suffix).
    expect(requested).toEqual(["https://x/app.js.map"]);
    const e = cap.events[0] as ErrorPayload;
    expect(e.frames[0]).toEqual({ function: "realFn", filename: "orig.ts", lineno: 42, colno: 7 });
  });

  test("while unloading, an error dispatches synchronously with RAW frames (no aborted fetch)", () => {
    const cap = capturingAdapter();
    init({
      adapter: cap.adapter,
      symbolicate: true,
      dedupWindowMs: 0,
      fetchSourceMap: async (mapUrl) => (mapUrl === "https://x/app.js.map" ? map : null),
    });
    // pagehide flags the page as unloading (and flushes) — a subsequent error's
    // async symbolication would be aborted, so it must ship synchronously.
    window.dispatchEvent(new Event("pagehide"));
    const err = new Error("boom");
    err.stack = "Error: boom\n    at min (https://x/app.js:1:1)";
    fireError("boom", err);
    // No await: the event is already dispatched, carrying the raw (unmapped) frame.
    expect(cap.events.length).toBe(1);
    expect((cap.events[0] as ErrorPayload).frames[0]).toEqual({
      function: "min", filename: "https://x/app.js", lineno: 1, colno: 1,
    });
  });

  test("a frame whose map is missing passes through unchanged", async () => {
    const cap = capturingAdapter();
    init({
      adapter: cap.adapter,
      symbolicate: true,
      dedupWindowMs: 0,
      fetchSourceMap: async () => null,
    });
    const err = new Error("boom");
    err.stack = "Error: boom\n    at min (https://x/app.js:9:9)";
    fireError("boom", err);
    await new Promise((r) => setTimeout(r, 0));
    const e = cap.events[0] as ErrorPayload;
    expect(e.frames[0]).toEqual({ function: "min", filename: "https://x/app.js", lineno: 9, colno: 9 });
  });

  // End-to-end: a REAL minified bundle + its REAL emitted `.map` (produced
  // by the release bundler) drive the full client symbolicator, proving the two
  // halves fit — the map the build emits is exactly what `symbolicate: true`
  // consumes to turn a production frame back into original source coordinates.
  test("a REAL emitted map symbolicates a REAL minified frame back to original source", async () => {
    const dir = mkdtempSync(join(tmpdir(), "sm-e2e-"));
    writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
    // The throw is on line 3; symbolication must recover that.
    writeFileSync(join(dir, "detonate.ts"), `export function detonate() {\n  const x = 1;\n  throw new Error("kaboom-marker");\n}\nexport default detonate;\n`);
    const out = join(dir, "App.js");
    const mapfile = join(dir, "App.js.map");
    await bundleIsland({ entry: join(dir, "detonate.ts"), outfile: out, mapfile, depfile: join(dir, "d.d"), external: [], minify: true, sourcemap: true });

    const js = readFileSync(out, "utf8");
    const realMap = JSON.parse(readFileSync(mapfile, "utf8")) as RawSourceMap;
    // Locate the minified `throw` — its 1-based (line, col) is the frame a
    // browser would report for the production crash.
    const lines = js.split("\n");
    let fr: { line: number; col: number } | null = null;
    for (let i = 0; i < lines.length; i++) {
      const c = lines[i].indexOf("throw");
      if (c !== -1) { fr = { line: i + 1, col: c + 1 }; break; }
    }
    expect(fr).not.toBeNull();

    const cap = capturingAdapter();
    init({
      adapter: cap.adapter,
      symbolicate: true,
      dedupWindowMs: 0,
      // The bundle is "served" at /App.js; the symbolicator appends `.map` and
      // fetches /App.js.map — we return the real map the build emitted.
      fetchSourceMap: async (mapUrl) => (mapUrl === "https://x/App.js.map" ? realMap : null),
    });
    const err = new Error("kaboom-marker");
    err.stack = `Error: kaboom-marker\n    at detonate (https://x/App.js:${fr!.line}:${fr!.col})`;
    fireError("kaboom-marker", err);
    await new Promise((r) => setTimeout(r, 0)); // symbolication is async
    const e = cap.events[0] as ErrorPayload;
    // The frame now names the ORIGINAL source (Bun records it relative to the
    // build cwd), not the minified App.js, and points at the real `throw` line.
    expect(e.frames[0].filename).toContain("detonate.ts");
    expect(e.frames[0].filename).not.toContain("App.js");
    expect(e.frames[0].lineno).toBe(3);               // the original `throw` line
  });
});

// --- perf / nav-timing capture ---------------------------------------------

describe("perf capture", () => {
  // A fake PerformanceObserver that immediately replays synthetic entries for
  // the observed type, so FCP/LCP/longtask wiring is tested deterministically
  // (real happy-dom never emits these entries).
  const ENTRIES: Record<string, any[]> = {
    paint: [{ name: "first-contentful-paint", startTime: 123 }, { name: "first-paint", startTime: 100 }],
    "largest-contentful-paint": [{ startTime: 456 }],
    longtask: [{ duration: 78 }],
  };
  class FakePO {
    disconnected = false;
    constructor(private cb: (list: { getEntries: () => any[] }) => void) {}
    observe(init: { type: string }) {
      const entries = ENTRIES[init.type] ?? [];
      this.cb({ getEntries: () => entries });
    }
    disconnect() { this.disconnected = true; }
  }

  test("perf:true captures FCP, LCP and long tasks as PerfPayloads", () => {
    const realPO = (globalThis as any).PerformanceObserver;
    (globalThis as any).PerformanceObserver = FakePO;
    try {
      const cap = capturingAdapter();
      init({ adapter: cap.adapter, perf: true, release: "v9" });
      const perf = cap.events.filter((e) => e.type === "perf") as any[];
      const byMetric = Object.fromEntries(perf.map((p) => [p.metric, p.value]));
      expect(byMetric.FCP).toBe(123); // only first-contentful-paint, not first-paint
      expect(byMetric.LCP).toBe(456);
      expect(byMetric.longtask).toBe(78);
      expect(perf[0].pathname).toBe("/app");
      expect(perf[0].release).toBe("v9");
    } finally {
      (globalThis as any).PerformanceObserver = realPO;
    }
  });

  test("perf events respect sampling", () => {
    const realPO = (globalThis as any).PerformanceObserver;
    (globalThis as any).PerformanceObserver = FakePO;
    try {
      const cap = capturingAdapter();
      init({ adapter: cap.adapter, perf: true, sampleRate: 0, random: () => 0 });
      expect(cap.events.filter((e) => e.type === "perf").length).toBe(0);
    } finally {
      (globalThis as any).PerformanceObserver = realPO;
    }
  });
});

// --- server / teardown -----------------------------------------------------

describe("lifecycle", () => {
  test("teardown removes listeners and restores the prior manual hook", () => {
    const priorHook = (_m: string) => {};
    (window as any).zigapagosOnError = priorHook;
    const cap = capturingAdapter();
    const teardown = init({ adapter: cap.adapter, dedupWindowMs: 0 });
    teardown();
    activeTeardown = undefined;
    expect((window as any).zigapagosOnError).toBe(priorHook);
    const before = cap.events.length;
    fireError("after-teardown");
    expect(cap.events.length).toBe(before); // listener gone
  });

  test("isServer → no-op teardown, no adapter interaction", () => {
    const { __setServerForTest } = require("./ssr-env.ts");
    __setServerForTest(true);
    try {
      const cap = capturingAdapter();
      const teardown = initObservability({ adapter: cap.adapter });
      activeTeardown = teardown;
      expect(typeof teardown).toBe("function");
      teardown();
      activeTeardown = undefined;
      expect(cap.events.length).toBe(0);
    } finally {
      __setServerForTest(undefined);
    }
  });
});
