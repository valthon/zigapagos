import { test, expect, afterEach } from "bun:test";
import { renderIsland, click, type RenderResult } from "@z/runtime/testing";
import Hero from "../components/Hero.island.tsx";

let r: RenderResult<any> | undefined;
afterEach(() => r?.unmount());

test("Hero island renders and toggles via the harness", async () => {
  r = renderIsland(Hero, { headline: "Welcome" });
  expect(r.text("h1")).toBe("Welcome");
  expect(r.get("button").textContent).toBe("+");
  await click(r.get("button"));
  expect(r.get("button").textContent).toBe("−");
});
