// Baked build-time flag defaults.
//
// The prerender pass inlines a `<script type="application/json" data-z-flags>`
// snapshot (shaped exactly like the /api/flags/state ResolvedState payload)
// into each SPA shell. The client boot (`mountSpa`) seeds the page-global
// "flags" store from it BEFORE hydration, so `useFlag`'s very first render is
// the declared default — no false-while-loading window — and the real state
// (initFlags fetch / SSE updates) still reconciles over it via the normal
// store-subscription path.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { h, render } from "@z/runtime/core";
import { host, __resetStoresForTest } from "@z/runtime/host";
import { useFlag, seedFlagsFromShell } from "@z/runtime/flags";
import { mountSpa } from "@z/runtime/router";
import { flush } from "@z/runtime/testing";

function addSnapshot(json: string): void {
  const el = document.createElement("script");
  el.setAttribute("type", "application/json");
  el.setAttribute("data-z-flags", "");
  el.textContent = json;
  document.head.appendChild(el);
}

beforeEach(() => {
  __resetStoresForTest();
  document.head.querySelectorAll("script[data-z-flags]").forEach((el) => el.remove());
  document.body.innerHTML = "";
});
afterEach(() => {
  delete (window as any).zigapagosOnError;
});

test("seedFlagsFromShell seeds the flags store from the shell data block", () => {
  addSnapshot('{"flags":{"bookAsGuest":true,"promoBanner":false},"experiments":{}}');
  seedFlagsFromShell();
  const state = host.store.getJson<{ flags: Record<string, boolean> }>("flags");
  expect(state.flags.bookAsGuest).toBe(true);
  expect(state.flags.promoBanner).toBe(false);
});

test("seedFlagsFromShell is a no-op without a data block", () => {
  seedFlagsFromShell();
  expect(host.store.getStr("flags")).toBe("");
});

test("seedFlagsFromShell never clobbers already-resolved real state", () => {
  host.store.setStr("flags", '{"flags":{"bookAsGuest":false},"experiments":{}}');
  addSnapshot('{"flags":{"bookAsGuest":true},"experiments":{}}');
  seedFlagsFromShell();
  const state = host.store.getJson<{ flags: Record<string, boolean> }>("flags");
  expect(state.flags.bookAsGuest).toBe(false);
});

test("seedFlagsFromShell decodes the <\\/ script-safe escape in flag names", () => {
  // The emitter escapes `</` as `<\/` (a valid JSON escape) so a pathological
  // flag name can't close the script element early; JSON.parse round-trips it.
  addSnapshot('{"flags":{"a<\\/b":true},"experiments":{}}');
  seedFlagsFromShell();
  const state = host.store.getJson<{ flags: Record<string, boolean> }>("flags");
  expect(state.flags["a</b"]).toBe(true);
});

test("seedFlagsFromShell reports (and skips) a malformed snapshot instead of poisoning the store", () => {
  const reported: string[] = [];
  (window as any).zigapagosOnError = (msg: string) => reported.push(msg);
  addSnapshot("{not json");
  seedFlagsFromShell();
  expect(host.store.getStr("flags")).toBe("");
  expect(reported.length).toBe(1);
  expect(reported[0]).toContain("data-z-flags");
});

test("mountSpa: useFlag's FIRST render is the baked default (correct by construction)", () => {
  addSnapshot('{"flags":{"bookAsGuest":true},"experiments":{}}');
  const seen: boolean[] = [];
  function App() {
    const on = useFlag("bookAsGuest");
    seen.push(on);
    return h("div", null, on ? "guest-on" : "guest-off");
  }
  const root = document.createElement("div");
  root.id = "z-spa-root";
  // The prerendered shell content: the sidecar SSRs with the same defaults
  // seeded, so the skeleton markup already shows the ON branch.
  root.innerHTML = "<div>guest-on</div>";
  document.body.appendChild(root);

  mountSpa(App, "#z-spa-root");
  expect(seen.length).toBeGreaterThan(0);
  expect(seen[0]).toBe(true); // never a false-while-loading first render
  expect(root.textContent).toBe("guest-on");
});

test("baked defaults reconcile when the real state arrives (store update wins)", async () => {
  addSnapshot('{"flags":{"bookAsGuest":true},"experiments":{}}');
  seedFlagsFromShell();
  const root = document.createElement("div");
  document.body.appendChild(root);
  function App() {
    return h("div", null, useFlag("bookAsGuest") ? "guest-on" : "guest-off");
  }
  render(h(App, {}), root);
  expect(root.textContent).toBe("guest-on");
  // The real /api/flags/state answer (or an SSE-triggered re-fetch) lands in
  // the same store key; subscribers re-render with the authoritative value.
  host.store.setStr("flags", '{"flags":{"bookAsGuest":false},"experiments":{}}');
  await flush();
  expect(root.textContent).toBe("guest-off");
});
