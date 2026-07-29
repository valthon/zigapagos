import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { h, render } from "./core.ts";
import { bootIsland, __setIslandImporter } from "./islands.ts";
import { flush } from "./testing/flush.ts";

// --- harness ---------------------------------------------------------------
// A `client:only` island root exactly as src/islands/pass.zig emits it, with
// the reserved `<template slot="fallback">` content already rendered INTO the
// wrapper div (that is what the server pass does — the template itself never
// reaches the browser). The module is fed through the injected importer so a
// test controls precisely when — and whether — it resolves.

const MODULE_URL = "/islands/Chart.island.js";

const roots: HTMLElement[] = [];

function Chart({ label }: { label: string }) {
  return h("div", { class: "chart" }, label);
}

function mountOnlyRoot(fallbackHtml: string, id = "z-island-0"): HTMLElement {
  const el = document.createElement("div");
  el.setAttribute("data-z-island", "");
  el.id = id;
  el.dataset.zModule = MODULE_URL;
  el.dataset.zClient = "only";
  el.innerHTML = fallbackHtml;
  const propsScript = document.createElement("script");
  propsScript.type = "application/json";
  propsScript.setAttribute("data-z-props", id);
  propsScript.textContent = JSON.stringify({ label: "sales" });
  document.body.append(el, propsScript);
  roots.push(el);
  return el;
}

beforeEach(() => {
  roots.length = 0;
});

afterEach(() => {
  for (const el of roots) {
    try { render(null as any, el); el.remove(); } catch { /* ignore */ }
  }
  document.body.innerHTML = "";
  __setIslandImporter(undefined);
});

describe("client:only fallback content (#58)", () => {
  test("the fallback is cleared and the component mounts in its place", async () => {
    __setIslandImporter(async () => ({ default: Chart }));
    const root = mountOnlyRoot('<div class="chart-skeleton">Loading…</div>');

    await bootIsland(root);
    await flush();

    // The skeleton is gone…
    expect(root.querySelector(".chart-skeleton")).toBeNull();
    // …and the real component is mounted in its place. Without the clear,
    // hydrate() ADOPTS the skeleton div — it never diffs attributes, so the
    // `chart-skeleton` class would be welded onto the mounted component.
    const mountedEl = root.querySelector(".chart");
    expect(mountedEl).toBeTruthy();
    expect(mountedEl!.classList.contains("chart-skeleton")).toBe(false);
    expect(root.textContent).toBe("sales");
  });

  test("a client:only root with NO fallback still mounts (the clear is a no-op)", async () => {
    __setIslandImporter(async () => ({ default: Chart }));
    const root = mountOnlyRoot("");

    await bootIsland(root);
    await flush();

    expect(root.querySelector(".chart")).toBeTruthy();
  });

  test("the fallback SURVIVES a module that fails to load", async () => {
    // The ordering pin. Clearing before the `await` would blank the box on a
    // failed import — the visitor loses the skeleton AND gets nothing back.
    __setIslandImporter(async () => {
      throw new Error("network down");
    });
    const root = mountOnlyRoot('<div class="chart-skeleton">Loading…</div>');

    await expect(bootIsland(root)).rejects.toThrow("network down");
    await flush();

    expect(root.querySelector(".chart-skeleton")).toBeTruthy();
    expect(root.textContent).toBe("Loading…");
  });

  test("a NON-client:only root's server-rendered content is never cleared", async () => {
    // client:load SSRs the component, and hydrate() must adopt that DOM. A
    // clear here would throw away the server render and force a fresh mount.
    __setIslandImporter(async () => ({ default: Chart }));
    const root = mountOnlyRoot('<div class="chart">sales</div>', "z-island-1");
    root.dataset.zClient = "load";

    const adopted = root.firstElementChild;
    await bootIsland(root);
    await flush();

    expect(root.firstElementChild).toBe(adopted); // same node, adopted in place
  });
});
