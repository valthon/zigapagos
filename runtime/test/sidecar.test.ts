import { test, expect } from "bun:test";
import { resolve } from "node:path";

const COUNTER = resolve(import.meta.dir, "fixtures/Counter.island.tsx");
const LOC = resolve(import.meta.dir, "fixtures/Loc.island.tsx");
const PANEL = resolve(import.meta.dir, "fixtures/Panel.island.tsx");

test("render-once renders an island to SSR HTML with given props", async () => {
  const proc = Bun.spawn(
    ["bun", resolve(import.meta.dir, "../sidecar/render-once.ts"), COUNTER, '{"start":2,"label":"hi"}', "/"],
    { stdout: "pipe" },
  );
  const out = (await new Response(proc.stdout).text()).trim();
  expect(await proc.exited).toBe(0);
  expect(out).toBe("<button>hi: 2</button>");
});

test("render-once injects the SSR pathname so host.pathname() agrees", async () => {
  const proc = Bun.spawn(
    ["bun", resolve(import.meta.dir, "../sidecar/render-once.ts"), LOC, "{}", "/booking/"],
    { stdout: "pipe" },
  );
  const out = (await new Response(proc.stdout).text()).trim();
  expect(await proc.exited).toBe(0);
  expect(out).toBe("<p>path: /booking/</p>");
});

test("NDJSON service weaves slots into the component output", async () => {
  const proc = Bun.spawn(["bun", resolve(import.meta.dir, "../sidecar/render.ts")], { stdin: "pipe", stdout: "pipe" });
  proc.stdin.write(JSON.stringify({ id: 1, src: PANEL, props: { title: "FAQ" },
    slots: { default: "<p>body</p>", heading: "<h2>Questions</h2>" }, pathname: "/" }) + "\n");
  await proc.stdin.end();
  const line = JSON.parse((await new Response(proc.stdout).text()).trim().split("\n")[0]);
  expect(line.id).toBe(1);
  // heading slot woven into <header>; default into <div class="body"> — at the component's positions
  expect(line.html).toContain('<header><z-slot data-z-slot="heading" style="display:contents"><h2>Questions</h2></z-slot></header>');
  expect(line.html).toContain('<div class="body"><z-slot data-z-slot="default" style="display:contents"><p>body</p></z-slot></div>');
});

test("a request with no slots is byte-identical to today (leaf island)", async () => {
  const proc = Bun.spawn(["bun", resolve(import.meta.dir, "../sidecar/render.ts")], { stdin: "pipe", stdout: "pipe" });
  proc.stdin.write(JSON.stringify({ id: 9, src: COUNTER, props: { start: 1, label: "n" }, pathname: "/" }) + "\n");
  await proc.stdin.end();
  const line = JSON.parse((await new Response(proc.stdout).text()).trim().split("\n")[0]);
  expect(line.html).toBe("<button>n: 1</button>");
});

test("NDJSON service answers each request line with its id + html", async () => {
  const proc = Bun.spawn(["bun", resolve(import.meta.dir, "../sidecar/render.ts")], {
    stdin: "pipe", stdout: "pipe",
  });
  proc.stdin.write(JSON.stringify({ id: 1, src: COUNTER, props: { start: 5, label: "n" }, pathname: "/" }) + "\n");
  proc.stdin.write(JSON.stringify({ id: 2, src: COUNTER, props: { start: 0, label: "x" }, pathname: "/" }) + "\n");
  await proc.stdin.end();
  const text = await new Response(proc.stdout).text();
  const lines = text.trim().split("\n").map((l) => JSON.parse(l));
  expect(lines).toContainEqual({ id: 1, html: "<button>n: 5</button>" });
  expect(lines).toContainEqual({ id: 2, html: "<button>x: 0</button>" });
});
