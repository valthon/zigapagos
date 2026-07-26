import { test, expect } from "bun:test";
import { checkParity } from "@z/runtime/testing/parity";
import { resolve } from "node:path";

test("Hero island has zero SSR↔hydration mismatch", async () => {
  const r = await checkParity(resolve(import.meta.dir, "../components/Hero.island.tsx"), {
    props: { headline: "Welcome" },
  });
  expect(r.ok).toBe(true);
});
