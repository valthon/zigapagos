import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCapture, runCheck } from "../../scripts/parity.ts";
import { routeToFile } from "../../scripts/parity/config.ts";

test("routeToFile maps routes to static files", () => {
  expect(routeToFile("/")).toBe("index.html");
  expect(routeToFile("/contact/")).toBe("contact/index.html");
  expect(routeToFile("/about")).toBe("about/index.html");
});

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "parity-")); });
afterEach(() => rmSync(dir, { recursive: true, force: true }));

function write(rel: string, html: string) {
  const p = join(dir, rel);
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, html);
}

const ASTRO = `<astro-island uid="x" component-url="Hero.js" props='{"title":[0,"Welcome"]}' client="load" ssr><section data-astro-cid-z><h1>Welcome</h1></section></astro-island>`;
const ZIG_OK = `<div data-z-island id="z-island-0" data-z-src="Hero.tsx" data-z-client="load" data-z-module="/x.js"><section><h1>Welcome</h1></section></div><script type="application/json" data-z-props="z-island-0">{"title":"Welcome"}</script>`;
const ZIG_BAD = ZIG_OK.replace("Welcome</h1>", "WELCOME</h1>");

const cfg = { reference: { kind: "static-dir" as const, path: "ref" }, build: { outDir: "build" }, routes: [{ path: "/" }] };

test("capture then check on an equivalent build → ok", () => {
  write("ref/index.html", ASTRO);
  write("build/index.html", ZIG_OK);
  runCapture(cfg, dir);
  const res = runCheck(cfg, dir);
  expect(res.ok).toBe(true);
  expect(res.routes[0].ok).toBe(true);
});

test("check on a divergent build → not ok, with a mismatch", () => {
  write("ref/index.html", ASTRO);
  write("build/index.html", ZIG_BAD);
  runCapture(cfg, dir);
  const res = runCheck(cfg, dir);
  expect(res.ok).toBe(false);
  expect(res.routes[0].structural.length).toBeGreaterThan(0);
});
