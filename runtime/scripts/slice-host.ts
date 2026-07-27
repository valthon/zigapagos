// Per-deployable host slicer.
//
// Given a SPA's transitive source files, statically determine WHICH `host.*`
// members that SPA actually uses, so a per-SPA runtime bundle can be assembled
// from ONLY those members (the bundler DCEs the rest). See build-spa-runtime.ts
// (the build driver) + build.zig for how the result is turned into a sliced
// /spa/<name>-runtime.js and threaded into that SPA's shell import-map.
//
// SAFE-FALLBACK is the whole safety model: the analysis is CONSERVATIVE. It
// records a member only for an unambiguous `host.<member>` property access, and
// returns `null` (⇒ the SPA falls back to the FULL shared runtime — worst case =
// today's behavior) the moment it sees ANY usage it cannot prove complete:
//   - a computed access `host[expr]` (the member name isn't statically known),
//   - an alias `const h = host` / destructure `const { x } = host`,
//   - a spread `{ ...host }` or shorthand `{ host }`,
//   - `host` passed as an argument / returned / assigned as a value,
//   - a namespace import (`import * as z from "@z/runtime"`) whose `z.host` is used.
// Over-include, NEVER under-include: a runtime missing a member the SPA calls at
// runtime is a crash, so every uncertain construct widens to the full runtime.
//
// CAPS TYPESCRIPT BELOW 7.0. This import is one of the two reasons the runtime's
// `typescript` devDependency is capped at `^6.0.3` (the other is
// sidecar/hot-transform.ts). 6.x is the final JavaScript-based line and carries
// the full compiler API; 7.0 is the Go rewrite and dropped it, so there
// `import ts from "typescript"` resolves to lib/version.cjs and yields only
// `{version, versionMajorMinor}`, making every `ts.*` call below a TypeError.
// The cap is enforced in .github/dependabot.yml, which carries the evidence and
// the unblock condition.
import ts from "typescript";

/** All 18 host members, in the source order of the `host` literal in host.ts. */
export const HOST_MEMBERS = [
  "store", "fetchShared", "reportError", "pathname", "search", "hash", "cookies", "now",
  "localDateParts", "onScroll", "onResize", "matchMedia", "enhance",
  "loadScript", "getValue", "recaptchaToken", "fetchOpts", "portal",
] as const;
export type HostMember = (typeof HOST_MEMBERS)[number];

// Members the ALWAYS-bundled core runtime modules access on `host` (router →
// reportError; flags → fetchShared, store; api → cookies). The sliced host MUST
// include these regardless of what the SPA source uses, or an internal
// `host.<member>` call would hit `undefined` at runtime and crash. A drift guard
// (slice-host.test.ts) asserts the core modules never grow a host member beyond
// this set without it being added here.
export const BASELINE_MEMBERS: readonly HostMember[] = [
  "store", "fetchShared", "reportError", "cookies",
];

/** Module specifiers that expose the runtime `host` binding to a SPA. */
const HOST_SPECIFIERS = new Set(["@z/runtime", "@z/runtime/host"]);

// Specifiers whose (value) import forces the SAFE-FALLBACK. A sliced runtime is
// built from spa-entry.ts, which OMITS the preact/compat + React surface — so a
// SPA that imports @z/runtime/compat(/client) or a bare react/react-dom specifier
// (the npm-React bridge) NEEDS that surface and must use the full shared
// runtime (whose import-map targets DO export it). Without this the SPA would be
// sliced and its `react`/`compat` import-map entries would resolve to a runtime
// missing those exports ⇒ `undefined` at load ⇒ a real prod crash.
const COMPAT_REACT_SPECIFIERS = new Set([
  "@z/runtime/compat", "@z/runtime/compat/client",
  "react", "react-dom", "react-dom/client",
  "react/jsx-runtime", "react/jsx-dev-runtime",
]);

export interface Source { path: string; code: string; }

function scriptKind(path: string): ts.ScriptKind {
  if (path.endsWith(".tsx")) return ts.ScriptKind.TSX;
  if (path.endsWith(".jsx")) return ts.ScriptKind.JSX;
  if (path.endsWith(".js") || path.endsWith(".mjs")) return ts.ScriptKind.JS;
  return ts.ScriptKind.TS;
}

/**
 * Analyze a SPA's transitive sources for `host.<member>` usage.
 * @returns the used-member set (always a superset of BASELINE_MEMBERS) for a
 *   fully-understood SPA, or `null` to signal the loud SAFE-FALLBACK (any
 *   dynamic/uncertain host usage ⇒ use the full shared runtime).
 */
export function analyzeHostUsage(sources: Source[]): Set<HostMember> | null {
  const used = new Set<HostMember>(BASELINE_MEMBERS);

  for (const src of sources) {
    const sf = ts.createSourceFile(
      src.path, src.code, ts.ScriptTarget.Latest, /*setParentNodes*/ true, scriptKind(src.path),
    );

    // A (value) import of the preact/compat or React surface ⇒ this SPA needs the
    // full shared runtime; fall back regardless of its host usage.
    if (importsCompatOrReact(sf)) return null;

    // Local names bound to the runtime `host` (named import) + namespace locals.
    const hostLocals = new Set<string>();
    const nsLocals = new Set<string>();
    collectImports(sf, hostLocals, nsLocals);
    if (hostLocals.size === 0 && nsLocals.size === 0) continue;

    let bail = false;
    const visit = (node: ts.Node): void => {
      if (bail) return;
      // `NS.host` where NS is a namespace import of @z/runtime — conservatively
      // fall back (we don't slice through a namespace access chain).
      if (
        ts.isPropertyAccessExpression(node) &&
        ts.isIdentifier(node.expression) && nsLocals.has(node.expression.text) &&
        node.name.text === "host"
      ) {
        bail = true;
        return;
      }
      if (ts.isIdentifier(node) && hostLocals.has(node.text)) {
        const verdict = classifyHostRef(node);
        if (verdict === "bail") { bail = true; return; }
        if (verdict !== "skip") used.add(verdict);
        // "skip" = not a value reference to the host binding (import specifier,
        // `x.host` accessor name, object key, declaration name) — ignore it.
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
    if (bail) return null;
  }
  return used;
}

/** True when the file has a VALUE import/re-export of a compat/react specifier
 *  (a type-only `import type … from "react"` is erased and does not need the
 *  runtime surface, so it does NOT force the fallback). */
function importsCompatOrReact(sf: ts.SourceFile): boolean {
  for (const stmt of sf.statements) {
    let spec: ts.Expression | undefined;
    let typeOnly = false;
    if (ts.isImportDeclaration(stmt)) {
      spec = stmt.moduleSpecifier;
      typeOnly = stmt.importClause?.isTypeOnly ?? false;
    } else if (ts.isExportDeclaration(stmt)) {
      spec = stmt.moduleSpecifier;
      typeOnly = stmt.isTypeOnly;
    }
    if (spec && ts.isStringLiteral(spec) && !typeOnly && COMPAT_REACT_SPECIFIERS.has(spec.text)) {
      return true;
    }
  }
  return false;
}

/** Populate host named-import locals + @z/runtime namespace-import locals. */
function collectImports(sf: ts.SourceFile, hostLocals: Set<string>, nsLocals: Set<string>): void {
  for (const stmt of sf.statements) {
    if (!ts.isImportDeclaration(stmt) || !ts.isStringLiteral(stmt.moduleSpecifier)) continue;
    const spec = stmt.moduleSpecifier.text;
    const clause = stmt.importClause;
    if (!clause || !clause.namedBindings) continue;
    if (ts.isNamespaceImport(clause.namedBindings)) {
      // EVERY host-exposing specifier counts, not just the bare "@z/runtime":
      // `import * as H from "@z/runtime/host"` exposes `H.host` just as much, and
      // missing it would UNDER-slice (the `NS.host` bail below would never fire).
      if (HOST_SPECIFIERS.has(spec)) nsLocals.add(clause.namedBindings.name.text);
      continue;
    }
    if (!HOST_SPECIFIERS.has(spec)) continue;
    if (ts.isNamedImports(clause.namedBindings)) {
      for (const el of clause.namedBindings.elements) {
        // `{ host }` → propertyName undefined, name "host"; `{ host as h }` →
        // propertyName "host", name "h". The imported symbol is propertyName ?? name.
        const imported = (el.propertyName ?? el.name).text;
        if (imported === "host") hostLocals.add(el.name.text);
      }
    }
  }
}

/**
 * Classify one Identifier that matches a host local binding:
 *   - `"skip"`        — not a value reference to the binding (accessor name of
 *                       `x.host`, an import specifier, an object-literal key, or
 *                       a declaration name).
 *   - a HostMember    — an unambiguous `host.<member>` access; record it.
 *   - `"bail"`        — a computed access or any use of `host` as a value ⇒
 *                       trigger the safe fallback.
 */
function classifyHostRef(node: ts.Identifier): HostMember | "skip" | "bail" {
  const p = node.parent;
  if (ts.isPropertyAccessExpression(p)) {
    if (p.name === node) return "skip";                 // `x.host` — host is the accessor name
    if (p.expression === node) {                         // `host.member`
      const m = p.name.text;
      return (HOST_MEMBERS as readonly string[]).includes(m) ? (m as HostMember) : "skip";
    }
  }
  if (ts.isElementAccessExpression(p) && p.expression === node) return "bail"; // `host[expr]`
  if (ts.isImportSpecifier(p) || ts.isImportClause(p) || ts.isNamespaceImport(p)) return "skip";
  if (ts.isPropertyAssignment(p) && p.name === node) return "skip";            // `{ host: … }` key
  if (
    (ts.isVariableDeclaration(p) || ts.isBindingElement(p) || ts.isParameter(p) ||
      ts.isFunctionDeclaration(p) || ts.isClassDeclaration(p)) &&
    (p as { name?: ts.Node }).name === node
  ) return "skip";                                                             // a declaration name
  // Anything else is `host` used AS A VALUE (alias, argument, spread/shorthand,
  // return, assignment, …) — the sliced object could leak, so fall back.
  return "bail";
}

// Members host.ts assigns from an ssr-env.ts function under a DIFFERENT name
// (`pathname: currentPathname`, `search: currentSearch`, `hash: currentHash`)
// rather than re-exporting its own binding of that name — so a sliced host must
// import these from ssrEnvModule under their real name, never from hostModule.
const SSR_ENV_MEMBERS: Partial<Record<HostMember, string>> = {
  pathname: "currentPathname", search: "currentSearch", hash: "currentHash",
};

/**
 * Emit the source of the generated sliced-host module: it imports ONLY the used
 * member functions from the real host.ts and assembles a `host` object with just
 * those members. Members in SSR_ENV_MEMBERS map to their ssr-env.ts function.
 * Member order follows HOST_MEMBERS so output is deterministic. `hostModule` /
 * `ssrEnvModule` are import specifiers (typically ABSOLUTE paths so the generated
 * file can live outside src/ while still resolving the real modules — the build
 * alias redirects only the RELATIVE `./host.ts` imports of the runtime's own
 * modules, never these).
 */
export function generateSlicedHost(
  used: Set<HostMember>,
  opts: { hostModule: string; ssrEnvModule: string; name?: string },
): string {
  const members = HOST_MEMBERS.filter((m) => used.has(m));
  const ssrEnvUsed = members.filter((m) => m in SSR_ENV_MEMBERS);
  const named = members.filter((m) => !(m in SSR_ENV_MEMBERS));

  const lines: string[] = [];
  lines.push(`// GENERATED by runtime/scripts/slice-host.ts${opts.name ? ` for SPA '${opts.name}'` : ""} — do not edit.`);
  lines.push(`// The per-SPA sliced host: only the ${members.length} member(s) this SPA uses.`);
  if (named.length > 0) {
    lines.push(`import { ${named.join(", ")} } from ${JSON.stringify(opts.hostModule)};`);
  }
  if (ssrEnvUsed.length > 0) {
    lines.push(`import { ${ssrEnvUsed.map((m) => SSR_ENV_MEMBERS[m]).join(", ")} } from ${JSON.stringify(opts.ssrEnvModule)};`);
  }
  lines.push(`export const host = {`);
  for (const m of members) {
    lines.push(m in SSR_ENV_MEMBERS ? `  ${m}: ${SSR_ENV_MEMBERS[m]},` : `  ${m},`);
  }
  lines.push(`};`);
  lines.push("");
  return lines.join("\n");
}
