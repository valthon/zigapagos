import { Link, Outlet, useState } from "@z/runtime";

// A GUARDED layout route (see app.spa.tsx: the /members route carries the
// requireAuth guard). Its chrome + the client counter live behind the guard, so
// once authorized the tabs (profile / billing) swap at the <Outlet/> while this
// layout instance — and its counter state — persists: per-scope authorization
// keeps the guarded layout mounted across intra-scope navigation.
export default function MembersArea() {
  const [count, setCount] = useState(0);
  return (
    <section data-view="members-area">
      <header data-members-chrome>Members area</header>
      <button data-members-inc onClick={() => setCount(count + 1)}>bump</button>
      <span data-members-count>{count}</span>
      <nav>
        <Link href="/members/profile" data-nav="to-profile">Profile</Link>
        <Link href="/members/billing" data-nav="to-billing">Billing</Link>
      </nav>
      <Outlet />
    </section>
  );
}
