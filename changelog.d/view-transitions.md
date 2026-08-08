### Added

- Opt-in view transitions for SPA soft navigation (issue #129): `viewTransitions: true` on a
  `.spa.tsx`'s `export const spa` makes `mountSpa` wrap every route flip in
  `document.startViewTransition()`, so a soft nav crossfades instead of flipping instantly —
  customizable with the standard `::view-transition-old(*)`/`::view-transition-new(*)` CSS and
  per-element `view-transition-name`. Off by default and feature-detected: without the opt-in,
  or on a browser without the API, navigation is byte-for-byte the previous instant flip.
  `setViewTransitions(on)` is exported from `@z/runtime` as the escape hatch for a hand-mounted
  `<Router>` that doesn't go through `mountSpa`. A non-boolean `spa.viewTransitions` is a loud
  build failure from the sidecar rather than a silent truthy coercion.
- Scope is deliberate: a pathname-changing `navigate()`/`<Link>` push and a back/forward
  (`popstate`) both transition; a `replace` navigation (including a declarative `redirect`'s
  URL-sync) and a query/hash-only navigation (a filter box calling `setSearchParams` per
  keystroke) never do — those must leave the viewport where it is rather than crossfade under
  the visitor's cursor. Scroll-to-top (push) and scroll restore (pop) run *inside* the
  transition, so the position change is part of the animated snapshot.
- Cross-document view transitions for content/island (MPA) pages are documented in
  `docs/islands.md`: one CSS rule, `@view-transition { navigation: auto; }`, in the site
  stylesheet — zero runtime JS, no build flag. An SPA shell has a fixed `<head>` and does not
  inherit the site stylesheet, so extending the rule across the content-page → SPA boundary
  means staging the stylesheet via `spa.head` (`docs/spa.md`).

### Known limitations

- A view transition captures the *immediate* route flip, not the settled page: a guarded
  route's guard and a `lazy()` route's chunk resolve after the transition finishes, so the
  animation lands on the route's `fallback`/skeleton rather than the final content. Waiting on
  that async work would risk the spec's ~4s transition timeout.
- Neither the SPA-side nor the cross-document feature disables itself under
  `prefers-reduced-motion`; the media-query guard is the author's to add.
