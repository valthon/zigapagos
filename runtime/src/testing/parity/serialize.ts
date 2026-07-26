export type MismatchKind = "text" | "attribute" | "structure" | "missing" | "extra" | "prop-serialization";
export type MismatchSource = "hydrate-snapshot" | "double-render";

export interface Mismatch {
  path: string;
  kind: MismatchKind;
  ssr: string;
  client: string;
  source: MismatchSource;
}

export interface SerializeOpts {
  ignoreAttributes?: string[];
  ignoreSelectors?: string[];
  normalizeWhitespace?: boolean;
}

export type SNode =
  | { type: "element"; tag: string; attrs: [string, string][]; children: SNode[] }
  | { type: "text"; text: string };

function normWs(s: string, on: boolean): string {
  return on ? s.replace(/\s+/g, " ").trim() : s;
}

// Serialize EL's child nodes (not el itself — the island wrapper carries data-z-* plumbing).
export function serializeDom(el: Element, opts: SerializeOpts = {}): SNode[] {
  const ignoreSel = opts.ignoreSelectors ?? [];
  const out: SNode[] = [];
  for (const node of Array.from(el.childNodes)) {
    if (node.nodeType === 3 /* TEXT */) {
      const t = normWs(node.textContent ?? "", !!opts.normalizeWhitespace);
      if (opts.normalizeWhitespace && t === "") continue; // drop whitespace-only nodes
      out.push({ type: "text", text: t });
    } else if (node.nodeType === 1 /* ELEMENT */) {
      const e = node as Element;
      if (ignoreSel.some((s) => e.matches(s))) continue; // intentional client divergence
      const attrs: [string, string][] = [];
      for (const a of Array.from(e.attributes)) {
        const name = a.name.toLowerCase();
        if (name.startsWith("data-z-")) continue;
        // case-insensitive: attribute names are lowercased above, so lowercase the filter too
        if (opts.ignoreAttributes?.some((x) => x.toLowerCase() === name)) continue;
        attrs.push([name, a.value]);
      }
      attrs.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
      out.push({ type: "element", tag: e.tagName.toLowerCase(), attrs, children: serializeDom(e, opts) });
    }
    // COMMENT (8) and others: skipped — Preact fragment markers are framework plumbing.
  }
  return out;
}

function describe(n: SNode): string {
  return n.type === "text" ? "#text" : n.tag;
}

export function diffDom(ssr: SNode[], client: SNode[], source: MismatchSource, path = ""): Mismatch[] {
  const out: Mismatch[] = [];
  const max = Math.max(ssr.length, client.length);
  for (let i = 0; i < max; i++) {
    const a = ssr[i];
    const b = client[i];
    const here = `${path}${path ? " > " : ""}${describe(a ?? b)}:nth(${i})`;
    if (a && !b) { out.push({ path: here, kind: "missing", ssr: describe(a), client: "", source }); continue; }
    if (!a && b) { out.push({ path: here, kind: "extra", ssr: "", client: describe(b), source }); continue; }
    if (a.type !== b.type) {
      out.push({ path: here, kind: "structure", ssr: describe(a), client: describe(b), source });
      continue;
    }
    if (a.type === "text" && b.type === "text") {
      if (a.text !== b.text) out.push({ path: here, kind: "text", ssr: a.text, client: b.text, source });
      continue;
    }
    if (a.type === "element" && b.type === "element") {
      if (a.tag !== b.tag) {
        out.push({ path: here, kind: "structure", ssr: a.tag, client: b.tag, source });
        continue;
      }
      // attribute diff (both already sorted, data-z-* dropped)
      const am = new Map(a.attrs), bm = new Map(b.attrs);
      for (const [k, v] of am) {
        if (bm.get(k) !== v) out.push({ path: `${here} @${k}`, kind: "attribute", ssr: v, client: bm.get(k) ?? "∅", source });
      }
      for (const [k, v] of bm) {
        if (!am.has(k)) out.push({ path: `${here} @${k}`, kind: "attribute", ssr: "∅", client: v, source });
      }
      out.push(...diffDom(a.children, b.children, source, here));
    }
  }
  return out;
}

// Model the data-z-props JSON round-trip (pass.zig emits JSON; bootIsland JSON.parses it).
// A value lost or changed (Date, function, bigint, undefined) is a real production fault.
export function checkPropSerialization(props: unknown): Mismatch[] {
  let round: unknown;
  try {
    round = JSON.parse(JSON.stringify(props ?? {}));
  } catch (e) {
    return [{ path: "props", kind: "prop-serialization", ssr: String(props), client: `(throws: ${(e as Error).message})`, source: "double-render" }];
  }
  const out: Mismatch[] = [];
  const walk = (a: any, b: any, p: string) => {
    if (Array.isArray(a)) {
      for (let i = 0; i < a.length; i++) walk(a[i], b?.[i], p ? `${p}[${i}]` : `[${i}]`);
      return;
    }
    if (typeof a === "object" && a !== null && a.constructor === Object) {
      for (const k of Object.keys(a)) walk(a[k], b?.[k], p ? `${p}.${k}` : k);
      return;
    }
    if (typeof a !== typeof b || JSON.stringify(a) !== JSON.stringify(b)) {
      out.push({ path: `props.${p}`, kind: "prop-serialization", ssr: String(a), client: String(b), source: "double-render" });
    }
  };
  walk(props ?? {}, round, "");
  return out;
}
