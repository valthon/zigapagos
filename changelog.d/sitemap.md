### Added

- `sitemap.xml` generation (issue #150): opt in with `.sitemap = true` in `zigapagos.ziggy`
  (requires `host_url`, already mandatory) and a release build emits `sitemap.xml` at the
  output root -- one entry per canonical page URL, drafts and alias/alternative duplicates
  excluded, paginated page-2+ windows included, and prerendered SPA routes included only
  when they are real pages (a static route or a `staticPaths` concrete entry, never a
  dynamic route's own pattern shell). `zigapagos migrate` now flags `@astrojs/sitemap` in
  the generated `MIGRATION.md` worklist instead of silently dropping it.

### Fixed

- A root `assets/sitemap.xml` selected by `static_assets` now fails with
  `ZP_STATIC_ASSET_OUTPUT_COLLISION` when sitemap generation is enabled,
  instead of being silently overwritten during the release build.
