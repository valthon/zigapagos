// Per-SITE islands runtime slicer — the ANALYSIS half.
//
// Every page carrying an island loads the full shared /zigapagos-runtime.js,
// which is the whole barrel: router, feature flags, the API client, the
// observability relay, the error relay, and the entire preact/compat React
// surface. A page whose one island is a 433-byte counter therefore ships ~58 KB
// of runtime it never calls (#52). Per-deployable slicing already exists for
// SPAs (slice-host.ts + build-spa-runtime.ts); islands never got it.
//
// This module answers one question per island: *which named `@z/runtime`
// exports does this island actually ask for?* — and does it by parsing the
// island's BUILT BUNDLE rather than its source. The bundle is the exact,
// already-resolved statement of what the browser will request:
//
//   Hero.island.js    import{useState as r}from"@z/runtime"
//                     import{jsx as e,jsxs as c}from"@z/runtime/jsx-runtime"
//   Widget.island.js  import{useState as o}from"react"
//
// `Widget.island.tsx`'s SOURCE imports `@demo/widget`; only the bundle reveals
// that the npm-React bridge is reached transitively. Analysing sources would
// slice that page and then crash it in the browser, because its import map's
// `react` entry would point at a runtime with no React surface. That is the one
// failure mode here that is a production crash rather than a size regression,
// and it is why this file reads bundles.
//
// SAFE-FALLBACK is the safety model, exactly as in slice-host.ts: any construct
// the analysis cannot prove complete bails THAT ISLAND to the shared runtime,
// and a page is only sliced when EVERY island on it was proved. Over-include,
// never under-include.
//
// CAPS TYPESCRIPT BELOW 7.0 — same reason as slice-host.ts: 6.x is the final
// JavaScript-based compiler line and carries the full compiler API; 7.0 is the
// Go rewrite, where `import ts from "typescript"` resolves to lib/version.cjs
// and yields only `{version, versionMajorMinor}`, making every `ts.*` call here
// a TypeError. The cap lives in .github/dependabot.yml with the evidence.
import ts from "typescript";

/**
 * The four names the JSX transform injects. A slice ALWAYS exports these: a
 * .tsx island's `import { jsx } from "@z/runtime/jsx-runtime"` is written by
 * the bundler, not by the author, and the page import map points
 * `@z/runtime/jsx-dev-runtime` at the same file.
 */
export const JSX_NAMES = ["jsx", "jsxs", "jsxDEV", "Fragment"] as const;

/** The two specifiers the JSX transform may emit. */
const JSX_SPECIFIERS = new Set(["@z/runtime/jsx-runtime", "@z/runtime/jsx-dev-runtime"]);

/**
 * Bare specifiers that force an island to bail. The generated slice entry
 * carries NO compat/React surface, so a page whose import map pointed
 * `@z/runtime/compat` (or `react`) at a slice would get `undefined` at load —
 * a real production crash. This is slice-host.ts's COMPAT_REACT_SPECIFIERS
 * reasoning, verbatim; the `@z/runtime/*` subpaths are covered more broadly by
 * the "any other @z/runtime subpath" rule in `analyzeIslandBundles`.
 */
const REACT_SPECIFIERS = new Set([
  "react", "react-dom", "react-dom/client",
  "react/jsx-runtime", "react/jsx-dev-runtime",
]);

export interface IslandBundle {
  /** Bundle basename with `.js` stripped, e.g. "Hero.island". The join key the
   *  manifest publishes and src/islands/pass.zig matches a page's islands on. */
  name: string;
  code: string;
}

export interface Verdict {
  /** Island names provably served by a slice, in input order. */
  sliceable: string[];
  /** Union of named `@z/runtime` imports across `sliceable`, sorted. Never
   *  contains a JSX_NAMES member: those are exported unconditionally from
   *  jsx-runtime.ts, and re-exporting one name twice is a hard Bun.build
   *  error. */
  exports: string[];
  /** name -> human reason, for the build log. Diagnostics only. */
  bailed: Record<string, string>;
}

/**
 * The exported VALUE names of runtime/src/index.ts (type-only exports excluded).
 *
 * This is what replaces a hand-maintained `export -> defining module` table: the
 * generated entry re-exports every name from `index.ts`, and an island asking
 * for a name index.ts does not export bails to the shared runtime instead of
 * producing a slice that fails to build (or, worse, one that builds and is
 * missing the name). It cannot go stale, because it is derived from the barrel
 * itself on every build.
 */
export function runtimeExportNames(indexSource: string): Set<string> {
  const names = new Set<string>();
  const sf = ts.createSourceFile("index.ts", indexSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  for (const stmt of sf.statements) {
    if (!ts.isExportDeclaration(stmt)) continue;
    if (stmt.isTypeOnly) continue; // `export type { … }`
    const clause = stmt.exportClause;
    if (!clause || !ts.isNamedExports(clause)) continue; // `export * from …` names nothing
    for (const el of clause.elements) {
      if (el.isTypeOnly) continue; // `export { type X }`
      // The EXPORTED name (`export { a as b }` -> "b") is what an island imports.
      names.add(el.name.text);
    }
  }
  return names;
}

/** True for a specifier the bundler should have resolved away (relative or
 *  absolute). Anything else surviving in a bundle is an unresolved external. */
function isLocalSpecifier(spec: string): boolean {
  return spec.startsWith(".") || spec.startsWith("/");
}

/**
 * Per-island verdicts from the BUILT bundles.
 *
 * Conservative by construction: an island is `sliceable` only when every import
 * in its bundle was fully understood. Every bail reason is recorded so the build
 * log can say which island cost the site its slice.
 */
export function analyzeIslandBundles(
  bundles: IslandBundle[],
  runtimeExports: Set<string>,
): Verdict {
  const sliceable: string[] = [];
  const bailed: Record<string, string> = {};
  const exports = new Set<string>();

  for (const b of bundles) {
    const perIsland = new Set<string>();
    const reason = analyzeOne(b, runtimeExports, perIsland);
    if (reason) {
      bailed[b.name] = reason;
      continue;
    }
    sliceable.push(b.name);
    for (const n of perIsland) exports.add(n);
  }

  return { sliceable, exports: [...exports].sort(), bailed };
}

/** @returns null when the island is sliceable (and `out` holds its named
 *  `@z/runtime` imports), else the human-readable bail reason. */
function analyzeOne(b: IslandBundle, runtimeExports: Set<string>, out: Set<string>): string | null {
  const sf = ts.createSourceFile(b.name, b.code, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);

  let bail: string | null = null;
  const fail = (why: string) => { bail ??= why; };

  for (const stmt of sf.statements) {
    if (bail) break;

    if (ts.isImportDeclaration(stmt)) {
      if (!ts.isStringLiteral(stmt.moduleSpecifier)) {
        fail("non-literal import specifier");
        break;
      }
      const spec = stmt.moduleSpecifier.text;
      const clause = stmt.importClause;
      // `import "x"` — side-effect only; still subject to the specifier rules.
      if (!checkSpecifier(spec, fail)) break;
      if (!clause) continue;
      if (clause.name) { fail(`default import from "${spec}"`); break; }
      const bindings = clause.namedBindings;
      if (!bindings) continue;
      if (ts.isNamespaceImport(bindings)) {
        // `import * as z from "@z/runtime"` — the used members are not
        // enumerable from the import, so nothing can be proved about them.
        fail(`namespace import from "${spec}"`);
        break;
      }
      for (const el of bindings.elements) {
        // The IMPORTED symbol, not the local alias: `import{useState as r}`
        // must record `useState`.
        const imported = (el.propertyName ?? el.name).text;
        if (JSX_SPECIFIERS.has(spec)) {
          if (!(JSX_NAMES as readonly string[]).includes(imported)) {
            fail(`imports "${imported}" from "${spec}", which only exports ${JSX_NAMES.join("/")}`);
            break;
          }
          continue; // JSX names are exported unconditionally; not part of the union.
        }
        if (spec !== "@z/runtime") continue; // local specifier: nothing to record
        if ((JSX_NAMES as readonly string[]).includes(imported)) {
          // Would be re-exported from BOTH jsx-runtime.ts and index.ts in the
          // generated entry, which is a hard Bun.build error. Vanishingly rare
          // (the transform emits these from the jsx-runtime specifier); bailing
          // is safe and keeps the entry generator free of dedupe special cases.
          fail(`imports the JSX name "${imported}" from the bare "@z/runtime" specifier`);
          break;
        }
        if (!runtimeExports.has(imported)) {
          // Drift/typo safety: the generated entry re-exports from index.ts, so
          // a name index.ts does not export could not be served by a slice.
          fail(`imports "${imported}", which runtime/src/index.ts does not export`);
          break;
        }
        out.add(imported);
      }
      continue;
    }

    if (ts.isExportDeclaration(stmt)) {
      // `export … from "…"` / `export * from "…"`: a re-export re-publishes a
      // module's surface, which the slice cannot enumerate or guarantee.
      if (stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
        const spec = stmt.moduleSpecifier.text;
        if (!isLocalSpecifier(spec)) {
          fail(`re-exports from "${spec}"`);
          break;
        }
      }
    }
  }

  if (bail) return bail;

  // A dynamic `import(...)` anywhere in the bundle — literal or computed —
  // pulls in a module graph this static walk never saw.
  const dyn = findDynamicImport(sf);
  if (dyn) return dyn;

  return null;
}

/** Apply the per-specifier bail rules. @returns false when the island bailed. */
function checkSpecifier(spec: string, fail: (why: string) => void): boolean {
  if (isLocalSpecifier(spec)) return true;
  if (spec === "@z/runtime" || JSX_SPECIFIERS.has(spec)) return true;
  if (REACT_SPECIFIERS.has(spec)) {
    // The npm-React bridge: this specifier resolves, via the page import map, to
    // the full preact/compat surface the slice does not carry.
    fail(`imports "${spec}"`);
    return false;
  }
  if (spec.startsWith("@z/runtime/")) {
    // @z/runtime/compat, /compat/client, /host, … — same story: the slice entry
    // exports the barrel + JSX names and nothing else.
    fail(`imports the runtime subpath "${spec}"`);
    return false;
  }
  // A bundled island should have no other bare specifier left. One that does is
  // an unresolved external nothing here can reason about.
  fail(`imports the unresolved bare specifier "${spec}"`);
  return false;
}

/** @returns a bail reason when the bundle contains any dynamic `import()`. */
function findDynamicImport(sf: ts.SourceFile): string | null {
  let found: string | null = null;
  const visit = (node: ts.Node): void => {
    if (found) return;
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      const arg = node.arguments[0];
      found = arg && ts.isStringLiteral(arg)
        ? `contains a dynamic import("${arg.text}")`
        : "contains a computed dynamic import()";
      return;
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  return found;
}

/**
 * The generated slice-entry source. Import specifiers are ABSOLUTE paths so the
 * generated file can live in a build cache dir and still resolve the real
 * modules.
 *
 * The `import "<islands.ts>"` line is UNCONDITIONAL: it is the side effect that
 * discovers `[data-z-island]` roots and hydrates them. A site whose islands only
 * use JSX would otherwise ship a runtime that does nothing at all.
 *
 * `Fragment` is exported from BOTH core.ts (via index.ts) and jsx-runtime.ts —
 * the same Preact object. It is taken from jsx-runtime.ts and never emitted in
 * the index.ts list: two explicit re-exports of one name is a hard Bun.build
 * error. (browser-entry.ts gets away with the overlap only because its first
 * line is `export *`, which loses to an explicit re-export.)
 */
export function generateIslandsEntry(
  exports: string[],
  opts: { islandsModule: string; indexModule: string; jsxModule: string },
): string {
  const named = [...new Set(exports)]
    .filter((n) => !(JSX_NAMES as readonly string[]).includes(n))
    .sort();
  const lines = [
    "// GENERATED by runtime/scripts/build-islands-runtime.ts — do not edit.",
    "// The per-site sliced islands runtime: islands.ts's hydration auto-init, the",
    `// JSX-transform names, and the ${named.length} @z/runtime export(s) this site's islands use.`,
    `import ${JSON.stringify(opts.islandsModule)};`,
    `export { ${JSX_NAMES.join(", ")} } from ${JSON.stringify(opts.jsxModule)};`,
  ];
  if (named.length > 0) {
    lines.push(`export { ${named.join(", ")} } from ${JSON.stringify(opts.indexModule)};`);
  }
  lines.push("");
  return lines.join("\n");
}
