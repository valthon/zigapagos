import type { BunPlugin } from "bun";
import { dirname, resolve } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, renameSync, rmSync, readdirSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { buildAllow } from "../scripts/lint-island-imports.ts";
import { effectiveResolveMap, type ZRuntimeConfig } from "../scripts/z-runtime-config.ts";

const digest = (value: string) => createHash("sha256").update(value).digest("hex");
let transformerIdentity: string | undefined;
const MAX_CACHE_ENTRIES = 128;
const MAX_CACHE_BYTES = 32 * 1024 * 1024;

// Evict oldest writes only after a miss; warm builds never scan or touch entries.
function pruneSourceCache(directory: string): void {
  const entries = readdirSync(directory).filter(name => /^[a-f0-9]{64}\.json$/.test(name)).flatMap(name => {
    const path = resolve(directory, name);
    try {
      const stat = statSync(path);
      return stat.isFile() ? [{path, size: stat.size, modified: stat.mtimeMs}] : [];
    } catch (error: any) {
      if (error.code === "ENOENT") return []; // Another bundler may have evicted it.
      throw error;
    }
  }).sort((a, b) => a.modified - b.modified || a.path.localeCompare(b.path));
  let bytes = entries.reduce((sum, entry) => sum + entry.size, 0);
  let count = entries.length;
  for (const entry of entries) {
    if (count <= MAX_CACHE_ENTRIES && bytes <= MAX_CACHE_BYTES) break;
    rmSync(entry.path, {force: true});
    count--;
    bytes -= entry.size;
  }
}

/** Remove route enumeration and the module bindings used exclusively by it.
 * Symbol references, rather than identifier spelling, keep shadowed names safe.
 * The compiler is loaded only for modules containing staticPaths on a cache miss. */
export async function stripStaticPaths(source: string, file: string, cacheDir?: string): Promise<string> {
  if (!source.includes("staticPaths")) return source;
  if (!cacheDir) return stripStaticPathsUncached(source, file);
  // The CLI starts new bundler processes on each rebuild. Keep this cache on
  // disk, outside its disposable bundle directory. Invalidate for source,
  // parser, Bun or transform changes, without loading the TypeScript compiler.
  try {
    const require = createRequire(import.meta.url);
    transformerIdentity ??= digest(readFileSync(import.meta.path, "utf8") +
      readFileSync(require.resolve("typescript/package.json"), "utf8") + Bun.version);
  } catch {
    // Cache metadata is optional. Let the compiler load below either succeed or
    // explain how to repair a missing runtime dependency.
    return stripStaticPathsUncached(source, file);
  }
  const key = digest(JSON.stringify([transformerIdentity, file, source]));
  const cachePath = resolve(cacheDir, key + ".json");
  try {
    const cached = JSON.parse(readFileSync(cachePath, "utf8"));
    if (cached && typeof cached.code === "string" && cached.digest === digest(cached.code)) return cached.code;
  } catch { /* Missing, corrupt or inaccessible cache entries are misses. */ }
  // Transform failures remain fatal. Only optional cache I/O is best-effort.
  const code = await stripStaticPathsUncached(source, file);
  try {
    const entry = JSON.stringify({code, digest: digest(code)});
    if (Buffer.byteLength(entry) > MAX_CACHE_BYTES) return code;
    mkdirSync(cacheDir, {recursive: true});
    const temporary = cachePath + "." + randomUUID() + ".tmp";
    try {
      writeFileSync(temporary, entry, {flag: "wx"});
      renameSync(temporary, cachePath);
    } finally { rmSync(temporary, {force: true}); }
    pruneSourceCache(cacheDir);
  } catch { /* Cleanup races or unavailable storage cannot invalidate code. */ }
  return code;
}

async function stripStaticPathsUncached(source: string, file: string): Promise<string> {
  let ts: typeof import("typescript");
  try { ts = await import("typescript"); }
  catch { throw new Error(`${file}: separating staticPaths requires typescript in the runtime installation; run bun install in the Zigapagos runtime directory`); }
  const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true,
    /\.tsx$/.test(file) ? ts.ScriptKind.TSX : /\.(?:js|jsx)$/.test(file) ? ts.ScriptKind.JSX : ts.ScriptKind.TS);
  const host = ts.createCompilerHost({ noResolve: true, noLib: true });
  host.getSourceFile = (name) => name === file ? sf : undefined;
  const checker = ts.createProgram([file], { noResolve: true, noLib: true }, host).getTypeChecker();
  const removed = new Set<import("typescript").Node>();
  const propertyKey = (name?: import("typescript").PropertyName): string | undefined => {
    if (!name) return;
    if (ts.isIdentifier(name) || ts.isStringLiteral(name)) return name.text;
    if (ts.isComputedPropertyName(name) && ts.isStringLiteral(name.expression)) return name.expression.text;
  };
  const find = (node: import("typescript").Node) => {
    if ((ts.isPropertyAccessExpression(node) && node.name.text === "staticPaths") ||
        (ts.isElementAccessExpression(node) && ts.isStringLiteral(node.argumentExpression) && node.argumentExpression.text === "staticPaths")) {
      throw new Error(`${file}: staticPaths must be declared directly in the route object, not read or assigned through a route reference`);
    }
    if (ts.isObjectLiteralExpression(node)) {
      const keys = node.properties.map(p => propertyKey(p.name));
      if (keys.includes("path") && node.properties.some(p => p.name && ts.isComputedPropertyName(p.name) && propertyKey(p.name) === undefined)) {
        throw new Error(`${file}: computed route keys cannot separate staticPaths safely; use explicit property names`);
      }
      if (keys.includes("staticPaths")) {
        if (!keys.includes("path") || node.properties.some(p => ts.isSpreadAssignment(p))) {
          throw new Error(`${file}: staticPaths must be an explicit property of a route object with path; spread route definitions cannot separate build-only data safely`);
        }
        for (const p of node.properties) {
          if (propertyKey(p.name) === "staticPaths") removed.add(p);
        }
      }
    }
    ts.forEachChild(node, find);
  };
  find(sf);
  if (!removed.size) return source;

  type Node = import("typescript").Node;
  type Symbol = import("typescript").Symbol;
  const candidates = new Map<Symbol, Node>();
  const exported = new Set<Node>();
  const bind = (name: import("typescript").BindingName, node: Node) => {
    if (ts.isIdentifier(name)) {
      const symbol = checker.getSymbolAtLocation(name);
      if (symbol) candidates.set(symbol, node);
    } else for (const e of name.elements) if (ts.isBindingElement(e)) bind(e.name, node);
  };
  for (const statement of sf.statements) {
    const isExport = ts.canHaveModifiers(statement) && ts.getModifiers(statement)?.some(m => m.kind === ts.SyntaxKind.ExportKeyword);
    if (ts.isVariableStatement(statement)) for (const d of statement.declarationList.declarations) {
      bind(d.name, d);
      if (isExport) exported.add(d);
    }
    else if ((ts.isFunctionDeclaration(statement) || ts.isClassDeclaration(statement)) && statement.name) {
      bind(statement.name, statement);
      if (isExport) exported.add(statement);
    } else if (ts.isImportDeclaration(statement) && statement.importClause) {
      const clause = statement.importClause;
      if (clause.name) bind(clause.name, clause.name);
      if (clause.namedBindings) {
        if (ts.isNamespaceImport(clause.namedBindings)) bind(clause.namedBindings.name, clause.namedBindings);
        else for (const e of clause.namedBindings.elements) bind(e.name, e);
      }
    }
  }
  const nodes = new Set(candidates.values());
  const references = (node: Node, skipCandidates = false): Set<Node> => {
    const refs = new Set<Node>();
    const visit = (n: Node) => {
      if ((n !== node && removed.has(n)) || (skipCandidates && nodes.has(n))) return;
      if (ts.isIdentifier(n)) {
        const symbol = ts.isExportSpecifier(n.parent)
          ? checker.getExportSpecifierLocalTargetSymbol(n.parent)
          : ts.isShorthandPropertyAssignment(n.parent)
            ? checker.getShorthandAssignmentValueSymbol(n.parent) : checker.getSymbolAtLocation(n);
        const declaration = symbol && candidates.get(symbol);
        if (declaration) refs.add(declaration);
      }
      ts.forEachChild(n, visit);
    };
    visit(node);
    return refs;
  };
  const expand = (set: Set<Node>) => {
    for (const node of set) for (const dep of references(node)) set.add(dep);
  };
  // The removed properties' references seed the build-only dependency closure.
  const buildOnly = new Set<Node>();
  for (const property of removed) for (const ref of references(property)) buildOnly.add(ref);
  expand(buildOnly);
  // Declarations outside the build-only closure remain in the module, even
  // when not exported. Their initializers can have client-side effects and
  // must keep all referenced bindings valid.
  const live = new Set<Node>([...exported, ...references(sf, true), ...[...nodes].filter(n => !buildOnly.has(n))]);
  expand(live);
  for (const node of buildOnly) if (!live.has(node)) removed.add(node);
  const result = ts.transform(sf, [context => root => {
    const visit = (node: Node): Node | undefined => {
      if (removed.has(node)) return undefined;
      const updated = ts.visitEachChild(node, visit, context);
      if (ts.isVariableStatement(updated) && !updated.declarationList.declarations.length) return undefined;
      if (ts.isImportDeclaration(updated) && node !== updated && updated.importClause) {
        const clause = updated.importClause;
        if (!clause.name && (!clause.namedBindings || (ts.isNamedImports(clause.namedBindings) && !clause.namedBindings.elements.length))) return undefined;
      }
      return updated;
    };
    return ts.visitNode(root, visit) as import("typescript").SourceFile;
  }]);
  try { return ts.createPrinter().printFile(result.transformed[0]); }
  finally { result.dispose(); }
}

/** Every application module, including local transitive imports, crosses this
 * boundary before resolution. Approved package internals and the framework's
 * own runtime are trusted; application aliases still undergo this check. */
export function clientSourcePlugin(config: ZRuntimeConfig, spa: boolean, captured: Set<string>,
  hot?: (src: string, file: string, key: string) => string, entry?: string, sourceCacheDir?: string): BunPlugin {
  const runtime = resolve(dirname(import.meta.path), "../src") + "/";
  const allow = buildAllow(config);
  const aliases = effectiveResolveMap(config);
  return {
    name: "application-client-source",
    setup(build) {
      build.onLoad({ filter: /\.[cm]?[jt]sx?$/ }, async args => {
        captured.add(args.path);
        if (args.path.includes("/node_modules/") || args.path.startsWith(runtime)) return undefined;
        const original = await Bun.file(args.path).text();
        let source = original;
        if (spa) source = await stripStaticPaths(source, args.path, sourceCacheDir);
        const loader = args.path.endsWith("tsx") ? "tsx" : /\.(?:js|jsx)$/.test(args.path) ? "jsx" : /\.[cm]?ts$/.test(args.path) ? "ts" : "js";
        const imports = new Bun.Transpiler({ loader }).scanImports(source);
        for (const { path } of imports) {
          if (!allow.some(re => re.test(path)) && !(path in aliases)) {
            if (path === "@z/site-data") throw new Error(`${args.path}: @z/site-data requires a "data" map in z-runtime.config.json`);
            throw new Error(`forbidden import in ${args.path}: ${path}; configure islandImports.firstParty, islandImports.npmCompat, or resolve in z-runtime.config.json`);
          }
        }
        if (hot && args.path === entry) source = hot(source, args.path, entry);
        if (source === original) return undefined;
        return { contents: source, loader };
      });
    },
  };
}
