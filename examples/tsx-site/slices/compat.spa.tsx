// A "compat" SPA for the per-deployable runtime-slicing e2e. It imports the
// preact/compat surface (`memo` from @z/runtime/compat, the npm-React bridge
// path) AND uses host statically — so WITHOUT the compat/react fallback guard the
// slicer would SLICE it, and its @z/runtime/compat import-map entry would resolve
// to a sliced runtime (spa-entry.ts) that has no `memo` export → a prod crash.
// The guard must force the SAFE-FALLBACK: no per-SPA runtime, shell → the shared
// /zigapagos-runtime.js (which HAS the compat surface), still hydrates.
import { Router, host, useState } from "@z/runtime";
import { memo } from "@z/runtime/compat";

export const spa = { base: "/compat", title: "Compat", noindex: true };

const CompatView = memo(function CompatView() {
  const [n, setN] = useState(0);
  const path = host.pathname(); // host used statically (would slice without the guard)
  return (
    <div data-view="compat">
      <p data-path>{path}</p>
      <button data-inc onClick={() => setN(n + 1)}>inc</button>
      <span data-count>{n}</span>
    </div>
  );
});

export const routes = [{ path: "/", component: CompatView }];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
