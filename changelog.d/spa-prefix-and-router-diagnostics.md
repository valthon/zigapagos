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

### Changed

- A `<Link>` rendered outside a `<Router>` is now a build error rather than a
  silently dead anchor: without router context the href cannot resolve against
  the SPA base and the click is never intercepted, so the prerendered shell
  shipped a link that 404s on a path-prefixed host. On the client the same
  situation warns once per href instead of throwing. Use a plain `<a>` for a
  non-router anchor.
- The build error for a dynamic route with no `skeleton` now names the concrete
  pathname the shell is prerendered at.
