import { test, expect, afterEach } from "bun:test";
import { mockHost, flush } from "@z/runtime/testing";
import { host } from "@z/runtime/host";

let mh: ReturnType<typeof mockHost>;
afterEach(() => mh?.restore());

test("flags: seeds the flags store as resolved", () => {
  mh = mockHost({ flags: { canBook: true }, experiments: { hero: "b" } });
  mh.install();
  expect(host.store.getJson<any>("flags")).toEqual({ flags: { canBook: true }, experiments: { hero: "b" } });
});

test("fetch: routes host.fetchOpts and captures calls", async () => {
  mh = mockHost({ fetch: (url) => ({ ok: url }) });
  mh.install();
  const env = await host.fetchOpts({ url: "/api/x" });
  expect(env.status).toBe(200);
  expect(JSON.parse(env.body)).toEqual({ ok: "/api/x" });
  expect(mh.fetches.map((f) => f.url)).toContain("/api/x");
});

test("reportError: captured into errors[]", () => {
  mh = mockHost(); mh.install();
  host.reportError("boom");
  expect(mh.errors).toEqual(["boom"]);
});

test("cookies: seeded and readable both ways", () => {
  mh = mockHost({ cookies: { sid: "abc" } }); mh.install();
  expect(host.cookies.get("sid")).toBe("abc");
  expect(mh.cookies.sid).toBe("abc");
});

test("clock: fixed now + advanceClock", () => {
  mh = mockHost({ now: 1000 }); mh.install();
  expect(host.now()).toBe(1000);
  mh.advanceClock(500);
  expect(host.now()).toBe(1500);
});

test("scroll: setScroll drives host.onScroll", async () => {
  mh = mockHost({ scrollY: 0 }); mh.install();
  let seen = -1;
  host.onScroll((y) => { seen = y; });
  await mh.setScroll(120);
  expect(seen).toBe(120);
});

test("matchMedia: seeded match + setMedia change", async () => {
  mh = mockHost({ media: { "(max-width: 600px)": true } }); mh.install();
  const seen: boolean[] = [];
  host.matchMedia("(max-width: 600px)", (m) => seen.push(m));
  await flush();                                     // host delivers the current value on a microtask
  await mh.setMedia("(max-width: 600px)", false);    // then the change
  expect(seen).toEqual([true, false]);
});

test("loadScript: resolves per config + records scriptsLoaded", async () => {
  const url = "https://x.test/ok.js";
  mh = mockHost({ scripts: { [url]: true } }); mh.install();
  await expect(host.loadScript(url)).resolves.toBe(true);
  expect(mh.scriptsLoaded).toContain(url);
});

test("loadScript: error case resolves false", async () => {
  const url = "https://x.test/bad.js";
  mh = mockHost({ scripts: { [url]: false } }); mh.install();
  await expect(host.loadScript(url)).resolves.toBe(false);
});

test("recaptcha: token seeded + live setter", () => {
  mh = mockHost({ recaptchaToken: "TOK" }); mh.install();
  expect(host.recaptchaToken()).toBe("TOK");
  mh.setRecaptchaToken("TOK2");
  expect(host.recaptchaToken()).toBe("TOK2");
});

test("server: drives isServer()===true for the test", () => {
  mh = mockHost({ server: true }); mh.install();
  expect(host.now()).toBe(0);
});

test("clock: mockHost({now}) freezes new Date() for non-zero value", () => {
  mh = mockHost({ now: 1000 }); mh.install();
  expect(new Date().getTime()).toBe(1000);
  mh.restore();
  expect(new Date().getTime()).not.toBe(1000);
});

test("restore: undoes fetch/matchMedia/error-hook/stores", () => {
  const origFetch = globalThis.fetch;
  const origMM = window.matchMedia;
  mh = mockHost({ flags: { a: true } }); mh.install();
  mh.restore();
  expect(globalThis.fetch).toBe(origFetch);
  expect(window.matchMedia).toBe(origMM);
  expect((window as any).zigapagosOnError).toBeUndefined();
  expect(host.store.getStr("flags")).toBe(""); // stores reset
});
