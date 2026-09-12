### Changed

- Update Happy DOM and its global registrator to 20.14.5, Bun and Bun types to
  1.4.2, and the Rails analysis toolchain to Ruby 4.0.6. Regenerate all three
  Bun lockfiles, including the transitive ws update to 8.21.3.
- Upgrade Node types to 26.5.1 and Undici types to 8.9.0 across runtime, site,
  and example lockfiles. Declare the Node types minimum explicitly so fresh
  consumer installs cannot select an older major via the registry default.
- Refresh Scripty, SuperHTML, Ziggy, Zeit, Flow Syntax, and the macOS framework
  SDK pins. Keep Zig 0.16.0 and TypeScript 6.0.3 for compiler compatibility;
  see `docs/dependency-audit.md` for the checked versions and deferred updates.
