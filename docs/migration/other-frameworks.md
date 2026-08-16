> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/migrate-from-other-frameworks/> — the site is the canonical reading experience.

# Migrating from Next.js, Gatsby, Nuxt/Vue, Hugo, Jekyll, Eleventy, or Hexo

Astro remains Zigapagos's reference migration: its islands model is the closest
architectural match and has the deepest automated analysis. These adapters make
the first inventory and mapping step equally discoverable for other common
sources without pretending their runtime models are interchangeable.

```sh
zigapagos migrate path/to/site
zigapagos migrate path/to/site --from next -o MIGRATION.md
zigapagos migrate path/to/site --from gatsby --scaffold components
zigapagos migrate path/to/site --from hugo --convert-content converted/content
zigapagos migrate path/to/site --from 11ty --convert-content converted/content
zigapagos migrate path/to/site --from hexo --convert-content converted/content
zigapagos migrate path/to/site --copy-assets converted/assets
zigapagos migrate path/to/site --target path/to/new-site
```

The command auto-detects a source from its conventional config file. Use
`--from astro|next|gatsby|nuxt|vue|hugo|jekyll|11ty|hexo` when a monorepo contains
multiple framework configs or its config has a nonstandard name. A bare
`_config.yml` is not enough to distinguish Jekyll from Hexo; without supporting
package or directory evidence, the command stops and asks the user or agent to
choose rather than guessing.

Source files are read-only. `migrate` always writes a worklist. For Astro,
Next.js, and Gatsby, `--scaffold` additionally writes non-clobbering starter TSX
islands. For Hugo, Jekyll, Eleventy, and Hexo, `--convert-content` writes a
separate content tree with normalized Ziggy frontmatter and preserved Markdown
bodies. `--copy-assets` streams conventional public/static files into a separate
Zigapagos assets tree while preserving their public URL-relative paths. Vue SFCs
and static-template components are listed but never represented as successful
automatic conversions.

Generated files never overwrite earlier work: a collision is written beside it
as `.new`, `.new.2`, and so on.

## Deterministic asset copy

`--copy-assets <target-assets-dir>` handles the conventional source trees whose
URL mapping is deterministic:

- Astro and Next.js `public/`, Gatsby and Hugo `static/`, and Nuxt/Vue
  `public/` or legacy `static/` are copied from the root of those directories.
  Nuxt/Vue `public/index.html` is an application bootstrap template, not a
  fixed asset, so it is skipped with a review warning instead of replacing the
  generated Zigapagos homepage.
- Jekyll's conventional `assets/`, `images/`, `css/`, `js/`, and `fonts/` keep
  those directory names, because they are part of the public URL. Known
  pipeline inputs (`.scss`, `.sass`, and `.coffee`) are excluded.
- Eleventy `public/` is copied at the URL root; conventional root `assets/`,
  `img/`, and `images/` directories keep their prefixes. Configured
  passthrough-copy sources with other names remain review items.
- Hexo copies non-renderable files from `source/` at their URL-relative paths;
  Markdown and template inputs are excluded rather than being mistaken for
  static output. `_posts`/`_drafts` asset folders are also excluded because
  Hexo relocates them using permalink and `post_asset_folder` configuration.
  When `_config.yml` names a local theme, already-static files from that
  theme's `source/` tree are copied too; stylesheet preprocessors and template
  inputs remain review work.

The copy is streamed, so large media does not need to fit in memory. Source
files are opened read-only. Existing targets are preserved and the new copy is
written as `.new`, `.new.2`, and so on for explicit review. Directory symlinks
and other non-file entries are not followed; the CLI reports how many it
skipped so linked asset trees remain visible review work.

Zigapagos does not publish every file under `assets/` automatically. During
initial parity work, add `.static_assets = ["**"]` to `zigapagos.ziggy` if all
copied fixed URLs must remain public; later, narrow that list and link normal
site assets from templates/content so unused files can be pruned. Framework
asset pipelines remain deliberate ports: Hugo Pipes, Gatsby image processing,
Nuxt modules, Jekyll plugins, Eleventy passthrough rules outside the conventional
trees, and Hexo renderer/generator output are not reconstructed by a byte copy.

## Assemble a target in one command

`--target <new-site>` composes every deterministic adapter for the detected
source into a minimal Zigapagos project:

- conventional fixed-URL assets are copied to `assets/`; when at least one is
  copied, the generated config starts with `.static_assets = ["**"]`;
- Hugo, Jekyll, Eleventy, and Hexo Markdown is converted into `content/`;
- Astro, Next.js, and Gatsby React candidates are scaffolded into `components/`;
- a minimal `zigapagos.ziggy`, `layouts/index.shtml`, `build.sh`, agent guidance,
  and `MIGRATION.md` are written;
- a valid root placeholder is added only when conversion did not produce
  `content/index.smd`.

```sh
zigapagos migrate path/to/old-site --target path/to/new-site
cd path/to/new-site
zigapagos validate
```

For a React source, pass `--runtime-path ../path/to/zigapagos/runtime` when that
local package location is already known. Without it, the generated
`package.json` contains the explicit `TODO-SET-RUNTIME-PATH` placeholder and the
CLI prints a review warning. Static-only targets do not receive a JavaScript
package graph.

For Hexo, simple top-level `title`, `url`, and `root` values in `_config.yml`
seed the generated site title, host URL, and URL path prefix. Complex YAML and
plugin-derived configuration remain review items.

The target must be missing or empty. The command refuses a non-empty directory
and any target nested inside the source tree; it never merges generated files
into an existing project. This protects authored work and prevents a copied
asset tree from recursively seeing its own output.

Assembly does not change the semantic boundary described by the worklist.
Next/Nuxt/Gatsby routes, Vue components, templates, loaders, plugins, image
pipelines, redirects, and runtime behavior still need an explicit port. The
root placeholder makes the target immediately valid; it is not a claim that a
source route was converted. Astro also retains the deeper
`zigapagos init --from-astro` scaffold, including Astro-specific wiring and
tests; `migrate --target` is the smaller uniform workflow shared by every
adapter.

## The shared target decision

Classify every route before translating syntax:

- Build-time pages become `content/**/*.smd` plus SuperHTML layouts.
- A client-routed application becomes one `.spa.tsx` with declared routes.
- A small interactive root becomes a `.island.tsx` embedded in a static page.
- Request-time rendering, API routes, secrets, database access, and mutation
  remain backend responsibilities. Zigapagos emits a static tree; it is not a
  Node server replacement.

Preserve the old route inventory, canonical URLs, redirects, metadata, public
asset URLs, and generated pages as an explicit parity checklist.

## Next.js

The scanner inventories both `app/` and `pages/` routers (including their
`src/` forms), plus conventional `components/` directories.

- `app/**/page.*` and `pages/**/*` become static content when their data is known
  at build time; cohesive client-routed areas are usually better as an SPA.
- `layout.*`, `_app.*`, `_document.*`, metadata exports, and route-level head
  declarations map to SuperHTML layouts and page frontmatter.
- `getStaticProps`, `getStaticPaths`, and build-time server components become
  generated content or frontmatter. `getServerSideProps`, server actions,
  middleware, route handlers, and API routes must move behind a backend API.
- JSX/TSX under conventional component directories and colocated App Router
  modules carrying `use client` are conservatively reported as island
  candidates. Keep interactive roots; presentation-only children can remain
  relative TSX modules or become SuperHTML partials.
- Replace `next/image`, `next/link`, font loaders, and framework metadata helpers
  with Zigapagos assets, ordinary links/the SPA `Link`, CSS, and frontmatter.

`--scaffold` copies candidate React sources, rewrites compatible React imports
to `@z/runtime`, and flags remaining npm imports for review. It does not convert
Next-specific data or routing APIs.

## Gatsby

The scanner inventories `src/pages`, `src/templates`, and `src/components`.

- File-created pages map to content; `createPages` output becomes generated
  content with the same paths and pagination.
- GraphQL queries are a data-source boundary, not template syntax. Export their
  results to frontmatter/generated files or replace them with a build-time feed.
- `gatsby-node`, source/transformer plugins, redirects, and image plugins each
  need an explicit replacement. Compare their emitted artifacts, not just code.
- React component files are conservative island candidates and support the same
  `--scaffold` path as Next.js.

## Nuxt and Vue

The scanner inventories Nuxt's `pages/`, `layouts/`, and `components/` forms,
including their `src/` variants. For a plain Vue application it inventories the
complete `src/**/*.vue` tree, since Vue itself imposes no route/component
directory convention. A Nuxt config or `nuxt`/`vue` package dependency enables
auto-detection; `--from vue` remains useful in a monorepo.

- Pages map to content or SPA routes; Nuxt layouts map to SuperHTML layouts.
- `asyncData`, `useAsyncData`, server routes, middleware, and Nitro behavior must
  be split into build-time inputs or backend-owned APIs.
- Static Vue SFC markup becomes SuperHTML. Interactive Vue roots are re-authored
  as TSX islands or SPA components while preserving props, emitted events,
  slots, provide/inject state, and client-only boundaries.
- Nuxt modules, auto-imports, runtime config, image/content modules, and route
  rules need explicit replacements.

There is deliberately no Vue-to-TSX `--scaffold`: a syntactic placeholder would
discard Vue semantics while looking automated. The worklist keeps that port
visible instead.

## Hugo

The scanner inventories `content/` and `layouts/`.

- Markdown content usually maps directly after translating frontmatter types,
  dates, aliases, draft behavior, and taxonomy fields.
- Go templates, base templates, blocks, partials, and shortcodes map to
  SuperHTML layouts/partials and Scripty expressions.
- Taxonomies, section/list pages, data files, multilingual output, pagination,
  pipes, and generated resources must be reproduced deliberately.
- Copy `static/` URLs exactly; move processed asset-pipeline inputs into the
  Zigapagos asset flow and compare emitted filenames.

`--convert-content DIR` converts `.md`/`.markdown` pages below `content/`, maps
`_index.md` to `index.smd`, recognizes scalar `title`, `date`, `description`, and
`draft` frontmatter from YAML or TOML, and preserves the Markdown body. It adds
`custom.migration_source`, `migration_framework`, and `migration_review = true`
so review status travels with every generated page. HTML layouts and shortcodes
remain worklist items. If the source contains fields outside the recognized
set, the complete original frontmatter is retained as
`custom.migration_frontmatter` and the CLI prints a review warning. An invalid
date is likewise retained as `custom.migration_invalid_date`; the required
target date uses a conspicuous epoch placeholder until it is reviewed.

## Jekyll

The scanner inventories `_posts`, `_pages`, `_layouts`, and `_includes`.

- Markdown posts/pages map to content after translating YAML frontmatter,
  permalinks, collections, defaults, drafts, and date behavior.
- Liquid layouts/includes/filters/tags map to SuperHTML and Scripty.
- `_data`, collection documents, pagination, feed/SEO/sitemap plugins, and
  plugin-generated pages need explicit equivalents.
- Preserve post URLs before renaming files: Jekyll often derives routes from
  filename dates and permalink configuration.

`--convert-content DIR` converts root Markdown pages, `_pages`, and `_posts`.
It recognizes `title`, `date`, `description`, `draft`, and `published: false`,
preserves dated post filenames under `posts/`, and carries the same migration
review metadata as Hugo output. Jekyll `{% highlight language %}` blocks become
ordinary fenced code blocks, preserving examples such as raw HTML without
making them invalid SuperMD page markup. Permalink rules, collection routing,
other Liquid constructs, HTML bodies, and plugin fields remain explicit review
work.

## Eleventy (11ty)

The scanner recognizes `.eleventy.*`, `eleventy.config.*`, or the
`@11ty/eleventy` package. It inventories root content plus conventional `src/`
and `content/` trees, and keeps `_layouts` and `_includes` out of the page list.

- Markdown and HTML inputs map to content; Nunjucks/Liquid/JavaScript templates
  map to SuperHTML layouts or generated content according to their output role.
- Data cascade files, directory data, computed data, collections, filters,
  shortcodes, and transforms require explicit Ziggy/Scripty or generation logic.
- Passthrough-copy rules map to Zigapagos asset installation while preserving
  their emitted URLs.
- Pagination and custom permalinks must be compared against the old route tree.

`--convert-content DIR` converts `.md`/`.markdown` below conventional content
roots, strips `src/` or `content/` from output paths, preserves Markdown bodies,
and carries layouts, permalinks, tags, and other unconverted data in
`custom.migration_frontmatter` for review. HTML and template-language inputs
remain worklist items.

## Hexo

The scanner uses the `hexo` package or the conventional `_config.yml` plus
`source/` and `themes/` structure. It inventories source pages/posts/drafts and
theme EJS, Swig, or Nunjucks templates.

- `source/_posts` maps to `content/posts`; `source/_drafts` maps to
  `content/drafts` and is emitted with `.draft = true`.
- Theme layouts and partials map to SuperHTML. Helpers, generators, renderers,
  and theme configuration remain explicit implementation boundaries.
- Categories, tags, archives, pagination, post assets, and permalink patterns
  must retain their generated route and asset behavior.
- Renderer plugins can change Markdown semantics; compare rendered HTML where a
  source uses Markdown-it extensions or custom tags.

`--convert-content DIR` converts Markdown content, preserves bodies and
unconverted metadata, and normalizes `_posts`/`_drafts` paths. ISO dates written
with either dashes or Hexo's common `YYYY/MM/DD` form become Ziggy timestamps.
Theme templates, Hexo tag syntax, plugin output, and generated indexes remain
review work. The converter removes the `<!-- more -->` excerpt marker and
translates simple `<blockquote>`/`<footer>` blocks to Markdown outside fenced
code; other raw HTML remains a validation-visible review item.

## Verification loop

```sh
zigapagos validate --format=json
zigapagos release --format=json --output=public
zigapagos doctor public --format=json
```

Then compare route inventories and crawl both builds. A clean Zigapagos build
proves the target is internally valid; it does not prove parity with the source.
Test metadata, redirects, asset URLs, structured data, forms, and every retained
interactive root.
