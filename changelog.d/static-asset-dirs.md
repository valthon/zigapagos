### Added

- `static_assets` accepts directories: every file in their subtree installs
  unconditionally at its stable path. Text and JSON diagnostics point at config
  entries for missing or invalid paths and name both selections of a duplicate.

### Changed

- Pre-1.0 breaking change: overlapping `static_assets` entries now fail builds.
  Remove repeated files or narrow overlapping directories and globs. Paths that
  escape the assets directory lexically are rejected. File symlinks may target
  external regular files; broken symlinks, directory symlinks and non-files are rejected.
