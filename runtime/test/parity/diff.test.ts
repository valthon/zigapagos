import { test, expect } from "bun:test";
import { diffRoute } from "../../scripts/parity/diff.ts";

const base = (href: string, label = "Book") =>
  `<div data-z-island id="z-island-0" data-z-src="components/Hero.island.tsx" data-z-client="load" data-z-module="/islands/Hero.island.js"><section><h1>Welcome</h1><a href="${href}">${label}</a></section></div><script type="application/json" data-z-props="z-island-0">{"title":"Welcome"}</script>`;

const astro = (href: string, label = "Book") =>
  `<astro-island uid="x" component-url="Hero.js" props='{"title":[0,"Welcome"]}' client="load" ssr><section data-astro-cid-z><h1>Welcome</h1><a href="${href}">${label}</a></section></astro-island>`;

test("equivalent Astro vs zigapagos render → ok", () => {
  const r = diffRoute("/", astro("/book"), base("/book"));
  expect(r.ok).toBe(true);
  expect(r.structural).toEqual([]);
  expect(r.props).toEqual([]);
});

test("a changed attribute (href) FAILS with an attribute mismatch", () => {
  const r = diffRoute("/", astro("/book"), base("/BOOKING"));
  expect(r.ok).toBe(false);
  expect(r.structural.some((m) => m.kind === "attribute" && m.expected === "/book" && m.actual === "/BOOKING")).toBe(true);
  expect(r.domDiff).not.toBe("");
});

test("a missing child FAILS structurally", () => {
  const actual = `<div data-z-island id="z-island-0" data-z-src="Hero.tsx" data-z-client="load" data-z-module="/x.js"><section><h1>Welcome</h1></section></div>`;
  const r = diffRoute("/", astro("/book"), actual);
  expect(r.ok).toBe(false);
  expect(r.structural.some((m) => m.kind === "missing" || m.kind === "structure")).toBe(true);
});

test("a reordered child FAILS structurally (swapped h1/a)", () => {
  const reordered = `<div data-z-island id="z-island-0" data-z-src="Hero.tsx" data-z-client="load" data-z-module="/x.js"><section><a href="/book">Book</a><h1>Welcome</h1></section></div><script type="application/json" data-z-props="z-island-0">{"title":"Welcome"}</script>`;
  const r = diffRoute("/", astro("/book"), reordered);
  expect(r.ok).toBe(false);
  expect(r.structural.some((m) => m.kind === "structure")).toBe(true);
});

test("a changed prop FAILS with a prop mismatch", () => {
  const r = diffRoute("/", astro("/book"),
    base("/book").replace('{"title":"Welcome"}', '{"title":"Bienvenue"}'));
  expect(r.ok).toBe(false);
  expect(r.props.some((p) => p.component === "Hero" && p.key === "title" && p.actual === "Bienvenue")).toBe(true);
});
