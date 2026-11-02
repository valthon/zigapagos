// SSR-side resolve overrides: the render sidecar applies the
// z-runtime.config.json `resolve` map (plus the react->compat defaults when
// npmCompat/firstParty is non-empty) as Bun runtime module overrides, so a bare
// `react` import — from ANY file at ANY package depth — lands on the ONE shared
// Preact, with no tsconfig `paths` and no per-machine shim symlinks.
import { test, expect } from "bun:test";
import { resolve, dirname, join } from "node:path";
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

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

test("without a config custom aliases stay off (a mapped-only specifier fails loudly)", async () => {
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

for (const bridged of [false, true]) {
  test(`SSR shares Preact with a copied local runtime package (bridged=${bridged})`, async () => {
    const site = mkdtempSync(join(tmpdir(), "z-copied-runtime-"));
    try {
      const runtime = resolve(import.meta.dir, "..");
      const localRuntime = join(site, "node_modules/@z/runtime");
      mkdirSync(localRuntime, { recursive: true });
      cpSync(join(runtime, "package.json"), join(localRuntime, "package.json"));
      cpSync(join(runtime, "src"), join(localRuntime, "src"), { recursive: true });
      // Separate physical packages reproduce materialized file: dependencies;
      // symlinks to the framework's own Preact would hide the identity split.
      for (const dependency of ["preact", "preact-render-to-string"]) {
        const packageDir = dirname(Bun.resolveSync(`${dependency}/package.json`, runtime));
        cpSync(packageDir, join(site, "node_modules", dependency), { recursive: true });
      }
      if (bridged) {
        writeFileSync(join(site, "z-runtime.config.json"), JSON.stringify({ islandImports: { npmCompat: ["fixture-lib"] } }));
      }
      const src = join(site, "App.spa.tsx");
      writeFileSync(src, `
        import { h, Router${bridged ? "" : ", useState"} } from "@z/runtime";
        ${bridged ? 'import { useState } from "react";' : ""}
        function Page() { const [n] = useState(7); return h("button", null, n); }
        const routes = [{ path: "/", component: Page }];
        export default function App() { return h(Router, { base: "/app", routes }); }
      `);
      const proc = Bun.spawn([process.execPath, RENDER], { stdin: "pipe", stdout: "pipe", stderr: "pipe", cwd: site });
      proc.stdin.write(JSON.stringify({ id: 1, src, props: {}, pathname: "/app/" }) + "\n");
      await proc.stdin.end();
      const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      expect(code).toBe(0);
      expect(err).toBe("");
      const response = JSON.parse(out.trim());
      expect(response.error).toBeUndefined();
      expect(response.html).toBe("<button>7</button>");
    } finally {
      rmSync(site, { recursive: true, force: true });
    }
  });
}
