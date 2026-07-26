import { test, expect, mock } from "bun:test";
import { host, __resetStoresForTest, __resetScriptsForTest } from "@z/runtime/host";

test("string store round-trips and notifies subscribers once per set", async () => {
  __resetStoresForTest();
  const cb = mock(() => {});
  host.store.subscribe("flags", cb);
  host.store.setStr("flags", '{"flags":{"canBook":true}}');
  await Promise.resolve(); // flush the queued microtask notify
  expect(cb).toHaveBeenCalledTimes(1);
  expect(host.store.getStr("flags")).toBe('{"flags":{"canBook":true}}');
});

test("getJson parses, but THROWS loudly on malformed data (never defaults)", () => {
  __resetStoresForTest();
  host.store.setStr("flags", '{"flags":{"canBook":true}}');
  expect(host.store.getJson<{ flags: Record<string, boolean> }>("flags").flags.canBook).toBe(true);

  host.store.setStr("bad", "{not json");
  expect(() => host.store.getJson("bad")).toThrow();
  // Missing store also throws — no silent default.
  expect(() => host.store.getJson("missing")).toThrow();
});

test("fetchShared issues ONE request per store no matter how many callers", async () => {
  __resetStoresForTest();
  const fetchMock = mock(async () => new Response('{"flags":{"canBook":true}}', { status: 200 }));
  globalThis.fetch = fetchMock as unknown as typeof fetch;

  host.fetchShared("/api/flags/state", "flags");
  host.fetchShared("/api/flags/state", "flags"); // de-duped
  await new Promise((r) => setTimeout(r, 5));
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(host.store.getJson<{ flags: Record<string, boolean> }>("flags").flags.canBook).toBe(true);
});

test("fetchShared on HTTP error reports the error and does NOT write a default", async () => {
  __resetStoresForTest();
  const reported: string[] = [];
  (window as any).zigapagosOnError = (m: string) => reported.push(m);
  globalThis.fetch = (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch;

  host.fetchShared("/api/flags/state", "flags");
  await new Promise((r) => setTimeout(r, 5));
  expect(reported.length).toBe(1);
  expect(host.store.getStr("flags")).toBe(""); // never silently defaulted to a value
  delete (window as any).zigapagosOnError;
});

// ── Gap 3: reportError accepts unknown ───────────────────────────────────────

test("reportError(Error) surfaces the stack (or message if no stack)", () => {
  __resetStoresForTest();
  const reported: unknown[] = [];
  (window as any).zigapagosOnError = (m: unknown) => reported.push(m);
  const err = new Error("boom");
  host.reportError(err);
  // stack contains the message; fall back to message when stack is absent
  const expected = err.stack ?? err.message;
  expect(reported).toEqual([expected]);
  delete (window as any).zigapagosOnError;
});

test("reportError(Error) falls back to .message when .stack is undefined", () => {
  __resetStoresForTest();
  const reported: unknown[] = [];
  (window as any).zigapagosOnError = (m: unknown) => reported.push(m);
  const err = new Error("no-stack");
  delete (err as any).stack;
  host.reportError(err);
  expect(reported).toEqual(["no-stack"]);
  delete (window as any).zigapagosOnError;
});

test("reportError(non-Error) normalizes via String()", () => {
  __resetStoresForTest();
  const reported: unknown[] = [];
  (window as any).zigapagosOnError = (m: unknown) => reported.push(m);
  host.reportError(42);
  host.reportError("plain string");
  expect(reported[0]).toBe("42");
  expect(reported[1]).toBe("plain string");
  delete (window as any).zigapagosOnError;
});

// ── Gap 4: recaptchaToken — reCAPTCHA v2 token convenience read ──────────────

test("recaptchaToken() reads token from g-recaptcha-response textarea", () => {
  __resetStoresForTest();
  const ta = document.createElement("textarea");
  ta.id = "g-recaptcha-response";
  ta.value = "TOKEN123";
  document.body.appendChild(ta);
  expect(host.recaptchaToken()).toBe("TOKEN123");
  document.body.removeChild(ta);
});

test("recaptchaToken() returns '' when element is absent", () => {
  __resetStoresForTest();
  // Ensure element is not in DOM
  const existing = document.getElementById("g-recaptcha-response");
  if (existing) existing.remove();
  expect(host.recaptchaToken()).toBe("");
});

test("__resetScriptsForTest clears the loadScript dedupe map", () => {
  const url = "https://example.test/dedupe.js";
  const count = () => document.head.querySelectorAll(`script[src="${url}"]`).length;
  host.loadScript(url);
  host.loadScript(url);          // deduped → still one <script>
  expect(count()).toBe(1);
  __resetScriptsForTest();
  host.loadScript(url);          // dedupe cleared → a second <script> is injected
  expect(count()).toBe(2);
  // cleanup
  document.head.querySelectorAll(`script[src="${url}"]`).forEach((s) => s.remove());
  __resetScriptsForTest();
});
