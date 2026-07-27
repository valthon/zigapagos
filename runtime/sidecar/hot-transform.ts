// ---------------------------------------------------------------------------
// Dev-only fast-refresh transform for island ENTRY modules.
//
// The island hot-swap re-imports the edited module and re-renders it in
// place; because a fresh import's `default` is a NEW function reference, Preact
// tears the old subtree down and plain `useState`/`useReducer` state resets.
// This transform rewrites an island entry so its top-level function components
// are routed through @z/runtime's hot registry (src/hot-registry.ts): the
// exported value becomes a STABLE proxy whose implementation is swapped in
// place when the re-imported component's build-time hook signature matches, so
// Preact keeps the mounted component instance (and its hook state) alive.
//
// CORRECTNESS OVER CLEVERNESS — everything here errs toward NOT preserving:
//   - a component whose hook sequence can't be fully proven (a custom hook
//     imported from another file, a `X.useY()` property call, an unknown
//     identifier that merely looks like a hook) is never wrapped, so a swap
//     remounts it (exactly the plain hot-swap behavior);
//   - a hook-sequence CHANGE between two builds changes the signature, so the
//     registry mints a new identity and Preact remounts — a swap can never
//     replay old hook state against a different hook order;
//   - anonymous/expression default exports, class components, async/generator
//     functions, and anything structurally unexpected are left untouched;
//   - when nothing can be safely wrapped the source is returned UNCHANGED.
//
// The transform is applied ONLY by bundle-island.ts under its dev-only `hot`
// flag — release bundles never contain it (byte-parity gate).
// ---------------------------------------------------------------------------

// PINS TYPESCRIPT BELOW 7.0 — see the same note in scripts/slice-host.ts. TS 7.0
// dropped the JavaScript compiler API, so `ts.ScriptKind` / `ts.createSourceFile`
// and the `ts.is*` predicates below are all `undefined` there. The ceiling is
// enforced in .github/dependabot.yml, which carries the evidence.
//
// bundle-island.ts imports this module dynamically behind a try/catch, but do NOT
// read that as cover for a missing API. The catch guards RESOLUTION — `typescript`
// absent from node_modules, the case its message names — and under TS 7 the
// package resolves perfectly well; only its API is gone. So the import SUCCEEDS,
// `hotTransform` is installed, and the TypeError instead lands where the transform
// is called, inside a `Bun.build` onLoad plugin, which fails the build. Measured
// on 7.0.2 that surfaces as a `bundle 500` from the sidecar, not the graceful
// degradation to a full remount that the fallback path is designed for.
import ts from "typescript";

/** Callee names that look like hooks (rules-of-hooks naming convention). */
const HOOK_RE = /^use[A-Z0-9_]/;
const COMPONENT_RE = /^[A-Z]/;

/** Where a top-level local name came from, for hook-origin proofs. */
interface ImportOrigin {
  specifier: string;
  /** The ORIGINAL exported name (aliasing normalized away), "default" or "*". */
  importedName: string;
}

interface TopFn {
  name: string;
  fn: ts.FunctionLikeDeclaration;
  stmt: ts.Statement;
  kind: "func" | "var";
}

interface ModuleInfo {
  sf: ts.SourceFile;
  imports: Map<string, ImportOrigin>;
  /** Top-level `useXxx` function/arrow declarations (same-file custom hooks). */
  localHooks: Map<string, ts.FunctionLikeDeclaration>;
  /** Top-level capitalized function/arrow declarations that render (JSX or hooks). */
  components: TopFn[];
}

function parse(source: string, fileName: string): ts.SourceFile {
  const kind = fileName.endsWith(".ts") ? ts.ScriptKind.TS : ts.ScriptKind.TSX;
  return ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, /*setParentNodes*/ true, kind);
}

function importOrigins(sf: ts.SourceFile): Map<string, ImportOrigin> {
  const map = new Map<string, ImportOrigin>();
  for (const st of sf.statements) {
    if (!ts.isImportDeclaration(st) || !st.importClause) continue;
    if (!ts.isStringLiteral(st.moduleSpecifier)) continue;
    const specifier = st.moduleSpecifier.text;
    const clause = st.importClause;
    if (clause.name) map.set(clause.name.text, { specifier, importedName: "default" });
    const nb = clause.namedBindings;
    if (nb && ts.isNamespaceImport(nb)) map.set(nb.name.text, { specifier, importedName: "*" });
    if (nb && ts.isNamedImports(nb)) {
      for (const el of nb.elements) {
        map.set(el.name.text, { specifier, importedName: (el.propertyName ?? el.name).text });
      }
    }
  }
  return map;
}

function hasModifier(st: ts.Node, kind: ts.SyntaxKind): boolean {
  const mods = ts.canHaveModifiers(st) ? ts.getModifiers(st) : undefined;
  return !!mods?.some((m) => m.kind === kind);
}

/** Plain (non-async, non-generator) function-like — the only shape we swap. */
function plainFunction(fn: ts.FunctionLikeDeclaration): boolean {
  if (fn.asteriskToken) return false;
  if (hasModifier(fn, ts.SyntaxKind.AsyncKeyword)) return false;
  return true;
}

function containsJsx(node: ts.Node): boolean {
  if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node) || ts.isJsxFragment(node)) return true;
  return ts.forEachChild(node, containsJsx) === true;
}

/** True when `callee` (an identifier) is hook-shaped by name or by import origin. */
function looksLikeHook(name: string, origin: ImportOrigin | undefined): boolean {
  if (HOOK_RE.test(name)) return true;
  return !!origin && origin.importedName !== "*" && HOOK_RE.test(origin.importedName);
}

/** Add every identifier bound by a binding name/pattern to `out`. */
function collectBoundNames(name: ts.BindingName, out: Set<string>): void {
  if (ts.isIdentifier(name)) {
    out.add(name.text);
    return;
  }
  // Array/object destructuring pattern — recurse into its elements.
  for (const el of name.elements) {
    if (ts.isBindingElement(el)) collectBoundNames(el.name, out);
  }
}

/**
 * Names that a function `fn` binds in its OWN scope: its parameters plus the
 * top-level declarations (var/let/const/function/class) of its body. When one
 * of these shadows an imported hook name, `info.imports` no longer describes the
 * real callee at that scope, so the hook-origin proof must fail closed.
 */
function shadowedNames(fn: ts.FunctionLikeDeclaration): Set<string> {
  const out = new Set<string>();
  for (const p of fn.parameters) collectBoundNames(p.name, out);
  const body = fn.body;
  if (body && ts.isBlock(body)) {
    for (const st of body.statements) {
      if (ts.isVariableStatement(st)) {
        for (const d of st.declarationList.declarations) collectBoundNames(d.name, out);
      } else if (ts.isFunctionDeclaration(st) && st.name) {
        out.add(st.name.text);
      } else if (ts.isClassDeclaration(st) && st.name) {
        out.add(st.name.text);
      }
    }
  }
  return out;
}

function hasHookCall(node: ts.Node, imports: Map<string, ImportOrigin>): boolean {
  let found = false;
  const visit = (n: ts.Node): void => {
    if (found) return;
    if (ts.isCallExpression(n)) {
      const callee = n.expression;
      if (ts.isIdentifier(callee) && looksLikeHook(callee.text, imports.get(callee.text))) {
        found = true;
        return;
      }
      if (ts.isPropertyAccessExpression(callee) && HOOK_RE.test(callee.name.text)) {
        found = true;
        return;
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(node);
  return found;
}

function collectTopFns(sf: ts.SourceFile): TopFn[] {
  const out: TopFn[] = [];
  for (const st of sf.statements) {
    if (ts.isFunctionDeclaration(st)) {
      if (!st.name || !st.body || !plainFunction(st)) continue;
      if (hasModifier(st, ts.SyntaxKind.DeclareKeyword)) continue;
      out.push({ name: st.name.text, fn: st, stmt: st, kind: "func" });
      continue;
    }
    if (ts.isVariableStatement(st)) {
      if (hasModifier(st, ts.SyntaxKind.DeclareKeyword)) continue;
      for (const decl of st.declarationList.declarations) {
        if (!ts.isIdentifier(decl.name) || !decl.initializer) continue;
        const init = decl.initializer;
        if (!ts.isArrowFunction(init) && !ts.isFunctionExpression(init)) continue;
        if (!plainFunction(init)) continue;
        out.push({ name: decl.name.text, fn: init, stmt: st, kind: "var" });
      }
    }
  }
  return out;
}

function moduleInfo(source: string, fileName: string): ModuleInfo {
  const sf = parse(source, fileName);
  const imports = importOrigins(sf);
  const topFns = collectTopFns(sf);
  const localHooks = new Map<string, ts.FunctionLikeDeclaration>();
  for (const f of topFns) if (HOOK_RE.test(f.name)) localHooks.set(f.name, f.fn);
  const components = topFns.filter(
    (f) =>
      COMPONENT_RE.test(f.name) &&
      f.fn.body !== undefined &&
      (containsJsx(f.fn.body) || hasHookCall(f.fn.body, imports)),
  );
  return { sf, imports, localHooks, components };
}

/** A node that opens a DIFFERENT hook scope: hook calls inside it belong to
 *  that nested function/class (a nested component, a render prop, an effect
 *  callback, a class method), never to the enclosing component. */
function isScopeBoundary(n: ts.Node): boolean {
  return ts.isFunctionLike(n) || ts.isClassLike(n);
}

/**
 * The build-time hook signature of one function: every hook-shaped call whose
 * NEAREST ENCLOSING FUNCTION is this one, in source order. Returns null the
 * moment ANY hook call's origin can't be proven (imported from outside
 * @z/runtime, property access, unknown name, namespace import, recursion
 * between local hooks) — null means "never preserve state across this
 * component" and the caller must not wrap it.
 *
 * Nested scopes are NOT flattened in (react-refresh/prefresh sign per function
 * scope): a hook-shaped call inside a nested function/class — e.g. a nested
 * component `const Inner = () => { useState(...) }` — makes the whole
 * component unprovable (null). Flattening would let two builds with different
 * REAL hook orders share one signature, and a preserving swap would then
 * replay old hook state against a different hook order — the exact corrupt
 * swap this transform must never perform.
 */
function computeSignature(
  fn: ts.FunctionLikeDeclaration,
  info: ModuleInfo,
  visiting: Set<string>,
): string | null {
  const tokens: string[] = [];
  let bad = false;
  // Names this function binds in its own scope (params + top-level body decls).
  // A hook-shaped call to one of these is NOT the imported/module hook it looks
  // like — the local binding shadows it — so its origin is unprovable.
  const shadowed = shadowedNames(fn);
  const visit = (n: ts.Node): void => {
    if (bad) return;
    if (isScopeBoundary(n)) {
      // Never descend for tokens; fail closed if the nested scope contains
      // anything hook-shaped (nested components/custom hooks/illegal calls).
      if (hasHookCall(n, info.imports)) bad = true;
      return;
    }
    if (ts.isCallExpression(n)) {
      const callee = n.expression;
      if (ts.isIdentifier(callee)) {
        const origin = info.imports.get(callee.text);
        if (looksLikeHook(callee.text, origin)) {
          if (shadowed.has(callee.text)) {
            // A local declaration/parameter shadows this hook name: the call
            // resolves to that binding, not the import/module hook, and its
            // internal hook usage is invisible here. Fail closed.
            bad = true;
            return;
          }
          if (origin) {
            const fromRuntime =
              origin.specifier === "@z/runtime" || origin.specifier.startsWith("@z/runtime/");
            if (fromRuntime && origin.importedName !== "*" && origin.importedName !== "default") {
              // Runtime hooks are stable across an island edit (the runtime is a
              // separate external bundle) — the ORIGINAL name is the token, so
              // `import { useState as uS }` and `import { useState }` agree.
              tokens.push(origin.importedName);
            } else {
              bad = true; // hook from anywhere else: origin unprovable
              return;
            }
          } else {
            const local = info.localHooks.get(callee.text);
            if (local) {
              if (visiting.has(callee.text)) { bad = true; return; } // cycle
              visiting.add(callee.text);
              const inner = computeSignature(local, info, visiting);
              visiting.delete(callee.text);
              if (inner === null) { bad = true; return; }
              // Inline the local hook's own sequence: editing the hook's INTERNAL
              // hooks must change every caller's signature (=> remount).
              tokens.push(callee.text + "{" + inner + "}");
            } else {
              bad = true; // hook-shaped call with no known declaration
              return;
            }
          }
          // Token recorded — STILL visit the arguments: a callback argument is
          // a nested scope whose own hook-shaped calls must fail the signature.
          ts.forEachChild(n, visit);
          return;
        }
      } else if (ts.isPropertyAccessExpression(callee) && HOOK_RE.test(callee.name.text)) {
        bad = true; // `X.useY()` — origin unprovable
        return;
      }
    }
    ts.forEachChild(n, visit);
  };
  if (fn.body) visit(fn.body);
  return bad ? null : tokens.join(",");
}

/**
 * Exposed for tests: the hook signature of every top-level component in the
 * module (null = not preservable — the transform will not wrap it).
 */
export function hookSignaturesFor(source: string, fileName: string): Map<string, string | null> {
  const info = moduleInfo(source, fileName);
  const out = new Map<string, string | null>();
  for (const c of info.components) out.set(c.name, computeSignature(c.fn, info, new Set()));
  return out;
}

interface Edit { start: number; end: number; text: string }

/**
 * Rewrite an island ENTRY module so its top-level function components route
 * through @z/runtime's hot registry. Returns `source` unchanged
 * when nothing can be safely transformed (=> the plain remount fallback).
 */
export function transformIslandForHot(source: string, fileName: string, moduleKey: string): string {
  let info: ModuleInfo;
  try {
    info = moduleInfo(source, fileName);
  } catch {
    return source; // unparseable => let the bundler report it untransformed
  }

  // Wrappable = component whose full hook sequence is provable at build time.
  const wrapped: { name: string; signature: string; top: TopFn }[] = [];
  for (const c of info.components) {
    const sig = computeSignature(c.fn, info, new Set());
    if (sig !== null) wrapped.push({ name: c.name, signature: sig, top: c });
  }
  if (wrapped.length === 0) return source;
  const wrappedNames = new Set(wrapped.map((w) => w.name));

  const sf = info.sf;
  const edits: Edit[] = [];
  let defaultName: string | null = null;

  for (const st of sf.statements) {
    // `export default function Name(...)` — strip `export default`, keep the
    // (named) declaration; the footer re-exports the registered proxy.
    if (
      ts.isFunctionDeclaration(st) &&
      st.name &&
      wrappedNames.has(st.name.text) &&
      hasModifier(st, ts.SyntaxKind.DefaultKeyword)
    ) {
      const mods = ts.getModifiers(st)!;
      const exportMod = mods.find((m) => m.kind === ts.SyntaxKind.ExportKeyword)!;
      const defaultMod = mods.find((m) => m.kind === ts.SyntaxKind.DefaultKeyword)!;
      edits.push({ start: exportMod.getStart(sf), end: defaultMod.end, text: "" });
      defaultName = st.name.text;
      continue;
    }
    // `export default Name;` where Name is wrapped — drop it; the footer
    // re-exports the proxy AFTER the registration line runs.
    if (
      ts.isExportAssignment(st) &&
      !st.isExportEquals &&
      ts.isIdentifier(st.expression) &&
      wrappedNames.has(st.expression.text)
    ) {
      edits.push({ start: st.getStart(sf), end: st.end, text: "" });
      defaultName = st.expression.text;
      continue;
    }
    // `const Name = () => …` — reassignable binding needed for the footer swap.
    if (ts.isVariableStatement(st) && (st.declarationList.flags & ts.NodeFlags.Const) !== 0) {
      const hasWrapped = st.declarationList.declarations.some(
        (d) => ts.isIdentifier(d.name) && wrappedNames.has(d.name.text),
      );
      if (hasWrapped) {
        const start = st.declarationList.getStart(sf);
        edits.push({ start, end: start + "const".length, text: "var" });
      }
    }
  }

  // Apply edits in DESCENDING start order so earlier offsets stay valid.
  edits.sort((a, b) => b.start - a.start);
  let out = source;
  for (const e of edits) out = out.slice(0, e.start) + e.text + out.slice(e.end);

  // Footer: register every wrapped component (import declarations hoist, so a
  // trailing import is fine), then re-export the default through its proxy.
  const lines: string[] = [
    "",
    ';import { __zHotRegister as __zigapagos_hot_register } from "@z/runtime";',
  ];
  for (const w of wrapped) {
    lines.push(
      `${w.name} = __zigapagos_hot_register(${w.name}, ${JSON.stringify(moduleKey)}, ${JSON.stringify(w.name)}, ${JSON.stringify(w.signature)});`,
    );
  }
  if (defaultName) lines.push(`export default ${defaultName};`);
  return out + lines.join("\n") + "\n";
}
