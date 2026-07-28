import { useState, useEffect } from "@z/runtime";

export interface Props {
  directive: string;
  note: string;
}

/**
 * One card per client: directive. The server-rendered state says "not
 * hydrated"; the effect flips it on mount. Because hydration timing is exactly
 * what the directive controls, the card's own state IS the demonstration —
 * client:visible stays grey until you scroll it into view, client:media until
 * you cross the breakpoint.
 */
export default function DirectiveDemo({ directive, note }: Props) {
  const [hydrated, setHydrated] = useState(false);
  const [at, setAt] = useState("");

  useEffect(() => {
    setHydrated(true);
    setAt(new Date().toLocaleTimeString(undefined, { hour12: false }));
  }, []);

  return (
    <div
      class={hydrated ? "dd-card dd-on" : "dd-card"}
      data-directive={directive}
    >
      <code class="dd-name">{directive}</code>
      <p class="dd-status">
        {hydrated ? `hydrated at ${at}` : "not hydrated yet"}
      </p>
      <p class="dd-note">{note}</p>
    </div>
  );
}
