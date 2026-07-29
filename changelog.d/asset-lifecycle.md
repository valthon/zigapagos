### Added

- `.asset_fingerprint = true` in `zigapagos.ziggy` installs every *linked* site asset under a
  content-hashed filename (`assets/style.css` → `/style.a1b2c3d4.css`), and every seam that
  prints a site-asset URL — `.link()`/`.absLink()`, the `![](…)` content directives, and
  `spa.head` hrefs — resolves to that name through one shared formatter, so an installed file
  and a link to it cannot drift apart. A changed file is a changed URL, which is what lets a
  deploy put `Cache-Control: immutable` on the asset tree. Opt-in and release-only;
  `static_assets` entries, build assets, page assets and the in-memory live server keep verbatim
  names. See `docs/assets.md`.

### Fixed

- A full build now names the site assets it pruned. An asset installs only when something bumps
  its refcount, and everything else was dropped in silence — a hand-authored SVG vanished from a
  build when its last `.link()` went away, and finding out why meant reading the refcount logic.
  The report is a sorted, capped list with the true total and both fixes spelled out. It stays a
  warning, since staging a file ahead of the page that will use it is legitimate, and it is
  suppressed wherever it would fire on correct code: incremental rebuilds, a build whose render
  pass failed, assets consumed by `.bytes()`/`.size()`/`.sriHash()`/`.ziggy()`,
  `.keep`/`.gitkeep` placeholders, and an `assets_dir_path` that doubles as a content dir.

### Internal

- `zig build test-assets` had been compiling and running **zero** tests while exiting 0, for as
  long as the step has existed: `filters` is a compile-time `--test-filter`, and no test in
  `main.zig` matched `assets:`, so nothing past `main.zig` was ever analysed. It now carries the
  anchor the other suites already had. Fallout: that finally compiled `src/PathTable.zig`'s
  inherited `test PathTable`, which had rotted against a `getPath` → `getPathNoName` rename and
  no longer built — repaired in place.
