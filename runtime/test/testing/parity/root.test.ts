import { test, expect, afterEach } from "bun:test";
import { makeIslandRoot, setLocationPathname } from "@z/runtime/testing/parity";
import { bootIsland } from "@z/runtime/islands";
import { renderToString, h } from "@z/runtime/core";
import { resolve } from "node:path";
import Counter from "../../fixtures/Counter.island.tsx";

const COUNTER_URL = resolve(import.meta.dir, "../../fixtures/Counter.island.tsx");
let made: ReturnType<typeof makeIslandRoot> | undefined;
afterEach(() => made?.cleanup());

test("root mirrors pass.zig shape and bootIsland hydrates over it", async () => {
  const props = { start: 2, label: "hi" };
  const ssr = renderToString(h(Counter, props));
  made = makeIslandRoot(ssr, props, COUNTER_URL, { id: "z-island-test-p", zClient: "load" });
  expect(made.root.hasAttribute("data-z-island")).toBe(true);
  expect(made.root.dataset.zModule).toBe(COUNTER_URL);
  expect(made.root.dataset.zClient).toBe("load");
  expect(made.propsScript.getAttribute("data-z-props")).toBe("z-island-test-p");
  await bootIsland(made.root);
  expect(made.root.hasAttribute("data-z-hydrated")).toBe(true);
  expect(made.root.querySelector("button")?.textContent).toBe("hi: 2");
});

test("setLocationPathname makes window.location.pathname agree", () => {
  setLocationPathname("/booking");
  expect(window.location.pathname).toBe("/booking");
  setLocationPathname("/"); // reset
});
