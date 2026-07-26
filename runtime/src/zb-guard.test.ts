import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { zbGuard } from "./zb-guard.ts";

// --- harness (same shape as api.test.ts) ------------------------------------
// zbGuard goes through apiFetch, so we pin the document to a fixed origin and
// monkeypatch globalThis.fetch to script the ZigBase auth-refresh response.

const ORIGIN = "https://app.example.com";

function setOrigin(url: string): void {
  const w = window as any;
  if (w.happyDOM?.setURL) w.happyDOM.setURL(url);
  else window.history.replaceState({}, "", url);
}

let captured: { input: string | URL | Request; init?: RequestInit } | null = null;
const realFetch = globalThis.fetch;

function respond(fn: () => Promise<Response>): void {
  globalThis.fetch = ((input: any, init?: any) => {
    captured = { input, init };
    return fn();
  }) as unknown as typeof fetch;
}

beforeEach(() => {
  setOrigin(`${ORIGIN}/`);
  captured = null;
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

const loc = { pathname: "/admin", params: {} };

describe("zbGuard", () => {
  test("probes POST /api/collections/{collection}/auth-refresh with credentials", async () => {
    respond(async () => new Response(JSON.stringify({ token: "t", record: { id: "u1" } }), { status: 200 }));
    const guard = zbGuard({ collection: "_superusers", redirect: "/admin/login" });
    await guard(loc);
    expect(String(captured!.input)).toBe("/api/collections/_superusers/auth-refresh");
    expect(captured!.init!.method).toBe("POST");
    expect(captured!.init!.credentials).toBe("include"); // same-origin apiFetch default
  });

  test("authenticated → { ok: true, data: record } (the identity slots into useGuardData)", async () => {
    respond(async () =>
      new Response(JSON.stringify({ token: "t", record: { id: "u1", email: "a@b.c" } }), { status: 200 }));
    const guard = zbGuard<{ id: string; email: string }>({ collection: "customers", redirect: "/portal/login" });
    const res = await guard(loc);
    expect(res).toEqual({ ok: true, data: { id: "u1", email: "a@b.c" } });
  });

  test("a 200 body WITHOUT a record envelope is returned as-is", async () => {
    respond(async () => new Response(JSON.stringify({ id: "u2" }), { status: 200 }));
    const res = await zbGuard({ collection: "customers", redirect: "/portal/login" })(loc);
    expect(res).toEqual({ ok: true, data: { id: "u2" } });
  });

  test("non-OK (401) → fail closed with { redirect }", async () => {
    respond(async () => new Response("nope", { status: 401 }));
    const res = await zbGuard({ collection: "_superusers", redirect: "/admin/login" })(loc);
    expect(res).toEqual({ redirect: "/admin/login" });
  });

  test("non-OK (500) → fail closed with { redirect }", async () => {
    respond(async () => new Response("boom", { status: 500 }));
    const res = await zbGuard({ collection: "_superusers", redirect: "/admin/login" })(loc);
    expect(res).toEqual({ redirect: "/admin/login" });
  });

  test("network error → fail closed with { redirect } (never throws into the Router)", async () => {
    respond(async () => { throw new TypeError("network down"); });
    const res = await zbGuard({ collection: "_superusers", redirect: "/admin/login" })(loc);
    expect(res).toEqual({ redirect: "/admin/login" });
  });

  test("a 200 with an unparseable body still authorizes (the endpoint said OK) with undefined data", async () => {
    respond(async () => new Response("not-json", { status: 200 }));
    const res = await zbGuard({ collection: "customers", redirect: "/portal/login" })(loc);
    expect(res).toEqual({ ok: true, data: undefined });
  });

  test("the collection segment is URL-encoded", async () => {
    respond(async () => new Response(JSON.stringify({ record: {} }), { status: 200 }));
    await zbGuard({ collection: "weird/名前", redirect: "/login" })(loc);
    expect(String(captured!.input)).toBe(`/api/collections/${encodeURIComponent("weird/名前")}/auth-refresh`);
  });

  test("zbGuard is re-exported from the @z/runtime barrel", async () => {
    const barrel = await import("./index.ts");
    expect(typeof (barrel as any).zbGuard).toBe("function");
  });
});
