// SSR-side resolve overrides: the render sidecar applies the
// z-runtime.config.json `resolve` map (plus the react->compat defaults when
// npmCompat/firstParty is non-empty) as Bun runtime module overrides, so a bare
// `react` import — from ANY file at ANY package depth — lands on the ONE shared
// Preact, with no tsconfig `paths` and no per-machine shim symlinks.
import { test, expect } from "bun:test";
import { resolve } from "node:path";

const SITE = resolve(import.meta.dir, "fixtures/resolve-site");
const RENDER = resolve(import.meta.dir, "../sidecar/render.ts");
const RENDER_ONCE = resolve(import.meta.dir, "../sidecar/render-once.ts");
const ISLAND = resolve(SITE, "ReactCounter.island.tsx");

test("render sidecar (NDJSON): bare `react` + a custom mapped specifier resolve via the config overrides", async () => {
  // cwd = the fixture site root, exactly how the Zig build spawns the sidecar
  // (cwd = website root); the config is discovered by walking up from there.
  const proc = Bun.spawn(["bun", RENDER], { stdin: "pipe", stdout: "pipe", cwd: SITE });
  proc.stdin.write(JSON.stringify({ id: 1, src: ISLAND, props: { label: "hi" }, pathname: "/" }) + "\n");
  await proc.stdin.end();
  const line = JSON.parse((await new Response(proc.stdout).text()).trim().split("\n")[0]);
  expect(line.error).toBeUndefined();
  // useState ran on the shared Preact (7), @acme/greeting hit ./greeting.ts,
  // store.cjs require("react")d through the override synchronously, and the
  // fixture tsconfig's jsxImportSource "@z/runtime" resolved via the identity
  // self-entries.
  expect(line.html).toBe("<button>hi: 7 (hello-from-override) [cjs-react-ok] [legacy-fn-ok]</button>");
});

test("render-once applies the same overrides", async () => {
  const proc = Bun.spawn(["bun", RENDER_ONCE, ISLAND, '{"label":"x"}', "/"], {
    stdout: "pipe",
    stderr: "pipe",
    cwd: SITE,
  });
  const out = (await new Response(proc.stdout).text()).trim();
  expect(await proc.exited).toBe(0);
  expect(out).toBe("<button>x: 7 (hello-from-override) [cjs-react-ok] [legacy-fn-ok]</button>");
});

test("without a config the overrides stay off (a mapped-only specifier fails loudly)", async () => {
  // cwd = the fixtures dir (no z-runtime.config.json anywhere up to /) — the
  // island's `@acme/greeting` import must NOT resolve.
  const proc = Bun.spawn(["bun", RENDER], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "ignore",
    cwd: resolve(import.meta.dir, "fixtures"),
  });
  proc.stdin.write(JSON.stringify({ id: 1, src: ISLAND, props: { label: "hi" }, pathname: "/" }) + "\n");
  await proc.stdin.end();
  const line = JSON.parse((await new Response(proc.stdout).text()).trim().split("\n")[0]);
  expect(line.error).toBeDefined();
});
