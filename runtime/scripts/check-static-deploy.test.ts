import { test, expect } from "bun:test";
import { join } from "node:path";

test("HTTP deployment rehearsal through native Bun networking", async () => {
  // runtime's happy-dom preload replaces fetch/Response with browser mocks.
  // Run real HTTP cases in a fresh root-cwd process instead of changing globals
  // underneath the runtime's other tests.
  const child = Bun.spawn([process.execPath, "test", "tests/deploy/checker.test.ts"], {
    cwd: join(import.meta.dir, "../.."), stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    Bun.readableStreamToText(child.stdout), Bun.readableStreamToText(child.stderr), child.exited,
  ]);
  if (code !== 0) throw new Error(stdout + stderr);
  expect(code).toBe(0);
}, 15000);
