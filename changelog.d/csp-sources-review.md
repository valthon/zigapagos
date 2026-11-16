### Fixed

- `csp_extra_sources` declarations stay additive: a fetch directive they create inherits the extended `default-src` instead of narrowing it to `'self'` (#265).
- Releases no longer delete or overwrite a user asset named `csp-sources.json`. Generated metadata is marked, a real collision at the installed path is reported before anything is written, and multilingual `assets_prefix_path` is taken into account. Release records which file is the site's own in `.zigapagos-csp-ownership.json` (keep it with the output), so the deploy checker and later emitter runs honour that decision. Bare-array metadata written by main builds since #269 is migrated (#265).
- `zigapagos release` run from a subdirectory without `--output` writes and cleans CSP metadata in the project's `public/`, while an explicit `--output` stays relative to the working directory (#265).
