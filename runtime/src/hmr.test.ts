import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { h, render } from "./core.ts";
import { useState, useReducer } from "./core.ts";
import { bootIsland, __setIslandImporter } from "./islands.ts";
import { applyIslandUpdate, installHmr } from "./hmr.ts";
import { __zHotRegister, __resetHotRegistryForTest } from "./hot-registry.ts";
import { useRestorableState } from "./dev-reload.ts";
import { __setServerForTest } from "./ssr-env.ts";
import { flush } from "./testing/flush.ts";
import { resolve } from "node:path";
import { unlinkSync } from "node:fs";

// --- harness ---------------------------------------------------------------
// Mount a real island root (data-z-island + data-z-module + a props <script>)
// and boot it through islands.ts, but feed the module via an injected importer
// so a test controls exactly what "the rebuilt bundle" exports on a hot-swap.

const MODULE_URL = "/islands/HmrWidget.island.js";

let container: HTMLElement | null = null;
let setterV1: ((v: string) => void) | null = null;
let plusV1: (() => void) | null = null;
// Every root mounted in a test, so afterEach can unmount ALL of them (a Preact
// tree left mounted would leak its zigapagos:beforereload listener into the next test).
const roots: HTMLElement[] = [];

// v1 of the island: a restorable text field + a PLAIN useState counter.
function WidgetV1({ label }: { label: string }) {
  const [text, setText] = useRestorableState<string>("field", "");
  const [n, setN] = useState(0);
  setterV1 = setText;
  plusV1 = () => setN(n + 1);
  return h("div", { class: "v1" }, `${label}:${text}:${n}`);
}

// v2 = the "edited" island: different marker markup, SAME restorable key.
function WidgetV2({ label }: { label: string }) {
  const [text] = useRestorableState<string>("field", "");
  return h("div", { class: "v2" }, `${label}!${text}`);
}

// A DISTINCT function identity with the same shape as V1 — a faithful re-import
// always yields a new function object, so a swap changes the component type.
function WidgetV1Reedited({ label }: { label: string }) {
  const [text] = useRestorableState<string>("field", "");
  const [n] = useState(0);
  return h("div", { class: "v1" }, `${label}:${text}:${n}`);
}

let current: { default: any } = { default: WidgetV1 };

function mountIsland(id = "z-island-0", props: Record<string, unknown> = { label: "hi" }) {
  container = document.createElement("div");
  container.setAttribute("data-z-island", "");
  container.id = id;
  container.dataset.zModule = MODULE_URL;
  container.dataset.zClient = "load";
  const propsScript = document.createElement("script");
  propsScript.type = "application/json";
  propsScript.setAttribute("data-z-props", id);
  propsScript.textContent = JSON.stringify(props);
  document.body.append(container, propsScript);
  roots.push(container);
  return container;
}

beforeEach(() => {
  window.sessionStorage.clear();
  __resetHotRegistryForTest();
  current = { default: WidgetV1 };
  setterV1 = null;
  plusV1 = null;
  roots.length = 0;
  // The importer ignores the cache-bust query and serves the current version.
  __setIslandImporter(async () => current);
});

afterEach(() => {
  for (const el of roots) {
    try { render(null as any, el); el.remove(); } catch { /* ignore */ }
  }
  document.body.innerHTML = "";
  container = null;
  window.sessionStorage.clear();
  __setIslandImporter(undefined);
  __setServerForTest(undefined);
  delete (window as any).__zigapagos_hmr;
});

describe("applyIslandUpdate — island hot-swap", () => {
  test("swaps the module in place, same root, no full navigation", async () => {
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    expect(root.querySelector(".v1")).toBeTruthy();

    current = { default: WidgetV2 }; // the rebuild
    const ok = await applyIslandUpdate([MODULE_URL]);
    await flush();

    expect(ok).toBe(true);
    // Same root element (in-place), now rendering v2's markup.
    expect(document.getElementById("z-island-0")).toBe(root);
    expect(root.querySelector(".v2")).toBeTruthy();
    expect(root.querySelector(".v1")).toBeNull();
  });

  test("preserves useRestorableState across the swap", async () => {
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    setterV1!("typed-value");
    await flush();
    expect(root.textContent).toContain("typed-value");

    current = { default: WidgetV2 };
    const ok = await applyIslandUpdate([MODULE_URL]);
    await flush();

    expect(ok).toBe(true);
    // v2 renders `label!text`; the restorable field survived the hot-swap.
    expect(root.textContent).toBe("hi!typed-value");
  });

  test("plain useState resets on swap (untransformed module — fallback)", async () => {
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    plusV1!(); // bump the plain counter to 1
    await flush();
    expect(root.textContent).toBe("hi::1");

    // Swap to a re-edited V1 (new function identity, as a real re-import gives):
    // plain state is torn down.
    current = { default: WidgetV1Reedited };
    const ok = await applyIslandUpdate([MODULE_URL]);
    await flush();
    expect(ok).toBe(true);
    expect(root.textContent).toBe("hi::0"); // counter reset, not preserved
  });

  test("leaves sibling islands (different module) untouched", async () => {
    const a = mountIsland("z-island-0");
    await bootIsland(a);
    // A second island on another module.
    const b = document.createElement("div");
    b.setAttribute("data-z-island", "");
    b.id = "z-island-1";
    b.dataset.zModule = "/islands/Other.island.js";
    b.dataset.zClient = "load";
    const bp = document.createElement("script");
    bp.type = "application/json";
    bp.setAttribute("data-z-props", "z-island-1");
    bp.textContent = JSON.stringify({ label: "other" });
    document.body.append(b, bp);
    roots.push(b);
    await bootIsland(b);
    await flush();
    const bMarkup = b.innerHTML;

    current = { default: WidgetV2 };
    const ok = await applyIslandUpdate([MODULE_URL]); // only island A's module
    await flush();

    expect(ok).toBe(true);
    expect(a.querySelector(".v2")).toBeTruthy(); // A swapped
    expect(b.innerHTML).toBe(bMarkup); // B identical — never touched
  });

  test("matches even if the payload URL carries a cache-bust query", async () => {
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    current = { default: WidgetV2 };
    const ok = await applyIslandUpdate([MODULE_URL + "?v=abc123"]);
    await flush();
    expect(ok).toBe(true);
    expect(root.querySelector(".v2")).toBeTruthy();
  });
});

// Fast refresh: modules built with the dev `hot` transform register
// their components through the hot registry, so the exported default is a
// STABLE proxy. `mk` simulates exactly what a transformed bundle's footer does.
describe("applyIslandUpdate — fast refresh (hot registry)", () => {
  const mk = (impl: any, sig: string) => ({
    default: __zHotRegister(impl, MODULE_URL, "Widget", sig),
  });

  test("plain useState survives a swap when the hook signature matches", async () => {
    const SIG = "useRestorableState,useState";
    let plus: (() => void) | null = null;
    function HotV1({ label }: { label: string }) {
      const [text] = useRestorableState<string>("field", "");
      const [n, setN] = useState(0);
      plus = () => setN(n + 1);
      return h("div", { class: "hot-v1" }, `${label}:${text}:${n}`);
    }
    function HotV2({ label }: { label: string }) {
      const [text] = useRestorableState<string>("field", "");
      const [n, setN] = useState(0);
      plus = () => setN(n + 1);
      return h("div", { class: "hot-v2" }, `${label}!${text}!${n}`);
    }

    current = mk(HotV1, SIG);
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    plus!(); // bump the PLAIN counter to 1
    await flush();
    expect(root.textContent).toBe("hi::1");

    current = mk(HotV2, SIG); // the rebuild: same hook sequence, new markup
    const ok = await applyIslandUpdate([MODULE_URL]);
    await flush();

    expect(ok).toBe(true);
    expect(root.querySelector(".hot-v2")).toBeTruthy(); // new implementation live
    expect(root.querySelector(".hot-v1")).toBeNull();
    expect(root.textContent).toBe("hi!!1"); // plain useState SURVIVED the swap
  });

  test("signature change forces a remount; useRestorableState still survives", async () => {
    const SIG = "useRestorableState,useState";
    let plus: (() => void) | null = null;
    let setText: ((v: string) => void) | null = null;
    function HotV1({ label }: { label: string }) {
      const [text, st] = useRestorableState<string>("field", "");
      const [n, setN] = useState(0);
      setText = st;
      plus = () => setN(n + 1);
      return h("div", { class: "hot-v1" }, `${label}:${text}:${n}`);
    }
    function HotV3({ label }: { label: string }) {
      const [text] = useRestorableState<string>("field", "");
      const [n] = useState(0);
      return h("div", { class: "hot-v3" }, `${label}~${text}~${n}`);
    }

    current = mk(HotV1, SIG);
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    setText!("typed");
    await flush();
    plus!();
    await flush();
    expect(root.textContent).toBe("hi:typed:1");

    // Different signature => the registry mints a NEW identity => remount.
    current = mk(HotV3, SIG + ",useEffect");
    const ok = await applyIslandUpdate([MODULE_URL]);
    await flush();

    expect(ok).toBe(true);
    expect(root.querySelector(".hot-v3")).toBeTruthy();
    // Plain counter RESET (fresh instance)…
    // …but the restorable field survived via the beforereload stash + restore.
    expect(root.textContent).toBe("hi~typed~0");
  });

  test("useReducer state is preserved and the NEW reducer logic applies after the swap", async () => {
    const SIG = "useReducer";
    let dispatch: (() => void) | null = null;
    function RedV1({ label }: { label: string }) {
      const [n, d] = useReducer((s: number) => s + 1, 0);
      dispatch = () => d(undefined as never);
      return h("div", { class: "red-v1" }, `${label}:${n}`);
    }
    function RedV2({ label }: { label: string }) {
      const [n, d] = useReducer((s: number) => s + 10, 0);
      dispatch = () => d(undefined as never);
      return h("div", { class: "red-v2" }, `${label}:${n}`);
    }

    current = mk(RedV1, SIG);
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    dispatch!();
    await flush();
    dispatch!();
    await flush();
    expect(root.textContent).toBe("hi:2");

    current = mk(RedV2, SIG);
    const ok = await applyIslandUpdate([MODULE_URL]);
    await flush();

    expect(ok).toBe(true);
    expect(root.textContent).toBe("hi:2"); // reducer STATE preserved
    dispatch!(); // the swapped-in reducer's logic (+10) applies from now on
    await flush();
    expect(root.textContent).toBe("hi:12");
  });
});

describe("applyIslandUpdate — full-reload fallbacks (returns false)", () => {
  test("no mounted root uses the changed module → false", async () => {
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    const ok = await applyIslandUpdate(["/islands/NotOnThisPage.island.js"]);
    expect(ok).toBe(false);
  });

  test("empty / non-array module list → false", async () => {
    expect(await applyIslandUpdate([])).toBe(false);
    expect(await applyIslandUpdate(null as any)).toBe(false);
  });

  test("a swap that throws (import error) → false, caller reloads", async () => {
    const root = mountIsland();
    await bootIsland(root);
    await flush();
    __setIslandImporter(async () => { throw new Error("bundle 500"); });
    const ok = await applyIslandUpdate([MODULE_URL]);
    expect(ok).toBe(false);
  });

  test("on the server → false, touches no window", async () => {
    __setServerForTest(true);
    expect(await applyIslandUpdate([MODULE_URL])).toBe(false);
  });
});

// End-to-end proof through the REAL dynamic-import path (no injected importer):
// write an island source file, boot it, EDIT the file on disk, then hot-swap.
// swapIsland's cache-bust query makes the browser (and Bun) re-fetch the edited
// module — exactly what `zigapagos dev` does when an island bundle is rebuilt.
describe("applyIslandUpdate — real dynamic import of an edited island file", () => {
  const FILE = resolve(import.meta.dir, "../test/fixtures/.tmp-hmr-e2e.island.tsx");

  const v1 = `
import { h } from "@z/runtime/core";
import { useRestorableState } from "@z/runtime";
export default function W({ label }: { label: string }) {
  const [t, setT] = useRestorableState<string>("field", "");
  (globalThis as any).__hmrSetT = setT;
  return h("div", { class: "v1" }, label + ":" + t);
}
`;
  const v2 = `
import { h } from "@z/runtime/core";
import { useRestorableState } from "@z/runtime";
export default function W({ label }: { label: string }) {
  const [t] = useRestorableState<string>("field", "");
  return h("div", { class: "v2" }, label + "!" + t);
}
`;

  test("editing an island's source hot-swaps it in place with state intact", async () => {
    __setIslandImporter(undefined); // use the REAL import(), not the mock
    await Bun.write(FILE, v1);

    try {
      const root = document.createElement("div");
      root.setAttribute("data-z-island", "");
      root.id = "z-island-e2e";
      root.dataset.zModule = FILE; // real absolute path Bun can import
      root.dataset.zClient = "load";
      const ps = document.createElement("script");
      ps.type = "application/json";
      ps.setAttribute("data-z-props", "z-island-e2e");
      ps.textContent = JSON.stringify({ label: "hi" });
      document.body.append(root, ps);
      roots.push(root);

      await bootIsland(root);
      await flush();
      expect(root.querySelector(".v1")).toBeTruthy();

      // "User interaction": change the restorable field to a live value.
      (globalThis as any).__hmrSetT("in-progress");
      await flush();
      expect(root.textContent).toBe("hi:in-progress");

      // "Developer edits the source" → the bundle on disk changes.
      await Bun.write(FILE, v2);

      // Rebuild signal arrives → hot-swap. Real import of FILE?z-hmr=… gets v2.
      const ok = await applyIslandUpdate([FILE]);
      await flush();

      expect(ok).toBe(true);
      expect(document.getElementById("z-island-e2e")).toBe(root); // same root, in place
      expect(root.querySelector(".v2")).toBeTruthy(); // v2 markup now live
      expect(root.querySelector(".v1")).toBeNull();
      expect(root.textContent).toBe("hi!in-progress"); // state survived the swap
    } finally {
      // Runs even if an assertion above throws, so the temp fixture never lingers.
      delete (globalThis as any).__hmrSetT;
      try { unlinkSync(FILE); } catch { /* ignore ENOENT */ }
    }
  });
});

describe("installHmr", () => {
  test("publishes window.__zigapagos_hmr.applyIsland on the client", () => {
    delete (window as any).__zigapagos_hmr;
    installHmr();
    expect(typeof (window as any).__zigapagos_hmr.applyIsland).toBe("function");
  });

  test("no-op on the server", () => {
    delete (window as any).__zigapagos_hmr;
    __setServerForTest(true);
    installHmr();
    expect((window as any).__zigapagos_hmr).toBeUndefined();
  });
});
