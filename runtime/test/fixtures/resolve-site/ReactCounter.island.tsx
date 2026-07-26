// @ts-nocheck — imports bare `react`, which only resolves through the
// z-runtime.config.json resolve overrides (react -> @z/runtime/compat is a
// DEFAULT whenever npmCompat/firstParty is non-empty). Without the override the
// SSR sidecar would auto-install the real React and useState would throw
// ("Invalid hook call") — hooks must run on the ONE shared Preact.
//
// The sibling tsconfig sets `jsxImportSource: "@z/runtime"`, so this file's
// transpiled JSX imports `@z/runtime/jsx(-dev)-runtime` — resolvable from an
// out-of-tree location only through the RUNTIME_SELF_ENTRIES identity
// overrides. store.cjs covers the sync-require path (an async module override
// would fail its `require("react")`).
import { useState } from "react";
import { greeting } from "@acme/greeting";
import { cjsReact } from "./store.cjs";
import legacy from "@acme/legacy";

export interface Props {
  label: string;
}

export default function ReactCounter({ label }: Props) {
  const [n] = useState(7);
  return (
    <button>
      {label}: {n} ({greeting}) [{cjsReact}] [{legacy()}]
    </button>
  );
}
