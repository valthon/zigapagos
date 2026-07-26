import { canonicalize, type NormalizeOptions, type IslandProps } from "./normalize.ts";
import type { SNode } from "../../src/testing/parity/serialize.ts";

export interface StructuralMismatch {
  path: string;
  kind: "text" | "attribute" | "structure" | "missing" | "extra";
  expected: string;
  actual: string;
}
export interface PropMismatch { component: string; key: string; expected: unknown; actual: unknown }
export interface RouteResult {
  route: string; ok: boolean;
  structural: StructuralMismatch[]; props: PropMismatch[]; domDiff: string;
}

function describe(n: SNode): string { return n.type === "text" ? "#text" : n.tag; }

export function diffNodes(expected: SNode[], actual: SNode[], path = ""): StructuralMismatch[] {
  const out: StructuralMismatch[] = [];
  const max = Math.max(expected.length, actual.length);
  for (let i = 0; i < max; i++) {
    const a = expected[i], b = actual[i];
    const here = `${path}${path ? " > " : ""}${describe(a ?? b)}:nth(${i})`;
    if (a && !b) { out.push({ path: here, kind: "missing", expected: describe(a), actual: "" }); continue; }
    if (!a && b) { out.push({ path: here, kind: "extra", expected: "", actual: describe(b) }); continue; }
    if (a.type !== b.type) { out.push({ path: here, kind: "structure", expected: describe(a), actual: describe(b) }); continue; }
    if (a.type === "text" && b.type === "text") {
      if (a.text !== b.text) out.push({ path: here, kind: "text", expected: a.text, actual: b.text });
      continue;
    }
    if (a.type === "element" && b.type === "element") {
      if (a.tag !== b.tag) { out.push({ path: here, kind: "structure", expected: a.tag, actual: b.tag }); continue; }
      const am = new Map(a.attrs), bm = new Map(b.attrs);
      for (const [k, v] of am) if (bm.get(k) !== v) out.push({ path: `${here} @${k}`, kind: "attribute", expected: v, actual: bm.get(k) ?? "∅" });
      for (const [k, v] of bm) if (!am.has(k)) out.push({ path: `${here} @${k}`, kind: "attribute", expected: "∅", actual: v });
      out.push(...diffNodes(a.children, b.children, here));
    }
  }
  return out;
}

export function diffProps(expected: IslandProps[], actual: IslandProps[]): PropMismatch[] {
  const out: PropMismatch[] = [];
  const byComp = (xs: IslandProps[]) => { const m = new Map<string, Record<string, unknown>>(); xs.forEach((x) => m.set(x.component, x.props)); return m; };
  const em = byComp(expected), bm = byComp(actual);
  for (const comp of new Set([...em.keys(), ...bm.keys()])) {
    const ep = em.get(comp) ?? {}, ap = bm.get(comp) ?? {};
    for (const key of new Set([...Object.keys(ep), ...Object.keys(ap)])) {
      if (JSON.stringify(ep[key]) !== JSON.stringify(ap[key])) out.push({ component: comp, key, expected: ep[key], actual: ap[key] });
    }
  }
  return out;
}

export function lineDiff(expected: string, actual: string): string {
  const e = expected.split("\n"), a = actual.split("\n");
  const set = new Set(a);
  const eSet = new Set(e);
  const lines = ["--- expected", "+++ actual"];
  for (const l of e) if (!set.has(l)) lines.push(`- ${l}`);
  for (const l of a) if (!eSet.has(l)) lines.push(`+ ${l}`);
  return lines.join("\n");
}

export function diffRoute(route: string, expectedHtml: string, actualHtml: string, opts?: NormalizeOptions): RouteResult {
  const e = canonicalize(expectedHtml, opts), b = canonicalize(actualHtml, opts);
  const structural = diffNodes(e.nodes, b.nodes);
  const props = diffProps(e.props, b.props);
  const ok = structural.length === 0 && props.length === 0;
  return { route, ok, structural, props, domDiff: ok ? "" : lineDiff(e.domString, b.domString) };
}
