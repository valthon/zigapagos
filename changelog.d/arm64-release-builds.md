### Added

- Publish native arm64 release archives for Linux and macOS, with matching npm
  packages and shell-installer support. Apple Silicon and Linux arm64 installs
  now receive binaries built and exercised on their native runner architecture.

### Changed

- Build the x86_64 macOS archive natively on `macos-15-intel` instead of
  cross-compiling it on an arm64 `macos-latest` runner.
- Release and development builds now share the checked-in Wuffs translation
  shims instead of release builds invoking `zig translate-c`. This removes a
  hand-maintained divergence and avoids the Zig 0.16 translation crash that
  blocked native arm64 artifacts.
