### Added

- `inspect-output --page=PATH` reports direct local JS/CSS resource bytes and
  inline script/style body bytes for one emitted HTML file. Optional
  `--max-page-js-bytes` and `--max-page-css-bytes` fail on regressions or
  incomplete direct-reference coverage. URL prefixes, normalized path aliases,
  unresolved/external resources, and byte-metric boundaries are explicit;
  aggregate inventory and budgets keep their existing meaning.
