import { Link, Outlet, useParams, host } from "@z/runtime";

// A layout route. It renders its matched child through <Outlet/>; the
// identical alternative is to take a `children` prop and render that — the
// two are the same element, so render exactly one (rendering both mounts the
// child twice, rendering neither renders it not at all, and the router warns
// about either). The nav's <Link>s must live INSIDE the routed tree: Router
// wraps only its own rendered chain in the context Links read to resolve
// base-relative hrefs and intercept clicks, and a Link outside it is now a
// build error rather than a silently dead anchor.
export function AppShell() {
  return (
    <div class="spa">
      <nav class="spa-nav">
        <Link href="/">Home</Link>
        <Link href="/guides">Guides</Link>
        <Link href="/guides/islands">A guide</Link>
        <Link href="/account">Account</Link>
      </nav>
      <div class="spa-body"><Outlet /></div>
      <p class="spa-foot">
        Every link above changes the URL without a page load. This entire
        application is one <code>.spa.tsx</code> file.
      </p>
      <p class="spa-hint">
        Found by building this demo on a path-prefixed deploy, and since
        fixed: the nav links above render with this site's full{" "}
        <code>/zigapagos/…</code> address, resolved at build time rather than
        only in the click handler. View source or hover a link and you'll see
        the real destination — so these links also work with JavaScript
        disabled, and a copied link is the address it says it is.
      </p>
    </div>
  );
}

export function Home() {
  return (
    <div>
      <h2>A native SPA</h2>
      <p>
        You arrived here on a prerendered HTML shell — view source and the
        heading is in it. Navigation from now on is client-side.
      </p>
    </div>
  );
}

export function GuidesLayout() {
  return (
    <div>
      <h2>Guides</h2>
      <p class="spa-hint">
        This layout stays mounted while you move between the guides below — that
        is what a nested route is for.
      </p>
      <div class="spa-nested"><Outlet /></div>
    </div>
  );
}

export function GuidesIndex() {
  return <p>Pick a guide: <Link href="/guides/islands">islands</Link>.</p>;
}

// Dynamic leaf: SSR renders every :param as "_", so a skeleton is required —
// the router shows this on both the prerendered shell and the first client
// render, then flips to Guide once hydration reads the real params.
export function GuideSkeleton() {
  return <p>Loading guide…</p>;
}

export function Guide() {
  const params = useParams();
  return <p>You are reading the <strong>{params.slug ?? "islands"}</strong> guide.</p>;
}

export function Account() {
  return (
    <div>
      <h2>Account</h2>
      <p>The guard let you through. Clear the cookie and reload to see it stop you.</p>
    </div>
  );
}

export function Denied() {
  return (
    <div>
      <h2>Not signed in</h2>
      <p>
        This route has a guard. It ran in your browser after the shell was
        served, which is why the shell itself can still be a static file.
      </p>
      <button
        type="button"
        class="demo-counter"
        onClick={() => {
          // Without an explicit path the cookie defaults to this document's
          // own directory (RFC 6265) rather than the whole site, so /account
          // reading it back would depend on incidental same-directory luck —
          // the opposite of what this demo is proving.
          host.cookies.set("zp_demo_session", "ok", { path: "/" });
          location.reload();
        }}
      >
        Sign in (sets a cookie)
      </button>
    </div>
  );
}

export function NotFound() {
  return <p>No such route.</p>;
}

// Rendered on SSR + the first client render for ANY guarded route while its
// guard is pending — a neutral loading state, never gated content, so it is
// safe on a static shell served to anyone.
export function GuardFallback() {
  return <p>Checking your session…</p>;
}
