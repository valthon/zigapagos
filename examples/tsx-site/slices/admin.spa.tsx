// An "admin" SPA for the per-deployable runtime-slicing e2e. It uses the
// admin-only host.loadScript binding, so its per-SPA runtime
// (/spa/admin-runtime.js) DOES contain that source — while the public SPA's does
// not. Both hydrate on their own sliced runtime (one Preact each).
import { Router, host, useState } from "@z/runtime";

export const spa = { base: "/admin", title: "Admin", noindex: true };

function AdminHome() {
  const [n, setN] = useState(0);
  // host.loadScript is an admin-only binding — referencing it here pulls its
  // source into THIS SPA's sliced runtime (and only this one).
  const loadTool = () => { void host.loadScript("https://example.test/admin-tool.js"); };
  return (
    <div data-view="admin">
      <button data-inc onClick={() => setN(n + 1)}>inc</button>
      <span data-count>{n}</span>
      <button data-load onClick={loadTool}>load</button>
    </div>
  );
}

export const routes = [{ path: "/", component: AdminHome }];

export default function App() {
  return <Router base={spa.base} routes={routes} />;
}
