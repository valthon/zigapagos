### Added

- Build-time image optimization (issue #132, PR A): `.image_optimize = {}` on a `Site` or
  `MultilingualSite` resamples every content `$image` whose source is a decodable still
  raster (JPEG, PNG, still WebP) into a WebP variant at build time, emitted inside a
  `<picture>` with the untouched original as the `<img>` fallback — decode is wuffs, resampling
  is a first-party linear-light Lanczos3, encoding is vendored libwebp. Off by default (`null`):
  a site that never sets the field is byte-identical to today. Derived variants are cached at
  `.zigapagos-cache/images/<stem>.<hash8>.<width>.webp`, addressed by source bytes plus every
  transform parameter, so a full rebuild after the first pays only file-copy cost. `zigapagos
  init` now scaffolds `.gitignore` (previously it wrote none) so the cache directory starts
  ignored. Full `srcset`/`sizes` and an opt-in AVIF path land in a follow-up PR; see
  `docs/images.md`.

### Fixed

- `zigapagos init` (without `--from-astro`) previously wrote no `.gitignore` at all, so a
  fresh scaffold left `node_modules/`, `zig-out/` and (as of this change) the image-derive
  cache untracked but unignored.
