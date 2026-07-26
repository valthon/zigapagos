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
import { mountSpa, Router } from "@z/runtime/router";
import { flush } from "@z/runtime/testing";
import { setLocationPathname } from "@z/runtime/testing/parity";

beforeEach(() => {
  __resetStoresForTest();
  document.body.innerHTML = "";
});
afterEach(() => {
  delete (window as any).zigapagosOnError;
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
