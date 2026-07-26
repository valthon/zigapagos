import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { initErrorRelay, ErrorBoundary } from "./errors.ts";
import { host } from "./host.ts";
import { h, render } from "./core.ts";

// --- harness ---------------------------------------------------------------
// Point the document at a fixed origin (so currentPathname is deterministic)
// and monkeypatch globalThis.fetch to capture every POST apiFetch performs.

const ORIGIN = "https://app.example.com";

function setOrigin(url: string): void {
  const w = window as any;
  if (w.happyDOM?.setURL) w.happyDOM.setURL(url);
  else window.history.replaceState({}, "", url);
}

let posts: any[] = [];
const realFetch = globalThis.fetch;

// Latest relay teardown; afterEach always calls it so a leaked interval/hook
// from one test can never bleed into the next.
let activeTeardown: (() => void) | undefined;
function init(opts: Parameters<typeof initErrorRelay>[0]): () => void {
  activeTeardown = initErrorRelay(opts);
  return activeTeardown;
}

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

// Dispatch synthetic events. Plain Event + assigned props exercises the same
// handler code across happy-dom versions without depending on ErrorEvent/
// PromiseRejectionEvent constructor availability.
function fireError(message: string): void {
  const ev = new Event("error") as any;
  ev.message = message;
  ev.error = new Error(message);
  window.dispatchEvent(ev);
}
function fireRejection(reason: unknown): void {
  const ev = new Event("unhandledrejection") as any;
  ev.reason = reason;
  window.dispatchEvent(ev);
}

const firstErrors = () => posts[0].body.errors;

describe("initErrorRelay", () => {
  test("window 'error' event → POSTed record with kind/message/pathname/ts", () => {
    init({ endpoint: "/_report", maxBatch: 1 });
    fireError("boom");
    expect(posts.length).toBe(1);
    expect(posts[0].input).toBe("/_report");
    const rec = firstErrors()[0];
    expect(rec.kind).toBe("error");
    expect(rec.message).toBe("boom");
    expect(rec.pathname).toBe("/app");
    expect(typeof rec.ts).toBe("number");
    expect(typeof rec.stack).toBe("string"); // from the Error
  });

  test("unhandledrejection is captured", () => {
    init({ endpoint: "/_report", maxBatch: 1 });
    fireRejection(new Error("nope"));
    expect(posts.length).toBe(1);
    const rec = firstErrors()[0];
    expect(rec.kind).toBe("unhandledrejection");
    expect(rec.message).toBe("nope");
  });

  test("host.reportError feeds in AND a pre-existing hook is still called (chaining)", () => {
    const prior: string[] = [];
    const priorHook = (m: string) => prior.push(m);
    (window as any).zigapagosOnError = priorHook;

    init({ endpoint: "/_report", maxBatch: 1 });
    host.reportError("manual boom");

    expect(posts.length).toBe(1);
    const rec = firstErrors()[0];
    expect(rec.kind).toBe("manual");
    expect(rec.message).toBe("manual boom");
    // the previously-installed hook was chained, not clobbered
    expect(prior).toEqual(["manual boom"]);
  });

  test("context() fields are merged into every record", () => {
    init({ endpoint: "/_report", maxBatch: 1, context: () => ({ release: "1.2.3", user: "u1" }) });
    fireError("boom");
    const rec = firstErrors()[0];
    expect(rec.release).toBe("1.2.3");
    expect(rec.user).toBe("u1");
  });

  test("sampleRate 0 drops every record (nothing POSTed)", () => {
    init({ endpoint: "/_report", maxBatch: 1, sampleRate: 0, random: () => 0 });
    fireError("a");
    fireError("b");
    expect(posts.length).toBe(0);
  });

  test("sampleRate 1 keeps every record", () => {
    init({ endpoint: "/_report", maxBatch: 1, sampleRate: 1, random: () => 0.999 });
    fireError("a");
    fireError("b");
    expect(posts.length).toBe(2);
  });

  test("reaching maxBatch triggers an immediate flush", () => {
    init({ endpoint: "/_report", maxBatch: 3, flushIntervalMs: 100000 });
    fireError("a"); expect(posts.length).toBe(0);
    fireError("b"); expect(posts.length).toBe(0);
    fireError("c"); expect(posts.length).toBe(1);
    expect(firstErrors().length).toBe(3);
  });

  test("pagehide flushes remaining records with keepalive", () => {
    init({ endpoint: "/_report", maxBatch: 100, flushIntervalMs: 100000 });
    fireError("pending");
    expect(posts.length).toBe(0);
    window.dispatchEvent(new Event("pagehide"));
    expect(posts.length).toBe(1);
    expect(posts[0].init.keepalive).toBe(true);
    expect(firstErrors()[0].message).toBe("pending");
  });

  test("visibilitychange→hidden flushes remaining records", () => {
    init({ endpoint: "/_report", maxBatch: 100, flushIntervalMs: 100000 });
    fireError("pending");
    expect(posts.length).toBe(0);
    const desc = Object.getOwnPropertyDescriptor(document, "visibilityState");
    Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
    try {
      document.dispatchEvent(new Event("visibilitychange"));
    } finally {
      if (desc) Object.defineProperty(document, "visibilityState", desc);
    }
    expect(posts.length).toBe(1);
    expect(posts[0].init.keepalive).toBe(true);
  });

  test("teardown removes listeners and restores the prior hook", () => {
    const priorHook = (_m: string) => {};
    (window as any).zigapagosOnError = priorHook;

    const teardown = init({ endpoint: "/_report", maxBatch: 1 });
    teardown();

    expect((window as any).zigapagosOnError).toBe(priorHook);
    posts = [];
    fireError("after-teardown"); // listeners gone → nothing captured
    expect(posts.length).toBe(0);
  });

  test("isServer → no-op teardown, no listeners installed", () => {
    const { __setServerForTest } = require("./ssr-env.ts");
    __setServerForTest(true);
    try {
      const teardown = initErrorRelay({ endpoint: "/_report" });
      activeTeardown = teardown;
      expect(typeof teardown).toBe("function");
      teardown(); // must not throw
    } finally {
      __setServerForTest(undefined);
    }
    expect(posts.length).toBe(0);
  });
});

describe("ErrorBoundary", () => {
  const Boom = () => { throw new Error("child boom"); };

  test("renders a node fallback and reports kind:'boundary'", async () => {
    init({ endpoint: "/_report", maxBatch: 1 });
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      render(h(ErrorBoundary, { fallback: h("p", null, "fallback!") }, h(Boom, null)), container);
      await new Promise((r) => setTimeout(r, 0));
      expect(container.textContent).toContain("fallback!");
      const rec = posts.map((p) => p.body?.errors?.[0]).find((r) => r?.kind === "boundary");
      expect(rec).toBeDefined();
      expect(rec.message).toBe("child boom");
    } finally {
      render(null as any, container);
      container.remove();
    }
  });

  test("renders a function fallback with the caught error", async () => {
    init({ endpoint: "/_report", maxBatch: 1 });
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      const fallback = (err: unknown) => h("p", null, `caught: ${(err as Error).message}`);
      render(h(ErrorBoundary, { fallback }, h(Boom, null)), container);
      await new Promise((r) => setTimeout(r, 0));
      expect(container.textContent).toContain("caught: child boom");
    } finally {
      render(null as any, container);
      container.remove();
    }
  });

  test("works pre-init: renders fallback even when the relay is not initialized", async () => {
    // No init() call → the enqueue sink is a no-op, but the boundary still
    // keeps the app alive by rendering its fallback.
    const container = document.createElement("div");
    document.body.appendChild(container);
    try {
      render(h(ErrorBoundary, { fallback: h("p", null, "safe") }, h(Boom, null)), container);
      await new Promise((r) => setTimeout(r, 0));
      expect(container.textContent).toContain("safe");
      expect(posts.length).toBe(0); // nothing reported pre-init
    } finally {
      render(null as any, container);
      container.remove();
    }
  });
});
