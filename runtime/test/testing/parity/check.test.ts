import { test, expect } from "bun:test";
import { checkParity } from "@z/runtime/testing/parity";
import { resolve } from "node:path";

const fx = (n: string) => resolve(import.meta.dir, "../../fixtures/" + n);

test("Counter (host-free) hydrates with zero mismatch", async () => {
  const r = await checkParity(fx("Counter.island.tsx"), { props: { start: 2, label: "hi" } });
  expect(r.ok).toBe(true);
  expect(r.mismatches).toEqual([]);
});

test("Loc: pathname neutralized on both sides → ok", async () => {
  const r = await checkParity(fx("Loc.island.tsx"), { pathname: "/booking" });
  expect(r.ok).toBe(true);
  expect(r.ssrHtml).toContain("path: /booking");
});

test("Gate: flags empty on both sides → ok (renders skeleton both)", async () => {
  const r = await checkParity(fx("Gate.island.tsx"), {});
  expect(r.ok).toBe(true);
});

test("sidecar SSR source is rejected in v1 with a clear message", async () => {
  await expect(checkParity(fx("Counter.island.tsx"), { ssr: "sidecar" })).rejects.toThrow(/sidecar.*v2/i);
});

test("a relative path is rejected (sidecar/import needs absolute)", async () => {
  await expect(checkParity("./Counter.island.tsx", {})).rejects.toThrow(/absolute/i);
});
