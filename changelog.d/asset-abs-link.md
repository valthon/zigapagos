### Added

- `$site.asset(...).absLink()` / `$page.asset(...).absLink()`: like `link()`,
  but always returns an absolute URL (`host_url` + `url_path_prefix` + asset
  path), and installs the asset the same way `link()` does. Use it for URLs
  consumed outside the page itself — `og:*`/`twitter:*` meta tags, canonical
  links, feeds — since `link()`'s output is root-relative and scrapers do not
  resolve those (#25).

### Fixed

- `absLink()` on a multilingual site returned a root-relative URL for page
  assets (`$page.asset(...)`), and dropped the separator after
  `assets_prefix_path` for site assets (`https://example.com/staticfoo.css`).
  Both are now absolute and well-formed in every locale.
