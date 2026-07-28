### Added

- `$site.asset(...).absLink()` / `$page.asset(...).absLink()`: like `link()`,
  but always returns an absolute URL (`host_url` + `url_path_prefix` + asset
  path), and installs the asset the same way `link()` does. Use it for URLs
  consumed outside the page itself — `og:*`/`twitter:*` meta tags, canonical
  links, feeds — since `link()`'s output is root-relative and scrapers do not
  resolve those (#25).
