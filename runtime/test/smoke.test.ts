import { test, expect } from "bun:test";

test("bun test runs and happy-dom globals are registered", () => {
  const el = document.createElement("div");
  el.id = "smoke";
  document.body.appendChild(el);
  expect(document.getElementById("smoke")).toBe(el);
});
