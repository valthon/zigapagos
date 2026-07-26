// A "fallback" SPA for the per-deployable runtime-slicing e2e. It reads a
// host member through a COMPUTED access `(host as any)[key]`, which the slicer
// cannot prove complete — so it triggers the loud SAFE-FALLBACK: no per-SPA
// runtime is emitted and this SPA uses the shared /zigapagos-runtime.js (worst
// case = today's behavior). It must still hydrate interactively.
import { Router, host, useState } from "@z/runtime";

export const spa = { base: "/fallback", title: "Fallback", noindex: true };

function FallbackHome() {
  const [n, setN] = useState(0);
  // Computed host access — the slicer bails to the full shared runtime.
  const key = "cookies";
  const dyn = (host as any)[key];
  const readCookie = () => { void dyn.get("z_session"); };
  return (
    <div data-view="fallback">
      <button data-inc onClick={() => { setN(n + 1); readCookie(); }}>inc</button>
      <span data-count>{n}</span>
    </div>
  );
}

export const routes = [{ path: "/", component: FallbackHome }];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
