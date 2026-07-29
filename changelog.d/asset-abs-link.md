### Added

- `$site.asset(...).absLink()` / `$page.asset(...).absLink()`: like `link()`,
  but always returns an absolute URL (`host_url` + `url_path_prefix` + asset
  path), and installs the asset the same way `link()` does. Use it for URLs
  consumed outside the page itself — `og:*`/`twitter:*` meta tags, canonical
  links, feeds — since `link()`'s output is root-relative and scrapers do not
  resolve those (#25).

### Fixed

- `absLink()` on a multilingual site returned a root-relative URL for page
  assets (`$page.asset(...)`). It is now absolute in every locale, and stays
  correct across locales too: `$page.locale('de').asset(...).absLink()` emits
  the target locale's host exactly once, including when that locale sets
  `host_url_override`.

- On a multilingual site whose locale sets `host_url_override`, a site asset
  linked with `link()` lost the separator after `assets_prefix_path` and came
  out as `https://example.com/staticfoo.css` (or `https://example.comfoo.css`
  with no prefix). This affected `link()` on those sites before `absLink()`
  existed, and is fixed for both.
