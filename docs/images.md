> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/images/> — the site is the canonical reading experience.

# Images

Turn on `image_optimize` and every content `$image` whose source is a
decodable still raster (JPEG, PNG, still WebP) is resampled at build time
into WebP variants at every configured width the source is large enough
for, emitted inside a `<picture>` with a full `srcset`/`sizes` and the
untouched original as the `<img>` fallback. Off by default (`null`): a site
that never sets the field gets byte-identical output to today, same as
`asset_fingerprint` and `speculation_rules`.

## Config

```ziggy
Site {
    .title = "…",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .image_optimize = {},
}
```

A bare `.image_optimize = {}` opts into the defaults below; any field may be
overridden.

| field | default | meaning |
| --- | --- | --- |
| `widths` | `[480, 800, 1200, 1920]` | Candidate variant widths (CSS px), site-wide — not per-image. Filtered per image to `<=` its intrinsic width — **never upscaled**. If the source is narrower than the smallest configured width, one variant is generated at the source's own intrinsic width. Rejected at config validation if empty, if any entry is `<= 0`, or if there are more than 64 entries (`error: image_optimize.widths in zigapagos.ziggy has N entries, must be <= 64`) — the planner's scratch buffer is sized off that bound, so it is enforced once, at validation, rather than silently re-capped later. |
| `quality` | `75` | WebP lossy quality (0–100) for JPEG/lossy-WebP sources. A PNG source (detected from its magic bytes, not its extension) always encodes lossless WebP, ignoring this. Rejected at config validation outside 0–100. |
| `sizes` | `"100vw"` | Emitted verbatim (HTML-escaped) as the `sizes` attribute on every `<source>` that carries `w` descriptors — which is always, once a variant exists. |
| `avif_encoder` | `null` | Reserved for an opt-in AVIF hatch; not wired up yet. |

`$image.size(w, h)` keeps its current meaning — display-size attributes on
the fallback `<img>` — and does not affect variant generation. Per-image
overrides (`$image.formats(...)`, a per-image `sizes`/`widths`) are out of
scope; see [Out of scope](#out-of-scope).

## What gets emitted

```html
<picture>
  <source type="image/webp" srcset="cover.a1b2c3d4.480.webp 480w, cover.a1b2c3d4.960.webp 960w" sizes="100vw">
  <img src="cover.e5f6a7b8.jpg" width="1600" height="900" alt="…">
</picture>
```

- The fallback `<img>` is the **original** asset through today's exact URL /
  fingerprint / refcount path — same bytes, same `width`/`height` attributes
  (from `$image.size` or the autosize probe), same `alt`/`title`/caption
  behavior as a plain `$image` directive.
- The `<source>`'s `srcset` lists every surviving width, ascending, each
  with a `w` descriptor, comma-joined, followed by `sizes` (required by the
  HTML spec whenever `srcset` uses `w` descriptors, which it always does
  here).
- Animated GIF/WebP, SVG, and anything wuffs can't decode at sniff time are
  filtered out **before** a variant is planned: silent, never fatal, plain
  `<img>` passthrough (reported via `--format=json` diagnostics). Once a
  variant *has* been planned, though, the render pass has already promised
  that URL in the page's HTML — a decode/resample/encode failure past that
  point is a broken `<picture>` if swallowed, so it **is** fatal
  (`fatal.msg`), not silently skipped.

## Dev-loop behavior

`zigapagos dev`'s incremental rebuild only re-renders the content pages that
actually changed, reusing the previous full build's output tree for
everything else — the same fast path `static_assets` installs and site-asset
fingerprints already take. Image planning runs on every rebuild, incremental
or not, so a **newly referenced** image on an incremental rebuild gets a
correct, param-addressed URL in the re-rendered page's HTML immediately. The
actual derive job that produces the bytes, though, only runs on a full
build — so the URL points at a file that doesn't exist yet until the next
full rebuild picks it up. This is the same shape as an unbuilt site asset on
the incremental path, not a new failure mode, but it means a broken image in
`zigapagos dev` right after adding a new one is expected, not a bug — a full
rebuild (or restarting `dev`) resolves it.

## Authoring gotcha: angle brackets on non-empty link text

A `$image` directive whose link text is **non-empty** needs its destination
wrapped in angle brackets:

```markdown
[A test image.](<$image.asset("photo.jpg").alt("test photo")>)

[]($image.siteAsset("art/wide.jpg"))
```

An **empty**-text directive (`[]( … )`, the common case — it applies the
directive to the image itself rather than wrapping it in a link) needs no
wrapping. See [`docs/scripty.md`'s content directive
syntax](scripty.md#content-directives) for the general directive-as-link
grammar this follows.

## Cache

Derived variants live at `.zigapagos-cache/images/<variant-basename>` under
the site root — the same directory a `zigapagos release` is run from. The
basename **is** the cache key:

```
<stem>.<hash8>.<width>.webp
```

`hash8` is 8 hex chars of Blake3 over the source bytes **and every transform
parameter** (width, codec, quality, encoder version), so any change to any
of those — not just the image's own bytes — moves the name. This is
deliberately stricter than the caveat [`docs/assets.md`'s fingerprinting
section documents for minified CSS](assets.md#content-hashed-filenames):
there, the hash is taken over source bytes only, so a minifier change
doesn't move the name. Here it does, because the transform *is* the thing
being cached.

Existence is validity: a cache hit is a stat-and-copy, a miss decodes,
resamples, encodes and writes into the cache before installing. This is what
makes a full rebuild cheap after the first — the first build pays the
encode cost once, every later one copies bytes.

**No eviction in v1.** The cache only grows; nothing prunes an entry whose
source image was since deleted or renamed. A cheap, size-capped sweep is a
natural follow-up, not yet built. It is always safe to delete the whole
`.zigapagos-cache/images/` directory — the next build regenerates whatever
is still referenced.

Writes go through a `.tmp.<job-id>.<basename>` sibling plus rename, so a
build killed mid-encode can never leave a torn file under a valid cache
name — but a `.tmp.*` file *can* be left behind by that kill. It is inert
(nothing ever reads it) and safe to delete.

**Add it to `.gitignore`.** `zigapagos init` scaffolds
`.zigapagos-cache/` into a fresh project's `.gitignore` already; an existing
site adopting this feature should add the line by hand:

```
.zigapagos-cache/
```

## Out of scope

- **Per-image directive control** (`$image.formats(...)`, a per-image
  `sizes`/`widths` override) — would require a supermd fork; triggered by
  real demand, not built speculatively. `widths` is site-wide, not
  per-image.
- **Vendored AV1 encoding, or any encoder auto-download.** An opt-in AVIF
  hatch, spawning a binary you already have, is not built yet.
- **Animated image optimization**; SVG is never touched.
- **Build-asset images** (`$image.buildAsset(...)`) — their install paths are
  CLI-declared (see [`docs/assets.md`'s fingerprint
  exclusions](assets.md#what-is-deliberately-not-fingerprinted)); they keep
  today's plain `<img>`.
- **Windows** — inherits the existing platform status (returns with the Zig
  0.17 port).

## Where this lives in the code

- `src/root.zig` — `ImageOptimize` (the config struct), `validateImageOptimize`,
  `Config.getImageOptimize`, `planImageVariants` (fills `build.image_variants`
  before the render pass reads it, mirroring `computeAssetFingerprints`'s
  write-once/read-lock-free discipline).
- `src/image/` — `plan.zig` (eligibility, width selection, variant naming),
  `decode.zig` (wuffs full-frame decode to RGBA), `resample.zig`
  (linear-light Lanczos3), `webp.zig` (libwebp bindings), `derive.zig` (the
  worker job: cache-or-compute each planned variant), `requests.zig`
  (analyze-time request collection).
- `src/render/html.zig` — the `.image` arm's `<picture>` emission
  (`writeImageSourceLine`).

Proof: `tests/images/optimize.sh`.
