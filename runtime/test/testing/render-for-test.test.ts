// renderForTest — the browser-free unit-test primitive for a single view/island.
// Renders to the exact SSR string the Bun sidecar produces, with
// props / guardData / flags / experiments / pathname injected in isolation.
import { test, expect } from "bun:test";
import { renderForTest } from "@z/runtime/testing";
import { host } from "@z/runtime/host";
import { setSsrPathname } from "@z/runtime/ssr-env";
import GuardView from "../fixtures/GuardView.island.tsx";

test("injects props into the view", () => {
  const html = renderForTest(GuardView, { props: { title: "Home" } });
  expect(html).toContain("<h1>Home</h1>");
  // Defaults for the un-injected inputs: no guard data, no promo flag.
  expect(html).toContain(`<p class="user">anonymous</p>`);
  expect(html).not.toContain("promo");
});

test("injects guardData — surfaces through useGuardData()", () => {
  const html = renderForTest(GuardView, { guardData: { name: "Ada" } });
  expect(html).toContain(`<p class="user">Ada</p>`);
});

test("injects baked flags — surfaces through useFlag() on first render", () => {
  const on = renderForTest(GuardView, { flags: { promoBanner: true } });
  expect(on).toContain(`<div class="promo">promo</div>`);
  const off = renderForTest(GuardView, { flags: { promoBanner: false } });
  expect(off).not.toContain("promo");
});

test("injects experiments — surfaces through useVariant()", () => {
  const html = renderForTest(GuardView, { experiments: { hero: "b" } });
  expect(html).toContain(`<p class="variant">b</p>`);
  // Absent experiment falls back to the view's own default.
  const control = renderForTest(GuardView, {});
  expect(control).toContain(`<p class="variant">control</p>`);
});

test("pathname drives host.pathname() on the server", () => {
  const html = renderForTest(GuardView, { pathname: "/app/dashboard" });
  expect(html).toContain(`<p class="path">/app/dashboard</p>`);
});

test("all inputs compose in one render", () => {
  const html = renderForTest(GuardView, {
    props: { title: "Dashboard" },
    guardData: { name: "Ada" },
    flags: { promoBanner: true },
    experiments: { hero: "b" },
    pathname: "/app/dashboard",
  });
  expect(html).toContain("<h1>Dashboard</h1>");
  expect(html).toContain(`<p class="user">Ada</p>`);
  expect(html).toContain(`<p class="path">/app/dashboard</p>`);
  expect(html).toContain(`<div class="promo">promo</div>`);
  expect(html).toContain(`<p class="variant">b</p>`);
});

test("omitting pathname resets to the '/' default — no leak from ambient SSR state", () => {
  // A prior render (sidecar, renderIsland, another test) left the SSR pathname set.
  setSsrPathname("/leaked");
  try {
    // renderForTest with no pathname must seed the documented "/" default, not
    // inherit the ambient value.
    const html = renderForTest(GuardView, {});
    expect(html).toContain(`<p class="path">/</p>`);
    expect(html).not.toContain("/leaked");
  } finally {
    setSsrPathname("/"); // don't leak into other tests
  }
});

test("omitting flags/experiments seeds empty flags — no leak from an ambient store", () => {
  const before = host.store.getStr("flags");
  // The page-global flags store carries ambient flags from a prior seed.
  host.store.setStr("flags", JSON.stringify({ flags: { promoBanner: true }, experiments: { hero: "b" } }));
  try {
    // With neither flags nor experiments injected, the view must see empties —
    // not the ambient promo/variant.
    const html = renderForTest(GuardView, {});
    expect(html).not.toContain("promo");
    expect(html).toContain(`<p class="variant">control</p>`);
  } finally {
    host.store.setStr("flags", before); // don't leak into other tests
  }
});

test("injected state is scoped — no bleed across calls", () => {
  const before = host.store.getStr("flags");
  renderForTest(GuardView, {
    flags: { promoBanner: true },
    guardData: { name: "Ada" },
    pathname: "/scoped",
  });
  // The page-global flags store is restored to what it was.
  expect(host.store.getStr("flags")).toBe(before);
  // A bare follow-up render sees defaults, not the previous call's inputs.
  const html = renderForTest(GuardView, {});
  expect(html).toContain(`<p class="user">anonymous</p>`);
  expect(html).not.toContain("promo");
  expect(html).toContain(`<p class="path">/</p>`); // pathname reset to "/"
});
