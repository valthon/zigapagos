import { Link, Outlet, useState } from "@z/runtime";

// A layout route: renders shared dashboard chrome once and an <Outlet/> where
// the matched child renders. The client-only counter proves the layout INSTANCE
// survives a sibling soft-nav — its state persists while only the Outlet swaps.
export default function DashLayout() {
  const [count, setCount] = useState(0);
  return (
    <section data-view="dash-layout">
      <header data-dash-chrome>Dashboard</header>
      <button data-dash-inc onClick={() => setCount(count + 1)}>bump</button>
      <span data-dash-count>{count}</span>
      <nav>
        <Link href="/dash/overview" data-nav="to-overview">Overview</Link>
        <Link href="/dash/settings" data-nav="to-settings">Settings</Link>
      </nav>
      <Outlet />
    </section>
  );
}
