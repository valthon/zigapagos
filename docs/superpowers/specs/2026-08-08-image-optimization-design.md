# Build-time image optimization (#132) — design

**Status:** approved 2026-08-08 · **Issue:** [#132](https://github.com/valthon/zigapagos/issues/132)

Closes the biggest capability gap vs Astro's front page ("optimized images"): real
resampling, WebP output, responsive `srcset`, and an opt-in AVIF path — while keeping the
dependency posture lean. Zigapagos today reads intrinsic dimensions (wuffs) and emits
`width`/`height` attributes; it never touches pixels.

## Decisions (with rationale)

1. **Encode/resample capability: vendored C with thin bindings.** A pure-Zig resampler
   plus libwebp compiled from upstream source via a Zig package. Bindings are hand-written
   `extern fn` declarations (~6 symbols), **not** translate-c — so the `src/hacks/`
   per-target pretranslation burden that wuffs carries does not apply. Hermetic, in-binary,
   works for pure-content sites with no Bun. The Bun-sidecar route stays rejected (the
   issue's "keep the seam narrow"); the external-tool route is reserved for AVIF only.
2. **Author surface: config-driven, no supermd fork.** A site-level `image_optimize`
   config in the mold of `image_size_attributes` (#53) and `speculation_rules` (#128).
   supermd stays an external pin; docgen stays truthful. Per-image overrides
   (`$image.formats(...)`, per-image `sizes`) are the documented trigger for a future
   supermd fork if real demand appears.
3. **Derived variants are WebP-only in-binary.** Every resampled variant is WebP
   (lossy for JPEG sources, lossless for PNG sources), emitted inside `<picture>` with the
   untouched original as the `<img>` fallback. This collapses the issue's phases 1+2:
   exactly one encoder, and no JPEG/PNG re-encoders to vendor. WebP support is effectively
   universal in 2026; non-supporting clients get correct layout and original bytes.
4. **AVIF: codec-agnostic core, opt-in external encoder.** Codec is a parameter of the
   variant spec, cache key, and emission from day one. AVIF activates only when the site
   config names an `avifenc`-compatible binary. Nothing is vendored (libaom/SVT-AV1 would
   dwarf the rest of the tree), nothing is downloaded.
5. **srcset ships in the first delivery** (the issue's phase 3), via a site-wide widths
   list — same machinery as a single variant, ×N.

## 1. Author surface

New nullable struct field on `Site` and `Multilingual` (`src/root.zig`), with a
`Config.getImageOptimize()` accessor beside `getImageAutosize`. `null` (the default) means
**off**: the default build, all snapshots, and every existing site are byte-identical.

```ziggy
.image_optimize = .{
    .widths = [480, 800, 1200, 1920],   // default if omitted; site-wide
    .quality = 75,                       // WebP lossy quality; PNG sources use lossless
    .sizes = "100vw",                    // emitted verbatim as the sizes attribute
    .avif_encoder = null,                // opt-in: name/path of an avifenc-compatible binary
},
```

Semantics when on:

- Every content `$image` directive whose source is a decodable raster (JPEG, PNG, WebP)
  is optimized. Animated GIF/WebP, SVG, and undecodable files pass through untouched as
  plain `<img>` — deterministic, surfaced in `--format=json` diagnostics, never fatal.
- `$image.size(w,h)` keeps its current meaning — display-size attributes on the fallback
  `<img>` — and does not alter variant generation.
- Widths are filtered to ≤ intrinsic width (**never upscale**). If the source is narrower
  than the smallest configured width, one variant at intrinsic width is generated.
- Per-image `widths`/`sizes` overrides are out of scope (future supermd-fork phase).

## 2. Emission

The `.image` arm of `src/render/html.zig` gains a second shape when the planner has
variants for the asset:

```html
<picture>
  <source type="image/avif" srcset="cover.a1b2c3d4.480.avif 480w, ..." sizes="100vw">  <!-- iff avif_encoder set -->
  <source type="image/webp" srcset="cover.a1b2c3d4.480.webp 480w, ..." sizes="100vw">
  <img src="cover.e5f6a7b8.jpg" width="1600" height="900" alt="...">
</picture>
```

- Codec order is fixed best-first (AVIF, then WebP).
- The fallback `<img>` is the original asset through today's exact URL / fingerprint /
  refcount path (`printUrl` → `fingerprint.fmtUrl`), with `width`/`height` from
  `$image.size` or the autosize probe as today.
- Existing attrs→class mapping, `title`, and caption behavior carry over unchanged.
- `sizes` is required by the HTML spec whenever `srcset` uses `w` descriptors, hence the
  config default `"100vw"`.

## 3. Pipeline

Key insight: **variant names are computable without pixel work** (name = source content
hash + transform params), so the render pass never waits on encoding. Three touchpoints,
no reordering of `src/root.zig`'s load-bearing pass order:

1. **Analyze pass** (existing, `src/worker.zig` `analyzeContent`): when an image directive
   resolves and the feature is on, register a derivation request
   `(asset PathName → intrinsic size)` in a mutex-guarded build-level map. Unsupported and
   animated sources are filtered here.
2. **Planning step** (new, single-threaded, beside `computeAssetFingerprints` in
   `src/root.zig`): expand each request into its variant list and content-addressed names,
   into a **write-once map** with the same fill-once/read-lock-free discipline as
   `asset_fingerprints` — that discipline is what keeps the multithreaded render workers
   sound, and it is preserved, not re-invented.
3. **Derive jobs** (new `worker.Job` variant, scheduled in the asset-install phase): one
   job per source image — decode once, resample per width, encode per codec, write into
   the output tree. Rides the existing thread pool; compiles under `-Dsingle-threaded`
   (comptime-pruned threading, per the repo gate).

The `mode == .memory` and `incremental` early returns sit above the install phase, so
derivation never runs for `validate`/`explain` or dev's changed-files fast path — matching
existing site-asset behavior there (no regression, no new behavior). Pruning is inherent:
requests originate only from real directive references, so unreferenced images get no
variants and the pruned-asset report is unaffected.

## 4. Naming and cache

Variant basename: `<stem>.<hash8>.<width>.<ext>`, where `hash8` is 8 hex chars of Blake3
over **(source bytes ‖ width ‖ codec ‖ quality ‖ encoder-version)**.

Hashing the transform parameters deliberately fixes the caveat `docs/assets.md` documents
for CSS minification (hash-over-source-bytes means a transform change doesn't move the
name): here, any parameter change **does** move the name, so stale bytes can never be
served under a current name.

Cache: `.zigapagos-cache/images/<variant-basename>` — the name *is* the key, so the logic
is "exists → copy into output; else derive, write cache, copy". `.zigapagos-cache/` is
already gitignored by `init` and excluded from island-discovery walks. No eviction in v1
(documented limitation; a size-capped sweep is a cheap follow-up). This is the repo's
first real content-addressed build cache, and it is what makes the dev loop's
re-exec-everything model fine: first build pays the encode cost once, later full rebuilds
are file copies.

## 5. Internals

- **Decode:** wuffs `decode_frame` + pixel swizzler to RGBA8. Both symbols already exist
  in the checked-in `src/hacks/` shims — no shim regeneration, no new wuffs surface.
- **Resample:** first-party Zig. Lanczos3 in **linear light** with premultiplied alpha
  (gamma-naive resampling visibly darkens edges; linear-light is the quality bar). Small,
  pure, golden-fixture testable. Allocator contract 1 (self-freeing) or 3 (caller-buffer);
  no arena, no allowlist rows.
- **WebP encode:** libwebp compiled from upstream source via a Zig package (same shape as
  the wuffs package). Whether a maintained allyourcodebase-style package exists is a
  planning-time verification item; worst case the packaging `build.zig` is ~40 lines
  written by us. Bindings: hand-written externs for the simple API (`WebPEncodeRGBA`,
  `WebPEncodeLosslessRGBA`, `WebPFree`, …) — no translate-c. This is the tree's first
  first-party-consumed C encoder; CI gets a cross-compile check for the four release
  targets.
- **Interchange PNG writer:** tiny first-party PNG encoder using stored (uncompressed)
  deflate blocks (~80 lines, zero deps). Exists solely to hand resampled pixels to the
  external AVIF encoder as a temp file; incidentally unlocks future lossless-PNG output.

## 6. AVIF hatch

When `avif_encoder` is set, each derive job writes the resampled pixels as a temp PNG
under the cache dir and spawns the configured binary once per variant. The binary is
resolved via normal `PATH` rules or an explicit path; missing binary or nonzero exit is
**fatal with a clear message** — the user explicitly opted in, so silence would be a lie.
No download machinery, no implicit PATH scanning for candidates.

## 7. Failure policy

`src/wuffs.zig`'s size probe fails silent-by-design (a missing attribute is cosmetic).
Derivation is the opposite: once the planner has promised a variant name to the render
pass, any decode/resample/encode failure is a broken `<picture>` in shipped HTML, so it is
a `fatal.msg` build failure. The only silent path is *pre-planning* filtering
(unsupported/animated/corrupt-at-sniff → plain `<img>` passthrough, reported via
`--format=json` diagnostics).

## 8. Testing

- New `test-images` step in `build/tests.zig` + CI's explicit test-step list: resampler
  golden tests against small checked-in fixtures (ε-tolerance), PNG-writer round-trip
  (decoded back with wuffs), variant-naming/planning determinism, width-filter edge cases
  (narrow images, exact-match widths).
- New `tests/images/*.sh` e2e (picked up by CI's glob automatically): fixture site with a
  JPEG page asset → assert `<picture>` shape, variant files exist with WebP magic bytes,
  fallback URL untouched; second build asserts cache hits (cache-file mtimes unchanged);
  config-off build asserts byte-identical current behavior.
- Regression tests verified to **fail without the fix** (repo standard).
- Gates: `zig build check -Dsingle-threaded` stays green; allocator-contract gate passes
  with no new allowlist rows; `zig fmt` clean.

## 9. Docs

- New `docs/images.md` — the subsystem spec, in the style of `docs/assets.md` /
  `docs/spa.md`.
- `docs/assets.md`: new "derived assets" category in the fingerprinting section; note that
  derived names hash transform params (resolving the minified-CSS caveat's sharper form).
- Config reference, `changelog.d/` entry, ROADMAP updated.
- Astro-migration mapping (`docs/migration/` **and** the mirrored skill — the mirror gate
  will fail if only one side changes): Astro `<Image>`/`astro:assets` → `image_optimize`.

## 10. Delivery

Two stacked PRs on one branch lineage, both in this effort:

- **PR A** — pipeline end-to-end behind the config: decode → resample → WebP encode,
  cache, `<picture>` emission with a **single** variant (the largest configured width
  ≤ intrinsic, as a single-entry `srcset` with no `w` descriptor, so no `sizes` needed),
  unit + e2e tests, docs skeleton. Independently shippable.
- **PR B** — `widths`/`srcset`/`sizes`, the AVIF hatch, full docs, migration mapping.

## Out of scope (explicit)

- Per-image directive control (`$image.formats(...)`, per-image `sizes`/`widths`) — future
  supermd fork, triggered by demand.
- Vendored AV1 encoding, any encoder auto-download.
- Build-asset images (`$image.buildAsset(...)`) — their install paths are CLI-declared (see
  `docs/assets.md`'s fingerprint exclusions); they keep today's plain `<img>`. Revisit on
  demand.
- Cache eviction (documented v1 limitation).
- Animated image optimization; SVG anything.
- Windows — inherits the existing platform status (returns with the Zig 0.17 port).
