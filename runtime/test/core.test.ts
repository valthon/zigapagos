import { test, expect } from "bun:test";
import { h, render, renderToString, hydrate, forwardRef, useImperativeHandle } from "@z/runtime/core";
import Counter from "./fixtures/Counter.island.tsx";

test("renderToString produces the SSR HTML", () => {
  const html = renderToString(h(Counter, { start: 2, label: "hi" }));
  expect(html).toBe("<button>hi: 2</button>");
});

test("hydrate adopts SSR DOM and is interactive", async () => {
  const root = document.createElement("div");
  root.innerHTML = renderToString(h(Counter, { start: 2, label: "hi" }));
  document.body.appendChild(root);
  hydrate(h(Counter, { start: 2, label: "hi" }), root);
  const btn = root.querySelector("button")!;
  expect(btn.textContent).toBe("hi: 2");
  btn.click();
  // Preact batches state updates and flushes on a microtask — let it flush.
  await new Promise((r) => setTimeout(r, 5));
  expect(btn.textContent).toBe("hi: 3");
});

// ── Gap 2: forwardRef / useImperativeHandle ───────────────────────────────────

// Defined outside test so the reference is stable across renders.
interface CounterHandle { increment: () => number }
let _count = 0;
const ImperativeCounter = forwardRef<CounterHandle, Record<string, never>>((_props, ref) => {
  useImperativeHandle(ref, () => ({
    increment: () => { _count += 1; return _count; },
  }));
  return h("div", null, "counter");
});

test("forwardRef + useImperativeHandle: ref's imperative method is callable", async () => {
  _count = 0;
  const root = document.createElement("div");
  document.body.appendChild(root);
  const ref: { current: CounterHandle | null } = { current: null };

  render(h(ImperativeCounter, { ref } as any), root);
  await new Promise((r) => setTimeout(r, 5));

  expect(typeof ref.current?.increment).toBe("function");
  expect(ref.current!.increment()).toBe(1);
  expect(ref.current!.increment()).toBe(2);
});
