// A "public" SPA for the per-deployable runtime-slicing e2e. It uses only
// non-privileged host bindings (store / pathname / fetchOpts), so its per-SPA
// runtime (/spa/public-runtime.js) must NOT contain the admin-only host.loadScript
// / host.recaptchaToken source — that is the SEPARATION win the slicer buys.
import { Router, host, useState, useEffect } from "@z/runtime";

export const spa = { base: "/public", title: "Public", noindex: true };

function PublicHome() {
  const [n, setN] = useState(0);
  // host.store + host.fetchOpts are referenced (recorded by the slicer); the
  // click also drives a hooks re-render so the browser test can prove this SPA
  // hydrated interactively on its OWN sliced runtime (one Preact).
  useEffect(() => { host.store.setStr("public:hits", String(n)); }, [n]);
  const ping = () => { void host.fetchOpts({ url: "/api/ping" }); };
  return (
    <div data-view="public">
      <p data-path>{host.pathname()}</p>
      <button data-inc onClick={() => { setN(n + 1); ping(); }}>inc</button>
      <span data-count>{n}</span>
    </div>
  );
}

export const routes = [{ path: "/", component: PublicHome }];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
