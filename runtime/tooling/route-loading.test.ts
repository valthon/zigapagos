import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { gzipSync, brotliCompressSync, constants } from "node:zlib";
import { measureRoute } from "./route-loading.ts";

async function fixture(files: Record<string, string>, run: (root: string) => Promise<void>) {
  const root = mkdtempSync(join(tmpdir(), "route-loading-"));
  try {
    for (const [path, content] of Object.entries(files)) { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), content); }
    await run(root);
  } finally { rmSync(root, { recursive: true, force: true }); }
}
const html = (head: string, body = "") => `<!doctype html><html><head><title>Fixture</title>${head}</head><body>${body}</body></html>`;

test("cycles, shared static edges, reexports and nested lazy imports have distinct physical closures", () => fixture({
  "index.html": html('<script type="module" src="./entry.js"></script><link rel="stylesheet" href="./main.css">'),
  "entry.js": 'import "./shared.js"; export {x} from "./cycle.js"; import("./lazy.js");',
  "shared.js": 'export const value = 1;',
  "cycle.js": 'import "./entry.js"; export const x=1;',
  "lazy.js": 'import "./shared.js"; import "./lazy-child.js"; import("./nested.js");',
  "lazy-child.js": 'export const y=2;', "nested.js": 'export default 3;',
  "main.css": '@import "./other.css" screen; body{background:url("not-measured.png")}',
  "other.css": '@import "./main.css"; body{color:red}',
  "unused.js": 'throw new Error("not reachable");',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.unknowns).toEqual([]);
  expect(r.initial.files).toEqual(["cycle.js", "entry.js", "main.css", "other.css", "shared.js"]);
  expect(r.lazy_only.files).toEqual(["lazy-child.js", "lazy.js", "nested.js"]);
  expect(r.lazy_entries).toHaveLength(2);
  expect(r.lazy_entries.find((e) => e.entry === "lazy.js")!.files).toEqual(["lazy-child.js", "lazy.js"]);
  expect(r.browser_loading_complete).toBe(false);
  expect(r.resources.some((r) => r.path === "unused.js")).toBe(false);
}));

test("import maps resolve exact, prefix, URL and longest-scope mappings under a mount", () => fixture({
  "docs/index.html": html('<script type="importmap">{"imports":{"lib":"/project/default.js","pkg/":"/project/pkg/","/project/old.js":"/project/new.js"},"scopes":{"/project/scoped/":{"lib":"/project/scoped-lib.js"}}}</script><script type="module" src="/project/entry.js"></script>'),
  "entry.js": 'import "lib"; import "pkg/a.js"; import "./old.js"; import("./scoped/route.js");',
  "default.js": '', "pkg/a.js": '', "new.js": '', "scoped/route.js": 'import "lib";', "scoped-lib.js": '',
}, async (root) => {
  const r = await measureRoute(root, "docs/index.html", "/project");
  expect(r.unknowns).toEqual([]);
  expect(r.initial.files).toEqual(["default.js", "entry.js", "new.js", "pkg/a.js"]);
  expect(r.lazy_only.files).toEqual(["scoped-lib.js", "scoped/route.js"]);
}));

test("HTML case and entities, CSS escapes, inline imports and duplicate URL aliases are parsed", () => fixture({
  "index.html": html('<SCRIPT TYPE="module">import "./m.js";</SCRIPT><LINK REL="STYLESHEET" HREF="./style&#46;css"><script type="module" src="./m.js?q=1&amp;x=2"></script><link rel="modulepreload" href="./m.js#alias"><style>@import "./inline.css";</style>', '<div data-z-module="./island.js"></div>'),
  "m.js": '', "style.css": '/* @import "missing.css" */ @import "./esc\\61 ped.css";', "escaped.css": '', "inline.css": '', "island.js": '',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.unknowns).toEqual([]);
  expect(r.initial.files).toEqual(["escaped.css", "inline.css", "m.js", "style.css"]);
  expect(r.lazy_only.files).toEqual(["island.js"]);
  expect(r.inline_body_bytes_in_html.js).toBe(Buffer.byteLength('import "./m.js";'));
  expect(r.edges.filter((e) => e.target === "m.js")).toHaveLength(3);
}));

test("raw and compressed sizes are per physical file; inline bodies remain in HTML", () => fixture({
  "index.html": html('<script type="module" src="./m.js"></script><script>console.log("inline")</script>'),
  "m.js": 'export const greeting="hello";'.repeat(20),
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  const bytes = Buffer.from('export const greeting="hello";'.repeat(20));
  expect(r.initial.bytes).toEqual({ raw: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length, brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length });
  expect(r.inline_body_bytes_in_html.js).toBeGreaterThan(0);
}));

test("unknown graph edges stay visible, and strict CLI rejects incomplete coverage", () => fixture({
  "index.html": html('<base href="https://elsewhere.invalid/"><script type="module" src="./entry.js"></script><link rel="stylesheet" href="https://external.invalid/style.css">'),
  "entry.js": 'import "bare"; import "./missing.js"; import "https://external.invalid/lib.js"; import(variable); require("legacy");',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  expect(r.unknowns).toHaveLength(7);
  expect(r.unknowns.some((u) => u.reason.includes("computed"))).toBe(true);
  const p = Bun.spawn([process.execPath, resolve(import.meta.dir, "route-loading.ts"), root, "--page=index.html", "--strict"], { stdout: "pipe", stderr: "pipe" });
  const output = await new Response(p.stdout).text();
  expect(await p.exited).toBe(1);
  expect(JSON.parse(output).coverage_complete).toBe(false);
}));

test("blocked/late maps, import attributes and parse failures cannot claim complete graph coverage", () => fixture({
  "index.html": html('<script type="importmap">{"imports":{"blocked":null}}</script><script type="module" src="./entry.js"></script><script type="importmap">{}</script>'),
  "entry.js": 'import "blocked"; import data from "./data.json" with {type:"json"}; import "./invalid.js";',
  "data.json": '{}', "invalid.js": 'function (',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  for (const word of ["blocked", "late", "attributes", "syntax"]) expect(r.unknowns.some((u) => u.reason.includes(word))).toBe(true);
}));

test("symlink, encoded slash, deployment escape and malformed CSS edges are explicit unknowns", () => fixture({
  "index.html": html('<script type="module" src="/outside.js"></script><script src="./linked.js"></script><script src="./a%2fb.js"></script><link rel="stylesheet" href="./bad.css">'),
  "real.js": '', "bad.css": '@import ;',
}, async (root) => {
  symlinkSync(join(root, "real.js"), join(root, "linked.js"));
  const r = await measureRoute(root, "index.html", "/project");
  expect(r.coverage_complete).toBe(false);
  for (const word of ["outside", "symlink", "encoding", "CSS parser"]) expect(r.unknowns.some((u) => u.reason.includes(word))).toBe(true);
}));

test("HTML parsing cannot fetch or execute scripts, styles or iframes", async () => {
  let requests = 0;
  const server = Bun.serve({ port: 0, fetch() { requests++; return new Response('throw new Error("executed")'); } });
  try {
    await fixture({ "index.html": html(`<script src="${server.url}script.js"></script><link rel="stylesheet" href="${server.url}style.css"><link rel="stylesheet" href="./local.css"><script>fetch("${server.url}executed")</script>`, `<iframe src="${server.url}frame"></iframe>`), "local.css": `@import "${server.url}import.css"; body { background: url("${server.url}image.png") }` }, async (root) => {
      const r = await measureRoute(root, "index.html");
      expect(r.coverage_complete).toBe(false);
      expect(requests).toBe(0);
    });
  } finally { await server.stop(true); }
});

test("preload roots, classic scripts before import maps and inert HTML contents", () => fixture({
  "index.html": html('<script src="./classic.js"></script><script type="importmap">{"imports":{"lib":"./lib.js"}}</script><script type="module">import "lib";</script><link rel="PRELOAD" as="SCRIPT" href="./pre.js"><link rel="preload" as="style" href="./pre.css">', '<template><script src="./missing-template.js"></script></template><noscript><script src="./missing-noscript.js"></script></noscript>'),
  "classic.js": 'console.log("classic");', "lib.js": '', "pre.js": '', "pre.css": '',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.unknowns).toEqual([]);
  expect(r.initial.files).toEqual(["classic.js", "lib.js", "pre.css", "pre.js"]);
}));

test("module syntax in external classic scripts cannot claim complete coverage", () => fixture({
  "index.html": html('<script src="./classic.js"></script>'),
  "classic.js": 'import "./dep.js";', "dep.js": '',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  expect(r.unknowns.some((u) => u.reason.includes("classic script"))).toBe(true);
}));


test("foreign script references and unknown legacy languages are not silently omitted", () => fixture({
  "index.html": html('<script language="unknown">legacy()</script>', '<svg><script href="./foreign.js"></script></svg>'),
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  expect(r.unknowns.some((u) => u.reason.includes("non-HTML"))).toBe(true);
  expect(r.unknowns.some((u) => u.reason.includes("legacy"))).toBe(true);
}));

test("scope keys require exact URLs or slash-terminated prefixes per WHATWG step 10.1", () => fixture({
  // https://html.spec.whatwg.org/multipage/webappapis.html#resolve-a-module-specifier
  "index.html": html('<script type="importmap">{"imports":{"lib":"./global.js"},"scopes":{"./scoped":{"lib":"./wrong.js"},"./exact.js":{"lib":"./exact-lib.js"},"./prefix/":{"lib":"./prefix-lib.js"}}}</script><script type="module" src="./scoped/route.js"></script><script type="module" src="./exact.js"></script><script type="module" src="./prefix/route.js"></script>'),
  "scoped/route.js": 'import "lib";', "exact.js": 'import "lib";', "prefix/route.js": 'import "lib";',
  "global.js": '', "exact-lib.js": '', "prefix-lib.js": '',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.unknowns).toEqual([]);
  expect(r.initial.files).toEqual(["exact-lib.js", "exact.js", "global.js", "prefix-lib.js", "prefix/route.js", "scoped/route.js"]);
}));

test("dynamic import second arguments flag unsupported options while retaining literal edges", () => fixture({
  "index.html": html('<script type="module" src="./entry.js"></script>'),
  "entry.js": 'import("./data.json", {with:{type:"json"}}); import("./module.js", options);',
  "data.json": '{}', "module.js": 'export default 1;',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  expect(r.unknowns.filter((u) => u.reason.includes("dynamic import options"))).toHaveLength(2);
  expect(r.lazy_only.files).toEqual(["data.json", "module.js"]);
  const p = Bun.spawn([process.execPath, resolve(import.meta.dir, "route-loading.ts"), root, "--page=index.html", "--strict"], { stdout: "pipe", stderr: "pipe" });
  const output = await new Response(p.stdout).text();
  expect(await p.exited).toBe(1);
  expect(JSON.parse(output).coverage_complete).toBe(false);
}));

test("unused malformed map entries and scope URLs flag conservative coverage", () => fixture({
  "index.html": html('<script type="importmap">{"imports":{"unused":123,"pkg/":"./pkg/?query"},"scopes":{"./unused/":{"bad":"bare-address"},"https://[":{}}}</script>'),
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  expect(r.unknowns).toHaveLength(4);
  const p = Bun.spawn([process.execPath, resolve(import.meta.dir, "route-loading.ts"), root, "--page=index.html", "--strict"], { stdout: "pipe", stderr: "pipe" });
  await new Response(p.stdout).text();
  expect(await p.exited).toBe(1);
}));

test("unused null blockers and valid external import-map addresses do not imply loading", () => fixture({
  "index.html": html('<script type="importmap">{"imports":{"blocked":null,"external":"https://external.invalid/module.js"}}</script>'),
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(true);
  expect(r.resources).toEqual([]);
}));

test("CSS query aliases ignore module scopes and classic preloads preserve script mode", () => fixture({
  "index.html": html('<script type="importmap">{"scopes":{"./":{"lib":"./lib.js"}}}</script><link rel="stylesheet" href="./main.css?v=1"><link rel="preload" as="script" href="./classic.js"><script src="./classic.js"></script>'),
  "main.css": '@import "./other.css#theme";', "other.css": '', "classic.js": 'console.log("classic")',
}, async (root) => {
  const r = await measureRoute(root, "index.html");
  expect(r.unknowns).toEqual([]);
  expect(r.initial.files).toEqual(["classic.js", "main.css", "other.css"]);
}));

test("failed graph visits do not emit resolved targets without resource records", () => fixture({
  "index.html": html('<script type="module" src="./missing.js"></script><link rel="stylesheet" href="./linked.css">'),
  "real.css": '',
}, async (root) => {
  symlinkSync(join(root, "real.css"), join(root, "linked.css"));
  const r = await measureRoute(root, "index.html");
  expect(r.coverage_complete).toBe(false);
  expect(r.edges.map((e) => e.target)).toEqual([null, null]);
  expect(r.resources).toEqual([]);
}));


test("repeated-slash aliases count physical JS/CSS once and preserve URL ambiguity", () => fixture({
  "index.html": html('<script type="module" src="/project/a/b.js"></script><script type="module" src="/project/a//b.js"></script><link rel="stylesheet" href="/project/a/c.css"><link rel="stylesheet" href="/project/a///c.css">'),
  "a/b.js": 'export const x = 1;', "a/c.css": 'body { color: red; }',
}, async (root) => {
  const r = await measureRoute(root, "index.html", "/project");
  expect(r.initial.files).toEqual(["a/b.js", "a/c.css"]);
  expect(r.resources).toHaveLength(2);
  for (const metric of ["raw", "gzip", "brotli"] as const) {
    expect(r.initial.bytes[metric]).toBe(r.resources.reduce((sum, resource) => sum + resource.bytes[metric], 0));
  }
  expect(r.edges.map((edge) => edge.target)).toEqual(["a/b.js", "a/b.js", "a/c.css", "a/c.css"]);
  expect(r.coverage_complete).toBe(false);
  expect(r.unknowns.filter((item) => item.reason.includes("repeated-slash"))).toHaveLength(2);
  // Collapsing a URL path is not equivalent to resolving its relative imports.
  expect(new URL("../child.js", "https://example.test/a//b.js").pathname).toBe("/a/child.js");
  expect(new URL("../child.js", "https://example.test/a/b.js").pathname).toBe("/child.js");
  const result = Bun.spawnSync(["bun", resolve(import.meta.dir, "route-loading.ts"), root, "--page=index.html", "--url-prefix=/project", "--strict"]);
  expect(result.exitCode).toBe(1);
}));
