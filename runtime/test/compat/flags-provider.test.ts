import { test, expect, afterEach } from "bun:test";
import { renderIsland, ssrIsland, flush, type RenderResult } from "@z/runtime/testing";
import { h } from "@z/runtime/core";
import { FlagsProvider, useFlag, useExperiment, useVariant } from "@z/runtime/compat";

function Gated() { return h("div", null, useFlag("canBook") ? "open" : "soon"); }
function App() { return h(FlagsProvider, { url: "/api/flags/state" }, h(Gated, {})); }

let r: RenderResult<any> | undefined;
afterEach(() => r?.unmount());

test("FlagsProvider primes the flags store (one fetch) + renders children", async () => {
  r = renderIsland(App, {}, { host: { fetch: () => ({ flags: { canBook: true }, experiments: {} }) } });
  expect(r.text()).toContain("soon");                       // unresolved skeleton first
  await flush();                                             // flush the primed fetch
  expect(r.host.fetches.filter((f) => f.url === "/api/flags/state").length).toBe(1);
});

test("children gate on the resolved flag", async () => {
  r = renderIsland(App, {}, { host: { flags: { canBook: true } } }); // pre-seeded store
  expect(r.text()).toContain("open");
});

test("useExperiment is useVariant; SSR renders the skeleton", () => {
  expect(useExperiment).toBe(useVariant);
  function Exp() { return h("div", null, useExperiment("hero") || "default"); }
  expect(ssrIsland(Exp, {})).toContain("default");
});
