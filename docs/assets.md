> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/assets/> — the site is the canonical reading experience.

# Assets

How a file under `assets_dir_path` becomes a file in the output tree, and the
two switches that change that: which assets are installed at all, and under
what name.

This document covers **site assets** — files under `assets_dir_path`, reached
from a template as `$site.asset('...')` and from content as
`[]($image.siteAsset('...'))`. Page assets (files next to a content page,
`$page.asset('...')`) and build assets (`zigapagos release --build-asset=NAME
PATH`) are mentioned only where they differ.

## The lifecycle

Zigapagos does not copy `assets/` into the output. Each site asset carries a
refcount, and only assets with a non-zero refcount are installed:

| what bumps it | where |
| --- | --- |
| `$site.asset('x').link()` / `.absLink()` | `src/context/Asset.zig` |
| `[]($image.siteAsset('x'))` and the other content directives | `src/worker.zig` |
| a `spa.head` entry whose `href` names it | `src/spa.zig` |
| a `static_assets` entry in `zigapagos.ziggy` | `src/root.zig` |

Everything else is dropped. That is the right default — an SSG that copied
every byte of `assets/` whether or not the site uses it would ship dead weight
on every deploy — but it has one sharp edge, which is that removing the last
reference to a file silently removes the file.

Note what is *not* in that table: `.bytes()`, `.size()`, `.sriHash()` and
`.ziggy()`. Those **read** an asset at build time and inline the result into
the page, so the file itself has no reason to be in the output tree and is
deliberately not installed. That is why
`<div :text="$site.asset('data.ziggy').ziggy().get('k')"></div>` works without
publishing `data.ziggy`. The reads are still tracked
(`Build.site_asset_reads`), because the pruned-asset report below must not
mistake them for an unused file.

### `static_assets`

The escape hatch for anything fetched by something *outside* the build, which
therefore has no `.link()` to bump anything:

```ziggy
.static_assets = ["favicon.ico", "CNAME", "robots.txt"],
```

An entry may be a `**` glob to take a whole subtree without listing it:
`"**"` installs the entire assets directory, `"img/**"` everything under
`assets/img/`. A glob that matches nothing is a build error.

Use it for files something else looks up at a fixed path. Do **not** use it for
site-wide CSS or feeds — those should be `.link()`ed, so that removing the last
use of them removes them from the deploy too.

### The pruned-asset report

Since issue #54, a build that drops assets says so:

```
warning: 2 asset(s) under 'assets' were not installed because nothing
references them. Link one from a template or a content file
($site.asset('...').link()), or list it in `static_assets` in zigapagos.ziggy
if something outside the build fetches it at a fixed path:
  - img/diagram.svg
  - press/logo-dark.svg
```

It is a warning, not an error: staging a file ahead of the page that will use
it is a legitimate state. Details worth knowing:

- **Sorted, and capped at ten** (with `... and N more`, and the true total
  always in the first line). `site_assets` is a hash map, so unsorted output
  would differ run to run; the cap keeps a large `assets/` tree from burying
  the build log.
- **Full builds only.** An incremental rebuild (`zigapagos dev`'s
  changed-files fast path) only re-derives the refcounts of the pages that
  changed, so every asset the rest of the site links would look pruned. The
  report is skipped there rather than lying.
- **Successful builds only.** A page whose render failed never ran its
  `.link()`s, so a failed build's refcounts are incomplete the same way an
  incremental build's are. The report stays silent — you get the render error,
  not a second wave of warnings caused by it.
- **Build-time reads don't count as pruning.** An asset consumed only through
  `.bytes()`/`.size()`/`.sriHash()`/`.ziggy()` is inlined, not dropped, so it
  is not reported. Without this the report would tell you to `.link()` a
  private data file or put it in `static_assets` — which would publish it.
- **`.keep` / `.gitkeep` are ignored.** Git cannot track an empty directory, so
  every scaffolded site has one and none of them is an asset.
- **Silent when `assets_dir_path` names a content dir.** Nothing forbids
  `.assets_dir_path = "content"`, but there every `.smd` page source is also
  scanned as a site asset and the report would name your whole content tree.
  Give assets their own directory to get it back.

## Content-hashed filenames

By default a site asset is installed at its verbatim path: `assets/style.css`
→ `/style.css`. That path is stable across deploys, which is exactly what makes
a long-lived `Cache-Control` unsafe — a CDN or GitHub Pages can serve a
returning visitor last week's stylesheet against today's HTML.

Turn on fingerprinting (issue #53) and the content hash goes into the filename:

```ziggy
Site {
    .title = "…",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .asset_fingerprint = true,
}
```

```
assets/style.css        ->  /style.a1b2c3d4.css
assets/fonts/inter.woff2 -> /fonts/inter.5e6f7a8b.woff2
```

Every reference resolves to the hashed name automatically — `.link()`,
`.absLink()`, the content directives, and `spa.head` hrefs. You do not spell
the hash anywhere. A changed file is a changed URL, so the whole asset tree can
be served `Cache-Control: public, max-age=31536000, immutable`. `zigapagos release`
already writes that policy for you — see the [Cache-Control](spa.md#cache-control)
section for the emitted `cache.{nginx,apache,zigbase}` artifacts.

The name is `<stem>.<8 hex>.<ext>`. The hash sits **before** the extension
because the extension is load-bearing downstream: a web server picks the
`Content-Type` from it, and a browser refuses a stylesheet served as
`text/plain`. An extension-less file gets the hash appended
(`CNAME` → `CNAME.a1b2c3d4`); only the last extension moves
(`archive.tar.gz` → `archive.tar.a1b2c3d4.gz`).

### What is deliberately *not* fingerprinted

- **`static_assets` entries.** They are installed unconditionally precisely
  because something outside the build fetches them at a fixed path; hashing
  `favicon.ico` or `CNAME` would break exactly the thing they exist for.
- **Build assets.** Their install path is yours to choose (`--install=` /
  `--install-always=`), and the generated ones (`zigapagos-runtime.js`,
  `spa/<name>.js`, `islands/<name>.js`) have their URLs baked into import maps,
  routing manifests and the hydration bootstrap.
- **The browser bundles zigapagos builds for itself** — the sliced islands
  runtime (`islands/_runtime.js`, #52) and the sliced SPA runtimes and lazy
  chunks under `spa/`. These never enter `site_assets` at all: they are
  registered as install-always build assets after the bundlers have run, and
  their URLs are likewise baked into import maps. They are therefore outside
  *both* halves of this document — not fingerprinted, and not candidates for
  the pruned-asset report either.
- **Page assets.** They are installed next to the page that owns them, and a
  page's own assets are invalidated by the same deploy that rewrites the page.

### Derived image variants

`image_optimize` (issue #132) names its own derived variants
`<stem>.<hash8>.<width>.webp` / `<stem>.<hash8>.<width>.avif` rather than
going through this section's `asset_fingerprint` machinery at all — see
[`docs/images.md`'s cache section](images.md#cache) for the full naming
rule, including one caveat this paragraph only summarizes: the hash is
taken over source bytes **and every transform parameter** (width, codec,
quality, encoder identity), so — for `.webp` — a change to any of those
moves the name, closing this document's own minified-CSS caveat below
(there, a minifier change moves no CSS hash, because that hash is
source-bytes-only). For `.avif`, though, "encoder identity" can only be a
hash of the *configured* `avif_encoder` string, since there is no
in-process version call for an external binary — so an in-place binary
upgrade at an unchanged path is the one case an image variant's name does
**not** move on a real change, mirroring this document's own minifier
caveat one level removed. `docs/images.md`'s cache section has the full
detail and remedy (delete `.zigapagos-cache/images/`).

Pruning is inherent rather than something this section's report has to
account for separately: a variant is planned only from a directive some page
actually references, so an unreferenced source image gets no variant and
never enters the pruned-asset report's accounting at all.

### Where it applies

Fingerprinting is a `zigapagos release` pass, so it applies wherever a release
build does — including `zigapagos dev`, which serves the real release tree. The
in-memory builds behind `zigapagos validate` and `zigapagos explain` write no
output at all and so have nothing to fingerprint.

### Cost

Turning it on reads every non-`static_assets` file in `assets/` once per build,
including files nothing ends up linking: which assets are referenced is not
known until the render pass has run, and the URLs are needed *during* it. That
is why the feature is opt-in rather than the default.

One caveat worth stating plainly: the hash is taken over the **source** bytes,
not the installed bytes. `.css` assets are minified on the way out, so a change
to the minifier itself changes the installed file without changing its name.
Bumping the toolchain is a full redeploy anyway; a change to *your* CSS is what
this exists to catch, and that always moves the hash.

## Where this lives in the code

- `src/fingerprint.zig` — the name and the URL formatter, shared by every seam
  that prints a site-asset URL so an installed file and a link to it cannot
  disagree.
- `src/root.zig` — `computeAssetFingerprints` (fills the map, once, before the
  render pass), the site-asset install loop, and `reportPrunedSiteAssets`.
- `src/context/Asset.zig` — `linkImpl`, the one place `.link()`/`.absLink()`
  bump a refcount, and `markSiteRead`, the one place the read builtins record
  a build-time read.
- `src/render/html.zig` — the `.site_asset` arm, for content directives.
- `src/spa.zig` — `spa.head` href staging and rewriting.

Proofs: `tests/assets/fingerprint.sh`, `tests/assets/pruned-report.sh`,
`tests/spa/head-fingerprint.sh`.
