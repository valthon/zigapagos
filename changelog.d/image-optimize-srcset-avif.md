### Added

- Full responsive `srcset` for build-time image optimization (issue #132, PR B): every
  surviving configured width — not just the largest — gets a variant, emitted with `w`
  descriptors plus a `sizes` attribute (`.image_optimize.sizes`, default `100vw`). Widths are
  still filtered to `<=` each image's intrinsic width (never upscaled) and site-wide, not
  per-image. `image_optimize.widths` is now rejected at config validation past 64 entries,
  closing a silent second truncation the planner used to apply on top of whatever validation
  let through.
- Opt-in AVIF via an external encoder: set `image_optimize.avif_encoder` to an
  `avifenc`-compatible binary (PATH-resolved name or explicit path) and every planned width
  also gets an AVIF variant, emitted as `<source type="image/avif">` ahead of the WebP source
  (best-format-first). Zigapagos never vendors or downloads an AV1 encoder — this only invokes
  a binary you already have, as `<avif_encoder> <in.png> <out.avif>`. A missing/unspawnable
  binary or a nonzero exit fails the build, naming the binary, the source, and the exit code.
  A first-party interchange PNG writer (`src/image/png.zig`) hands the resampled pixels to the
  encoder; it is never installed into the output tree itself.
- AVIF variants are cached and named exactly like WebP ones, with one caveat: since there is no
  in-process version call for an external binary, the cache key's encoder-identity component is
  a hash of the *configured* `avif_encoder` string, not the binary's actual behavior. Pointing
  `avif_encoder` at a different path/name busts the cache as expected; upgrading the binary in
  place does not, and needs `.zigapagos-cache/images/` deleted by hand to force a re-encode. See
  `docs/images.md`'s cache section for the full detail, including why `quality` moves an AVIF
  variant's name without changing its (encoder-side-ignored) bytes.

### Changed

- `docs/images.md` now documents the complete, shipped feature (config reference, `<picture>`
  emission shape, cache/eviction status including the AVIF cache-identity caveat above, the
  silent-filtering-vs-fatal failure split, dev-loop behavior for a newly referenced image on an
  incremental rebuild, and an authoring gotcha for `$image` directives with non-empty link
  text) — the earlier "PR A of two" framing and its "lands in PR B" hedges are gone.
  `docs/assets.md`'s derived-image-variants paragraph is updated for the two-codec cache-key
  reality. `docs/migration/astro-to-zigapagos.md` (and its byte-identical mirror under
  `skills/zigapagos-astro-migration/references/`) gains a new §14 mapping Astro's `<Image>` /
  `astro:assets` to `image_optimize`, with the semantic deltas: site-wide widths rather than
  per-image, never-upscale, AVIF requiring an external encoder, and no per-image format
  overrides.
