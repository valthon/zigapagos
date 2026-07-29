# Assets

How a file under `assets_dir_path` becomes a file in the output tree, and what
decides whether it is installed at all.

This document covers **site assets** — files under `assets_dir_path`, reached
from a template as `$site.asset('...')` and from content as
`[]($image.siteAsset('...'))`. Page assets (files next to a content page,
`$page.asset('...')`) and build assets (declared in your `build.zig`) are
mentioned only where they differ.

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

## Where this lives in the code

- `src/root.zig` — the site-asset install loop and `reportPrunedSiteAssets`.
- `src/context/Asset.zig` — `linkImpl`, the one place `.link()`/`.absLink()`
  bump a refcount, and `markSiteRead`, the one place the read builtins record
  a build-time read.

Proof: `tests/assets/pruned-report.sh`.
