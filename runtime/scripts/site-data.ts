// @z/site-data: build-time content injection.
//
// z-runtime.config.json's `data` map selects content files/collections to
// expose ({ key: "path-or-glob" }, relative to the config's dir — the website
// root). Both build sides resolve `import site from "@z/site-data"` to a JSON
// module built from those files:
//   - the CLIENT bundler (bundle-island.ts) via a virtual-module plugin
//     (`siteDataPlugin`), which also reports the content files so they land in
//     the bundle's depfile — a content edit invalidates the bundle exactly like
//     any other build input — and emits `z-site-data.d.ts` next to the config
//     so the module is TYPED for tsc/editors;
//   - the SSR sidecar (ssr-resolve.ts) as a runtime module override, rebuilt
//     each sidecar spawn (one per build / dev rebuild), so prerendered HTML
//     always sees fresh content.
//
// Value shape per `data` key:
//   - single file (no glob magic): `.json` -> its parsed value;
//     `.smd`/`.md` -> { frontmatter, body }
//   - glob: an array sorted by path of { path, frontmatter, body } (smd/md)
//     or { path, data } (json), `path` relative to the config dir
//
// Frontmatter between the `---` fences is either a ziggy struct literal (the
// same frontmatter the SSG's content pipeline reads — detected by its leading
// `.field =`) or YAML (Bun.YAML; the gray-matter ecosystem default, so
// existing .md content dirs work without conversion). The ziggy parser below
// covers the frontmatter SUBSET of ziggy — strings (incl. `\\` multiline
// lines), numbers, bools, null, `@tag("…")` (yields the string argument),
// arrays, structs and quoted-key maps — and loud-fails with file/offset
// context on anything else.
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";

// --- ziggy frontmatter (subset) parser --------------------------------------

class ZiggyParser {
  private i = 0;
  constructor(
    private readonly src: string,
    private readonly file: string,
  ) {}

  fail(msg: string): never {
    const line = this.src.slice(0, this.i).split("\n").length;
    throw new Error(`${this.file}: frontmatter parse error at line ${line}: ${msg}`);
  }

  private skipWs(): void {
    for (;;) {
      while (this.i < this.src.length && /\s/.test(this.src[this.i])) this.i++;
      if (this.src.startsWith("//", this.i)) {
        const nl = this.src.indexOf("\n", this.i);
        this.i = nl === -1 ? this.src.length : nl + 1;
        continue;
      }
      return;
    }
  }

  private peek(): string {
    return this.src[this.i] ?? "";
  }

  private eat(ch: string): void {
    if (this.src[this.i] !== ch) this.fail(`expected '${ch}'`);
    this.i++;
  }

  private ident(): string {
    const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(this.src.slice(this.i));
    if (!m) this.fail("expected an identifier");
    this.i += m[0].length;
    return m[0];
  }

  private quotedString(): string {
    this.eat('"');
    let out = "";
    for (;;) {
      const c = this.src[this.i];
      if (c === undefined) this.fail("unterminated string");
      this.i++;
      if (c === '"') return out;
      if (c !== "\\") {
        out += c;
        continue;
      }
      const e = this.src[this.i++];
      switch (e) {
        case "n": out += "\n"; break;
        case "t": out += "\t"; break;
        case "r": out += "\r"; break;
        case '"': out += '"'; break;
        case "\\": out += "\\"; break;
        case "u": {
          // \u{...} (zig) or \uXXXX — hex format + codepoint range validated
          // here so a bad escape fails through fail() (file/line context),
          // never as a raw NaN/RangeError out of String.fromCodePoint.
          if (this.src[this.i] === "{") {
            const end = this.src.indexOf("}", this.i);
            if (end === -1) this.fail("unterminated \\u{...} escape");
            const hex = this.src.slice(this.i + 1, end);
            if (!/^[0-9a-fA-F]{1,6}$/.test(hex)) this.fail(`invalid \\u{...} escape '\\u{${hex}}'`);
            const cp = parseInt(hex, 16);
            if (cp > 0x10ffff) this.fail(`\\u{${hex}} is beyond the max unicode codepoint (10FFFF)`);
            out += String.fromCodePoint(cp);
            this.i = end + 1;
          } else {
            const hex = this.src.slice(this.i, this.i + 4);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) this.fail(`invalid \\uXXXX escape '\\u${hex}'`);
            out += String.fromCharCode(parseInt(hex, 16));
            this.i += 4;
          }
          break;
        }
        default: this.fail(`unsupported string escape '\\${e}'`);
      }
    }
  }

  /** Consecutive `\\…` lines — ziggy's multiline string literal. */
  private multilineString(): string {
    const lines: string[] = [];
    for (;;) {
      // at a line starting with \\ (skipWs already consumed leading ws)
      this.i += 2;
      const nl = this.src.indexOf("\n", this.i);
      const end = nl === -1 ? this.src.length : nl;
      lines.push(this.src.slice(this.i, end));
      this.i = nl === -1 ? this.src.length : nl + 1;
      this.skipWs();
      if (!this.src.startsWith("\\\\", this.i)) return lines.join("\n");
    }
  }

  value(): unknown {
    this.skipWs();
    const c = this.peek();
    if (c === '"') return this.quotedString();
    if (this.src.startsWith("\\\\", this.i)) return this.multilineString();
    if (c === "[") return this.array();
    if (c === "{") return this.structOrMap();
    if (c === "@") {
      // @tag("...") — e.g. @date("2024-01-01T00:00:00") — yields the string.
      this.i++;
      this.ident();
      this.skipWs();
      this.eat("(");
      this.skipWs();
      const s = this.quotedString();
      this.skipWs();
      this.eat(")");
      return s;
    }
    const num = /^[+-]?(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)/.exec(this.src.slice(this.i));
    if (num) {
      this.i += num[0].length;
      return Number(num[0].replace(/_/g, ""));
    }
    const word = /^[a-z]+/.exec(this.src.slice(this.i));
    if (word) {
      if (word[0] === "true") { this.i += 4; return true; }
      if (word[0] === "false") { this.i += 5; return false; }
      if (word[0] === "null") { this.i += 4; return null; }
    }
    this.fail(`unsupported value starting with '${c}'`);
  }

  private array(): unknown[] {
    this.eat("[");
    const out: unknown[] = [];
    for (;;) {
      this.skipWs();
      if (this.peek() === "]") { this.i++; return out; }
      out.push(this.value());
      this.skipWs();
      if (this.peek() === ",") { this.i++; continue; }
      this.skipWs();
      this.eat("]");
      return out;
    }
  }

  /** `{ .field = v, ... }` (struct) or `{ "key": v, ... }` (map). */
  private structOrMap(): Record<string, unknown> {
    this.eat("{");
    const out: Record<string, unknown> = {};
    for (;;) {
      this.skipWs();
      if (this.peek() === "}") { this.i++; return out; }
      if (this.peek() === ".") {
        this.i++;
        const name = this.ident();
        this.skipWs();
        this.eat("=");
        out[name] = this.value();
      } else if (this.peek() === '"') {
        const key = this.quotedString();
        this.skipWs();
        this.eat(":");
        out[key] = this.value();
      } else {
        this.fail("expected '.field =' or '\"key\":'");
      }
      this.skipWs();
      if (this.peek() === ",") this.i++;
    }
  }

  /** Top-level frontmatter: a brace-less struct body (`.field = value,`*). */
  topLevel(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (;;) {
      this.skipWs();
      if (this.i >= this.src.length) return out;
      this.eat(".");
      const name = this.ident();
      this.skipWs();
      this.eat("=");
      out[name] = this.value();
      this.skipWs();
      if (this.peek() === ",") this.i++;
    }
  }
}

/** Parse a ziggy frontmatter body (the text BETWEEN the `---` fences). */
export function parseZiggyFrontmatter(src: string, file: string): Record<string, unknown> {
  return new ZiggyParser(src, file).topLevel();
}

/** Parse a YAML frontmatter body via Bun's native YAML parser. */
export function parseYamlFrontmatter(src: string, file: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = Bun.YAML.parse(src);
  } catch (e) {
    throw new Error(`${file}: YAML frontmatter parse error: ${e instanceof Error ? e.message : String(e)}`);
  }
  if (value === null || value === undefined) return {};
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${file}: YAML frontmatter must be a mapping, got ${Array.isArray(value) ? "a sequence" : typeof value}`);
  }
  return value as Record<string, unknown>;
}

/**
 * Discriminate the frontmatter dialect and parse. Ziggy top-level fields start
 * with `.name =` (after whitespace / `//` comments); anything else is YAML —
 * the gray-matter ecosystem default, so an existing `.md` content dir shared
 * with other consumers (an SSG, a headless CMS) works without conversion.
 */
export function parseFrontmatter(src: string, file: string): Record<string, unknown> {
  let i = 0;
  for (;;) {
    while (i < src.length && /\s/.test(src[i])) i++;
    if (src.startsWith("//", i)) {
      const nl = src.indexOf("\n", i);
      if (nl === -1) return {};
      i = nl + 1;
      continue;
    }
    break;
  }
  // Ziggy iff the full `.ident =` field shape follows (the ident charset is
  // pinned to ZiggyParser.ident()) — a bare leading dot is NOT enough: YAML
  // keys may start with one (`.meta: value`) and must route to the YAML side.
  if (i >= src.length || /^\.[A-Za-z_][A-Za-z0-9_]*\s*=/.test(src.slice(i)))
    return parseZiggyFrontmatter(src, file);
  return parseYamlFrontmatter(src, file);
}

/** Split an .smd/.md source into { frontmatter, body } (both parsed). */
export function parseContentDocument(src: string, file: string): { frontmatter: Record<string, unknown>; body: string } {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(src);
  if (!m) return { frontmatter: {}, body: src };
  return { frontmatter: parseFrontmatter(m[1], file), body: src.slice(m[0].length) };
}

// --- data builder ------------------------------------------------------------

const GLOB_MAGIC = /[*?[\]{}]/;

function parseFile(abs: string, rel: string): { kind: "json"; value: unknown } | { kind: "doc"; value: { frontmatter: Record<string, unknown>; body: string } } {
  const ext = extname(abs).toLowerCase();
  // Strip a leading UTF-8 BOM: JSON.parse throws on it, and it would silently
  // hide the `---` frontmatter fence from the document regex.
  const text = readFileSync(abs, "utf8").replace(/^\uFEFF/, "");
  if (ext === ".json") return { kind: "json", value: JSON.parse(text) };
  if (ext === ".smd" || ext === ".md") return { kind: "doc", value: parseContentDocument(text, rel) };
  throw new Error(
    `z-runtime.config.json data: unsupported content file "${rel}" — expected .json, .smd, or .md`,
  );
}

/**
 * Build the @z/site-data payload for a `data` map. `baseDir` is the config
 * file's directory (the website root); patterns resolve relative to it.
 * Returns the data plus every selected content file (absolute, sorted) so
 * callers can register them as build inputs. Loud-fails on a missing file, an
 * empty glob, or an unsupported extension — a content-selection typo must fail
 * the build, not ship an empty array.
 */
export function buildSiteData(
  dataMap: Record<string, string>,
  baseDir: string,
): { data: Record<string, unknown>; files: string[] } {
  const data: Record<string, unknown> = {};
  const files: string[] = [];
  for (const [key, pattern] of Object.entries(dataMap)) {
    if (GLOB_MAGIC.test(pattern)) {
      const rels = [...new Bun.Glob(pattern).scanSync({ cwd: baseDir })].sort();
      if (rels.length === 0) {
        throw new Error(`z-runtime.config.json data."${key}": glob "${pattern}" matched no files under ${baseDir}`);
      }
      data[key] = rels.map((rel) => {
        const abs = resolve(baseDir, rel);
        files.push(abs);
        const parsed = parseFile(abs, rel);
        const path = rel.split(sep).join("/");
        return parsed.kind === "json" ? { path, data: parsed.value } : { path, ...parsed.value };
      });
    } else {
      const abs = resolve(baseDir, pattern);
      let parsed: ReturnType<typeof parseFile>;
      try {
        parsed = parseFile(abs, pattern);
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code === "ENOENT") {
          throw new Error(`z-runtime.config.json data."${key}": content file "${pattern}" not found under ${baseDir}`);
        }
        throw e;
      }
      files.push(abs);
      data[key] = parsed.value;
    }
  }
  return { data, files: [...new Set(files)].sort() };
}

// --- emitted sources -----------------------------------------------------------

/** The virtual module's source: one default-exported JSON object. */
export function siteDataModuleSource(data: Record<string, unknown>): string {
  return (
    "// @z/site-data — built by zigapagos from z-runtime.config.json's `data` map.\n" +
    `export default ${JSON.stringify(data, null, 2)};\n`
  );
}

function typeOf(v: unknown, indent: string): string {
  if (v === null) return "null";
  if (typeof v === "string") return "string";
  if (typeof v === "number") return "number";
  if (typeof v === "boolean") return "boolean";
  if (Array.isArray(v)) {
    const uniq = [...new Set(v.map((e) => typeOf(e, indent)))];
    if (uniq.length === 0) return "unknown[]";
    if (uniq.length === 1) return /^[A-Za-z]+$/.test(uniq[0]) ? `${uniq[0]}[]` : `Array<${uniq[0]}>`;
    return `Array<${uniq.join(" | ")}>`;
  }
  const entries = Object.entries(v as Record<string, unknown>);
  if (entries.length === 0) return "Record<string, never>";
  const inner = entries
    .map(([k, val]) => `${indent}  ${JSON.stringify(k)}: ${typeOf(val, indent + "  ")};`)
    .join("\n");
  return `{\n${inner}\n${indent}}`;
}

/** The `.d.ts` source typing the virtual module (structural, inferred from the data). */
export function siteDataDts(data: Record<string, unknown>): string {
  return (
    "// Generated by zigapagos from z-runtime.config.json's `data` map — do not edit.\n" +
    "// Regenerated whenever a bundle that imports @z/site-data is built.\n" +
    'declare module "@z/site-data" {\n' +
    `  const data: ${typeOf(data, "  ")};\n` +
    "  export default data;\n" +
    "}\n"
  );
}

export const SITE_DATA_DTS_NAME = "z-site-data.d.ts";

/**
 * Write `z-site-data.d.ts` next to the config (atomically, and only when the
 * content changed — several island bundles may build concurrently).
 */
export function emitSiteDataDts(configDir: string, data: Record<string, unknown>): string {
  const dts = siteDataDts(data);
  const out = join(configDir, SITE_DATA_DTS_NAME);
  try {
    if (readFileSync(out, "utf8") === dts) return out;
  } catch {
    /* absent: write below */
  }
  const tmp = join(configDir, `.${SITE_DATA_DTS_NAME}.${process.pid}.tmp`);
  writeFileSync(tmp, dts);
  renameSync(tmp, out);
  return out;
}

// --- Bun.build plugin -------------------------------------------------------------

/**
 * Bun.build plugin resolving `@z/site-data` to the built JSON module. The data
 * is built lazily on first use; the selected content files are appended to
 * `files` so the caller can add them to the bundle's depfile (and the d.ts is
 * emitted) ONLY when the bundle actually imports the module — no
 * over-invalidation of bundles that don't use site data. With no `data` config,
 * importing the module fails loudly with a pointer to the config.
 */
export function siteDataPlugin(
  dataMap: Record<string, string>,
  baseDir: string,
  files?: Set<string>,
): import("bun").BunPlugin {
  return {
    name: "z-site-data",
    setup(build) {
      build.onResolve({ filter: /^@z\/site-data$/ }, (args) => {
        if (Object.keys(dataMap).length === 0) {
          throw new Error(
            `@z/site-data imported by ${args.importer}, but z-runtime.config.json declares no "data" map ` +
              `(add e.g. { "data": { "services": "content/services/*.smd" } } at the website root)`,
          );
        }
        return { path: "@z/site-data", namespace: "z-site-data" };
      });
      build.onLoad({ filter: /.*/, namespace: "z-site-data" }, () => {
        const { data, files: used } = buildSiteData(dataMap, baseDir);
        for (const f of used) files?.add(f);
        emitSiteDataDts(baseDir, data);
        return { contents: siteDataModuleSource(data), loader: "js" };
      });
    },
  };
}
