### Added

- `dev wait` waits for pending watcher changes and rebuilds, with a timeout and build-result exit status. `dev logs --json` exposes versioned NDJSON build events for foreground and background sessions.

### Fixed

- SPA navigation honors reduced-motion preferences. Development deep links get ZigBase fallback markers even with nginx/apache production targets.
- Conditional layout outlets no longer trigger premature missing-outlet warnings; missing outlets are diagnosed on layout exit.
- Host cache rules cover shared split chunks and their sourcemaps, while stable entry bundles/maps continue to revalidate.
