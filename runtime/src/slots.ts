import { h } from "./core.ts";
import type { VNode } from "./core.ts";

export type Slots = Record<string, VNode | undefined>;

// The single source of truth for slot DOM — used by BOTH the sidecar (SSR) and
// bootIsland (hydrate) so the trees are byte-identical (clean adopt-hydration).
export function slotVNode(name: string, html: string): VNode {
  return h("z-slot", {
    "data-z-slot": name,
    style: "display:contents",
    dangerouslySetInnerHTML: { __html: html },
  }) as unknown as VNode;
}

// Split the wire map into the children VNode (default slot) + the named record.
export function buildSlots(
  slots: Record<string, string> | undefined,
): { children?: VNode; slots?: Slots } {
  if (!slots) return {};
  const out: { children?: VNode; slots?: Slots } = {};
  for (const [name, html] of Object.entries(slots)) {
    if (name === "default") out.children = slotVNode(name, html);
    else (out.slots ??= {})[name] = slotVNode(name, html);
  }
  return out;
}
