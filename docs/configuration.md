# Site configuration

`zigapagos.ziggy` is parsed from the `Site` or `Multilingual` configuration types in
`src/root.zig`. Config validation runs before content scanning and output writes.

A Zigapagos project is configured in two places: `zigapagos.ziggy` describes the
site, and the `zigapagos release` invocation that builds it declares the islands
and SPAs to compile.

## zigapagos.ziggy

```ziggy
.site = .simple(.{
    .title = "My Site",
    .host_url = "https://example.com",
    .url_path_prefix = "",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .deploy_target = "zigbase",
    .sitemap = true,
})
```

`.title` is available in every layout as `$site.title`.

`.host_url` is the origin used to build absolute URLs — canonical links, feeds,
and social metadata.

`.url_path_prefix` is the subpath the site is served from. On GitHub project
pages this is the repository name. **Set it and then never hand-write an
internal URL**: `$site.page('docs/overview').link()` and
`$site.asset('style.css').link()` apply the prefix, and a literal `/docs/` does
not, so a hardcoded link works locally and 404s in production.

`.content_dir_path`, `.layouts_dir_path` and `.assets_dir_path` are relative to
the project root.

`.static_assets` is a list of strings naming files or directories under
`assets_dir_path`, for example `.static_assets = ["favicon.ico", "fonts", "downloads/"],`.
A directory includes every file in its subtree unconditionally, at its original
path, including when fingerprinting is enabled. A trailing slash is optional;
empty directories are valid. Existing `"**"` and `"img/**"` globs still work.
Missing or invalid paths and files selected by more than one entry are build
errors; duplicate diagnostics name both entries. Paths must remain inside the
assets directory by their spelling. Selected file symlinks may target regular
files outside it; their contents are copied. Directory symlinks are not
traversed. All files in a selected directory are published, including private build-time data. See
[assets](assets.md#static_assets) for validation and diagnostic details.

`.deploy_target` selects which host configuration the build emits — `zigbase`,
`nginx`, or `apache`. See [native SPAs](spa.md) for what each
one generates.

`.image_optimize = .{}` turns on build-time image optimization: WebP variants of
every content image at configured widths, emitted as a `<picture>` with a full
`srcset`/`sizes` and the untouched original as the fallback, with opt-in AVIF
via an external encoder you supply. Off by default (`null`).
[Images](images.md) is the full reference, including the
variant cache and the failure rules.

`.speculation_rules = true` injects a browser-native
`<script type="speculationrules">` prefetch hint into every rendered page:
supporting browsers prefetch same-origin links on hover, with zero runtime JS,
and browsers without support ignore the block. Off by default; the
[islands reference](islands.md) covers it under link
prefetching.

`.sitemap = true` emits `sitemap.xml` at the output root: one entry per
canonical page URL, composed from `host_url` + `url_path_prefix` exactly like
every other absolute link this build writes. Drafts and alias/alternative
duplicates are excluded; a paginated section's page-2+ windows are included;
a prerendered SPA route is included only when it is a real, indexable page —
a static route or a `staticPaths` concrete entry (never a dynamic route's own
pattern shell, since nobody can visit `/app/club/:id` as a URL), and never a
route belonging to an SPA whose `noindex` is on (the default) — a sitemap
listing a URL the same build tells crawlers not to index is a Search Console
error, not a feature. Off by default. Requires `host_url` to be set — which
every `zigapagos.ziggy` already must, so there is nothing extra to configure.
A page whose `aliases` **or** `alternatives` output resolves to the
site-root `sitemap.xml` is a build error while the sitemap is enabled, since
either would otherwise silently collide with it.

`sitemap` is a `Site`-only field — a multilingual `zigapagos.ziggy`
(`.site = .multilingual(.{ ... })`) has no field of this name, so setting it there is a
config-parse-time "unknown field" error, not a silent no-op. Composing one
crawler-facing URL set across per-locale hosts/prefixes is a bigger design
than this feature covers yet.

`zigapagos dev`'s incremental rebuilds (the fast path that re-renders only
changed content pages) never touch `sitemap.xml`: only a full, non-incremental
build (the dev loop's first build, or a plain `zigapagos release`) writes it,
so a previously-written sitemap is left as-is — stale, not wrong-shaped —
until the next full rebuild.

## `csp_extra_sources`

Optional array, default `[]`, on both `Site` and `Multilingual` (site-wide across locales).
Each entry has a string `directive` and an array of string `sources`:

```ziggy
.csp_extra_sources = [
    .{ .directive = "frame-src", .sources = ["https://www.google.com/recaptcha/"] },
    .{ .directive = "connect-src", .sources = ["https://api.example.com"] },
],
```

Supported directives: `default-src`, `script-src`, `frame-src`, `connect-src`,
`img-src`, `style-src`, `style-src-elem`, `style-src-attr`, `font-src`, `object-src`,
and `base-uri`. Unknown directives fail config validation with the field name.
Sources must be individual CSP source expressions: host sources (optionally a
scheme, wildcard subdomain, port and path), scheme sources such as `data:` or
`https:`, `*`, quoted CSP keywords, or quoted nonce/hash sources. Keywords such
as `'self'` need their single quotes inside the Ziggy string. Queries, fragments,
whitespace, raw semicolons, malformed hashes and header fragments are rejected.
Use percent-encoding for reserved path characters. Paths with a trailing `/`
match a prefix, following CSP rules. Literal `$` and `,` in paths are emitted as
`%24` and `%2C` across all host formats to avoid nginx variable expansion and
CSP policy separators.

Sources are deduplicated and added in sorted order; repeated directive entries
are unioned. Existing sources and generated hashes stay. A directive previously
falling back to `default-src` is emitted explicitly with the effective extended
`default-src` sources, then its own additions. `style-src`
extras also extend `style-src-elem`, which otherwise takes precedence. `'none'`
is omitted from any nonempty union containing other sources, following CSP
semantics. These are additional permissions, not a replacement policy; security
keywords such as `'unsafe-eval'` or `'strict-dynamic'` change browser enforcement
and should only be declared deliberately.

Release emits all host formats via the runtime emitter (`ZIGAPAGOS_RUNTIME_DIR`).
The generated `csp-sources.json` records these inputs for subsequent emitter and
deploy-checker runs; retain it with the output. Removing the config field removes
stale generated metadata on the next full runtime-enabled release. Release records
installed user-file ownership in `.zigapagos-csp-ownership.json`; retain that file
with the output too. The deploy checker and later standalone emitter runs honor
this decision even if the user file resembles generated metadata. That ownership
filename is reserved: installing an asset there fails without overwriting it.
Unrelated files of the same name are preserved and cause an error when declarations
would overwrite them. A previously recorded user file stays protected after asset
deselection; remove it from the output explicitly before generating declarations.
Pre-marker main builds wrote declarations as a bare JSON array. Without an
installed asset or recorded user ownership, that legacy format is read as
declarations and migrated on release (or removed when declarations are cleared).
For older trees containing a same-shaped user asset, rebuild with release first
so its asset inventory records ownership before standalone emitter/checker use.
Installing a root
`csp-sources.json` via `static_assets` (including `"**"`) while declarations are
present fails validation before output writes, following sitemap collision checks.
Collision and ownership checks use the installed path: a multilingual site's
`assets_prefix_path = "static"` installs that asset at `static/csp-sources.json`,
which can coexist with root metadata. Without declarations a root asset remains
an ordinary user file. From a child
directory, metadata and host configuration use the project's default `public/`;
an explicit `--output` remains relative to the invocation directory. The default
CSP artifact contents are byte-for-byte unchanged when the field is absent or empty.

## The build invocation

`zigapagos` is a standalone executable, so a project's build is one command
rather than a build graph — nothing here needs a Zig toolchain. Keep that command
in a `build.sh` at the project root so the entries are declared in exactly one
place; `zigapagos init --from-astro` scaffolds one for you.

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

exec zigapagos release \
  --force \
  --output=public \
  --island=components/Counter.island.tsx \
  --spa='app/app.spa.tsx|/app' \
  --spa-not-found=app \
  "$@"
```

`--island=SRC` names one island source as a path relative to the project root,
and that path is what an `<island src="…">` attribute must match. Repeat the flag
once per island.

`--spa=SRC|BASE` registers a native SPA. `BASE` **must** equal the `base`
exported from the `.spa.tsx` module. The build validates the match and fails
loudly if they diverge, because a mismatch produces an application whose router
and whose prerendered shells disagree about where they live.

`--spa-not-found=NAME` names which SPA owns the site-wide `404.html`, by file
basename without the `.spa.tsx` suffix. Set it explicitly when there is more than
one SPA; otherwise declaration order decides, which is not a property you want a
deployment to depend on.

`--output=DIR` is the output tree (default `public/`), and `--force` lets the
build overwrite one it did not create. Run `zigapagos release --help` for the
rest.

## A note on failure and partial output

Build failures write the output tree in place, so a failure partway through
leaves a partially updated site. The pass order limits the damage — SPA
validation runs before any page is written — but it is not atomicity. Build to a
staging directory if you are deploying by syncing the output tree.

## Ziggy 0.3 and editor schemas

The top level is `.site = .simple(.{ ... })` or
`.site = .multilingual(.{ ... })`; locale entries use `.{ ... }`. There is no
version field. See the [upgrade guide](migration/ziggy-0.3.md) for the idempotent
converter and CRLF handling. Run `zigapagos install-schemas` for Ziggy LSP files;
`init` includes them.

Both site types accept `.custom = { "brand": "Example" }`, available as
`$site.custom.get('brand')`. `.supermd = .{ .auto_target_blank = false }`
disables the default new tab behavior for external Markdown links. Omit it
(or set true) to retain the existing behavior. Heading baselines are unchanged.
