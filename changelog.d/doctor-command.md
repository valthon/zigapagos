### Added

- `zigapagos doctor [DIR]`: audits a BUILT output tree (default `public`, read-only — never
  builds, never touches site source) for authoring mistakes that are only visible in the final
  emitted HTML. Ships two checks: `abs-url-meta` (a root-relative Open Graph / Twitter / canonical
  URL — crawlers can't resolve it, so this is an `error`) and `dangling-internal-link` (a
  root-relative `href`/`src` with no file behind it in the tree, including under `--url-prefix` —
  a `warn`, since a client-routed SPA route legitimately has no file). Exit code: any `error`
  finding, or a file doctor could not read, exits non-zero; `warn`-only findings exit 0 unless
  `--strict` is passed.
