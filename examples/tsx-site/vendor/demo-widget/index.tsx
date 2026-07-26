// A stand-in for a real npm React component: it imports a React API from the
// bare `react` specifier (NOT @z/runtime). The npm-compat bridge bundles
// this package into the island while aliasing `react` to the shared runtime
// (@z/runtime/compat) — kept external — so it runs on the ONE shared Preact.
import { useState } from "react";

export interface WidgetProps {
  label: string;
}

export function Widget({ label }: WidgetProps) {
  const [count, setCount] = useState(0);
  return (
    <button data-widget onClick={() => setCount(count + 1)}>
      {label}: {count}
    </button>
  );
}
