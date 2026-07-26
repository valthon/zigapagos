import { test, expect } from "bun:test";
import { renderToString, h } from "@z/runtime/core";
import { buildSlots, slotVNode } from "@z/runtime/slots";

test("slotVNode emits an opaque z-slot with the html verbatim", () => {
  const html = renderToString(slotVNode("heading", "<h2>Q & A</h2>"));
  expect(html).toContain('<z-slot data-z-slot="heading"');
  expect(html).toContain("display:contents");
  expect(html).toContain("<h2>Q & A</h2>");           // opaque — NOT entity-escaped/diffed
});

test("buildSlots splits default → children, named → slots record", () => {
  const { children, slots } = buildSlots({ default: "<p>body</p>", heading: "<h2>Q</h2>" });
  expect(children).toBeDefined();
  expect(slots?.heading).toBeDefined();
  expect(slots?.default).toBeUndefined();             // default is NOT in the named record
  expect(buildSlots(undefined)).toEqual({});          // leaf island → empty
});

test("a component consuming children + slots renders them in position", () => {
  function Panel({ children, slots }: any) {
    return h("section", null, h("header", null, slots?.heading), h("div", { class: "body" }, children));
  }
  const { children, slots } = buildSlots({ default: "<p>B</p>", heading: "<h2>H</h2>" });
  const out = renderToString(h(Panel, { slots }, children));
  expect(out).toContain('<header><z-slot data-z-slot="heading"');
  expect(out).toContain("<h2>H</h2>");
  expect(out).toContain('<div class="body"><z-slot data-z-slot="default"');
  expect(out).toContain("<p>B</p>");
});
