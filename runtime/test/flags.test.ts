import { test, expect, afterEach } from "bun:test";
import { renderToString, h, hydrate } from "@z/runtime/core";
import { host } from "@z/runtime/host";
import { __resetStoresForTest } from "@z/runtime/host";
import { FeatureFlag } from "@z/runtime/flags";
import { renderIsland, flush, type RenderResult } from "@z/runtime/testing";
import Gate from "./fixtures/Gate.island.tsx";

// ── Migrated onto the harness ─────────────────────────────────────────────────

let r: RenderResult<any> | undefined;
afterEach(() => r?.unmount());

test("useFlag reads the SERVER-resolved flag from the store (no client bucketing)", async () => {
  r = renderIsland(Gate, {});
  // SSR renders the skeleton (store empty → flag false).
  expect(r.query("span")?.textContent).toBe("soon");
  // Server resolves the flag → store gets the value → island re-renders gated UI.
  await r.host.setFlags({ canBook: true });
  expect(r.query("a")?.getAttribute("href")).toBe("/booking");
});

// ── Gap 1: FeatureFlag skeleton prop ──────────────────────────────────────────

test("FeatureFlag: skeleton renders when flag is off/unresolved (SSR)", () => {
  __resetStoresForTest();
  const wrapper = document.createElement("div");
  wrapper.innerHTML = renderToString(
    h("div", null,
      h(FeatureFlag, { name: "myFlag", skeleton: h("span", null, "soon") },
        h("a", { href: "/book" }, "Book"),
      ),
    ),
  );
  expect(wrapper.querySelector("span")?.textContent).toBe("soon");
  expect(wrapper.querySelector("a")).toBeNull();
});

test("FeatureFlag: children render after flag resolves true (hydrate + store update)", async () => {
  __resetStoresForTest();
  const root = document.createElement("div");
  const vnode = h("div", null,
    h(FeatureFlag, { name: "myFlag", skeleton: h("span", null, "soon") },
      h("a", { href: "/book" }, "Book"),
    ),
  );
  root.innerHTML = renderToString(vnode);
  document.body.appendChild(root);

  hydrate(vnode, root);
  host.store.setStr("flags", '{"flags":{"myFlag":true},"experiments":{}}');
  await flush();
  expect(root.querySelector("a")?.getAttribute("href")).toBe("/book");
  expect(root.querySelector("span")).toBeNull();
});

test("FeatureFlag: backward-compat — returns null (not skeleton) when flag is false and no skeleton", () => {
  __resetStoresForTest();
  const html = renderToString(
    h(FeatureFlag, { name: "myFlag" }, h("a", { href: "/book" }, "Book")),
  );
  expect(html).toBe("");
});
