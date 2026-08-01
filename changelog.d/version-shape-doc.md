### Fixed

- The changelog's own description of what `zigapagos version` prints. It documented
  `git describe`'s raw `v0.1.1-<n>-g<sha>` spelling, which `build/config.zig` never
  emits — it reformats that into semver (`v0.2.0-dev.7+e1d7033`) — and the paragraph
  is published as the site's changelog page. All three shapes the binary can actually
  print are now listed, and `tests/changelog/version-shape.sh` fails the build if the
  list and the emitter disagree.
