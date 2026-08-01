### Added

- `zigapagos release --summary`: after a build, print on stdout an inventory of the files it
  emitted, grouped by category — pages, page aliases and alternatives, page assets, site
  assets, build assets, SPA shells, SPA routing manifests and the SPA 404 fallback. Every entry
  is recorded where the file is written, and `tests/summary/summary.sh` compares the printed set
  against the emitted tree, so the report cannot describe a tree the build did not produce. A
  build with rendering errors prints a one-line refusal instead of an inventory — on stdout too,
  so `--summary >file` answers on the same stream whatever the build's outcome.
