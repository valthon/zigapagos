import { test, expect, afterEach } from "bun:test";
import { renderIsland, ssrIsland, click } from "@z/runtime/testing";
import Counter from "../fixtures/Counter.island.tsx";
import Gate from "../fixtures/Gate.island.tsx";
import Loc from "../fixtures/Loc.island.tsx";

let r: ReturnType<typeof renderIsland>;
afterEach(() => r?.unmount());

test("hydrate mode: SSR markup adopted and interactive", async () => {
  r = renderIsland(Counter, { start: 2, label: "hi" });
  expect(r.get("button").textContent).toBe("hi: 2");
  await click(r.get("button"));
  expect(r.get("button").textContent).toBe("hi: 3");
});

test("render mode: client-only, interactive", async () => {
  r = renderIsland(Counter, { start: 0, label: "n" }, { mode: "render" });
  expect(r.text("button")).toBe("n: 0");
  await click(r.get("button"));
  expect(r.text("button")).toBe("n: 1");
});

test("ssrIsland: pure server string, no clock leak", () => {
  expect(ssrIsland(Counter, { start: 5, label: "x" })).toBe("<button>x: 5</button>");
});

test("flag gating via inline mock config", async () => {
  r = renderIsland(Gate, {}, { host: { flags: { canBook: true } } });
  expect(r.query("a[href='/booking']")).not.toBeNull();
  await r.host.setFlags({ canBook: false });
  expect(r.query("a[href='/booking']")).toBeNull();
  expect(r.text()).toContain("soon");
});

test("pathname opt drives host.pathname()", () => {
  r = renderIsland(Loc, {}, { mode: "ssr", pathname: "/booking" });
  expect(r.html()).toContain("path: /booking");
});

test("get throws on 0 or >1 matches", () => {
  r = renderIsland(Counter, { start: 0, label: "z" });
  expect(() => r.get(".nope")).toThrow();
});

test("get throws when selector matches >1 element", () => {
  r = renderIsland(Counter, { start: 0, label: "z" });
  // Inject two duplicate nodes so get() sees multiple matches.
  r.container.innerHTML += '<span class="dup"></span><span class="dup"></span>';
  expect(() => r.get(".dup")).toThrow(/2 matches/);
});
