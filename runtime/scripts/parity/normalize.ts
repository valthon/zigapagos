import { Window } from "happy-dom";
import { serializeDom, type SNode } from "../../src/testing/parity/serialize.ts";

export interface NormalizeOptions { classHashPattern?: RegExp; dropAstroCid?: boolean }
export interface IslandProps { component: string; props: Record<string, unknown> }
export interface Canonical { nodes: SNode[]; domString: string; props: IslandProps[] }

// Strips optional Astro chunk-hash suffix (.x1, .BhMxZzna, …) + optional .island. + extension.
// e.g. "Hero.x1.js" → "Hero", "Hero.island.tsx" → "Hero", "Hero.astro" → "Hero"
// LOW edge case: a dotted filename like "my.widget.tsx" strips to "my" (loses ".widget"),
// but this is symmetric across Astro/zigapagos so it cannot cause a false parity pass.
const EXT_RE = /(\.[a-z0-9]{1,12})?\.(island\.)?(tsx|ts|js|zig|astro)$/i;

export function componentKey(url: string): string {
  const base = (url.split("/").pop() ?? url).trim();
  return base.replace(EXT_RE, "");
}

export function decodeAstroProps(raw: string | null): Record<string, unknown> {
  if (!raw) return {};
  let obj: Record<string, unknown>;
  try { obj = JSON.parse(raw); } catch { return {}; }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    out[k] = Array.isArray(v) && v.length === 2 && typeof v[0] === "number" ? v[1] : v;
  }
  return out;
}

function collectComments(node: Node, acc: Node[]): void {
  for (const child of Array.from(node.childNodes)) {
    if (child.nodeType === 8 /* COMMENT */) acc.push(child);
    else collectComments(child, acc);
  }
}

function foldHost(doc: Document, host: Element, comp: string): void {
  const z = doc.createElement("z-island");
  z.setAttribute("data-src", comp);
  while (host.firstChild) z.appendChild(host.firstChild);
  host.replaceWith(z);
}

function scrub(root: Element, doc: Document, opts: NormalizeOptions): void {
  // Remove all HTML comments
  const comments: Node[] = [];
  collectComments(root, comments);
  comments.forEach((c) => (c as ChildNode).remove());
  // Unwrap slot wrappers — Astro's <astro-slot> and zigapagos's <z-slot> —
  // (flatten their children into parent) so slot containers do not diff
  for (const slot of Array.from(root.querySelectorAll("astro-slot, z-slot"))) {
    while (slot.firstChild) slot.parentNode!.insertBefore(slot.firstChild, slot);
    slot.remove();
  }
  // Strip data-astro-* attributes (default: on) and apply classHashPattern
  for (const el of Array.from(root.querySelectorAll("*"))) {
    // Snapshot attribute names before mutating the collection
    for (const a of Array.from(el.attributes)) {
      if (opts.dropAstroCid !== false && a.name.startsWith("data-astro-")) {
        el.removeAttribute(a.name);
      }
    }
    const cls = el.getAttribute("class");
    if (opts.classHashPattern && cls) {
      const cleaned = cls
        .split(/\s+/)
        .map((c) => c.replace(opts.classHashPattern!, ""))
        .join(" ")
        .trim();
      if (cleaned) el.setAttribute("class", cleaned);
      else el.removeAttribute("class");
    }
  }
}

export function renderNodes(nodes: SNode[], indent = ""): string {
  let s = "";
  for (const n of nodes) {
    if (n.type === "text") {
      if (n.text) s += `${indent}"${n.text}"\n`;
    } else {
      const attrs = n.attrs.map(([k, v]) => `${k}="${v}"`).join(" ");
      s += `${indent}<${n.tag}${attrs ? " " + attrs : ""}>\n`;
      s += renderNodes(n.children, indent + "  ");
    }
  }
  return s;
}

export function canonicalize(html: string, opts: NormalizeOptions = {}): Canonical {
  const win = new Window();
  const doc = win.document as unknown as Document;
  doc.body.innerHTML = html;
  const root = doc.body;
  const props: IslandProps[] = [];

  // 1. Extract + remove zigapagos props scripts, keyed by data-z-props id.
  const propsById = new Map<string, Record<string, unknown>>();
  for (const s of Array.from(root.querySelectorAll('script[type="application/json"][data-z-props]'))) {
    const id = s.getAttribute("data-z-props") ?? "";
    try { propsById.set(id, JSON.parse(s.textContent ?? "{}")); } catch { propsById.set(id, {}); }
    s.remove();
  }
  // Slot-content scripts are hydration scaffolding with no Astro counterpart; drop them.
  for (const s of Array.from(root.querySelectorAll('script[type="application/json"][data-z-slots]'))) {
    s.remove();
  }

  // 2. Fold zigapagos island hosts.
  for (const host of Array.from(root.querySelectorAll("div[data-z-island]"))) {
    const comp = componentKey(host.getAttribute("data-z-src") ?? "");
    props.push({ component: comp, props: propsById.get(host.getAttribute("id") ?? "") ?? {} });
    foldHost(doc, host, comp);
  }

  // 3. Fold Astro island hosts.
  for (const host of Array.from(root.querySelectorAll("astro-island"))) {
    const comp = componentKey(host.getAttribute("component-url") ?? host.getAttribute("component-export") ?? "");
    props.push({ component: comp, props: decodeAstroProps(host.getAttribute("props")) });
    foldHost(doc, host, comp);
  }

  // 4. Strip framework noise across the tree.
  scrub(root, doc, opts);

  const nodes = serializeDom(root, { normalizeWhitespace: true });
  props.sort((a, b) => (a.component < b.component ? -1 : a.component > b.component ? 1 : 0));
  return { nodes, domString: renderNodes(nodes), props };
}
