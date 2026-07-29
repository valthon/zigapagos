### Added

- A layout route now receives its matched child as a `children` prop as well as
  through `<Outlet/>` — the two are the same channel (`children` *is* an
  `<Outlet/>`), so a layout written as `<div>{children}</div>` renders its child
  instead of an empty container. Rendering both warns, and so does rendering
  neither.
- `zigapagos` warns at build time when a SPA declares no `spa.head` on a site
  that has stylesheet assets, since SPA shells have a fixed `<head>` and do not
  inherit site styles. `head: []` declares the omission deliberate and silences
  it.

### Fixed

- The site's `url_path_prefix` is now composed into `Router.base` in both
  environments, so a path-prefixed deploy (a GitHub project-pages site) emits
  prerendered `<a href>` values that carry the prefix, works without JavaScript,
  and soft-navigates to a URL that survives a hard refresh. The prefix reaches
  the build's SSR pass over the sidecar protocol and the browser over a
  `data-z-prefix` attribute on the shell's hydration root, so the two can never
  disagree. Sites with no `url_path_prefix` are unaffected, byte for byte.
- `zigapagos serve` prefixes the SPA bundle and runtime URLs it bakes into dev
  shells, which its own request handler already required.
- An island's SSR pathname (`host.pathname()`, `useLocation()`) now carries the
  site's `url_path_prefix`, matching what the browser reports. An island that
  branches on the path — active-nav highlighting, breadcrumbs — used to render
  one thing at build time and another after hydration.
- The generated nginx, Apache and ZigBase host configs now account for a site's
  `url_path_prefix`, each according to its own semantics rather than by
  prepending the prefix everywhere: nginx prefixes its `location` selectors and
  `try_files` targets; Apache emits a `RewriteBase` and keeps its per-directory
  patterns relative; ZigBase prefixes its `.match` patterns but leaves `.serve`
  targets pointing at the output tree, which has no prefix directory.
  `routing-manifest.json` carries the prefix as its own `url_path_prefix` field
  for them to apply — its route values stay tree-relative.

### Changed

- A `<Link>` rendered outside a `<Router>` is now a build error rather than a
  silently dead anchor: without router context the href cannot resolve against
  the SPA base and the click is never intercepted, so the prerendered shell
  shipped a link that 404s on a path-prefixed host. On the client the same
  situation warns once per href instead of throwing. Use a plain `<a>` for a
  non-router anchor.
- The build error for a dynamic route with no `skeleton` now names the concrete
  pathname the shell is prerendered at.
