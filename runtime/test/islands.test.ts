import { test, expect, afterEach } from "bun:test";
import { renderToString, h } from "@z/runtime/core";
import { bootIsland, swapIsland, mountedIslands, __setIslandImporter } from "@z/runtime/islands";
import { buildSlots } from "@z/runtime/slots";
import { renderIsland, click, flush, type RenderResult } from "@z/runtime/testing";
import { expectParity } from "@z/runtime/testing/parity";
import Counter from "./fixtures/Counter.island.tsx";
import Panel from "./fixtures/Panel.island.tsx";
import { resolve } from "node:path";

const COUNTER_URL = resolve(import.meta.dir, "fixtures/Counter.island.tsx");
const PANEL_URL = resolve(import.meta.dir, "fixtures/Panel.island.tsx");

function mountSSR(props: { start: number; label: string }) {
  const root = document.createElement("div");
  root.setAttribute("data-z-island", "");
  root.id = "z-island-0";
  root.dataset.zModule = COUNTER_URL;
  root.dataset.zClient = "load";
  root.innerHTML = renderToString(h(Counter, props));
  const propsScript = document.createElement("script");
  propsScript.type = "application/json";
  propsScript.setAttribute("data-z-props", "z-island-0");
  propsScript.textContent = JSON.stringify(props);
  document.body.append(root, propsScript);
  return root;
}

// Exercises islands.ts wiring directly: data-z-hydrated / data-z-module attributes.
// Keep this test AS-IS (it tests bootIsland, not the generic harness).
test("bootIsland hydrates over SSR markup and becomes interactive", async () => {
  const root = mountSSR({ start: 2, label: "hi" });
  await bootIsland(root);
  expect(root.hasAttribute("data-z-hydrated")).toBe(true);
  const btn = root.querySelector("button")!;
  expect(btn.textContent).toBe("hi: 2");
  btn.click();
  // Preact batches state updates and flushes on a microtask — let it flush.
  await flush();
  expect(btn.textContent).toBe("hi: 3");
});

// Registry hygiene: a root that leaves the document must be pruned on the next
// mount — even in production (no HMR). Guards the leak fixed by calling
// forgetDetachedIslands() at the top of bootIsland.
test("bootIsland prunes a detached island root from the registry (no HMR)", async () => {
  const first = mountSSR({ start: 0, label: "a" });
  await bootIsland(first);
  expect(mountedIslands().has(first)).toBe(true);

  // Detach the first root outside any navigation — the registry still holds it.
  first.remove();
  expect(first.isConnected).toBe(false);
  expect(mountedIslands().has(first)).toBe(true);

  // Booting a *second* island (no HMR involved) must sweep the stale entry.
  const second = mountSSR({ start: 0, label: "b" });
  second.id = "z-island-1";
  await bootIsland(second);
  expect(mountedIslands().has(first)).toBe(false); // detached root pruned
  expect(mountedIslands().has(second)).toBe(true);
  second.remove();
});

// swapIsland must splice the cache-bust query BEFORE any #fragment (a query
// after a fragment is an invalid URL). Capture the URL the importer receives.
test("swapIsland inserts the z-hmr cache-bust before a #fragment", async () => {
  const seen: string[] = [];
  const root = mountSSR({ start: 0, label: "x" });
  root.dataset.zModule = COUNTER_URL + "#frag";
  __setIslandImporter(async (url) => {
    seen.push(url);
    return { default: Counter };
  });
  try {
    await bootIsland(root);
    await swapIsland(root, "abc123");
    const swapUrl = seen[seen.length - 1];
    // Query precedes the fragment, and the fragment is preserved intact.
    expect(swapUrl).toBe(COUNTER_URL + "?z-hmr=abc123#frag");
    expect(swapUrl.indexOf("z-hmr=")).toBeLessThan(swapUrl.indexOf("#"));
  } finally {
    __setIslandImporter(undefined);
    root.remove();
  }
});

// Generic "render + interact" case migrated onto the harness.
let r: RenderResult<any> | undefined;
afterEach(() => r?.unmount());

test("island hydrates over SSR markup and becomes interactive", async () => {
  r = renderIsland(Counter, { start: 2, label: "hi" });
  expect(r.get("button").textContent).toBe("hi: 2");
  await click(r.get("button"));
  expect(r.get("button").textContent).toBe("hi: 3");
});

test("Counter SSR↔hydration parity holds", async () => {
  await expectParity(COUNTER_URL, { props: { start: 2, label: "hi" } });
});

// --- slot hydration tests ---

test("bootIsland adopt-hydration: Panel composite island slots survive hydration", async () => {
  const rawSlots = { heading: "<h2>My Heading</h2>", default: "<p>Body text</p>" };
  const props = { title: "Panel Title" };
  const id = "z-island-panel-adopt";

  const root = document.createElement("div");
  root.setAttribute("data-z-island", "");
  root.id = id;
  root.dataset.zModule = PANEL_URL;
  root.dataset.zClient = "load";

  // SSR: use buildSlots exactly as the sidecar does — byte-identical with what bootIsland will rebuild
  const { children, slots } = buildSlots(rawSlots);
  root.innerHTML = renderToString(h(Panel, { ...props, slots } as any, children));

  const propsScript = document.createElement("script");
  propsScript.type = "application/json";
  propsScript.setAttribute("data-z-props", id);
  propsScript.textContent = JSON.stringify(props);

  const slotsScript = document.createElement("script");
  slotsScript.type = "application/json";
  slotsScript.setAttribute("data-z-slots", id);
  slotsScript.textContent = JSON.stringify(rawSlots);

  document.body.append(root, propsScript, slotsScript);

  // Capture references BEFORE hydration — identity assertions prove Preact ADOPTS
  // the existing DOM nodes (no clear + recreate, no reflow).
  const headingSlotBefore = root.querySelector('z-slot[data-z-slot="heading"]');
  const defaultSlotBefore = root.querySelector('z-slot[data-z-slot="default"]');
  const sectionBefore = root.querySelector("section");
  expect(headingSlotBefore).toBeTruthy();
  expect(defaultSlotBefore).toBeTruthy();
  expect(sectionBefore).toBeTruthy();

  await bootIsland(root);

  expect(root.hasAttribute("data-z-hydrated")).toBe(true);
  // Reference-identity: the same DOM nodes must survive hydration (adopted, not recreated).
  // If Preact cleared + recreated the slot node, these would fail — exposing a reflow bug.
  expect(root.querySelector('z-slot[data-z-slot="heading"]')).toBe(headingSlotBefore);  // adopted, not recreated
  expect(root.querySelector('z-slot[data-z-slot="default"]')).toBe(defaultSlotBefore);  // adopted, not recreated
  expect(root.querySelector("section")).toBe(sectionBefore);                             // outer element kept identity
  // Slot DOM survived hydration — z-slot elements present with their content
  const headingSlot = root.querySelector('z-slot[data-z-slot="heading"]');
  expect(headingSlot).toBeTruthy();
  expect(headingSlot!.innerHTML).toBe("<h2>My Heading</h2>");
  const defaultSlot = root.querySelector('z-slot[data-z-slot="default"]');
  expect(defaultSlot).toBeTruthy();
  expect(defaultSlot!.innerHTML).toBe("<p>Body text</p>");
});

test("bootIsland client:only: fresh mount with data-z-slots populates slot content", async () => {
  const rawSlots = { heading: "<h2>Fresh Heading</h2>", default: "<p>Fresh body</p>" };
  const props = { title: "Fresh Panel" };
  const id = "z-island-panel-fresh";

  const root = document.createElement("div");
  root.setAttribute("data-z-island", "");
  root.id = id;
  root.dataset.zModule = PANEL_URL;
  root.dataset.zClient = "only";
  // No innerHTML — empty container (client:only)

  const propsScript = document.createElement("script");
  propsScript.type = "application/json";
  propsScript.setAttribute("data-z-props", id);
  propsScript.textContent = JSON.stringify(props);

  const slotsScript = document.createElement("script");
  slotsScript.type = "application/json";
  slotsScript.setAttribute("data-z-slots", id);
  slotsScript.textContent = JSON.stringify(rawSlots);

  document.body.append(root, propsScript, slotsScript);

  await bootIsland(root);

  expect(root.hasAttribute("data-z-hydrated")).toBe(true);
  // Panel rendered into the container with slot content
  expect(root.querySelector("section")).toBeTruthy();
  expect(root.querySelector('z-slot[data-z-slot="heading"]')).toBeTruthy();
  expect(root.querySelector('z-slot[data-z-slot="heading"]')!.innerHTML).toBe("<h2>Fresh Heading</h2>");
  expect(root.querySelector('z-slot[data-z-slot="default"]')).toBeTruthy();
  expect(root.querySelector('z-slot[data-z-slot="default"]')!.innerHTML).toBe("<p>Fresh body</p>");
});
