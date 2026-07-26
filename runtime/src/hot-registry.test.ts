import { test, expect, describe, beforeEach } from "bun:test";
import { __zHotRegister, __resetHotRegistryForTest } from "./hot-registry.ts";

const KEY = "/islands/Counter.island.tsx";

beforeEach(() => {
  __resetHotRegistryForTest();
});

describe("__zHotRegister", () => {
  test("same key + same signature => SAME proxy identity, new impl served", () => {
    const v1 = () => "v1";
    const v2 = () => "v2";
    const p1 = __zHotRegister(v1, KEY, "Widget", "useState") as () => string;
    const p2 = __zHotRegister(v2, KEY, "Widget", "useState") as () => string;
    expect(p2).toBe(p1); // stable identity — Preact keeps the instance
    expect(p1()).toBe("v2"); // implementation swapped in place
  });

  test("changed signature => NEW proxy identity (remount fallback)", () => {
    const p1 = __zHotRegister(() => 1, KEY, "Widget", "useState");
    const p2 = __zHotRegister(() => 2, KEY, "Widget", "useState,useEffect");
    expect(p2).not.toBe(p1);
  });

  test("different component names under the same module are independent", () => {
    const a = __zHotRegister(() => "a", KEY, "A", "");
    const b = __zHotRegister(() => "b", KEY, "B", "");
    expect(a).not.toBe(b);
    expect((a as () => string)()).toBe("a");
    expect((b as () => string)()).toBe("b");
  });

  test("different module keys never collide", () => {
    const a = __zHotRegister(() => "a", "/islands/A.tsx", "W", "");
    const b = __zHotRegister(() => "b", "/islands/B.tsx", "W", "");
    expect(a).not.toBe(b);
  });

  test("non-function input is returned unchanged", () => {
    const obj = { not: "a function" };
    expect(__zHotRegister(obj, KEY, "X", "")).toBe(obj);
    expect(__zHotRegister(undefined, KEY, "X", "")).toBeUndefined();
  });

  test("class components (prototype.render) are never proxied", () => {
    class Klass { render() { return "k"; } }
    expect(__zHotRegister(Klass, KEY, "Klass", "")).toBe(Klass);
  });

  test("proxy forwards all arguments and `this`", () => {
    function impl(this: { tag: string }, a: number, b: number, c: number) {
      return `${this?.tag}:${a + b + c}`;
    }
    const proxy = __zHotRegister(impl, KEY, "Sum", "") as typeof impl;
    expect(proxy.call({ tag: "t" }, 1, 2, 3)).toBe("t:6");
  });

  test("proxy carries displayName and tracks defaultProps across swaps", () => {
    const v1 = (() => "v1") as (() => string) & { defaultProps?: unknown };
    v1.defaultProps = { a: 1 };
    const p = __zHotRegister(v1, KEY, "Named", "") as (() => string) & {
      displayName?: string;
      defaultProps?: unknown;
    };
    expect(p.displayName).toBe("Named");
    expect(p.defaultProps).toEqual({ a: 1 });
    const v2 = (() => "v2") as (() => string) & { defaultProps?: unknown };
    v2.defaultProps = { a: 2 };
    __zHotRegister(v2, KEY, "Named", "");
    expect(p.defaultProps).toEqual({ a: 2 });
  });

  test("compound-component statics survive registration and swaps", () => {
    // `Card.Header = Header` executes on the raw impl BEFORE the transform's
    // footer swaps in the proxy — the proxy must mirror the static, or
    // `h(Card.Header, …)` renders garbage in a --hot dev bundle.
    const Header = () => "header";
    const v1 = (() => "v1") as (() => string) & Record<string, unknown>;
    v1.Header = Header;
    v1.variant = "outlined";
    const p = __zHotRegister(v1, KEY, "Card", "useState") as (() => string) &
      Record<string, unknown>;
    expect(p.Header).toBe(Header);
    expect(p.variant).toBe("outlined");

    // A preserving swap re-mirrors the NEW impl's statics on the SAME proxy…
    const Header2 = () => "header2";
    const v2 = (() => "v2") as (() => string) & Record<string, unknown>;
    v2.Header = Header2;
    expect(__zHotRegister(v2, KEY, "Card", "useState")).toBe(p);
    expect(p.Header).toBe(Header2);
    // …and drops statics the new impl no longer carries.
    expect("variant" in p).toBe(false);
  });

  test("symbol statics are mirrored too", () => {
    const tag = Symbol("brand");
    const v1 = (() => "v1") as (() => string) & { [k: symbol]: unknown };
    v1[tag] = "yes";
    const p = __zHotRegister(v1, KEY, "Branded", "") as (() => string) & {
      [k: symbol]: unknown;
    };
    expect(p[tag]).toBe("yes");
  });

  test("impl's own displayName wins; the registered name is only the fallback", () => {
    const v1 = (() => "v1") as (() => string) & { displayName?: string };
    v1.displayName = "FancyCard";
    const p = __zHotRegister(v1, KEY, "Card2", "") as (() => string) & {
      displayName?: string;
    };
    expect(p.displayName).toBe("FancyCard");
    // A swap to an impl WITHOUT displayName falls back to the registered name.
    __zHotRegister(() => "v2", KEY, "Card2", "");
    expect(p.displayName).toBe("Card2");
  });

  test("__resetHotRegistryForTest mints fresh identities", () => {
    const p1 = __zHotRegister(() => 1, KEY, "W", "s");
    __resetHotRegistryForTest();
    const p2 = __zHotRegister(() => 1, KEY, "W", "s");
    expect(p2).not.toBe(p1);
  });
});
