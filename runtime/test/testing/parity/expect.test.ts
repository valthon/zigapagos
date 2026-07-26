import { test, expect } from "bun:test";
import { expectParity } from "@z/runtime/testing/parity";
import { resolve } from "node:path";

const fx = (n: string) => resolve(import.meta.dir, "../../fixtures/" + n);

test("expectParity passes for a host-free island", async () => {
  await expectParity(fx("Counter.island.tsx"), { props: { start: 1, label: "x" } });
});

test("expectParity THROWS on a real host divergence (Clock: server now()=0 vs client Date.now())", async () => {
  await expect(expectParity(fx("Clock.island.tsx"), {})).rejects.toThrow(/mismatch/i);
});

test("a frozen clock via the mock host neutralizes the divergence", async () => {
  await expectParity(fx("Clock.island.tsx"), { host: { now: 0 } }); // Date.now()===0 on client → "0" both sides
});

test("ignoreSelectors also neutralizes it", async () => {
  await expectParity(fx("Clock.island.tsx"), { ignoreSelectors: ["time"] });
});
