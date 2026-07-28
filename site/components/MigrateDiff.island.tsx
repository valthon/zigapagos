import { useState } from "@z/runtime";

export interface Props {
  cases: { title: string; note: string; before: string; after: string }[];
}

/**
 * Before/after viewer for the Astro→Zigapagos mapping. Server-rendered showing
 * the first case in full, so the content is present and indexable without
 * JavaScript; the case selector becomes live on hydration.
 */
export default function MigrateDiff({ cases }: Props) {
  const [i, setI] = useState(0);
  const c = cases[i];
  return (
    <div class="zp-migrate">
      <div class="zp-migrate-picker" role="tablist">
        {cases.map((k, n) => (
          <button
            type="button"
            role="tab"
            aria-selected={n === i}
            class={n === i ? "zp-tab zp-tab-on" : "zp-tab"}
            onClick={() => setI(n)}
          >
            {k.title}
          </button>
        ))}
      </div>
      <p class="zp-migrate-note">{c.note}</p>
      <div class="zp-migrate-pair">
        <div class="zp-migrate-side">
          <p class="zp-migrate-label zp-before">Astro</p>
          <pre><code>{c.before}</code></pre>
        </div>
        <div class="zp-migrate-side">
          <p class="zp-migrate-label zp-after">Zigapagos</p>
          <pre><code>{c.after}</code></pre>
        </div>
      </div>
    </div>
  );
}
