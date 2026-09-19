### Added

- `zigapagos release --css-minify` uses the bundled runtime to minify site CSS in one Bun process, preserving independent stylesheet output, external imports and URLs, asset paths, and legacy custom minifier drivers. The canonical site build scripts now use this mode.
