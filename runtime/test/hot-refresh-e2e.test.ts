// ---------------------------------------------------------------------------
// Fast-refresh pipeline proof: island SOURCE -> bundleIsland({hot:true}) -> REAL
// dynamic import -> edit + re-bundle -> applyIslandUpdate hot-swap.
//
//   - a same-hook-sequence edit preserves PLAIN useState across the swap
//     (the transformed bundle's components are stable registry proxies);
//   - an edit that ADDS a hook changes the build-time signature, so the
//     registry mints a new identity and the island REMOUNTS (state resets) —
//     the remount fallback, never a corrupt swap.
//
// Modeled on hmr.test.ts's "real dynamic import" describe block: the fixtures
// live under test/fixtures so the package self-reference resolves @z/runtime
// from inside runtime/, and try/finally unlinks them.
// ---------------------------------------------------------------------------
import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { render } from "../src/core.ts";
import { bootIsland, __setIslandImporter } from "../src/islands.ts";
import { applyIslandUpdate } from "../src/hmr.ts";
import { __resetHotRegistryForTest } from "../src/hot-registry.ts";
import { flush } from "../src/testing/flush.ts";
import { bundleIsland } from "../sidecar/bundle-island.ts";
import { resolve } from "node:path";
import { unlinkSync } from "node:fs";

const SRC = resolve(import.meta.dir, "fixtures/.tmp-hot-e2e.island.tsx");
const OUT = resolve(import.meta.dir, "fixtures/.tmp-hot-e2e.js");
const DEP = resolve(import.meta.dir, "fixtures/.tmp-hot-e2e.d");

// v1: a plain-useState counter. v2 = same hook sequence, new markup. v3 adds a
// hook (useEffect) => different signature => must remount.
const v1 = `
import { h, useState } from "@z/runtime/core";
export default function Counter({ label }: { label: string }) {
  const [n, setN] = useState(0);
  (globalThis as any).__hotBump = () => setN((v: number) => v + 1);
  return h("div", { class: "hot-v1" }, label + ":" + n);
}
`;
const v2 = `
import { h, useState } from "@z/runtime/core";
export default function Counter({ label }: { label: string }) {
  const [n, setN] = useState(0);
  (globalThis as any).__hotBump = () => setN((v: number) => v + 1);
  return h("div", { class: "hot-v2" }, label + "!" + n);
}
`;
const v3 = `
import { h, useState, useEffect } from "@z/runtime/core";
export default function Counter({ label }: { label: string }) {
  const [n, setN] = useState(0);
  useEffect(() => {}, []);
  (globalThis as any).__hotBump = () => setN((v: number) => v + 1);
  return h("div", { class: "hot-v3" }, label + "~" + n);
}
`;

async function rebuild(): Promise<void> {
  await bundleIsland({
    entry: SRC,
    outfile: OUT,
    depfile: DEP,
    external: ["@z/runtime", "@z/runtime/core", "@z/runtime/jsx-runtime"],
    minify: false,
    hot: true,
  });
}

// applyIslandUpdate cache-busts with Date.now(); two swaps in the same
// millisecond would collide on the same import URL and serve stale bytes.
async function nextMs(): Promise<void> {
  const t = Date.now();
  while (Date.now() === t) await new Promise((r) => setTimeout(r, 1));
}

const roots: HTMLElement[] = [];

beforeEach(() => {
  __resetHotRegistryForTest();
  __setIslandImporter(undefined); // the REAL import(), not a mock
  window.sessionStorage.clear();
});

afterEach(() => {
  for (const el of roots) {
    try { render(null as any, el); el.remove(); } catch { /* ignore */ }
  }
  roots.length = 0;
  document.body.innerHTML = "";
  delete (globalThis as any).__hotBump;
  window.sessionStorage.clear();
  for (const f of [SRC, OUT, DEP]) {
    try { unlinkSync(f); } catch { /* ignore ENOENT */ }
  }
});

describe("fast refresh through the real bundle pipeline", () => {
  test("edit with same hooks preserves plain useState; adding a hook remounts", async () => {
    await Bun.write(SRC, v1);
    await rebuild();

    const root = document.createElement("div");
    root.setAttribute("data-z-island", "");
    root.id = "z-island-hot-e2e";
    root.dataset.zModule = OUT; // boot off the BUILT bundle, like the browser
    root.dataset.zClient = "load";
    const ps = document.createElement("script");
    ps.type = "application/json";
    ps.setAttribute("data-z-props", "z-island-hot-e2e");
    ps.textContent = JSON.stringify({ label: "hi" });
    document.body.append(root, ps);
    roots.push(root);

    await bootIsland(root);
    await flush();
    expect(root.querySelector(".hot-v1")).toBeTruthy();

    // "User interaction": bump the PLAIN counter to 2.
    (globalThis as any).__hotBump();
    await flush();
    (globalThis as any).__hotBump();
    await flush();
    expect(root.textContent).toBe("hi:2");

    // Edit 1: same hook sequence, new markup — rebuild and hot-swap.
    await Bun.write(SRC, v2);
    await rebuild();
    await nextMs();
    const ok1 = await applyIslandUpdate([OUT]);
    await flush();

    expect(ok1).toBe(true);
    expect(document.getElementById("z-island-hot-e2e")).toBe(root); // in place
    expect(root.querySelector(".hot-v2")).toBeTruthy();
    expect(root.querySelector(".hot-v1")).toBeNull();
    expect(root.textContent).toBe("hi!2"); // plain useState SURVIVED

    // …and the swapped-in implementation is fully live (its setter works).
    (globalThis as any).__hotBump();
    await flush();
    expect(root.textContent).toBe("hi!3");

    // Edit 2: ADD a hook — signature changes, so the swap must REMOUNT.
    await Bun.write(SRC, v3);
    await rebuild();
    await nextMs();
    const ok2 = await applyIslandUpdate([OUT]);
    await flush();

    expect(ok2).toBe(true);
    expect(root.querySelector(".hot-v3")).toBeTruthy();
    expect(root.textContent).toBe("hi~0"); // counter reset: fresh instance
  });
});
