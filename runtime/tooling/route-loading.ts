#!/usr/bin/env bun
/** Checkout-only static JS/CSS closure estimates. Never executes application code. */
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { resolve, join, relative, sep } from "node:path";
import { gzipSync, brotliCompressSync, constants } from "node:zlib";
import { Window } from "happy-dom";
import ts from "typescript";

type Kind = "js" | "css";
type Edge = { from: string; specifier: string; mode: "initial" | "lazy"; target: string | null };
type Unknown = { from: string; specifier?: string; reason: string };
type Bytes = { raw: number; gzip: number; brotli: number };
type Node = { path: string; kind: Kind; module: boolean; bytes: Bytes; eager: string[]; lazy: string[] };
type ImportMap = { imports?: Record<string, unknown>; scopes?: Record<string, Record<string, unknown>> };
const origin = "https://zigapagos.invalid";
const maxFileBytes = 16 * 1024 * 1024;
const maxNodes = 10000;
const jsTypes = new Set(["", "module", "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript", "application/x-ecmascript", "application/x-javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript"]);
function size(source: Buffer): Bytes {
  return { raw: source.length, gzip: gzipSync(source, { level: 9 }).length, brotli: brotliCompressSync(source, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length };
}
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }

/** Parsing only: all CSS references are externalized, so Bun never reads or
 * fetches dependencies. Its CSS parser handles escapes, comments and @import. */
async function cssImports(source: string): Promise<{ imports: string[]; problems: string[] }> {
  const imports: string[] = [];
  try {
    const built = await Bun.build({ entrypoints: ["graph.css"], plugins: [{ name: "css-edges", setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (args.kind === "entry-point-build") return { path: args.path, namespace: "graph" };
        if (args.kind === "import-rule") imports.push(args.path);
        return { path: args.path, external: true };
      });
      build.onLoad({ filter: /.*/, namespace: "graph" }, () => ({ contents: source, loader: "css" }));
    } }] });
    return { imports, problems: built.logs.map((log) => log.message) };
  } catch (error) { return { imports, problems: [String(error)] }; }
}

export async function measureRoute(root: string, page: string, prefix = "") {
  root = realpathSync(root);
  if (!page || page.startsWith("/") || page.split(/[\\/]/).some((p) => p === ".." || p === "." || !p) || page.includes("\\")) throw new Error("page must be an emitted path inside the output directory");
  if (prefix.includes("\\") || /[?#%\u0000-\u0020]/.test(prefix) || prefix.split("/").some((p) => p === "." || p === "..")) throw new Error("prefix must be a plain deployment path, such as /project");
  prefix = "/" + prefix.split("/").filter(Boolean).join("/");
  if (prefix === "/") prefix = "";
  const pageURL = new URL(prefix + "/" + page.split("/").map(encodeURIComponent).join("/"), origin);
  const unknowns: Unknown[] = [], edges: Edge[] = [];
  const nodes = new Map<string, Node>();
  const initialRoots: string[] = [], lazyRoots: string[] = [];
  const inline = { js: 0, css: 0 };
  let map: ImportMap = {};
  function unknown(from: string, reason: string, specifier?: string) { unknowns.push({ from, reason, ...(specifier === undefined ? {} : { specifier }) }); }
  function read(path: string): Buffer {
    let current = root;
    for (const part of path.split("/")) {
      current = join(current, part);
      if (lstatSync(current).isSymbolicLink()) throw new Error("symlink target is unsupported");
    }
    const stat = lstatSync(current);
    if (!stat.isFile()) throw new Error("target is not a regular file");
    if (stat.size > maxFileBytes) throw new Error("file exceeds 16 MiB analysis limit");
    return readFileSync(current);
  }
  function local(url: URL): string {
    if (url.origin !== origin) throw new Error("external resource is not measured");
    if (!url.pathname.startsWith(prefix + "/")) throw new Error("resource is outside deployment prefix");
    const path = url.pathname.slice(prefix.length + 1).split("/").map((part) => {
      const decoded = decodeURIComponent(part);
      if (/[\\/\u0000-\u001f\u007f]/.test(decoded) || decoded === "." || decoded === "..") throw new Error("unsupported URL path encoding");
      return decoded;
    }).join("/");
    if (!path || path.endsWith("/")) throw new Error("resource needs an exact file path; host rewrites are not modeled");
    const canonical = path.split("/").filter(Boolean).join("/");
    const rel = relative(root, resolve(root, canonical));
    if (rel.startsWith(".." + sep) || rel === ".." || resolve(root, canonical) === root) throw new Error("resource leaves output directory");
    return canonical;
  }
  function urlLike(specifier: string) { return specifier.startsWith("/") || specifier.startsWith("./") || specifier.startsWith("../") || /^[a-zA-Z][a-zA-Z\d+.-]*:/.test(specifier); }
  // Conservative coverage validation includes unused malformed entries. Null
  // is a supported blocking entry; valid external addresses are not fetched.
  function validateMap(value: ImportMap) {
    const tables: [string, Record<string, unknown>][] = [["imports", value.imports ?? {}]];
    for (const [scope, table] of Object.entries(value.scopes ?? {})) {
      try { new URL(scope, pageURL); }
      catch { unknown(page, "invalid import-map scope URL", scope); }
      tables.push(["scope " + scope, table]);
    }
    for (const [name, table] of tables) for (const [key, address] of Object.entries(table)) {
      try {
        if (!key) throw new Error("empty specifier key");
        if (urlLike(key)) new URL(key, pageURL);
        if (address === null) continue;
        if (typeof address !== "string" || !urlLike(address)) throw new Error("address must be URL-like or a null blocker");
        const url = new URL(address, pageURL);
        if (key.endsWith("/") && !url.href.endsWith("/")) throw new Error("prefix address must end in slash");
      } catch (error) { unknown(page, "invalid import-map entry in " + name + ": " + String(error), key); }
    }
  }
  function mapped(specifier: string, importer: URL): URL {
    const normalized = urlLike(specifier) ? new URL(specifier, importer).href : specifier;
    const tables = Object.entries(map.scopes ?? {}).map(([scope, table]) => [new URL(scope, pageURL).href, table] as const)
      .filter(([scope]) => importer.href === scope || (scope.endsWith("/") && importer.href.startsWith(scope)))
      .sort(([a], [b]) => b.length - a.length).map(([, table]) => table);
    tables.push(map.imports ?? {});
    for (const table of tables) {
      const entries = Object.entries(table).map(([key, value]) => [urlLike(key) ? new URL(key, pageURL).href : key, value] as const)
        .filter(([key]) => key === normalized || (key.endsWith("/") && normalized.startsWith(key))).sort(([a], [b]) => b.length - a.length);
      if (!entries.length) continue;
      const [key, value] = entries[0]!;
      if (typeof value !== "string" || !urlLike(value)) throw new Error("blocked or unsupported import-map address");
      const target = new URL(value, pageURL);
      if (key.endsWith("/")) {
        if (!target.href.endsWith("/")) throw new Error("import-map prefix target must end in slash");
        const expanded = new URL(normalized.slice(key.length), target);
        if (!expanded.href.startsWith(target.href)) throw new Error("import-map prefix backtracking is unsupported");
        return expanded;
      }
      return target;
    }
    if (!urlLike(specifier)) throw new Error("unmapped bare module specifier");
    return new URL(specifier, importer);
  }
  async function reference(from: string, base: URL, specifier: string, mode: "initial" | "lazy", kind: Kind, module = false, syntaxModule = true): Promise<string | null> {
    const edge: Edge = { from, specifier, mode, target: null }; edges.push(edge);
    try {
      if (/[\\\u0000-\u001f\u007f]/.test(specifier)) throw new Error("unsupported URL characters");
      const url = module ? mapped(specifier, base) : new URL(specifier, base);
      const path = local(url);
      if (url.pathname.includes("//")) unknown(from, "repeated-slash URL resolution is unsupported; physical file counted once", specifier);
      if (kind === "js" && Object.keys(map.scopes ?? {}).length && (url.search || url.hash)) unknown(from, "query/fragment module identity with import-map scopes is unsupported", specifier);
      await visit(path, kind, syntaxModule);
      edge.target = path;
      return path;
    } catch (error) { unknown(from, String(error), specifier); return null; }
  }
  async function scanJS(source: string, from: string, base: URL, eager: string[], lazy: string[], module: boolean) {
    const file = ts.createSourceFile(from, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    const diagnostics = (file as ts.SourceFile & { parseDiagnostics: readonly ts.Diagnostic[] }).parseDiagnostics;
    if (diagnostics.length) unknown(from, "JavaScript syntax could not be fully parsed");
    const imports: { specifier: string; lazy: boolean }[] = [];
    function walk(node: ts.Node): void {
      if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier) {
        if (!module) unknown(from, "module syntax in a classic script");
        if (node.attributes) unknown(from, "module import attributes are outside JS/CSS graph coverage");
        if (ts.isStringLiteral(node.moduleSpecifier)) imports.push({ specifier: node.moduleSpecifier.text, lazy: false });
      } else if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
        if (node.arguments.length > 1) unknown(from, "dynamic import options/attributes are outside JS/CSS graph coverage");
        const arg = node.arguments[0];
        if (arg && (ts.isStringLiteral(arg) || ts.isNoSubstitutionTemplateLiteral(arg))) imports.push({ specifier: arg.text, lazy: true });
        else unknown(from, "computed dynamic import has unknown dependencies");
      } else if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "require") unknown(from, "CommonJS require is outside the module graph");
      ts.forEachChild(node, walk);
    }
    walk(file);
    for (const item of imports) {
      const target = await reference(from, base, item.specifier, item.lazy ? "lazy" : "initial", "js", true);
      if (target) (item.lazy ? lazy : eager).push(target);
    }
  }
  async function scanCSS(source: string, from: string, base: URL, eager: string[]) {
    const scan = await cssImports(source);
    for (const problem of scan.problems) unknown(from, "CSS parser: " + problem);
    for (const specifier of scan.imports) {
      const target = await reference(from, base, specifier, "initial", "css");
      if (target) eager.push(target);
    }
  }
  async function visit(path: string, kind: Kind, module: boolean) {
    const prior = nodes.get(path);
    if (prior) { if (prior.kind !== kind || (kind === "js" && prior.module !== module)) unknown(path, "file referenced with conflicting script/style modes"); return; }
    if (nodes.size >= maxNodes) throw new Error("graph exceeds 10000-file analysis limit");
    const content = read(path);
    const node: Node = { path, kind, module, bytes: size(content), eager: [], lazy: [] };
    nodes.set(path, node); // Before recursion: static and dynamic cycles are safe.
    const base = new URL(prefix + "/" + path.split("/").map(encodeURIComponent).join("/"), origin);
    if (kind === "js") await scanJS(content.toString("utf8"), path, base, node.eager, node.lazy, module);
    else await scanCSS(content.toString("utf8"), path, base, node.eager);
  }
  const html = read(page);
  const window = new Window({ url: pageURL.href, settings: { disableJavaScriptEvaluation: true, disableJavaScriptFileLoading: true, disableCSSFileLoading: true, disableIframePageLoading: true } });
  try {
    const document = new window.DOMParser().parseFromString(html.toString("utf8"), "text/html");
    if (document.querySelector("svg,math")) unknown(page, "non-HTML SVG/MathML content is outside parser graph coverage");
    if (document.querySelector("base[href]")) unknown(page, "base href is unsupported; relative references use the supplied page path");
    let seenMap = false, seenModule = false;
    for (const element of document.querySelectorAll("script,link,style,[data-z-module]")) {
      // With scripting enabled, noscript content is inert; template contents
      // are never roots until application code instantiates them.
      if (element.closest("template,noscript")) continue;
      if (element.namespaceURI !== "http://www.w3.org/1999/xhtml") { unknown(page, "non-HTML script/style references are unsupported"); continue; }
      const tag = element.tagName.toLowerCase();
      const type = (element.getAttribute("type") ?? "").trim().toLowerCase();
      const language = (element.getAttribute("language") ?? "").trim().toLowerCase();
      if (tag === "script" && !type && language && !jsTypes.has("text/" + language)) { unknown(page, "unsupported legacy script language"); continue; }
      if (tag === "script" && type === "importmap") {
        if (element.hasAttribute("src")) unknown(page, "external import maps are unsupported");
        if (seenMap || seenModule) { unknown(page, "multiple or late import maps are unsupported"); continue; }
        seenMap = true;
        try {
          const value: unknown = JSON.parse(element.textContent);
          if (!isRecord(value) || (value.imports !== undefined && !isRecord(value.imports)) || (value.scopes !== undefined && (!isRecord(value.scopes) || Object.values(value.scopes).some((v) => !isRecord(v))))) throw new Error("invalid import-map structure");
          if (Object.keys(value).some((key) => !["imports", "scopes"].includes(key))) unknown(page, "unsupported import-map fields");
          map = value as ImportMap;
          validateMap(map);
        } catch (error) { unknown(page, "import-map parse: " + String(error)); }
        continue;
      }
      if (tag === "script" && jsTypes.has(type)) {
        seenModule ||= type === "module";
        const src = element.getAttribute("src");
        if (src !== null) { const target = await reference(page, pageURL, src, "initial", "js", false, type === "module"); if (target) initialRoots.push(target); }
        else { inline.js += Buffer.byteLength(element.textContent); await scanJS(element.textContent, page + "#inline-script", pageURL, initialRoots, lazyRoots, type === "module"); }
      } else if (tag === "style" && (!type || type === "text/css")) {
        inline.css += Buffer.byteLength(element.textContent); await scanCSS(element.textContent, page + "#inline-style", pageURL, initialRoots);
      } else if (tag === "link") {
        const rel = (element.getAttribute("rel") ?? "").toLowerCase().split(/\s+/);
        const href = element.getAttribute("href");
        const preload = rel.includes("preload") && ["script", "style"].includes((element.getAttribute("as") ?? "").toLowerCase());
        if (href !== null && (rel.includes("stylesheet") || rel.includes("modulepreload") || preload)) {
          seenModule ||= rel.includes("modulepreload");
          const kind = rel.includes("stylesheet") || (preload && element.getAttribute("as")?.toLowerCase() === "style") ? "css" : "js";
          const target = await reference(page, pageURL, href, "initial", kind, false, rel.includes("modulepreload"));
          if (target) initialRoots.push(target);
        }
      }
      const island = element.getAttribute("data-z-module");
      if (island !== null) { const target = await reference(page, pageURL, island, "lazy", "js"); if (target) lazyRoots.push(target); }
    }
  } finally { await window.happyDOM.close(); }
  function closure(roots: string[]): Set<string> {
    const seen = new Set<string>(), pending = [...roots];
    while (pending.length) { const path = pending.pop()!; if (seen.has(path) || !nodes.has(path)) continue; seen.add(path); pending.push(...nodes.get(path)!.eager); }
    return seen;
  }
  const initial = closure(initialRoots);
  const allLazy = [...new Set([...lazyRoots, ...[...nodes.values()].flatMap((node) => node.lazy)])].sort();
  const lazyOnly = new Set([...nodes.keys()].filter((path) => !initial.has(path)));
  function group(files: Set<string>) {
    const total = { raw: 0, gzip: 0, brotli: 0 };
    for (const path of files) { const bytes = nodes.get(path)!.bytes; total.raw += bytes.raw; total.gzip += bytes.gzip; total.brotli += bytes.brotli; }
    return { files: [...files].sort(), bytes: total };
  }
  return {
    schema: 1, page, url_prefix: prefix, metric: "static_js_css_closure_estimate", coverage_complete: unknowns.length === 0,
    browser_loading_complete: false, lazy_classification: "potential dynamic/deferred candidates, not proof of loading after interaction", compression: "per-file gzip level 9 / Brotli quality 11; estimates, not HTTP transfer bytes",
    deduplication: "normalized physical output path; query and fragment aliases count once",
    html: size(html), inline_body_bytes_in_html: inline,
    initial: group(initial), lazy_only: group(lazyOnly),
    lazy_entries: allLazy.map((entry) => ({ entry, ...group(new Set([...closure([entry])].filter((path) => !initial.has(path)))) })),
    resources: [...nodes.values()].sort((a, b) => a.path.localeCompare(b.path)).map(({ path, kind, bytes }) => ({ path, kind, bytes })),
    edges, unknowns,
  };
}

if (import.meta.main) {
  try {
    const args = process.argv.slice(2);
    if (args.includes("--help")) {
      console.log("Usage: bun runtime/tooling/route-loading.ts OUTPUT --page=index.html [--url-prefix=/project] [--strict]\nCheckout-only static JS/CSS graph report as JSON. --strict fails on unknown coverage.");
    } else {
      const output = args.shift();
      if (!output || output.startsWith("--")) throw new Error("an output directory is required");
      let page = "", prefix = "", strict = false;
      for (const arg of args) {
        if (arg.startsWith("--page=")) page = arg.slice(7);
        else if (arg.startsWith("--url-prefix=")) prefix = arg.slice(13);
        else if (arg === "--strict") strict = true;
        else throw new Error("unknown argument: " + arg);
      }
      const report = await measureRoute(output, page, prefix);
      console.log(JSON.stringify(report, null, 2));
      if (strict && !report.coverage_complete) process.exitCode = 1;
    }
  } catch (error) { console.error("route-loading: " + String(error)); process.exitCode = 1; }
}
