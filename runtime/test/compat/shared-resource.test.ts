import { test, expect, afterEach } from "bun:test";
import { renderIsland, ssrIsland, flush, type RenderResult } from "@z/runtime/testing";
import { h } from "@z/runtime/core";
import { makeSharedResource } from "@z/runtime/compat";

interface Cust { name: string }
const customer = makeSharedResource<Cust>({ store: "customer", url: "/api/club/me" });
function Reader() { const c = customer.use(); return h("div", null, c ? c.name : "loading"); }

let r: RenderResult<any> | undefined;
afterEach(() => r?.unmount());

test("use() is null until the store resolves, then returns the parsed value", async () => {
  r = renderIsland(Reader, {});
  expect(r.text()).toBe("loading");                 // store empty → null
  await r.host.resolveShared("customer", { name: "Ada" });
  expect(r.text()).toBe("Ada");
});

test("prime() de-dupes via host.fetchShared (one fetch per store)", async () => {
  r = renderIsland(Reader, {}, { host: { fetch: () => ({ name: "Ada" }) } });
  customer.prime();
  customer.prime();
  await flush();
  expect(r.host.fetches.filter((f) => f.url === "/api/club/me").length).toBe(1);
});

test("ssr renders the skeleton (server store empty → null)", () => {
  expect(ssrIsland(Reader, {})).toContain("loading");
});
