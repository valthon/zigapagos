### Added

- `zigapagos doctor` checks document-relative `href` and `src` URLs in emitted
  HTML, including nested pages, local assets, query/fragment suffixes, and
  deployment prefixes. Missing files remain warnings, escalated by `--strict`.

### Fixed

- Doctor normalizes URL paths before stripping a deployment prefix and refuses
  symlink-backed targets, preventing files outside the deployment from making
  broken links appear valid. Documents using `<base href>` report incomplete
  audit coverage and exit nonzero instead of checking against the wrong base.
