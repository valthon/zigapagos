import { test, expect } from "bun:test";
import { canonicalize, componentKey, decodeAstroProps } from "../../scripts/parity/normalize.ts";

test("componentKey strips dir + framework extensions", () => {
  expect(componentKey("components/Hero.island.tsx")).toBe("Hero");
  expect(componentKey("/islands/Hero.island.js")).toBe("Hero");
  expect(componentKey("../src/Hero.astro")).toBe("Hero");
});

test("decodeAstroProps unwraps the [typeCode, value] tuples", () => {
  expect(decodeAstroProps('{"title":[0,"hi"],"n":[0,5]}')).toEqual({ title: "hi", n: 5 });
  expect(decodeAstroProps(null)).toEqual({});
});

const ZIG = `<div data-z-island id="z-island-0" data-z-src="components/Hero.island.tsx" data-z-client="load" data-z-module="/islands/Hero.island.js"><section><h1>Welcome</h1><a href="/book">Book</a></section></div><script type="application/json" data-z-props="z-island-0">{"title":"Welcome"}</script>`;

const ASTRO = `<!--astro:page--><astro-island uid="abc" component-url="/_astro/Hero.x1.js" component-export="default" renderer-url="/_astro/client.js" props='{"title":[0,"Welcome"]}' client="load" ssr><section data-astro-cid-aaa><h1 data-astro-cid-aaa>Welcome</h1><a href="/book" data-astro-cid-aaa>Book</a></section></astro-island><!--astro:end-->`;

test("Astro and zigapagos renders of the same component canonicalize-equal", () => {
  const z = canonicalize(ZIG);
  const a = canonicalize(ASTRO);
  expect(z.domString).toBe(a.domString);           // structure identical after normalization
  expect(z.props).toEqual(a.props);                // props semantically equal
  expect(z.props).toEqual([{ component: "Hero", props: { title: "Welcome" } }]);
});

test("island host is folded to <z-island data-src> with inner DOM preserved", () => {
  const z = canonicalize(ZIG);
  expect(z.domString).toContain("<z-island");
  expect(z.domString).toContain('data-src="Hero"');
  expect(z.domString).toContain("Welcome");
  expect(z.domString).not.toContain("data-z-island");   // scaffolding folded away
  expect(z.domString).not.toContain("data-z-module");
});

test("comments, data-astro-cid-*, and props scripts are stripped", () => {
  const a = canonicalize(ASTRO);
  expect(a.domString).not.toContain("astro-cid");
  expect(a.domString).not.toContain("astro:");
  expect(a.domString).not.toContain("script");
});

const ZIG_SLOTTED = `<div data-z-island id="z-island-0" data-z-src="components/Panel.island.tsx" data-z-client="load" data-z-module="/islands/Panel.island.js"><section><header><z-slot data-z-slot="heading" style="display:contents"><h2>Custom</h2></z-slot></header><div><z-slot data-z-slot="default" style="display:contents"><p>body</p></z-slot></div></section></div><script type="application/json" data-z-props="z-island-0">{"title":"Panel"}</script><script type="application/json" data-z-slots="z-island-0">{"heading":"<h2>Custom</h2>","default":"<p>body</p>"}</script>`;

const ASTRO_SLOTTED = `<astro-island uid="p1" component-url="/_astro/Panel.x1.js" component-export="default" renderer-url="/_astro/client.js" props='{"title":[0,"Panel"]}' client="load" ssr><section><header><astro-slot name="heading"><h2>Custom</h2></astro-slot></header><div><astro-slot><p>body</p></astro-slot></div></section></astro-island>`;

test("z-slot wrappers are unwrapped (children hoisted, wrapper removed)", () => {
  const z = canonicalize(ZIG_SLOTTED);
  expect(z.domString).not.toContain("z-slot");
  expect(z.domString).toContain("Custom");
  expect(z.domString).toContain("body");
});

test("data-z-slots scripts are stripped", () => {
  const z = canonicalize(ZIG_SLOTTED);
  expect(z.domString).not.toContain("data-z-slots");
  expect(z.domString).not.toContain("script");
});

test("slotted Astro and zigapagos renders canonicalize-equal", () => {
  const z = canonicalize(ZIG_SLOTTED);
  const a = canonicalize(ASTRO_SLOTTED);
  expect(z.domString).toBe(a.domString);
  expect(z.props).toEqual(a.props);
  expect(z.props).toEqual([{ component: "Panel", props: { title: "Panel" } }]);
});

test("classHashPattern strips a scoped-class suffix", () => {
  const out = canonicalize('<p class="btn_a1b2c3d4 lead">x</p>', { classHashPattern: /_[a-z0-9]{8}$/ });
  expect(out.domString).toContain('class="btn lead"');
});
