### Fixed

- Quote nginx cache-map regex tokens, including fingerprint quantifiers. The
  generated `cache.nginx.conf` now passes nginx configuration parsing instead
  of failing with `unexpected "{"`.

### Added

- A real nginx and Chrome release rehearsal for root and subpath hosting:
  generated headers, dynamic SPA deep links, hydration, lazy navigation, ETag
  revalidation, and an explicit retained-chunk release transition. A dedicated
  CI job runs it without a frontend toolchain in the deployed server.
