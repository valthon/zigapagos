import { expect, test, afterAll } from "bun:test";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const dir = join(import.meta.dir, ".describe-fixture");
mkdirSync(dir, { recursive: true });
const fixture = join(dir, "app.spa.tsx");
writeFileSync(fixture, `
import { h } from "@z/runtime/core";
export const spa = { base: "/app", title: "T", noindex: true };
export const routes = [
  { path: "/", component: () => h("i", null, "home") },
  { path: "/club/:id", component: () => null, skeleton: () => null },
  { path: "/admin/*", component: () => null, skeleton: false },
];
export default function App() { return h("div", null); }
`);
afterAll(() => rmSync(dir, { recursive: true, force: true }));

async function describe(src: string) {
  const proc = Bun.spawn(["bun", join(import.meta.dir, "render.ts")], {
    stdin: "pipe", stdout: "pipe", cwd: join(import.meta.dir, ".."),
  });
  proc.stdin.write(JSON.stringify({ id: 1, src, describe: true }) + "\n");
  await proc.stdin.flush();
  const reader = proc.stdout.getReader();
  const { value } = await reader.read();
  proc.kill();
  return JSON.parse(new TextDecoder().decode(value).split("\n")[0]);
}

test("describe returns spa config + classified routes (skeleton: false classifies as hasSkeleton: false)", async () => {
  const res = await describe(fixture);
  expect(res.id).toBe(1);
  expect(res.spa).toEqual({ base: "/app", title: "T", noindex: true });
  expect(res.routes).toEqual([
    { path: "/", dynamic: false, hasSkeleton: false },
    { path: "/club/:id", dynamic: true, hasSkeleton: true },
    { path: "/admin/*", dynamic: true, hasSkeleton: false },
  ]);
});

// --- the skeleton rule, enforced in describe ----------------------------------
// A dynamic route with neither a `skeleton` component nor the explicit
// `skeleton: false` opt-out must fail describe with an error naming the route;
// the Zig side (`sidecar.zig`) prefixes the SPA's src and fails the build.
const noSkeletonDir = join(import.meta.dir, ".describe-noskeleton-fixture");
mkdirSync(noSkeletonDir, { recursive: true });
const noSkeletonFixture = join(noSkeletonDir, "app.spa.tsx");
writeFileSync(noSkeletonFixture, `
import { h } from "@z/runtime/core";
export const spa = { base: "/app", title: "T", noindex: true };
export const routes = [
  { path: "/", component: () => h("i", null, "home") },
  { path: "/club/:id", component: () => null },
];
export default function App() { return h("div", null); }
`);
afterAll(() => rmSync(noSkeletonDir, { recursive: true, force: true }));

test("describe fails loudly when a dynamic route lacks a skeleton, naming the route", async () => {
  const res = await describe(noSkeletonFixture);
  expect(res.id).toBe(1);
  expect(res.routes).toBeUndefined();
  expect(res.error).toContain('"/club/:id"');
  expect(res.error).toContain("skeleton");
});

// --- staticPaths (getStaticPaths parity) ----------------------------------
const staticPathsDir = join(import.meta.dir, ".describe-staticpaths-fixture");
mkdirSync(staticPathsDir, { recursive: true });
const staticPathsFixture = join(staticPathsDir, "app.spa.tsx");
writeFileSync(staticPathsFixture, `
import { h } from "@z/runtime/core";
export const spa = { base: "/app", title: "T", noindex: true };
export const routes = [
  { path: "/", component: () => h("i", null, "home") },
  { path: "/club/:id", component: () => null, skeleton: () => null, staticPaths: () => [{ id: "1" }, { id: "2" }] },
];
export default function App() { return h("div", null); }
`);
afterAll(() => rmSync(staticPathsDir, { recursive: true, force: true }));

test("describe resolves staticPaths into concrete in-app paths on the dynamic leaf", async () => {
  const res = await describe(staticPathsFixture);
  expect(res.id).toBe(1);
  expect(res.routes).toEqual([
    { path: "/", dynamic: false, hasSkeleton: false },
    { path: "/club/:id", dynamic: true, hasSkeleton: true, staticPaths: ["/club/1", "/club/2"] },
  ]);
});

// --- spa.flags: baked build-time flag defaults -----------------------------
// `describe` passes `spa.flags` through (spa.zig snapshots it into each shell)
// and validates the values are booleans; `render` seeds the sidecar's flags
// store from the module's declared defaults so the SSR'd skeleton and the
// snapshot-seeded first client render agree — and CLEARS it again for a module
// without flags (one persistent process renders many modules).

/** Send several NDJSON requests to ONE render.ts process; returns the parsed
 * responses in order. */
async function rpc(reqs: object[]): Promise<any[]> {
  const proc = Bun.spawn(["bun", join(import.meta.dir, "render.ts")], {
    stdin: "pipe", stdout: "pipe", cwd: join(import.meta.dir, ".."),
  });
  for (const r of reqs) proc.stdin.write(JSON.stringify(r) + "\n");
  await proc.stdin.flush();
  const reader = proc.stdout.getReader();
  let out = "";
  while (out.split("\n").filter(Boolean).length < reqs.length) {
    const { value, done } = await reader.read();
    if (done) break;
    out += new TextDecoder().decode(value);
  }
  proc.kill();
  return out.split("\n").filter(Boolean).map((l) => JSON.parse(l));
}

const flagsDir = join(import.meta.dir, ".describe-flags-fixture");
mkdirSync(flagsDir, { recursive: true });
const flagsFixture = join(flagsDir, "app.spa.tsx");
writeFileSync(flagsFixture, `
import { h } from "@z/runtime/core";
import { useFlag } from "@z/runtime/flags";
export const spa = { base: "/app", title: "T", flags: { bookAsGuest: true, promoBanner: false } };
export const routes = [{ path: "/", component: () => null }];
export default function App() {
  return h("i", null, useFlag("bookAsGuest") ? "guest-on" : "guest-off");
}
`);
const noFlagsFixture = join(flagsDir, "plain.spa.tsx");
writeFileSync(noFlagsFixture, `
import { h } from "@z/runtime/core";
import { useFlag } from "@z/runtime/flags";
export const spa = { base: "/plain", title: "T" };
export const routes = [{ path: "/", component: () => null }];
export default function App() {
  return h("i", null, useFlag("bookAsGuest") ? "guest-on" : "guest-off");
}
`);
const badFlagsFixture = join(flagsDir, "bad.spa.tsx");
writeFileSync(badFlagsFixture, `
import { h } from "@z/runtime/core";
export const spa = { base: "/bad", flags: { bookAsGuest: "yes" } };
export const routes = [{ path: "/", component: () => null }];
export default function App() { return h("div", null); }
`);
afterAll(() => rmSync(flagsDir, { recursive: true, force: true }));

test("describe passes spa.flags through for the shell snapshot", async () => {
  const res = await describe(flagsFixture);
  expect(res.error).toBeUndefined();
  expect(res.spa.flags).toEqual({ bookAsGuest: true, promoBanner: false });
});

test("describe rejects a non-boolean spa.flags value (loud build failure)", async () => {
  const res = await describe(badFlagsFixture);
  expect(res.error).toContain("bookAsGuest");
  expect(res.error).toContain("boolean");
});

test("render seeds the SSR flag state from spa.flags — skeleton shows the default-ON branch", async () => {
  const [res] = await rpc([{ id: 1, src: flagsFixture, props: {}, pathname: "/app/" }]);
  expect(res.error).toBeUndefined();
  expect(res.html).toContain("guest-on");
});

test("render clears stale flag state for a module without spa.flags", async () => {
  const [first, second] = await rpc([
    { id: 1, src: flagsFixture, props: {}, pathname: "/app/" },
    { id: 2, src: noFlagsFixture, props: {}, pathname: "/plain/" },
  ]);
  expect(first.html).toContain("guest-on");
  // The previous module's defaults must not bleed into this render.
  expect(second.html).toContain("guest-off");
});

// --- clientInit: the client-only lifecycle hook ----------------------------
// The SSR sidecar must NEVER call a module's `clientInit` export — neither on
// a describe nor on a render. The fixture's clientInit throws, so any sidecar
// call would surface as an {error} response.
const clientInitDir = join(import.meta.dir, ".clientinit-fixture");
mkdirSync(clientInitDir, { recursive: true });
const clientInitFixture = join(clientInitDir, "app.spa.tsx");
writeFileSync(clientInitFixture, `
import { h } from "@z/runtime/core";
export const spa = { base: "/app", title: "T" };
export const routes = [{ path: "/", component: () => null }];
export function clientInit(): void {
  throw new Error("clientInit ran under SSR");
}
export default function App() { return h("i", null, "ssr-ok"); }
`);
afterAll(() => rmSync(clientInitDir, { recursive: true, force: true }));

test("the SSR sidecar never calls clientInit — describe and render both succeed", async () => {
  const [desc, rendered] = await rpc([
    { id: 1, src: clientInitFixture, describe: true },
    { id: 2, src: clientInitFixture, props: {}, pathname: "/app/" },
  ]);
  expect(desc.error).toBeUndefined();
  expect(desc.routes).toEqual([{ path: "/", dynamic: false, hasSkeleton: false }]);
  expect(rendered.error).toBeUndefined();
  expect(rendered.html).toContain("ssr-ok");
});

// --- render error payload carries message + stack ---------------------------
// When an island's SSR render throws, the response must include BOTH the JS
// message AND the (source-mapped) stack so the Zig build can surface them and
// attribute the failure — instead of losing the stack across the NDJSON
// boundary. The fixture's default component throws on render.
const throwDir = join(import.meta.dir, ".throw-fixture");
mkdirSync(throwDir, { recursive: true });
const throwFixture = join(throwDir, "boom.island.tsx");
writeFileSync(throwFixture, `
import { h } from "@z/runtime/core";
export default function Boom() {
  throw new Error("kaboom during render");
  return h("div", null);
}
`);
afterAll(() => rmSync(throwDir, { recursive: true, force: true }));

test("a render throw returns { error, stack } — the stack is propagated, not swallowed", async () => {
  const [res] = await rpc([{ id: 1, src: throwFixture, props: {}, pathname: "/" }]);
  expect(res.html).toBeUndefined();
  expect(res.error).toContain("kaboom during render");
  // The stack is present and references the throwing component/module, so the
  // build log can point at source lines.
  expect(typeof res.stack).toBe("string");
  expect(res.stack).toContain("kaboom during render");
  expect(res.stack).toContain("boom.island.tsx");
});

// --- stdin framing: UTF-8 across a chunk boundary ---------------------------
// `Bun.stdin.stream()` chunks on BYTE counts, so a multi-byte codepoint can be
// split across two chunks. Decoding each chunk with a FRESH TextDecoder turns
// both halves into U+FFFD; the request still parses as JSON, so the corruption
// lands silently in the prerendered HTML. The sidecar must decode with ONE
// streaming decoder.
const utf8Dir = join(import.meta.dir, ".utf8-fixture");
mkdirSync(utf8Dir, { recursive: true });
const utf8Fixture = join(utf8Dir, "echo.island.tsx");
writeFileSync(utf8Fixture, `
import { h } from "@z/runtime/core";
export default function Echo({ text }: { text: string }) {
  return h("div", null, text);
}
`);
afterAll(() => rmSync(utf8Dir, { recursive: true, force: true }));

test("a multi-byte codepoint split across two stdin chunks survives intact", async () => {
  const proc = Bun.spawn(["bun", join(import.meta.dir, "render.ts")], {
    stdin: "pipe", stdout: "pipe", cwd: join(import.meta.dir, ".."),
  });
  const line = JSON.stringify({ id: 1, src: utf8Fixture, props: { text: "A—B" }, pathname: "/" }) + "\n";
  const bytes = new TextEncoder().encode(line);
  // Split INSIDE the em-dash (E2 80 94): after its first byte.
  const split = bytes.indexOf(0xe2) + 1;
  expect(split).toBeGreaterThan(0);
  proc.stdin.write(bytes.slice(0, split));
  await proc.stdin.flush();
  await Bun.sleep(50); // force the remainder into a SEPARATE stdin chunk
  proc.stdin.write(bytes.slice(split));
  await proc.stdin.flush();
  const reader = proc.stdout.getReader();
  let out = "";
  while (!out.includes("\n")) {
    const { value, done } = await reader.read();
    if (done) break;
    out += new TextDecoder().decode(value);
  }
  proc.kill();
  const res = JSON.parse(out.split("\n")[0]);
  expect(res.error).toBeUndefined();
  expect(res.html).toContain("A—B");
  expect(res.html).not.toContain("�");
});
