// @z/site-data: a virtual module resolved at build time from the
// site's content, selected by z-runtime.config.json's `data` map. Covers the
// ziggy-frontmatter subset parser, the data builder (globs + single files),
// the emitted module/.d.ts sources, the bundler integration (virtual module,
// content files as depfile inputs, d.ts emission), and the lint integration.
import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  parseZiggyFrontmatter,
  parseContentDocument,
  buildSiteData,
  siteDataModuleSource,
  siteDataDts,
} from "../scripts/site-data.ts";
import { bundleIsland } from "../sidecar/bundle-island.ts";
import { buildAllow } from "../scripts/lint-island-imports.ts";
import type { ZRuntimeConfig } from "../scripts/z-runtime-config.ts";

const DATA_SITE = resolve(import.meta.dir, "fixtures/data-site");

// --- ziggy frontmatter parser (subset) ------------------------------------

test("parseZiggyFrontmatter: strings, numbers, bools, @date, arrays", () => {
  const fm = parseZiggyFrontmatter(
    `.title = "Hi \\"there\\"",\n.count = 3,\n.ratio = 1.5,\n.neg = -2,\n.on = true,\n.off = false,\n.d = @date("2024-01-01T00:00:00"),\n.tags = ["a", "b"],\n`,
    "test.smd",
  );
  expect(fm).toEqual({
    title: 'Hi "there"',
    count: 3,
    ratio: 1.5,
    neg: -2,
    on: true,
    off: false,
    d: "2024-01-01T00:00:00",
    tags: ["a", "b"],
  });
});

test("parseZiggyFrontmatter: nested structs, maps, null, trailing commas optional", () => {
  const fm = parseZiggyFrontmatter(
    `.extra = { .note = "n", .codes = [1, 2] },\n.map = { "k v": 9 },\n.nothing = null\n`,
    "test.smd",
  );
  expect(fm).toEqual({ extra: { note: "n", codes: [1, 2] }, map: { "k v": 9 }, nothing: null });
});

test("parseZiggyFrontmatter: multiline string lines join with newlines", () => {
  const fm = parseZiggyFrontmatter(`.motto =\n\\\\line one\n\\\\line two\n,\n.x = 1,\n`, "t.smd");
  expect(fm).toEqual({ motto: "line one\nline two", x: 1 });
});

test("parseZiggyFrontmatter: loud-fails with the file name on bad syntax", () => {
  expect(() => parseZiggyFrontmatter(`.title = wat,\n`, "bad.smd")).toThrow(/bad\.smd/);
});

test("parseZiggyFrontmatter: valid unicode escapes decode; invalid ones fail through the parser (file/line context)", () => {
  // Valid \uXXXX and \u{...} escapes.
  expect(parseZiggyFrontmatter(`.a = "\\u0041\\u{1F600}",\n`, "u.smd")).toEqual({ a: "A\u{1F600}" });
  // Invalid hex must be the parser's contextual error — never a raw
  // NaN/RangeError with a bare stack from String.fromCodePoint.
  expect(() => parseZiggyFrontmatter(`.a = "\\uZZZZ",\n`, "u.smd")).toThrow(/u\.smd.*line 1.*\\uXXXX/);
  expect(() => parseZiggyFrontmatter(`.a = "\\u12",\n`, "u.smd")).toThrow(/u\.smd.*line 1/);
  expect(() => parseZiggyFrontmatter(`.a = "\\u{NOPE}",\n`, "u.smd")).toThrow(/u\.smd.*line 1/);
  // Beyond the max unicode codepoint.
  expect(() => parseZiggyFrontmatter(`.a = "\\u{110000}",\n`, "u.smd")).toThrow(/u\.smd.*10FFFF/);
});

// --- YAML frontmatter (the gray-matter ecosystem default) -------------------

test("parseContentDocument: YAML frontmatter (key:, folded scalars, nested sequences) parses via Bun.YAML", () => {
  const doc = parseContentDocument(
    `---
section: '01'
name: Movement Screen
sub: >-
  line one
  line two
dark: true
order: 4
options:
  - label: 60 MIN
    price: 180
---

Body text.`,
    "svc.md",
  );
  expect(doc.frontmatter).toEqual({
    section: "01",
    name: "Movement Screen",
    sub: "line one line two",
    dark: true,
    order: 4,
    options: [{ label: "60 MIN", price: 180 }],
  });
  expect(doc.body).toBe("\nBody text.");
});

test("parseContentDocument: leading-dot frontmatter still parses as ziggy (incl. after // comments)", () => {
  const doc = parseContentDocument(
    `---
// a ziggy comment
.title = "Hi",
.n = 2,
---
b`,
    "z.smd",
  );
  expect(doc.frontmatter).toEqual({ title: "Hi", n: 2 });
});

test("parseContentDocument: dot-prefixed YAML keys parse as YAML, not ziggy", () => {
  // `.meta: value` is valid YAML; only the full `.ident =` shape is ziggy.
  const doc = parseContentDocument("---\n.meta: value\nplain: 1\n---\nbody", "dot.md");
  expect(doc.frontmatter).toEqual({ ".meta": "value", plain: 1 });
});

test("parseContentDocument: YAML that is not a mapping loud-fails with the file name", () => {
  expect(() => parseContentDocument("---\n- just\n- a list\n---\nb", "bad.md")).toThrow(/bad\.md.*mapping/);
});

// --- buildSiteData ---------------------------------------------------------

test("buildSiteData: glob key -> sorted entries with path/frontmatter/body; single json -> parsed value", () => {
  const { data, files } = buildSiteData(
    { services: "content/services/*.smd", hours: "content/hours.json" },
    DATA_SITE,
  );
  const services = data.services as any[];
  expect(services.map((s) => s.path)).toEqual([
    "content/services/alpha.smd",
    "content/services/beta.smd",
  ]);
  expect(services[0].frontmatter.title).toBe("Alpha Service");
  expect(services[0].frontmatter.tags).toEqual(["one", "two"]);
  expect(services[0].body).toContain("Alpha body **markdown**.");
  expect(services[1].frontmatter.extra).toEqual({ note: "nested", codes: [1, 2, 3] });
  expect(data.hours).toEqual({ mon: "9-5", sat: "closed" });
  // Every selected content file is reported (build-input tracking).
  expect(files.some((f) => f.endsWith("alpha.smd"))).toBe(true);
  expect(files.some((f) => f.endsWith("beta.smd"))).toBe(true);
  expect(files.some((f) => f.endsWith("hours.json"))).toBe(true);
});

test("buildSiteData: loud-fails on a glob with zero matches and on a missing single file", () => {
  expect(() => buildSiteData({ x: "content/nope/*.smd" }, DATA_SITE)).toThrow(/x/);
  expect(() => buildSiteData({ x: "content/missing.json" }, DATA_SITE)).toThrow(/missing\.json/);
});

test("buildSiteData: a UTF-8 BOM is stripped from json and smd content files", () => {
  const dir = mkdtempSync(join(tmpdir(), "site-data-bom-"));
  // BOM would make JSON.parse throw and would hide the `---` frontmatter fence.
  writeFileSync(join(dir, "hours.json"), "\uFEFF" + JSON.stringify({ mon: "9-5" }));
  writeFileSync(join(dir, "doc.smd"), "\uFEFF" + '---\n.title = "Bommed",\n---\n\nBody.\n');
  const { data } = buildSiteData({ hours: "hours.json", doc: "doc.smd" }, dir);
  expect(data.hours).toEqual({ mon: "9-5" });
  expect((data.doc as any).frontmatter.title).toBe("Bommed");
  expect((data.doc as any).body).toContain("Body.");
});

test("buildSiteData: loud-fails on an unsupported extension", () => {
  const dir = mkdtempSync(join(tmpdir(), "site-data-ext-"));
  writeFileSync(join(dir, "x.yaml"), "a: 1\n");
  expect(() => buildSiteData({ x: "x.yaml" }, dir)).toThrow(/x\.yaml/);
});

// --- module + d.ts sources --------------------------------------------------

test("siteDataModuleSource is a default-export JSON module", async () => {
  const src = siteDataModuleSource({ a: [1, 2], b: "x" });
  const tmp = join(mkdtempSync(join(tmpdir(), "site-data-mod-")), "m.js");
  writeFileSync(tmp, src);
  const mod = await import(tmp);
  expect(mod.default).toEqual({ a: [1, 2], b: "x" });
});

test("siteDataDts declares the @z/site-data module with structural types", () => {
  const dts = siteDataDts({ hours: { mon: "9-5" }, counts: [1, 2], flag: true, nothing: null });
  expect(dts).toContain('declare module "@z/site-data"');
  expect(dts).toContain("export default data");
  expect(dts).toContain('"mon": string');
  expect(dts).toContain("number[]");
  expect(dts).toContain("boolean");
  expect(dts).toContain("null");
});

// --- bundler integration -----------------------------------------------------

function makeDataSite(): string {
  const dir = mkdtempSync(join(tmpdir(), "site-data-bundle-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(
    join(dir, "z-runtime.config.json"),
    JSON.stringify({ data: { hours: "content/hours.json" } }),
  );
  mkdirSync(join(dir, "content"), { recursive: true });
  writeFileSync(join(dir, "content/hours.json"), JSON.stringify({ mon: "MARKER-NINE-TO-FIVE" }));
  writeFileSync(join(dir, "island.ts"), `import site from "@z/site-data";\nexport default () => site.hours.mon;\n`);
  return dir;
}

test("bundleIsland inlines @z/site-data from the config's data map and tracks content in the depfile", async () => {
  const dir = makeDataSite();
  const out = join(dir, "out.js");
  const deps = await bundleIsland({
    entry: join(dir, "island.ts"), outfile: out, depfile: join(dir, "out.d"),
    external: ["@z/runtime"], minify: false,
  });
  const js = readFileSync(out, "utf8");
  expect(js).toContain("MARKER-NINE-TO-FIVE"); // content baked in
  // The virtual module is resolved away — no import of it survives (only the
  // bundler's provenance comment may mention the name).
  expect(js).not.toMatch(/(?:from\s*|import\s*\(?\s*)"@z\/site-data"/);
  // Content edits must invalidate the bundle: content + config are build inputs.
  expect(deps.some((p) => p.endsWith("content/hours.json"))).toBe(true);
  expect(deps.some((p) => p.endsWith("z-runtime.config.json"))).toBe(true);
  // The typing surface is emitted next to the config.
  const dts = readFileSync(join(dir, "z-site-data.d.ts"), "utf8");
  expect(dts).toContain('declare module "@z/site-data"');
  expect(dts).toContain('"mon": string');
});

test("bundleIsland: importing @z/site-data WITHOUT a data config fails loudly with a pointer to the config", async () => {
  const dir = mkdtempSync(join(tmpdir(), "site-data-none-"));
  writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx" } }));
  writeFileSync(join(dir, "z-runtime.config.json"), JSON.stringify({}));
  writeFileSync(join(dir, "island.ts"), `import site from "@z/site-data";\nexport default () => site;\n`);
  let msg = "";
  try {
    await bundleIsland({
      entry: join(dir, "island.ts"), outfile: join(dir, "out.js"), depfile: join(dir, "out.d"),
      external: ["@z/runtime"], minify: false,
    });
  } catch (e) {
    // Bun.build rejects with an AggregateError; the plugin's message is inside.
    const agg = e as AggregateError;
    msg = [agg.message, ...(agg.errors ?? []).map((x: unknown) => (x instanceof Error ? x.message : String(x)))].join("\n");
  }
  expect(msg).toMatch(/"data" map/);
  expect(existsSync(join(dir, "z-site-data.d.ts"))).toBe(false); // nothing emitted
});

test("an island that never imports @z/site-data does not pick up content deps", async () => {
  const dir = makeDataSite();
  writeFileSync(join(dir, "plain.ts"), `export default () => "no data";\n`);
  const deps = await bundleIsland({
    entry: join(dir, "plain.ts"), outfile: join(dir, "plain.js"), depfile: join(dir, "plain.d"),
    external: ["@z/runtime"], minify: false,
  });
  // No over-invalidation: content files are inputs only for bundles that use them.
  expect(deps.some((p) => p.endsWith("content/hours.json"))).toBe(false);
});

// --- SSR sidecar integration --------------------------------------------------

test("render sidecar resolves @z/site-data from the site's data config", async () => {
  const proc = Bun.spawn(["bun", resolve(import.meta.dir, "../sidecar/render.ts")], {
    stdin: "pipe", stdout: "pipe", cwd: DATA_SITE,
  });
  proc.stdin.write(
    JSON.stringify({
      id: 1,
      src: resolve(DATA_SITE, "SiteData.island.tsx"),
      props: {},
      pathname: "/",
    }) + "\n",
  );
  await proc.stdin.end();
  const line = JSON.parse((await new Response(proc.stdout).text()).trim().split("\n")[0]);
  expect(line.error).toBeUndefined();
  expect(line.html).toBe("<p>Alpha Service / mon 9-5 / 2 services</p>");
});

// --- lint integration ----------------------------------------------------------

test("lint: @z/site-data is importable iff the config declares a data map", () => {
  const withData: ZRuntimeConfig = {
    islandImports: { firstParty: [], npmCompat: [] },
    data: { hours: "content/hours.json" },
  };
  const without: ZRuntimeConfig = { islandImports: { firstParty: [], npmCompat: [] } };
  expect(buildAllow(withData).some((re) => re.test("@z/site-data"))).toBe(true);
  expect(buildAllow(without).some((re) => re.test("@z/site-data"))).toBe(false);
});
