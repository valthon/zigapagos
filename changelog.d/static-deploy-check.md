### Added

- Developer-side static deployment checker compares a served release with local HTML/CSS/JS, generated CSP/cache headers, and sampled SPA deep links. Includes root/subpath HTTP fixtures and explicit failures for stale bytes, wrong fallbacks, redirects, timeouts, and header mismatches; production hosts need no frontend toolchain.
