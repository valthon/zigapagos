import { useState } from "@z/runtime";

export interface Props {
  tabs: { label: string; code: string }[];
}

/**
 * Tabbed code viewer. Server-rendered with the first tab open, so the code is
 * in the HTML and readable (and indexable) before hydration; clicking only
 * becomes live once the island hydrates.
 */
export default function CodeTabs({ tabs }: Props) {
  const [active, setActive] = useState(0);
  return (
    <div class="zp-codetabs">
      <div class="zp-codetabs-bar" role="tablist">
        {tabs.map((t, i) => (
          <button
            type="button"
            role="tab"
            aria-selected={i === active}
            class={i === active ? "zp-tab zp-tab-on" : "zp-tab"}
            onClick={() => setActive(i)}
          >
            {t.label}
          </button>
        ))}
      </div>
      <pre class="zp-codetabs-body"><code>{tabs[active].code}</code></pre>
    </div>
  );
}
