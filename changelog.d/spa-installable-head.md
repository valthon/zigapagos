### Added

- SPA shells accept `spa.lang`, a `spa.viewport` override and ordered `{ meta: { ... } }` head entries, including media-qualified theme colors for installable apps (#243).

### Fixed

- Generated ZigBase CSP instructions explain its missing static-header support and include an Nginx reverse-proxy example with the release hashes, instead of suggesting an unsupported `.headers` key (#244).
