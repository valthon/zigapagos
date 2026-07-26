// Testing-preload resolution preset: the one-line bunfig preload
// (`@z/runtime/testing/preload`) must make renderForTest work on a view that
// lives in an OUT-OF-TREE workspace package (bun links workspace deps as
// symlinks and `bun test` realpaths their files outside the project root,
// where tsconfig `paths` and the package's own node_modules can't resolve
// react/@z/runtime), and must supply @z/site-data (config-fed + mockable).
//
// Module overrides are process-global, so — like test/ssr-resolve.test.ts —
// every scenario spawns a child `bun test` in a fixture app rather than
// registering overrides in THIS process. Fixtures are built in tmpdirs
// (node_modules/ is gitignored repo-wide, so symlinked fixtures can't be
// checked in).
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const RUNTIME_DIR = resolve(import.meta.dir, "../.."); // runtime/ (the @z/runtime package)

async function runChildBunTest(appDir: string): Promise<{ out: string; code: number }> {
  const proc = Bun.spawn([process.execPath, "test"], {
    cwd: appDir,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { out: `${out}\n${err}`, code };
}

function writePreloadBunfig(appDir: string): void {
  writeFileSync(join(appDir, "bunfig.toml"), `[test]\npreload = ["@z/runtime/testing/preload"]\n`);
}

/** Symlink the framework runtime into the app's node_modules (how bun links it). */
function linkRuntime(appDir: string): void {
  mkdirSync(join(appDir, "node_modules/@z"), { recursive: true });
  symlinkSync(RUNTIME_DIR, join(appDir, "node_modules/@z/runtime"));
}

test("out-of-tree workspace view: one runtime, injected flags, config-fed @z/site-data, mockSiteData", async () => {
  const root = mkdtempSync(join(tmpdir(), "preload-workspace-"));

  // The shared workspace package, OUTSIDE the app dir — bun test realpaths
  // node_modules/@acme/shared to here, where no tsconfig paths / node_modules
  // chain can resolve react or @z/runtime without the preload's overrides.
  const shared = join(root, "shared");
  mkdirSync(shared, { recursive: true });
  writeFileSync(
    join(shared, "package.json"),
    JSON.stringify({ name: "@acme/shared", type: "module", main: "Card.tsx" }),
  );
  writeFileSync(
    join(shared, "tsconfig.json"),
    JSON.stringify({ compilerOptions: { jsx: "react-jsx", jsxImportSource: "@z/runtime" } }),
  );
  writeFileSync(
    join(shared, "Card.tsx"),
    `import { useFlag } from "@z/runtime";
import { useState } from "react";
import site from "@z/site-data";
export function Card({ label }: { label: string }) {
  const [n] = useState(3); // react -> compat bridge exercised
  const promo = useFlag("promo"); // ONE runtime: reads the flags renderForTest seeds
  return <div>{label}:{n}:{promo ? "PROMO" : "noflag"}:{(site as { hours: { mon: string } }).hours.mon}</div>;
}
`,
  );

  const app = join(root, "app");
  mkdirSync(join(app, "content"), { recursive: true });
  mkdirSync(join(app, "test"), { recursive: true });
  writePreloadBunfig(app);
  writeFileSync(
    join(app, "z-runtime.config.json"),
    JSON.stringify({
      islandImports: { firstParty: ["@acme/shared"] },
      data: { hours: "content/hours.json" },
    }),
  );
  writeFileSync(join(app, "content/hours.json"), JSON.stringify({ mon: "9-5" }));
  linkRuntime(app);
  mkdirSync(join(app, "node_modules/@acme"), { recursive: true });
  symlinkSync(shared, join(app, "node_modules/@acme/shared")); // out-of-tree workspace link
  writeFileSync(
    join(app, "test/card.test.ts"),
    `import { test, expect } from "bun:test";
import { renderForTest, mockSiteData } from "@z/runtime/testing";
import { Card } from "@acme/shared";
test("out-of-tree workspace view: one runtime, injected flags, config-fed site data", () => {
  expect(renderForTest(Card, { props: { label: "hi" }, flags: { promo: true } }))
    .toBe("<div>hi:3:PROMO:9-5</div>");
});
test("mockSiteData overrides config data; restore() returns to the config baseline", () => {
  const restore = mockSiteData({ hours: { mon: "MOCKED" } });
  expect(renderForTest(Card, { props: { label: "m" } })).toContain("MOCKED");
  restore();
  expect(renderForTest(Card, { props: { label: "m" } })).toContain("9-5");
});
`,
  );

  const { out, code } = await runChildBunTest(app);
  expect(out).toContain(" 2 pass");
  expect(code).toBe(0);
});

test("config-fed app: enumeration-FIRST access (Object.keys/in/spread) seeds from config", async () => {
  // Regression: the lazy config seed used to fire only in the
  // Proxy's `get` trap, so a view whose FIRST site-data access enumerated keys
  // (Object.entries(site), {...site}, `key in site`) silently saw {} where the
  // real build (sidecar override / bundler-baked module) saw the config data.
  // Fresh fixture app: bun test runs files in one process, so this must not
  // share a fixture with tests that `get` site data first.
  const app = mkdtempSync(join(tmpdir(), "preload-enumfirst-"));
  mkdirSync(join(app, "content"), { recursive: true });
  mkdirSync(join(app, "test"), { recursive: true });
  writePreloadBunfig(app);
  writeFileSync(
    join(app, "z-runtime.config.json"),
    JSON.stringify({ data: { hours: "content/hours.json" } }),
  );
  writeFileSync(join(app, "content/hours.json"), JSON.stringify({ mon: "9-5" }));
  linkRuntime(app);
  writeFileSync(
    join(app, "test/enum-first.test.ts"),
    `import { test, expect } from "bun:test";
import site from "@z/site-data";
import { mockSiteData } from "@z/runtime/testing";
test("Object.keys as the VERY FIRST access sees the config data", () => {
  expect(Object.keys(site)).toEqual(["hours"]);
});
test("'in' and spread see the config data too", () => {
  expect("hours" in site).toBe(true);
  expect({ ...(site as Record<string, unknown>) }).toEqual({ hours: { mon: "9-5" } });
});
test("after mockSiteData()+restore(), enumeration-first re-seeds to the config baseline", () => {
  const restore = mockSiteData({ nav: ["a"] });
  expect(Object.keys(site)).toEqual(["nav"]);
  restore();
  expect(Object.keys(site)).toEqual(["hours"]); // NOT [] — restore re-seeds lazily
  expect((site as { hours: { mon: string } }).hours.mon).toBe("9-5");
});
`,
  );

  const { out, code } = await runChildBunTest(app);
  expect(out).toContain(" 3 pass");
  expect(code).toBe(0);
});

test("configless app: unseeded @z/site-data loud-fails; mockSiteData works with no config at all", async () => {
  // No z-runtime.config.json anywhere above the tmpdir → no resolve overrides
  // (base behavior) and a mock-only @z/site-data.
  const app = mkdtempSync(join(tmpdir(), "preload-configless-"));
  mkdirSync(join(app, "test"), { recursive: true });
  writePreloadBunfig(app);
  linkRuntime(app);
  writeFileSync(
    join(app, "test/mock.test.ts"),
    `import { test, expect } from "bun:test";
import site from "@z/site-data";
import { mockSiteData } from "@z/runtime/testing";
test("unseeded @z/site-data loud-fails with an actionable pointer", () => {
  expect(() => (site as { nav?: unknown }).nav).toThrow(/mockSiteData|"data" map/);
});
test("mockSiteData supplies data with no config at all; restore reverts to loud-fail", () => {
  const restore = mockSiteData({ nav: ["a"] });
  expect((site as { nav: string[] }).nav).toEqual(["a"]);
  restore();
  expect(() => (site as { nav?: unknown }).nav).toThrow(/mockSiteData/);
});
`,
  );

  const { out, code } = await runChildBunTest(app);
  expect(out).toContain(" 2 pass");
  expect(code).toBe(0);
});
