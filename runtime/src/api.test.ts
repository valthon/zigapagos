import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { apiFetch } from "./api.ts";

// --- harness ---------------------------------------------------------------
// Point the document at a fixed origin so same/cross-origin detection is
// deterministic, then monkeypatch globalThis.fetch to capture the (input, init)
// it was called with (without performing a real request).

const ORIGIN = "https://app.example.com";

function setOrigin(url: string): void {
  const w = window as any;
  if (w.happyDOM?.setURL) w.happyDOM.setURL(url);
  else window.history.replaceState({}, "", url);
}

// Clear any zb_csrf cookie between cases (document.cookie can't be deleted, but
// setting an expired one drops it).
function clearCsrf(): void {
  document.cookie = "zb_csrf=; Max-Age=0";
}

let captured: { input: string | URL | Request; init?: RequestInit } | null = null;
const realFetch = globalThis.fetch;

beforeEach(() => {
  setOrigin(`${ORIGIN}/`);
  clearCsrf();
  captured = null;
  globalThis.fetch = ((input: any, init?: any) => {
    captured = { input, init };
    return Promise.resolve(new Response("ok", { status: 200 }));
  }) as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = realFetch;
  clearCsrf();
});

// init.headers as passed to fetch — normalize to a Headers for assertions.
function sentHeaders(): Headers {
  return new Headers(captured!.init!.headers as HeadersInit);
}

describe("apiFetch", () => {
  test("GET same-origin: no X-CSRF-Token, credentials include", async () => {
    document.cookie = "zb_csrf=tok123"; // present, but must NOT be echoed on GET
    await apiFetch("/api/thing");
    expect(sentHeaders().has("X-CSRF-Token")).toBe(false);
    expect(captured!.init!.credentials).toBe("include");
  });

  test("POST same-origin with zb_csrf: X-CSRF-Token === cookie, credentials include", async () => {
    document.cookie = "zb_csrf=tok123";
    await apiFetch("/api/thing", { method: "POST" });
    expect(sentHeaders().get("X-CSRF-Token")).toBe("tok123");
    expect(captured!.init!.credentials).toBe("include");
  });

  test("POST cross-origin: token NOT leaked and credentials NOT forced to include", async () => {
    document.cookie = "zb_csrf=tok123";
    await apiFetch("https://evil.example.net/steal", { method: "POST" });
    // The whole security point: a third-party origin must never see the token.
    expect(sentHeaders().has("X-CSRF-Token")).toBe(false);
    // And we must not force cookies cross-origin (caller passed nothing).
    expect(captured!.init!.credentials).toBeUndefined();
  });

  test("caller-provided X-CSRF-Token is preserved (not overwritten)", async () => {
    document.cookie = "zb_csrf=cookieTok";
    await apiFetch("/api/thing", { method: "PUT", headers: { "X-CSRF-Token": "callerTok" } });
    expect(sentHeaders().get("X-CSRF-Token")).toBe("callerTok");
  });

  test("no zb_csrf cookie: no X-CSRF-Token header on a mutating request", async () => {
    // clearCsrf() ran in beforeEach; cookie absent.
    await apiFetch("/api/thing", { method: "POST" });
    expect(sentHeaders().has("X-CSRF-Token")).toBe(false);
  });

  test("caller can override credentials (same-origin)", async () => {
    await apiFetch("/api/thing", { credentials: "omit" });
    expect(captured!.init!.credentials).toBe("omit");
  });

  describe("header merge across HeadersInit shapes (mutating, csrf added)", () => {
    beforeEach(() => { document.cookie = "zb_csrf=tok123"; });

    test("Headers instance", async () => {
      const h = new Headers({ "X-Custom": "a" });
      await apiFetch("/api/thing", { method: "POST", headers: h });
      const sent = sentHeaders();
      expect(sent.get("X-Custom")).toBe("a");
      expect(sent.get("X-CSRF-Token")).toBe("tok123");
      // caller's object is not mutated
      expect(h.has("X-CSRF-Token")).toBe(false);
    });

    test("record", async () => {
      await apiFetch("/api/thing", { method: "POST", headers: { "X-Custom": "b" } });
      const sent = sentHeaders();
      expect(sent.get("X-Custom")).toBe("b");
      expect(sent.get("X-CSRF-Token")).toBe("tok123");
    });

    test("array of pairs", async () => {
      await apiFetch("/api/thing", { method: "POST", headers: [["X-Custom", "c"]] });
      const sent = sentHeaders();
      expect(sent.get("X-Custom")).toBe("c");
      expect(sent.get("X-CSRF-Token")).toBe("tok123");
    });
  });

  test("method taken from a Request object (POST → CSRF echoed)", async () => {
    document.cookie = "zb_csrf=tok123";
    const req = new Request(`${ORIGIN}/api/thing`, { method: "POST" });
    await apiFetch(req);
    expect(sentHeaders().get("X-CSRF-Token")).toBe("tok123");
    expect(captured!.init!.credentials).toBe("include");
  });

  test("absolute same-origin URL is treated as same-origin", async () => {
    document.cookie = "zb_csrf=tok123";
    await apiFetch(`${ORIGIN}/api/thing`, { method: "POST" });
    expect(sentHeaders().get("X-CSRF-Token")).toBe("tok123");
    expect(captured!.init!.credentials).toBe("include");
  });
});

// --- session-expiry notification --------------------------------------------
// A same-origin 401/403 response through apiFetch notifies the (framework-
// internal) unauthorized listener — the Router subscribes to re-run the active
// route's guard. Cross-origin responses never trigger it, and a throwing
// listener must never break the fetch path.
import { onUnauthorizedResponse } from "./session.ts";

describe("apiFetch unauthorized notification", () => {
  function respondWith(status: number): void {
    globalThis.fetch = ((input: any, init?: any) => {
      captured = { input, init };
      return Promise.resolve(new Response(status === 204 ? null : "x", { status }));
    }) as typeof fetch;
  }

  test("same-origin 401 notifies the unauthorized listener (after the response settles)", async () => {
    let notified = 0;
    const off = onUnauthorizedResponse(() => { notified++; });
    respondWith(401);
    const res = await apiFetch("/api/me");
    expect(res.status).toBe(401); // the response still reaches the caller
    expect(notified).toBe(1);
    off();
  });

  test("same-origin 403 notifies too", async () => {
    let notified = 0;
    const off = onUnauthorizedResponse(() => { notified++; });
    respondWith(403);
    await apiFetch("/api/admin", { method: "POST" });
    expect(notified).toBe(1);
    off();
  });

  test("same-origin 200/404/500 do NOT notify", async () => {
    let notified = 0;
    const off = onUnauthorizedResponse(() => { notified++; });
    for (const status of [200, 404, 500]) {
      respondWith(status);
      await apiFetch("/api/thing");
    }
    expect(notified).toBe(0);
    off();
  });

  test("cross-origin 401 does NOT notify (the session policy is same-origin only)", async () => {
    let notified = 0;
    const off = onUnauthorizedResponse(() => { notified++; });
    respondWith(401);
    await apiFetch("https://elsewhere.example.org/api/me");
    expect(notified).toBe(0);
    off();
  });

  test("a throwing listener never breaks the fetch path", async () => {
    const off = onUnauthorizedResponse(() => { throw new Error("boom"); });
    respondWith(401);
    const res = await apiFetch("/api/me");
    expect(res.status).toBe(401);
    off();
  });

  test("an unsubscribed listener is not called", async () => {
    let notified = 0;
    const off = onUnauthorizedResponse(() => { notified++; });
    off();
    respondWith(401);
    await apiFetch("/api/me");
    expect(notified).toBe(0);
  });
});
