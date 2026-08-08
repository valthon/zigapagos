// Client-only clientInit() lifecycle hook.
//
// A `.spa.tsx` module also executes under build-time SSR, so client-side
// module-load side effects (error relays, persisted-theme application, …)
// each needed a `typeof document === "undefined"` guard. Instead, the module
// may `export function clientInit(): void`; the shell bootstrap passes the
// module namespace to `mountSpa`, which calls `clientInit()` in the browser
// BEFORE the first render/hydration. The SSR sidecar never calls it (see
// sidecar/render.describe.test.ts), so module top level goes back to being
// import-only.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { h } from "@z/runtime/core";
import { __resetStoresForTest } from "@z/runtime/host";
import { mountSpa, Router, navigate, __setRouterBaseForTest } from "@z/runtime/router";
import { flush } from "@z/runtime/testing";
import { setLocationPathname } from "@z/runtime/testing/parity";

beforeEach(() => {
  __resetStoresForTest();
  document.body.innerHTML = "";
});
afterEach(() => {
  delete (window as any).zigapagosOnError;
  delete (document as any).startViewTransition;
});

function shellRoot(html: string): HTMLElement {
  const root = document.createElement("div");
  root.id = "z-spa-root";
  root.innerHTML = html;
  document.body.appendChild(root);
  return root;
}

test("mountSpa calls the module's clientInit exactly once, BEFORE the first render", () => {
  const order: string[] = [];
  function App() {
    order.push("render");
    return h("div", null, "hi");
  }
  const mod = { clientInit: () => order.push("clientInit") };
  shellRoot("<div>hi</div>");

  mountSpa(App, "#z-spa-root", mod);
  expect(order[0]).toBe("clientInit");
  expect(order.filter((e) => e === "clientInit").length).toBe(1);
  expect(order).toContain("render");
});

test("mountSpa without a module namespace (or without clientInit) still hydrates — back-compat", () => {
  function App() {
    return h("div", null, "plain");
  }
  const root = shellRoot("<div>plain</div>");
  mountSpa(App, "#z-spa-root"); // two-arg call: the pre-clientInit shell bootstrap
  expect(root.textContent).toBe("plain");

  document.body.innerHTML = "";
  const root2 = shellRoot("<div>plain</div>");
  mountSpa(App, "#z-spa-root", {}); // namespace without a clientInit export
  expect(root2.textContent).toBe("plain");
});

test("a throwing clientInit is reported loudly but does not abort hydration", () => {
  const reported: string[] = [];
  (window as any).zigapagosOnError = (msg: string) => reported.push(msg);
  function App() {
    return h("div", null, "alive");
  }
  const root = shellRoot("<div>alive</div>");
  mountSpa(App, "#z-spa-root", {
    clientInit: () => {
      throw new Error("boom in clientInit");
    },
  });
  expect(reported.length).toBe(1);
  expect(reported[0]).toContain("boom in clientInit");
  expect(root.textContent).toBe("alive"); // the app still hydrated
});

// --- spa.viewTransitions: the mountSpa opt-in ------------------------------
// `mountSpa` reads the module's `export const spa` and drives the router's
// (default-off) view-transition opt-in from `spa.viewTransitions`, applied
// BEFORE `clientInit` runs (a clientInit that calls `navigate()` must already
// see the setting) and unconditionally (explicit `false` on absence), so a
// later mountSpa() call — or the two-arg back-compat call — never inherits a
// PREVIOUS module's setting. happy-dom has no `startViewTransition`, so each
// test stubs it on `document` (cleared in `afterEach` above).
function installVTStub(): Array<() => Promise<void> | void> {
  const calls: Array<() => Promise<void> | void> = [];
  (document as any).startViewTransition = (cb: () => Promise<void> | void) => {
    calls.push(cb);
    const p = Promise.resolve(cb());
    return { ready: p.catch(() => {}), updateCallbackDone: p };
  };
  return calls;
}
const VtHome = () => h("div", { "data-view": "home" }, "home");
const VtOther = () => h("div", { "data-view": "other" }, "other");
function VtApp() {
  return h(Router, { routes: [{ path: "/", component: VtHome }, { path: "/other", component: VtOther }] });
}

test("mountSpa's spa.viewTransitions: true wraps a subsequent navigate() in startViewTransition (regression: behavioral, not a test-only getter)", async () => {
  __setRouterBaseForTest("");
  setLocationPathname("/");
  const calls = installVTStub();
  const root = shellRoot('<div data-view="home">home</div>');
  mountSpa(VtApp, "#z-spa-root", { spa: { viewTransitions: true } });
  await flush();
  navigate("/other");
  expect(calls.length).toBe(1); // wrapped synchronously as part of navigate()
  await flush();
  expect(root.textContent).toBe("other");
});

test("a subsequent mountSpa() without spa.viewTransitions resets to OFF — no bleed from a prior module (also covers the two-arg back-compat call)", async () => {
  __setRouterBaseForTest("");
  setLocationPathname("/");
  const calls = installVTStub();

  // First module opts in.
  shellRoot('<div data-view="home">home</div>');
  mountSpa(VtApp, "#z-spa-root", { spa: { viewTransitions: true } });
  await flush();

  // A namespace WITHOUT spa.viewTransitions (mirrors a plain SPA's shell
  // boot) must not inherit the previous module's opt-in.
  document.body.innerHTML = "";
  const root2 = shellRoot('<div data-view="home">home</div>');
  mountSpa(VtApp, "#z-spa-root", {});
  await flush();
  navigate("/other");
  await flush();
  expect(calls.length).toBe(0);
  expect(root2.textContent).toBe("other");

  // The two-arg back-compat call (no module namespace at all) resets the
  // same way: explicit `false` on ABSENCE, never "leave it as it was".
  // Two things this block has to get right or it asserts NOTHING:
  //   - RE-ARM the opt-in first. The `{}` mount above already turned it off,
  //     so a two-arg call that skipped the reset entirely would still leave it
  //     off and the expectation below would pass on a broken implementation.
  //   - Put the location back to "/". `navigate()` short-circuits a
  //     same-pathname target BEFORE the transition seam, so navigating to
  //     "/other" while already on "/other" can never reach the stub.
  document.body.innerHTML = "";
  shellRoot('<div data-view="home">home</div>');
  mountSpa(VtApp, "#z-spa-root", { spa: { viewTransitions: true } });
  await flush();
  setLocationPathname("/");
  document.body.innerHTML = "";
  shellRoot('<div data-view="home">home</div>');
  mountSpa(VtApp, "#z-spa-root");
  await flush();
  navigate("/other");
  await flush();
  expect(calls.length).toBe(0);
});

test("spa.viewTransitions is applied BEFORE clientInit runs — clientInit's own navigate() is already wrapped", async () => {
  __setRouterBaseForTest("");
  setLocationPathname("/");
  const calls = installVTStub();
  const root = shellRoot('<div data-view="home">home</div>');
  mountSpa(VtApp, "#z-spa-root", {
    spa: { viewTransitions: true },
    clientInit: () => { navigate("/other"); },
  });
  expect(calls.length).toBe(1); // clientInit's navigate() was already wrapped
  await flush();
  expect(root.textContent).toBe("other");
});

test("clientInit runs before the first render AND before any route guard fires", async () => {
  // A guard's work (e.g. an apiFetch session check) must be able to rely on
  // whatever clientInit installed (error relay, auth header source, …). Guards
  // run client-side post-mount, and clientInit runs before the first render,
  // so the ordering clientInit -> first render -> guard is structural — this
  // test pins it against a real guarded Router boot.
  const order: string[] = [];
  const Home = () => {
    order.push("render");
    return h("div", { "data-view": "guarded-home" }, "home");
  };
  const Fallback = () => h("div", { "data-z-wait": "" }, "wait");
  const routes = [{
    path: "/",
    component: Home,
    guard: async () => {
      order.push("guard");
      return true as const;
    },
  }];
  function App() {
    return h(Router, { routes, fallback: Fallback });
  }
  const root = shellRoot('<div data-z-wait="">wait</div>'); // guarded shell = the neutral fallback
  setLocationPathname("/"); // happy-dom defaults to about:blank; the route table matches "/"

  mountSpa(App, "#z-spa-root", { clientInit: () => order.push("clientInit") });
  await flush(); // let the mount effects + the async guard settle

  expect(order[0]).toBe("clientInit"); // before everything, exactly once
  expect(order.filter((e) => e === "clientInit").length).toBe(1);
  const guardAt = order.indexOf("guard");
  expect(guardAt).toBeGreaterThan(0); // the guard DID run, and after clientInit
  expect(root.textContent).toBe("home"); // authorized: the gated view painted
});
