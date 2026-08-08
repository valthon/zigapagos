### Added

- Prefetching (issue #128): a `<Link>` now starts a lazy route's chunk load on hover/focus/
  touchstart by default (`prefetch="hover"`), or when it scrolls into view
  (`prefetch="viewport"`); `prefetch={false}` opts out per-link. Prefetch failures are silent
  and never block the real navigation load, and prefetching is skipped under a browser's
  data-saver signal (`navigator.connection.saveData`/slow `effectiveType`).
- Opt-in build-time link prefetching for content pages: `.speculation_rules = true` on a
  `Site` or `MultilingualSite` injects a `<script type="speculationrules">` block into
  every rendered page's `<head>`, hinting Speculation-Rules-supporting browsers
  (Chromium today) to prefetch same-origin links on hover — pure declarative HTML,
  zero runtime JS, and inert on browsers without support. This is also how a content
  page warms an SPA's shell (including concrete `staticPaths` pages) ahead of the
  hard-navigation entry into the SPA, since a soft navigation never fetches shell HTML.
- `emit-host-config.ts`'s generated CSP now adds the CSP3 `'inline-speculation-rules'`
  script-src keyword whenever a scanned page carries a `speculationrules` block, so a
  strict-CSP deployment doesn't silently drop the feature (hash-sources don't cover this
  script type in Chromium).

### Changed

- Default hover-prefetch of lazy route chunks is a behavior change for existing SPAs using
  `lazy()`: hovering a `<Link>` to such a route now fetches its chunk before the click. It
  only affects lazy leaves, is connection-guarded, and chunks are documented side-effect-free
  at module scope — set `prefetch={false}` on a `Link` to opt a specific link out.
