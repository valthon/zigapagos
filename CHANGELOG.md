# Changelog

Notable changes to Zigapagos. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[semver](https://semver.org/spec/v2.0.0.html) with the pre-1.0 caveat that a
minor bump may break an API.

Two things to know before reading it:

- **This file starts at the first public release, deliberately.** The repository
  carries 372 commits, but only the last two are this fork's: the full history of
  the upstream generator it forks, then a Zig 0.16 port and one squashed commit
  for all of the fork's own work. Splitting work that was never released into a
  per-version history would be invention, so this file does not do it. The
  subsystem specs in `docs/` are the source of truth for *what the code does*;
  this file records *when it changed*, starting now.
- **This repository does not carry the forked project's release tags.** A
  single fork-point tag, `fork-point-zine-v0-11-2`, marks where the history <!-- branding-ok: the tag is named for the upstream release it marks -->
  diverges, and `0.1.0` was the first Zigapagos version number — `build.zig.zon`
  declares the current one. `zigapagos version` prints the string
  `build/config.zig` stamped into the binary at build time, derived from
  `git describe --match '*.*.*' --tags` against the tags that actually exist
  here, never from an inherited tag, because there are none to describe against.
  It has exactly three shapes:

  - `v0.2.0` — the build sat on a release tag, so describe's output is used
    verbatim.
  - `v0.2.0-dev.7+e1d7033` — an untagged commit: the last release tag, how many
    commits past it, and the abbreviated hash. This is deliberately *not* how
    `git describe` spells it. The height is moved into a `-dev.` pre-release, the
    hash into `+` build metadata, and describe's conventional `g` prefix is
    dropped, so everything after the leading `v` is a valid semver version and
    orders against the releases below. The `v` is not part of that version number
    — semver excludes it — it is carried over from the tag name, which describe
    returns verbatim.
  - `unknown` — `git` is missing, or `git describe` failed: nothing to describe
    against, because the checkout is shallow, or because the tree is not a git
    repository at all. CI's own `build-binary` job is the shallow case, so the
    binary it uploads says `unknown` while a release build says the tag.

  `tests/npm/packaging.sh` pins the installed binary's output to that grammar and
  `tests/changelog/version-shape.sh` pins this list to it, so the tool and this
  paragraph cannot disagree without a gate going red.

## [Unreleased]

Pending changes are **not listed here** — they live one file each in
[`changelog.d/`](changelog.d/), and `scripts/assemble-changelog.sh` folds them
into a new version section at release time. That is the whole point: two pull
requests each adding their own fragment merge cleanly, whereas two pull requests
each appending a bullet to this block collide on the same lines. To see what is
queued for the next release, read `changelog.d/`.

## [0.5.0] - 2026-09-01

### Added

- Content-authored `<z-island>` elements can receive native SuperMD-rendered
  children and named slots. `markdown-slot="section-id"` supplies `children`;
  `markdown-slot-NAME="section-id"` supplies `slots.NAME`; referenced sections
  are marked with `.attrs('island-slot')`. Their Markdown keeps normal content
  directives, fenced-code validation, and tree-sitter highlighting, while
  missing, unused, or duplicate slot references fail the build instead of
  losing or duplicating content. This completes issue #153's remaining
  authoring gap.
- Content-authored `<z-island>` elements can opt into page-bound Scripty
  `prop-NAME="$…"` values with `scripty:props`; resolved props feed both SSR and
  the `--island-props-check` TypeScript gate while unmarked fences stay
  verbatim.
- `zigapagos migrate` now recognizes Eleventy (`11ty`) and Hexo projects,
  inventories their conventional content/template trees, and supports
  non-clobbering Markdown conversion with loss-visible frontmatter review
  metadata. Ambiguous projects stop with an actionable `--from` prompt instead
  of guessing from a shared config filename.
- `zigapagos migrate` now auto-detects Next.js, Gatsby, Nuxt/Vue, Hugo, and
  Jekyll projects (or accepts `--from`) and writes source-specific migration
  worklists. Next.js and Gatsby React components, including JSX authored in
  `.js`, can use the existing non-clobbering `--scaffold` path;
  `--convert-content` normalizes Hugo/Jekyll YAML or TOML frontmatter into a
  separate Zigapagos content tree while preserving Markdown bodies. Unconverted
  frontmatter and invalid source dates travel with the generated page as
  explicit review metadata and produce CLI warnings instead of disappearing
  silently. Vue and static-template sources remain explicit manual ports.
- `zigapagos migrate --copy-assets DIR` now streams conventional framework
  public/static trees into a separate Zigapagos assets directory while
  preserving URL-relative paths and source immutability. Existing targets are
  never overwritten: repeat runs write `.new`, `.new.2`, and later review
  copies.
- `zigapagos migrate <source> --target <new-site>` now assembles a minimal valid
  Zigapagos project by composing each framework adapter's deterministic
  content, React-island, and fixed-URL asset transforms. It refuses non-empty or
  source-nested targets and leaves semantic framework behavior explicit in the
  generated `MIGRATION.md`.
- `zigapagos migrate` now provides an end-to-end Rails presentation migration
  workflow. It detects Rails applications, inventories their presentation
  sources and integrations, statically recovers and classifies routes, and
  emits deterministic `MIGRATION.md` and versioned manifest artifacts. Every
  unsupported or uncertain construct is recorded as a stable blocker or
  answerable finding rather than being silently omitted; `--strict` turns any
  blocker into a non-zero result for CI and agent loops.
- `zigapagos migrate <rails-app> --from rails --target DIR` converts the
  supported ERB subset into a buildable Zigapagos project with content,
  layouts, partials, deterministic assets, islands, configuration, and build
  files. `MIGRATION.decisions.json` records durable operator choices, while
  the versioned `MIGRATION.handoff.json` records what every user-facing route
  became. Exit code 3 means the target was written successfully but still has
  unanswered routes; exit code 0 means every route was migrated, redirected,
  bound to a backend, or explicitly retained or blocked.
- `--backend openapi.json` binds Rails forms, mutating links, JSON routes, and
  sign-in/sign-up journeys to operations from a ZigBase OpenAPI contract.
  Generated islands use `@zigbase/client`, render backend validation errors,
  preserve confirmed redirects, and keep authentication and authorization
  enforcement on the server. Controller authentication guards become explicit
  decisions instead of silently turning protected pages public.
- Portable presentation behavior can become generated islands: structural
  Stimulus controllers, Turbo Frames, literal-props React roots and their
  relative imports, request-backed list and record regions, and literal Turbo
  Stream subscriptions/actions through the ZigBase realtime client. Dynamic or
  ambiguous shapes remain explicit `retain` or `blocked` decisions.
- Handoffs include typed, deterministic parity evidence for migrated pages,
  assets, authentication, allowed and denied mutations, and validation errors.
  Generated Bun and Playwright runners replay those facts against an isolated
  ZigBase instance without booting the source Rails application.
- The Rails migration reference and installable migration skill document the
  supported template, route, asset, backend, interactivity, decision, handoff,
  and parity contracts. Generated JSON Schemas for the presentation manifest
  and handoff are checked against the emitting Zig types and validated against
  real fixture output in CI.
- `sitemap.xml` generation (issue #150): opt in with `.sitemap = true` in
  `zigapagos.ziggy` (requires `host_url`, already mandatory) and a release build
  emits `sitemap.xml` at the output root -- one entry per canonical page URL,
  drafts and alias/alternative duplicates excluded, paginated page-2+ windows
  included, and prerendered SPA routes included only when they are real pages
  (a static route or a `staticPaths` concrete entry, never a dynamic route's own
  pattern shell). `zigapagos migrate` now flags `@astrojs/sitemap` in the
  generated `MIGRATION.md` worklist instead of silently dropping it.

### Changed

- Singular Rails resources now resolve to their plural controllers, matching
  ActionDispatch. Generated TypeScript projects include the runtime JSX types
  and bundler settings needed to type-check copied JavaScript and JSX sources.
  `--runtime-path` still takes precedence, but generated projects fall back to
  `ZIGAPAGOS_RUNTIME_DIR` instead of leaving a package placeholder when that
  installed-runtime path is available.
- A route's discovery `classification` and migration `status` are deliberately
  separate claims: classification describes source evidence, while status says
  what the converter produced after applying decisions. Consumers deciding
  whether a route migrated should read `MIGRATION.handoff.json`.

### Fixed

- Prefixed `dev` and `e2e` servers now publish fully staged trees with a
  directory swap, so a refresh cannot expose a partially copied site; a staging
  failure after the server starts also tears the child server down.
- Rails discovery retains safe symlinked views and controllers while refusing
  controller links that resolve outside the application, reports malformed or
  locale-mismatched translation documents, ignores commented default-locale
  assignments, honors namespace helper-prefix overrides, and preserves nested
  `fields_for`, block-form links, dynamic assets, and named-yield defaults as
  explicit migration facts.
- Converter gaps are now answerable: block locals inside findings stay owned by
  those findings; dynamic page titles, genuinely unbound locals, unresolved or
  cyclic partials, and route helpers whose arguments cannot form a URL receive
  stable finding ids. Missing `--doctor`, `--backend`, and `--decisions` inputs
  report the flag, path, and operating-system error and exit 1 instead of
  aborting a debug build.
- A root `assets/sitemap.xml` selected by `static_assets` now fails with
  `ZP_STATIC_ASSET_OUTPUT_COLLISION` when sitemap generation is enabled,
  instead of being silently overwritten during the release build.

### Known limitations

- Route recovery is static AST analysis and does not boot Rails. Dynamic route
  generation, engine mounts, external route files, arbitrary helpers, dynamic
  layouts, Haml/Slim, and runtime-generated assets are reported for manual
  handling rather than guessed. Only the configured default i18n locale is
  resolved.
- Stimulus conversion is structural rather than Ruby-to-JavaScript method
  transpilation. Nested controllers, unsupported action descriptors, raw-text
  action elements, React `require()` or dynamic imports, and Vue roots require
  manual work. A Turbo Frame with a `src` still needs that same-origin endpoint
  proxied until the migrated site serves equivalent fragment HTML; realtime
  islands dispatch record facts rather than rendering Rails partials as DOM.
- Forms declared in layouts cannot yet be replaced with bound islands, and an
  authentication form reached only through a layout may remain a separate
  backend question. A generated target uses `https://example.com` as its
  `host_url` until the operator supplies the deployment host.
- Parity runners verify observable presentation and API behavior; they do not
  move authorization into browser code. ZigBase collection and consumer rules
  remain the enforcement boundary.
- With `auto_heading_ids` on, a same-page reference through the
  `$link.ref('slug')` Scripty directive still fails with `unknown ref` because
  SuperMD validates references before ids can be injected. Plain Markdown
  links work, and `$link.unsafeRef('slug')` is the workaround.
- Shared SPA split chunks and `.map` sourcemaps are not tracked per route, so
  emitted host config gives them the revalidating baseline rather than an
  immutable policy. The fingerprint rule remains a filename-shape heuristic,
  not proof that `asset_fingerprint` was enabled.
- A view transition captures the immediate route flip rather than the settled
  page. Guard and lazy-route resolution can therefore finish after the
  transition, and neither SPA nor cross-document transitions automatically
  disable themselves for `prefers-reduced-motion`.
- **No Windows support** until the Zig 0.17 port. Inherited watcher and Wuffs
  code does not compile on stable Zig 0.16.0.
- **No FreeBSD binary**, and the current source build still lacks a checked-in
  Wuffs shim and a native watcher selection for that target.
- **The emitted host config is only a file until you deploy it.** Serving the
  generated CSP and caching policy, and updating them after a rebuild, remains
  the host's responsibility. `style-src-attr` still permits `'unsafe-inline'`
  for framework-authored inline style attributes.
- **A per-locale `host_url_override` cannot be exercised locally.** `dev`
  serves one built tree on one origin, so a multi-host locale set must be
  verified after deployment.
- **Prebuilt binaries cover four Unix targets**: `x86_64-linux-musl`,
  `aarch64-linux-musl`, `x86_64-macos`, and `aarch64-macos`. Other hosts need a
  source build where supported.
- **AVIF needs an encoder you already have.** Zigapagos never vendors or
  downloads an AV1 encoder; without `image_optimize.avif_encoder`, image
  optimization emits WebP and the original only.
- Pre-1.0: APIs may change between minor versions.

## [0.4.0] - 2026-08-09

### Added

- `zigapagos validate --format=json` (issue #131): the fast pre-SSR gate now emits the same
  NDJSON diagnostic stream on stderr as `release --format=json` — same `ZP_*` code registry,
  same `{"code","severity","file","line","col","message","help"}` schema — so an agent's
  `release` → fix → `validate` loop never parses prose. In JSON mode the trailing
  `validate: FAILED` prose line is suppressed; the non-zero exit and the stream carry it.
- `zigapagos doctor --format=json`: each finding as one NDJSON object on **stdout** (doctor's
  report stream, distinct from the build-diagnostics stderr stream), shaped
  `{"check","severity","file","message"}`, followed by exactly one
  `{"errors","warnings","files","skipped"}` summary object as the last line. `check` ids
  (`abs-url-meta`, `dangling-internal-link`, …) are stable once shipped; `message` prose is
  not. Doctor fatals emit `ZP_FATAL` NDJSON on stderr. Text-mode output is byte-for-byte
  unchanged.
- `zigapagos explain-code --format=json`: the frozen code registry as NDJSON on stderr, one
  `{"code","summary","explanation"}` object per line — the machine-readable dictionary an
  agent reaches for after matching a `code`.
- `zigapagos init` now scaffolds `AGENTS.md` and `CLAUDE.md` into a new site (`CLAUDE.md` is
  exactly `@AGENTS.md`). The generated `AGENTS.md` documents the two naming traps (`build` is
  spelled `release`, `serve` is spelled `dev`), the `--format=json` fix loop, the
  match-on-`code`-never-`message` rule, and the exit-code semantics. Both ride the existing
  exclusive-create path — an existing file is skipped, never overwritten.
- The Astro migration ships as an installable Agent Skill: `skills/zigapagos-astro-migration/`
  in the open agentskills.io `SKILL.md` format (read by Claude Code, Codex, Cursor, Gemini CLI
  and others) — a workflow layer over the `zigapagos migrate` scan and the JSON fix loop, with
  the full deterministic mapping spec bundled under `references/`.
- **`zigapagos dev --background`**: detach the dev loop as its own process
  group (stdio to `.zigbase/dev.log`), wait for it to actually become ready,
  then print its URL/PID/log path and exit 0 — no more babysitting a
  foreground `dev` from a script or an agent. `dev stop|status [--json]|logs
  [--follow]` manage it afterward; `--force` restarts an existing session,
  `--ignore-lock` runs a second, untracked instance. See `docs/dev-server.md`.
- **`GET /_zigapagos/status`**: the dev control server (formerly just the
  live-reload stream, now always on) reports the served URL/PID plus
  build-aware state — a monotonic `generation` counter, `status`
  (`ok`/`failed`/`building`), `duration_ms`, and a bounded `error` tail on
  failure — so an agent can poll for its own edit to land and branch on the
  result instead of guessing when a rebuild finished.
- **Agent auto-detection**: `zigapagos dev` backgrounds itself automatically
  in a recognized AI-agent environment (Claude Code, OpenAI Codex, Gemini
  CLI, Cursor's agent mode, and others — see the table in
  `docs/dev-server.md`). `ZIGAPAGOS_DEV_BACKGROUND=0` opts out;
  `ZIGAPAGOS_DEV_BACKGROUND=1` forces it even outside a detected environment.
- `dev stop` now reaps a zigbase left orphaned by a `kill -9`'d dev session
  (health-verified via zigbase's own `/api/health` before touching it),
  retiring the previously-documented manual `pkill zigbase` recovery.
- Cache-Control host config (issue #133): `zigapagos release` now writes a site-wide caching
  policy at the output root alongside the routing and CSP artifacts — `cache.nginx.conf`,
  `cache.apache.conf` and `cache.zigbase.txt`, emitted wherever the CSP artifacts already are —
  which is every site carrying islands or an SPA, island-only sites with no SPA namespace
  included. (A content-only site with neither gets no host config at all; the emitter is a pass
  over the finished tree and `release` skips it, exactly as it already skipped the CSP.)
  nginx's `map $uri $zigapagos_cache_control { … }` merges into
  `http{}` with `add_header Cache-Control $zigapagos_cache_control always;` in the *same*
  block that carries `csp.nginx.conf`'s header (a nested `add_header` suppresses the
  server-level one); Apache's `<FilesMatch>` stanzas install where `csp.apache.conf` does.
  Documented in `docs/spa.md`.
- The policy is two header values with `no-cache` as the baseline, so nothing the build emits
  ships header-less: `public, max-age=31536000, immutable` for `asset_fingerprint`'s
  `<stem>.<8 hex>[.<ext>]` name shape and for this build's content-hashed SPA lazy-route
  chunks (exact-listed from each namespace's `routing-manifest.json`, never pattern-matched —
  a naive chunk regex would also swallow stable paths like `<name>-runtime.js`); `no-cache`
  for `*.html`, routing manifests, and every stable path whose URL survives a deploy while its
  content does not. Header-less is not "no caching" but *unspecified* caching (heuristic
  freshness, CDN extension-keyed TTLs) — i.e. fresh HTML paired with a stale entry bundle —
  and `no-cache` still permits a 304, so the cost is one conditional request. Revalidating
  rules always outrank immutable ones, encoded per target's match semantics (nginx `map` is
  first-match-wins, Apache `Header set` is last-match-wins), so hand-merging the stanzas in a
  different order is the one way to break it.
- `cache.zigbase.txt` is advisory, the same stance as `csp.zigbase.txt`: ZigBase has no
  per-path response-header configuration, so the file records the ideal policy for a CDN or
  reverse proxy in front of it, and warns against pointing ZigBase's one *global* knob
  (`--static-cache-control`) at the immutable value — that would cache a stale shell and HTML
  across deploys. Stock `zigbase serve` already sends `max-age=3600` + ETag revalidation for
  static files and `no-cache` for fallback shells.
- Build-time image optimization (issue #132): `.image_optimize = {}` on a `Site` or
  `MultilingualSite` resamples every content `$image` whose source is a decodable still
  raster (JPEG, PNG, still WebP) into a WebP variant at build time, emitted inside a
  `<picture>` with the untouched original as the `<img>` fallback — decode is wuffs, resampling
  is a first-party linear-light Lanczos3, encoding is vendored libwebp. Off by default (`null`):
  a site that never sets the field is byte-identical to today. Derived variants are cached at
  `.zigapagos-cache/images/<stem>.<hash8>.<width>.webp`, addressed by source bytes plus every
  transform parameter, so a full rebuild after the first pays only file-copy cost. `zigapagos
  init` now scaffolds `.gitignore` (previously it wrote none) so the cache directory starts
  ignored. Full `srcset`/`sizes` and the opt-in AVIF path are part of this same release, in the
  entries that follow; see `docs/images.md`.
- Full responsive `srcset` for build-time image optimization (issue #132): every
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
- Pagination for content sections (issue #127): a section index opts in with
  `.pagination = { .page_size = 10 }` in its `index.smd` frontmatter and the build renders
  that index once per window of active subpages. Nothing changes for a section that doesn't
  set it, and drafts are excluded from the counts rather than merely hidden. Three URL styles
  via `.pagination.url_style` — `page_dir` (`/blog/page/2/`, the default), `plain_dir`
  (`/blog/2/`), `page_html` (`/blog/page-2.html`) — and page 1 is always the section's own URL
  in every style. One formula backs the generated `href`, the on-disk output path and the
  browser pathname handed to island SSR, so a link and the file it addresses cannot drift.
- Windowed layout surface: `$page.subpages()` and `$page.subpagesAlphabetic()` return only the
  current window when called on the index being rendered — a shared layout's existing loop
  paginates with no edit. `$page.pagination?()` returns a `Paginator` on such a render and
  null everywhere else, so a layout shared with unpaginated sections branches with a plain
  `:if`. `Paginator` carries `current`, `total`, `page_size`, `total_items`, plus
  `prevLink?()`, `nextLink?()` and `pageLink(n)` (which errors out of range — guard numbered
  pagers with `.total`). A different section reached through `$site.page(…)` still sees its
  full subpage list, and RSS `alternatives` are never windowed.
- Guardrails and observability: `ZP_INVALID_PAGINATION_SIZE` (zero `page_size`) and
  `ZP_PAGINATION_NOT_SECTION` (`.pagination` on a leaf page) are span-carrying frontmatter
  diagnostics; a pagination URL colliding with a real page (a subpage literally named `2`
  under `plain_dir`) aborts through the ordinary collision gate; `--summary` counts a
  "pagination pages" category and `explain` lists each pagination page by output path.
- Stale pagination output is pruned on rebuild. Pagination is the first feature whose output
  set *shrinks* with content, and dev builds into the same tree, so a section dropping from
  three pages to one would otherwise serve an orphaned `page/2/` forever. The prune probes
  past each section's live plan in all three URL styles (changing `url_style` orphans the
  previous shape) and skips anything registered as a real output or prerendered by an SPA.
- Astro importer support: `zigapagos migrate` recognises `[page].astro` / `[...page].astro`
  routes calling `paginate()`, reads a literal `pageSize` (flagging a computed one for review
  rather than guessing), and prescribes the conversion in the worklist, the port doctor's
  report and its `--format=json` output; `zigapagos init --from-astro` writes the section
  `index.smd` stub with `.pagination` already set.
- Prefetching (issue #128): a `<Link>` now starts a lazy route's chunk load on hover/focus/
  touchstart by default (`prefetch="hover"`), or when it scrolls into view
  (`prefetch="viewport"`); `prefetch={false}` opts out per-link. Prefetch failures are silent
  and never block the real navigation load, and prefetching is skipped under a browser's
  data-saver signal (`navigator.connection.saveData`/slow `effectiveType`).
- Opt-in build-time link prefetching for content pages: `.speculation_rules = true` on a
  `Site` or `MultilingualSite` injects a `<script type="speculationrules">` block into
  every rendered page's `<head>`, hinting Speculation-Rules-supporting browsers
  (Chromium today) to prefetch same-origin links on hover — pure declarative HTML,
  zero runtime JS, and inert on browsers without support. This is also how a content
  page warms an SPA's shell (including concrete `staticPaths` pages) ahead of the
  hard-navigation entry into the SPA, since a soft navigation never fetches shell HTML.
- `emit-host-config.ts`'s generated CSP now adds the CSP3 `'inline-speculation-rules'`
  script-src keyword whenever a scanned page carries a `speculationrules` block, so a
  strict-CSP deployment doesn't silently drop the feature (hash-sources don't cover this
  script type in Chromium).
- Opt-in view transitions for SPA soft navigation (issue #129): `viewTransitions: true` on a
  `.spa.tsx`'s `export const spa` makes `mountSpa` wrap every route flip in
  `document.startViewTransition()`, so a soft nav crossfades instead of flipping instantly —
  customizable with the standard `::view-transition-old(*)`/`::view-transition-new(*)` CSS and
  per-element `view-transition-name`. Off by default and feature-detected: without the opt-in,
  or on a browser without the API, navigation is byte-for-byte the previous instant flip.
  `setViewTransitions(on)` is exported from `@z/runtime` as the escape hatch for a hand-mounted
  `<Router>` that doesn't go through `mountSpa`. A non-boolean `spa.viewTransitions` is a loud
  build failure from the sidecar rather than a silent truthy coercion.
- Scope is deliberate: a pathname-changing `navigate()`/`<Link>` push and a back/forward
  (`popstate`) both transition; a `replace` navigation (including a declarative `redirect`'s
  URL-sync) and a query/hash-only navigation (a filter box calling `setSearchParams` per
  keystroke) never do — those must leave the viewport where it is rather than crossfade under
  the visitor's cursor. Scroll-to-top (push) and scroll restore (pop) run *inside* the
  transition, so the position change is part of the animated snapshot.
- Cross-document view transitions for content/island (MPA) pages are documented in
  `docs/islands.md`: one CSS rule, `@view-transition { navigation: auto; }`, in the site
  stylesheet — zero runtime JS, no build flag. An SPA shell has a fixed `<head>` and does not
  inherit the site stylesheet, so extending the rule across the content-page → SPA boundary
  means staging the stylesheet via `spa.head` (`docs/spa.md`).

### Changed

- The `--format` pre-scan gate in `main.zig` (which suppresses stderr chatter before the
  authoritative parse) now covers `release`, `validate`, `doctor` and `explain-code`. It stays
  an explicit allowlist — a command joins it only in the same change that teaches its own
  parser the flag.
- The generated strict-CSP header (`csp.nginx.conf`/`csp.apache.conf`/`csp.zigbase.txt`) now
  emits the CSP3 `style-src-elem`/`style-src-attr` split instead of a blanket
  `style-src 'self' 'unsafe-inline'`. `<style>` elements and `<link>` stylesheets are now hashed
  and governed by `style-src-elem`, exactly as strict as `script-src`; only `style-src-attr` keeps
  `'unsafe-inline'`, confined to the framework's inline `style` *attributes* (`display:contents`
  on island slot wrappers), which CSP hashes cannot cover. Operators who deployed a previously
  generated CSP header must regenerate and redeploy it — the directive name changed, so a stale
  copy no longer matches what the site's HTML needs. Sites relying on the old blanket grant for
  their own inline `<style>` elements (e.g. the `zigapagos init` scaffold layouts) keep working
  automatically: those elements are now hashed rather than allowed by the removed
  `unsafe-inline`. The one case that does NOT survive is a `<style>` element created at RUNTIME by
  client code (a CSS-in-JS library injecting one on hydration): it has no build-time text to hash,
  so `style-src-elem` blocks it where the blanket grant permitted it — ship those as a stylesheet
  asset or as `style` attributes instead (`docs/spa.md`). Fixes #130.
- The pinned toolchain moves from Bun 1.2.23 (the final release of the discontinued 1.2
  line) to Bun 1.3.14, and the pin is now exact — `bun = "1.3.14"` — because Bun minors
  change the bundler's minified-identifier allocation and therefore emitted chunk content
  hashes. Which is also the migration note: the first rebuild under 1.3.14 renames every
  content-hashed bundle (`app.spa-<hash>.js`, lazy chunks), so a deploy that syncs without
  deleting (rsync sans `--delete`) will retain stale chunks alongside the new ones.
  `install.sh` and the npm package's `bun` dependency follow the pin. The shipped runtime
  also picks up preact 10.29.8 (flushSync batching fix, faster memo/sCU bailouts).
- Syntax highlighting advances flow-syntax to its maintained `zig-0.16` branch: query
  directives no longer mis-evaluate, a crash in `get_cached_query` on tree-sitter-less
  builds is fixed, and Vue and GLSL grammars land alongside `*.S` assembly recognition.
- `docs/images.md` now documents the complete, shipped feature (config reference, `<picture>`
  emission shape, cache/eviction status including the AVIF cache-identity caveat above, the
  silent-filtering-vs-fatal failure split, dev-loop behavior for a newly referenced image on an
  incremental rebuild, and an authoring gotcha for `$image` directives with non-empty link
  text), rather than the partial feature it described while the work was still landing.
  `docs/assets.md`'s derived-image-variants paragraph is updated for the two-codec cache-key
  reality. `docs/migration/astro-to-zigapagos.md` (and its byte-identical mirror under
  `skills/zigapagos-astro-migration/references/`) gains a new §14 mapping Astro's `<Image>` /
  `astro:assets` to `image_optimize`, with the semantic deltas: site-wide widths rather than
  per-image, never-upscale, AVIF requiring an external encoder, and no per-image format
  overrides.
- `docs/migration/astro-to-zigapagos.md` gains the full `paginate()` mapping table
  (`page.data` → windowed `$page.subpages()`, `page.currentPage`/`page.lastPage`/`page.size`/
  `page.total` → `Paginator` fields, `page.url.*` → the link helpers; `page.start`/`page.end`
  have no direct equivalent — compute from `.current` and `.page_size`). Two porting notes:
  Astro's `[...page].astro` is exact URL parity with `plain_dir`, while `[page].astro` puts
  page 1 at `/blog/1` — zigapagos always puts page 1 at the section URL, so add
  `.aliases = ["1/index.html"]` if the old URL must keep working.
- Default hover-prefetch of lazy route chunks is a behavior change for existing SPAs using
  `lazy()`: hovering a `<Link>` to such a route now fetches its chunk before the click. It
  only affects lazy leaves, is connection-guarded, and chunks are documented side-effect-free
  at module scope — set `prefetch={false}` on a `Link` to opt a specific link out.

### Fixed

- The `--format` pre-scan disagreed with the command parsers on a repeated flag: it kept the
  **first** `--format=` value while every accepting parser keeps the **last**, so accepted
  input like `release --format=text --format=json` printed the Debug banner onto what the
  parser then treated as an NDJSON stream — reachable on released builds. The scan is now
  last-wins with the parsers' overwrite semantics, and a trailing invalid value resolves to
  "no format chosen", matching the parser about to fatal on it.
- `doctor --format=json` printed a mid-walk failure (an unreadable subdirectory encountered
  after the walk began) as prose straight onto the machine-readable stream; it now emits
  `ZP_FATAL` NDJSON in JSON mode, with text mode byte-identical.
- The unescaped-attribute defect recorded under **Security** below has a second, entirely
  innocent face: a directive `title` or an image `alt` containing a plain double quote —
  `He said "hi"` — terminated the attribute early and emitted malformed HTML. No malice
  required, just a quotation mark. Both now render as `&quot;`.
- A `$code` directive carrying `attrs` emitted a broken opening tag, in three different ways
  depending on the arm. With a language it wrote no ` class="` and no leading space, so the
  first attr fused onto the tag *name* — `[]($code.asset('x.zig').language('zig').attrs('a'))`
  produced `<prea beta >`, an element called `prea` rather than a `<pre>` with a class. Without
  a language it opened `class="` and never closed it, swallowing the `<code>` child and the
  snippet into the attribute value. And the `=mathtex` arm jammed the attrs onto
  `type="math/tex"`, because the guard meant to open the quote there was unreachable. All three
  now write the same matched open/write/close trio every other directive arm uses.
- `zigapagos init` (without `--from-astro`) previously wrote no `.gitignore` at all, so a
  fresh scaffold left `node_modules/`, `zig-out/` and (as of this change) the image-derive
  cache untracked but unignored.
- `frontmatter.ziggy-schema` had drifted from the frontmatter the build actually accepts: it
  was missing `translation_key` and `Alternative.name`, and still declared an
  `Alternative.title` that no longer exists — editors validating against the schema rejected
  valid fields and accepted a dead one.

### Security

- SuperMD directive metadata is now HTML-escaped everywhere it reaches an HTML attribute
  (issue #148). `src/render/html.zig` printed `title`, `alt`, `id`, `attrs` (rendered into
  `class`), `$link.ref(…)` fragments and the code-fence language with `{s}` — raw — so an
  author-supplied value containing `"` closed the attribute it sat in and could open new ones:
  a `title` of `x" onload="alert(1)` became a real `onload` handler on the emitted element.
  Reachable only by whoever writes the content, so self-inflicted on a single-author site, and
  **not** self-inflicted where content authorship is broader than code authorship — a migrated
  site whose frontmatter came from elsewhere, generated or scripted content, or a repo that
  accepts content contributions. Every such value now goes through `HtmlSafe`, which escapes
  `&`, `<`, `>`, `'` and `"`. URLs are unaffected: `href`/`src` are emitted through `printUrl`
  on its own resolution path, which this change does not touch.
- Dropped the blanket `style-src 'unsafe-inline'` grant, which permitted inline `<style>`
  *element* injection sitewide to cover something narrower (inline style *attributes*). The new
  `style-src-elem` directive is hash-strict with no `unsafe-inline`; the lenient grant is now
  confined to `style-src-attr` alone.
- The declared `preact-render-to-string` range is raised from `^6.6.2` to `^6.7.0`, whose
  attribute serializer rejects unsafe attribute *keys* before namespace normalization
  (preactjs/preact-render-to-string#461). Under 6.6.x a key that looked namespaced but
  contained `>` or spaces was rewritten and emitted — markup injection through prop keys on
  the SSR path that renders every island. Committed lockfiles already resolved 6.7.0, so
  sites built from this repository's locked toolchain were never affected; the raised floor
  closes the window for fresh resolutions (including the published npm package, whose
  dependency ranges derive from this manifest).

### Known limitations

- With `auto_heading_ids` on, a same-page reference through the `$link.ref('slug')` Scripty
  directive still fails with `unknown ref` — SuperMD's own `invalid_ref` check runs inside
  `Ast.init`, before ids can be injected. Plain Markdown links (`[t](#slug)`,
  `[t](/other#slug)`) are validated later and work fine; `$link.unsafeRef('slug')` is the
  workaround for the Scripty-directive case.
- A content-authored `<z-island>` only accepts static props (`:props` Ziggy
  literals and literal `prop-NAME="value"` attributes). `prop-NAME="$page.*"`
  Scripty expressions do **not** resolve in content — Scripty is evaluated by
  SuperHTML at layout render time, and an `=html` fence's body is emitted
  verbatim, never run through SuperHTML's template evaluator. A page-bound
  prop still needs a layout.
- Two documented gaps in the emitted policy, both falling back to the revalidating baseline
  rather than to a wrong header: shared (non-lazy-route) split chunks and `.map` sourcemaps
  are not tracked per-route by the routing manifests, so they cannot be exact-listed as
  immutable; and the fingerprint rule is a name-shape heuristic, not proof `asset_fingerprint`
  is on — the emitter runs over a finished output tree with no site config, so a
  coincidentally fingerprint-shaped filename is marked immutable too. Both artifacts say so
  and show how to drop the line.
- A view transition captures the *immediate* route flip, not the settled page: a guarded
  route's guard and a `lazy()` route's chunk resolve after the transition finishes, so the
  animation lands on the route's `fallback`/skeleton rather than the final content. Waiting on
  that async work would risk the spec's ~4s transition timeout.
- Neither the SPA-side nor the cross-document feature disables itself under
  `prefers-reduced-motion`; the media-query guard is the author's to add.
- **No Windows support** until the Zig 0.17 port. Inherited upstream code
  (`src/cli/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile on
  stable Zig 0.16.0 — `os.windows` has neither `OVERLAPPED` nor `PAGE_READONLY`
  there — and the fix rides upstream's 0.17-dev branch.
- **No FreeBSD binary**, and a source build does not substitute for one: the
  watcher-selection logic compiles the inotify-based `LinuxWatcher` on FreeBSD,
  whose `inotify_init1`/`inotify_add_watch`/`inotify_rm_watch` that target does
  not have, and there is no checked-in Wuffs shim for it under `src/hacks/`.
  Both blockers are recorded against the shipped matrix in `build/release.zig`,
  which is the list to re-add the target to once they are fixed.
- **The emitted host config is only a file until you deploy it.** The build
  writes the hash-strict CSP and the caching policy; serving them — and
  re-serving them after a rebuild, since the CSP hashes are byte-exact — is the
  host's job. As of this release the CSP's one lenient grant is
  `style-src-attr 'unsafe-inline'`, for the framework's inline `style`
  *attributes*; `style-src-elem` is hash-strict like `script-src`.
- **A per-locale `host_url_override` cannot be exercised locally.** `zigapagos dev`
  points ZigBase at one built tree and serves it verbatim on one origin, so a
  multi-host locale set builds correctly but can only be checked as deployed. The
  emitted output is unaffected; this is a preview limitation, not a build one.
- **Prebuilt binaries cover four Unix targets**: `x86_64-linux-musl`,
  `aarch64-linux-musl`, `x86_64-macos` and `aarch64-macos`, each built on its own
  native runner, with `runtime.tar.xz` and `SHA256SUMS` beside them. arm64 archives
  start at `v0.3.0` — earlier tags are x64-only, and `v0.1.0` predates prebuilt
  binaries entirely. Any other host still needs a source build.
- **AVIF needs an encoder you already have.** `image_optimize.avif_encoder` invokes an
  external `avifenc`-compatible binary; Zigapagos never vendors or downloads an AV1 encoder,
  and with no encoder configured a build emits WebP and the original only.
- Pre-1.0: APIs may change between minor versions.

### Internal

- `tests/skills/sync.sh` turns drift between `skills/zigapagos-astro-migration/references/*`
  and the canonical `docs/migration/*` into a red test (the reference copies must be
  byte-identical — an installed skill is self-contained), and checks the agentskills.io
  frontmatter invariants plus the progressive-disclosure line budget on `SKILL.md`.
- Four new shell gates cover the JSON surfaces and the scaffold, each verified to fail against
  the pre-change binary.
- `tests/rendering/attr-escaping.sh` pins the whole class per attribute name rather than per
  call site, so one directive arm regressing cannot hide behind another still passing, and was
  verified to fail against the pre-fix renderer. Its fixture uses Markdown's angle-bracket
  destination form (`[text](<$directive…>)`): a bare destination ends at the first double
  quote, so a quote-carrying payload would not parse as a directive at all and the test would
  have proved nothing.
- `ReleaseFast` is now confined to the published release matrix (`build/release.zig`); build
  and test tooling is Debug (issue #63). The snapshot suite's `camera` helper was built
  `ReleaseFast`, and `build/config.zig` still carried a commented-out
  `.preferred_optimize_mode = .ReleaseFast` left over from the consumer build API that #108
  removed. The measurement behind it, taken on this repo's own site with isolated caches: a
  cold Debug build is 29s against ReleaseFast's 96s (link alone, 3s against 58s) and produces
  **byte-identical output** — so the optimization was buying nothing a contributor can
  observe except the wait.
- `build.zig.zon` drops `lsp_kit` and `translate_c`, inherited from upstream's LSP build
  and consumed by nothing; `scripts/rescue-codeberg.sh` now warms the one remaining
  Codeberg-hosted pin (SuperMD's transitive translate-c) and was verified against a fresh
  cache under strace: zero Codeberg DNS queries or connections from warm through
  `zig build --fetch`, and the warmed cache resolves fully offline.
- CI workflow actions are unified on current majors (upload-artifact v7, download-artifact
  v8, setup-node v7 — clearing the fall-2026 Node 20 runner removal), and Dependabot now
  ignores jdx/mise-action minors/patches, whose tagging scheme otherwise makes it propose
  stale concrete pins against the moving `@v4` tag (PR #125's `@v4.2.3` while `v4` already
  pointed at 4.2.4).
- happy-dom moves to 20.11.2 (MutationObserver callbacks no longer silently die after a
  GC — the flaky-test kind of latent bug), and the site/ and examples/tsx-site lockfiles
  are regenerated pinned to `configVersion: 0`, keeping Bun's hoisted linker so the
  props-check gate's website-root `tsc` resolution cannot silently flip layouts.
- Two allocator defects surfaced by the new tests and fixed alongside: `migrate.zig`'s
  `buildReport` returned an `Allocating` buffer *view* that panics with "Invalid free" under
  the debug allocator once a caller frees it, and `scanDir` leaked one joined-path allocation
  per directory level.

## [0.3.0] - 2026-08-02

### Added

- Publish native arm64 release archives for Linux and macOS, with matching npm
  packages and shell-installer support. Apple Silicon and Linux arm64 installs
  now receive binaries built and exercised on their native runner architecture.
- `zigapagos release --summary`: after a build, print on stdout an inventory of the files it
  emitted, grouped by category — pages, page aliases and alternatives, page assets, site
  assets, build assets, SPA shells, SPA routing manifests and the SPA 404 fallback. Every entry
  is recorded where the file is written, and `tests/summary/summary.sh` compares the printed set
  against the emitted tree, so the report cannot describe a tree the build did not produce. A
  build with rendering errors prints a one-line refusal instead of an inventory — on stdout too,
  so `--summary >file` answers on the same stream whatever the build's outcome.
- A shell installer, `curl -fsSL https://valthon.github.io/zigapagos/install.sh | sh`, now the
  headline install method on the README and the download page. It installs a **complete**
  zigapagos — the binary, the `@z/runtime` tree it renders islands and SPAs through, and Bun and
  ZigBase when the host has neither — under `~/.local/share/zigapagos`, with a generated launcher
  in `~/.local/bin`. No `sudo`, no edits to shell startup files, and nothing written until each
  download has been verified against the release's published SHA-256 sums. It is idempotent: a
  second run installs alongside the first and repoints the launcher. `--version`, `--prefix`,
  `--bin-dir`, `--no-bun` and `--no-zigbase` cover the rest. Windows hosts are refused with the
  same wording the npm package uses, rather than being given an emulated build that looks native.
- A `runtime.tar.xz` release asset: the `@z/runtime` tree with its dependencies vendored. This is
  what makes an install outside npm able to render an island at all — the per-target archives
  carry the binary alone, and the sidecar, bundlers and slicers are scripts inside that tree. It
  is staged by the same code that stages npm's copy (`npm/stage-runtime.mjs`), so the two
  channels ship the same files by construction.
- **`zigapagos release` builds the per-site islands runtime slice.** The second
  pass over the built island bundles (`/islands/_runtime.js`) used to run only
  as a build-graph step, so a toolchain-free build silently shipped the full
  shared runtime to every island page.
- **`zigapagos release` emits host config and the strict-CSP artifacts.** The
  per-namespace server config (`.spa` marker + `zigbase.static_routes.zig`,
  `nginx.nginx.conf`, `.htaccess`) and the site-wide `csp.{nginx.conf,apache.conf,zigbase.txt}`
  are written over the finished output tree. Every npm-path build until now
  shipped a tree with neither, which loses SPA deep-link fallback and serves a
  CSP that blocks the site's own inline import map.
- `zigapagos release --source-maps`, replacing `Options.source_maps`. Still
  opt-in and off by default.
- **`docs/runtime-dependencies.md`** — what the standalone binary needs at run
  time, stated once instead of inferred. A table covering every command and the
  external programs it requires; when `zigapagos release` actually needs Bun
  (the condition is the *configuration*, not whether the site has islands — with
  `ZIGAPAGOS_RUNTIME_DIR` set, a site with none still spawns the sidecar); how
  the pinned ZigBase is resolved, cached and fetched, including the `curl` and
  `tar` the fetch shells out to; and what each distribution supplies. Notably:
  a release archive carries the binary alone, so islands and SPAs built from one
  need an `@z/runtime` tree pointed at by `ZIGAPAGOS_RUNTIME_DIR` — `@z/runtime`
  is `private: true` and cannot be installed from npm on its own.
- `tests/meta/runtime-deps-doc.sh` checks that page against the sources every
  claim came from: the command table against `src/main.zig`'s `Command` enum,
  the ZigBase pin and cache path against `src/cli/zigbase.zig`, the environment
  variable against `src/cli/release.zig`, `@z/runtime`'s privacy against
  `runtime/package.json`, the binary-only release archive against
  `build/release.zig`, and every flag the page names against the file that
  parses it.

### Changed

- Build the x86_64 macOS archive natively on `macos-15-intel` instead of
  cross-compiling it on an arm64 `macos-latest` runner.
- Release and development builds now share the checked-in Wuffs translation
  shims instead of release builds invoking `zig translate-c`. This removes a
  hand-maintained divergence and avoids the Zig 0.16 translation crash that
  blocked native arm64 artifacts.
- `docs/runtime-dependencies.md`'s distribution table gains an `install.sh` column, and its
  gate (`tests/meta/runtime-deps-doc.sh`) gains a rule that fails the build if that column
  ever describes a script or an asset that no longer exists.
- `zigapagos init` now scaffolds only the frontmatter a page needs. `.author`
  and `.draft` are gone from every template and `.date` remains only on the blog
  posts and devlog years whose listing layouts render one — `.title` and
  `.layout` are the only required fields, and the scaffold no longer models the
  optional ones as obligatory. The sample homepage and the quick start now say
  which fields have defaults.
- `zigapagos migrate --help` now states outright that the command converts
  nothing: it reads the Astro project, writes a `MIGRATION.md` worklist, and
  the port itself is manual — `--scaffold` being the one exception, and only
  for islands. The README bullet and the site's overview page said or implied
  otherwise.
- **`zigapagos dev` is zero-config.** Run it in a site directory with no
  arguments and it works:
  - `--site` defaults to `public`, the same directory a bare `zigapagos release`
    writes to;
  - the rebuild command defaults to *this binary's* own `release`, resolved by
    absolute path rather than by name on `PATH`, so an npm install and a
    downloaded release tarball both work (it was `zig build`, which named a
    toolchain a standalone user never installed);
  - the island/SPA source directories to watch are derived from the entries
    `release` discovers, so a component edit rebuilds without `--watch-dir`;
  - a missing `zigbase` is fetched from the pinned release into the cache
    (SHA256-verified) instead of failing with instructions. `--no-download`
    restores the previous behaviour for offline machines and for CI that pins
    its own binary. `zigapagos e2e` is unchanged: it still fetches only on
    `--download-zigbase`, because an unannounced network fetch in CI is a
    surprise rather than a convenience.
- `zigapagos init` now points a new site at `zigapagos dev` rather than at the
  bare command.

### Removed

- **The bundled live server is gone**, along with its `--proxy` reverse-proxy
  mode, the `serve` and `server` subcommands, and the bare-command entry point
  that started it (issue #56). `zigapagos` is a standalone executable, and a
  standalone executable has no default action: run bare it now prints its help
  and exits 0, which is what `npx zigapagos` does too. An argument that names no
  command prints the same menu and exits non-zero.
- **The consumer zig-build API is gone.** `zigapagos.website()`, `zigapagos.e2e()`
  and `zigapagos.dev()`, the option types (`Options`, `Island`, `Spa`,
  `BuildAsset`, `E2eOptions`, `DevOptions`) and the whole `build/` half that
  served them no longer exist. A site is built by RUNNING the `zigapagos`
  binary; `zig build` builds zigapagos itself and nothing else. Nothing in a
  zigapagos project needs a Zig toolchain, a `build.zig`, a `build.zig.zon` or a
  `.path` dependency on this repository any more.

  The replacements, all of which already existed:

  | was | now |
  |---|---|
  | `zigapagos.website(b, .{ .islands = …, .spas = … })` | `zigapagos release --island=SRC --spa='SRC\|BASE'` |
  | `zigapagos.e2e(b, opts, .{})` + `zig build e2e -- CMD` | `zigapagos e2e --site=DIR -- CMD` |
  | `zigapagos.dev(b, opts, .{})` + `zig build dev` | `zigapagos dev` |
  | `Options.source_maps = true` | `zigapagos release --source-maps` |
  | `Options.not_found` | `--spa-not-found=NAME` |
  | `Options.build_assets` | `--build-asset=NAME PATH [--install=P \| --install-always=P]` |

- `zigapagos release --spa-chunks=` and `--spa-slice=` are removed. They existed
  to hand `release` bundles the build graph had already produced; it now builds
  them itself.
- `zigapagos init --from-astro --zigapagos-path` is removed with the
  `build.zig.zon` it filled in. The importer scaffolds a `build.sh` instead.

### Fixed

- `zigapagos release` now honours `ZIGAPAGOS_HOT_ISLANDS`, passing `--hot` to
  the island bundle driver when it is set. Nothing on the `release` path read
  the variable `zigapagos dev` sets, so a dev rebuild produced non-hot island
  bundles and an island hot-swap silently reset every `useState` instead of
  preserving it.
- A CLI report no longer overwrites the command's own stderr when both streams are redirected
  to one file (`cmd >f 2>&1`). `explain`, `doctor`, `validate` and `migrate --doctor` built
  their buffered stdout writers with `Io.File.writer`, which writes positionally from an offset
  of its own, so the end-of-command flush landed on top of bytes stderr had already committed —
  silently corrupting the merged output. They now use `writerStreaming`.
- **Island bundles are minified.** The build graph passed `--minify` to the
  shared runtime, both runtime slicers and every SPA bundle, and to islands
  alone did not. The four islands on this project's own marketing site shrink
  from 4113 to 2094 bytes.
- **The island-sidecar spawn diagnostics no longer send you to a `build.zig`
  that does not exist.** All three ENOENT messages ended by pointing at the
  consumer build API's `.islands` table, which is gone; they now name the flag
  that actually configures each input (`--bun`, `--island-sidecar`,
  `--island-src-dir`) and `ZIGAPAGOS_RUNTIME_DIR`. The interpreter message also
  claimed bun alone cannot enable islands on a toolchain-free install "because
  the sidecar script and `@z/runtime` come from that Zig build integration" —
  false for the npm path, which ships both, and true only of a release archive.
- **The README no longer claims a release archive "gets you the same thing" as
  the npm channel.** It does not: the archive is the binary alone, so it has
  neither Bun nor the `@z/runtime` tree that islands and SPAs need. The
  quick-start's "a plain content site needs neither it nor Bun" was ambiguous
  in the same direction — setting `ZIGAPAGOS_RUNTIME_DIR` is exactly what makes
  a content-only build require Bun, and `npx zigapagos` always sets it.
- A failed island-sidecar spawn now names the input that is actually missing. A `bun` that is
  not on `PATH` previously produced `failed to spawn island sidecar (bun …/render.ts):
  FileNotFound`, which reads as "render.ts is missing" about a path that resolves; the
  interpreter, the sidecar script and the island source dir are now reported separately, each
  with the fix for that specific case.
- The changelog's own description of what `zigapagos version` prints. It documented
  `git describe`'s raw `v0.1.1-<n>-g<sha>` spelling, which `build/config.zig` never
  emits — it reformats that into a `v`-prefixed semver version
  (`v0.2.0-dev.7+e1d7033`) — and the paragraph is published as the site's changelog
  page. All three shapes the binary can actually print are now listed, and
  `tests/changelog/version-shape.sh` fails the build if the list and the emitter
  disagree.
- `zigapagos dev` no longer risks a crash or invalid free when overlapping watched
  directories refer to the same path with different spellings. Allocation failures and
  malformed input also fail cleanly instead of leaking or indexing out of bounds.

### Known limitations

- With `auto_heading_ids` on, a same-page reference through the `$link.ref('slug')` Scripty
  directive still fails with `unknown ref` — SuperMD's own `invalid_ref` check runs inside
  `Ast.init`, before ids can be injected. Plain Markdown links (`[t](#slug)`,
  `[t](/other#slug)`) are validated later and work fine; `$link.unsafeRef('slug')` is the
  workaround for the Scripty-directive case.
- A content-authored `<z-island>` only accepts static props (`:props` Ziggy
  literals and literal `prop-NAME="value"` attributes). `prop-NAME="$page.*"`
  Scripty expressions do **not** resolve in content — Scripty is evaluated by
  SuperHTML at layout render time, and an `=html` fence's body is emitted
  verbatim, never run through SuperHTML's template evaluator. A page-bound
  prop still needs a layout.
- **No Windows support** until the Zig 0.17 port. Inherited upstream code
  (`src/cli/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile on
  stable Zig 0.16.0 — `os.windows` has neither `OVERLAPPED` nor `PAGE_READONLY`
  there — and the fix rides upstream's 0.17-dev branch.
- **No FreeBSD binary**, and a source build does not substitute for one: the
  watcher-selection logic compiles the inotify-based `LinuxWatcher` on FreeBSD,
  whose `inotify_init1`/`inotify_add_watch`/`inotify_rm_watch` that target does
  not have, and there is no checked-in Wuffs shim for it under `src/hacks/`.
  Both blockers are recorded against the shipped matrix in `build/release.zig`,
  which is the list to re-add the target to once they are fixed.
- **Strict CSP requires deploying the emitted header.** The build writes the
  hash-strict policy, but serving it (and re-serving it after a rebuild, since the
  hashes are byte-exact) is the host's job. `style-src` still needs
  `unsafe-inline` for the framework's inline `style` attributes.
- **A per-locale `host_url_override` cannot be exercised locally.** `zigapagos dev`
  points ZigBase at one built tree and serves it verbatim on one origin, so a
  multi-host locale set builds correctly but can only be checked as deployed. The
  emitted output is unaffected; this is a preview limitation, not a build one.
- **Prebuilt binaries cover four Unix targets**: `x86_64-linux-musl`,
  `aarch64-linux-musl`, `x86_64-macos` and `aarch64-macos`, each built on its own
  native runner, with `runtime.tar.xz` and `SHA256SUMS` beside them. arm64 archives
  start at this release — earlier tags are x64-only, and `v0.1.0` predates prebuilt
  binaries entirely. Any other host still needs a source build.
- Pre-1.0: APIs may change between minor versions.

### Internal

- CI now builds its reusable `zigapagos` binary for the architecture's baseline CPU instead
  of the build runner's native CPU. A runner with AVX-512 produced an artifact whose
  `compiler_rt.memcpy` executed AVX-512 unconditionally on unrelated downstream runners;
  hosts without that feature raised SIGILL, and a signal on a render worker could leave the
  main thread waiting forever. The artifact gate now rejects host-width YMM/ZMM memcpy code.
- Contributors blocked by a Codeberg outage can run `scripts/rescue-codeberg.sh` to
  verify and warm the exact pinned `translate-c` packages from GitHub before retrying
  their normal build.
- `site/scripts/md-to-smd.ts` no longer rewrites link targets inside **inline** code spans.
  It already left fenced blocks alone, but a link-shaped string between backticks in a
  paragraph was rewritten like a real link — silently, in both directions: a published
  target became a `$link.page(...)` directive the author never wrote, and an unpublished one
  became a bare GitHub URL with no marker at all. The second row was live on this site's own
  changelog page, where a sentence about the `![](…)` content directives published a link to
  `https://github.com/valthon/zigapagos/blob/main/…`. Spans are now split per CommonMark (a
  run of N backticks closes on the next run of exactly N) and only the prose between them is
  rewritten; `slugifyHeading` unwraps spans the same way, so a multi-backtick span in a
  heading no longer leaves its padding spaces behind as an extra hyphen in the anchor (#66).
- A fence language is looked up in `fenceLangRemap` with `Object.hasOwn` rather than a raw
  index, so a fence tagged `constructor`, `toString`, `valueOf`, `hasOwnProperty` or
  `__proto__` is a miss instead of resolving through `Object.prototype` and splicing a
  stringified function into the mirror's language slot. The module is documented as
  copy-me code taking a caller-supplied table, and the caller supplying it is exactly the
  person who cannot see the lookup (#67).
- npm publishing authenticates with **OIDC trusted publishing** instead of a stored
  registry credential. Each package names `valthon/zigapagos` + `release.yml` as its
  trusted publisher on npmjs.com, and the `publish-npm` job exchanges the OIDC identity
  GitHub mints for the run for a short-lived registry token — so the right to publish
  belongs to that one workflow rather than to a credential anything able to read it
  could use. The job's guard that *failed* when `NPM_PUBLISH_ENABLED` was set but no
  stored credential was configured went with it; against a repository that deliberately
  has none, that guard would have failed the next tag. The `NPM_PUBLISH_ENABLED` arming
  switch is unchanged.
- The publish job installs and asserts `npm >= 11.5` before uploading anything. OIDC
  trusted publishing is an npm 11.5 feature and `node-version: 24` does not imply it —
  node 24.2.0 bundles npm 11.3.0, and 24.5.0 was the first with 11.5.1 — so an older
  npm would have failed as a bare authentication error partway through a
  dependency-ordered publish.
- `tests/meta/npm-oidc.sh` pins the publishing job's shape: `publish-npm` must keep
  `id-token: write` — without it GitHub mints no identity and OIDC has nothing to
  exchange — and both gating conditions. The job runs only on a `v*` tag, so without a
  gate these are properties nothing tests until a release.
- The published-release smoke workflow now also installs `zigapagos@<version>` from npm
  on each platform and runs it. The archives it already checked cannot show a platform
  package that was never published, or an `optionalDependencies` resolution that yields
  an install with no binary in it.
- Release CI now warms the exact pinned `translate-c` packages from Zig's official
  GitHub archive before resolving the dependency graph. This avoids persistent
  Codeberg protocol failures on GitHub-hosted runners; content hashes and a
  resolved-graph gate ensure the mirror cannot silently supply different or stale
  dependency bytes. Only dependency fetching is retried, while compilation runs once.

## [0.2.0] - 2026-07-30

### Added

- **npm distribution.** `npx zigapagos` now scaffolds, serves and builds a content
  site with no Zig toolchain. Three packages, released together at
  `build.zig.zon`'s version: `@zigapagos/cli-<platform>` carrying the prebuilt
  binary, `@zigapagos/cli` (canonical) resolving the right one at run time through
  `optionalDependencies`, and the unscoped `zigapagos` as a thin alias so `npx
  zigapagos` works. Prebuilt for macOS x64 and Linux x64 — the two targets
  `build/release.zig` ships. Every other host is refused with the reason rather
  than the bare fact, and arm64 (macOS or Linux) is refused rather than served the
  x64 binary: `npm install` fails with `EBADPLATFORM` because the launcher packages
  declare the `os`/`cpu` they have binaries for, so an unsupported host cannot end
  up with an install that looks clean and has no binary in it. **Everything builds
  from `npm i zigapagos` alone** — content, islands, native SPAs and `zigapagos dev`:
  `@zigapagos/cli` ships the `@z/runtime` sources and the Bun SSR sidecar, and
  declares `bun`, `typescript` and `@zigbase/server` as *optional* dependencies, so
  the tools it shells out to are installed rather than asked for. npm puts
  `node_modules/.bin` on `PATH`, and the launcher appends it to the child's, so the
  zigbase locator finds the server with no flag, no global install and nothing
  downloaded. `--omit=optional` still builds; it loses `dev`'s server and the SPA
  runtime slice. The remaining difference from a Zig build is caching, not
  capability. The published READMEs say so. See `npm/README.md`.
- The zigbase dependency is the **scoped** `@zigbase/server`, at exactly the
  `pinned_version` in `src/cli/zigbase.zig` (currently ZigBase `v0.12.0`) — the same
  release `--download-zigbase` fetches, so `zigapagos dev` runs one zigbase however
  it was installed. `npm/check-toolchain.mjs` fails the build if those two ever
  disagree.
- `zigapagos doctor [DIR]`: audits a BUILT output tree (default `public`, read-only — never
  builds, never touches site source) for authoring mistakes that are only visible in the final
  emitted HTML. Ships two checks: `abs-url-meta` (a root-relative Open Graph / Twitter / canonical
  URL — crawlers can't resolve it, so this is an `error`) and `dangling-internal-link` (a
  root-relative `href`/`src` with no file behind it in the tree, including under `--url-prefix` —
  a `warn`, since a client-routed SPA route legitimately has no file). Exit code: any `error`
  finding, or a file doctor could not read, exits non-zero; `warn`-only findings exit 0 unless
  `--strict` is passed.
- `zigapagos validate [OPTIONS]`: a fast, in-memory subset of `zigapagos release`'s checks (issue
  #45). Parses and analyzes the site — frontmatter/Ziggy schema, SuperMD parse, layout resolution,
  content-side `$link.page`/asset references, output-URL collisions, template SuperHTML/Scripty
  parse, the `:` directive lint, and template RENDER errors (a failing Scripty expression, a
  `$site.page(...)` naming no page) — WITHOUT bundling islands, spawning the Bun sidecar, or
  writing an output tree. It does not cover island SSR, the typed island props check, SPA route
  enumeration/spec checks, asset installation, or CSS minification — those stay `release`-only, so
  a green `validate` is a subset guarantee, not a green `release`. Measured (this repo's
  `examples/tsx-site`, warm caches): a content-only edit loop goes from `zig build`'s ~2s to
  `validate`'s ~0.02–0.03s — and unlike `zig build`, `validate` needs no `bun`, `node_modules`,
  `build.zig`, or consumer build graph, and never writes the output tree.
- `zigapagos explain <route>`: resolves one output route to its content source, layout `extends`
  chain (for a route that is one of a page's `alternatives`, that alternative's OWN layout, not the
  page's), effective frontmatter (after schema defaults), islands (as declared in the markup, not
  SSR-verified), page-owned assets (referenced vs. pruned), and EMITTED PATHS relative to the
  output directory (issue #47). Runs the same kind of fast in-memory build as `validate`. Content
  routes only — a memory build never prerenders SPAs, so a client-routed SPA route is not covered;
  the miss message says so.
- `zigapagos languages`: lists every code-fence language registered for syntax
  highlighting.
- `zigapagos release --format=json` emits build diagnostics as NDJSON on stderr — one
  minified JSON object per line, `{"code","severity","file","line","col","message","help"}`
  — instead of the historical multi-line prose. The consumer this is for is an unattended
  agent: it can now tell *which* diagnostic fired without pattern-matching English. Default
  is `--format=text` and text mode is byte-for-byte unchanged.
- The diagnostic `code` is the stability guarantee; `message` and `help` explicitly are not.
  `src/diag-codes.frozen` is the append-only ledger that makes that a gate rather than a
  promise — a code is never renamed and never reused for a different meaning after
  retirement, enforced against the enum on every build.
- `zigapagos explain-code <CODE>` prints the long form of any code: what condition produced
  the diagnostic and what to change in the source. `zigapagos explain-code` with no argument lists
  every registered code with a one-line summary. Every code is required by the compiler to
  have both, so the listing cannot go stale relative to what the build emits.
- The two `:` directive lints get one code each rather than a shared one —
  `ZP_TEMPLATE_ELSE_DIRECTIVE` and `ZP_TEMPLATE_BRANCHING_WITHOUT_END_TAG` — because they
  are unrelated failures with unrelated fixes and `code` is what a consumer switches on.
- `docs/diagnostics.md` is the consumer contract: the wire schema, what is and is not
  stable, and an explicit inventory of what is *not* converted and why — including the
  rule that matters most, **skip a stderr line that does not parse as JSON rather than
  failing the run**, since the Bun sidecar and the usage-menu path legitimately write
  prose to the same stream.
- Islands can now be embedded directly in `.smd` content, not only in
  layouts: inside a fenced code block whose fence info is `=html` (SuperMD's
  existing validated raw-HTML escape hatch), use the hyphenated
  `<z-island src="…" client:load :props='…'></z-island>` spelling — the
  islands pass treats it identically to `<island>` in a layout (SSR,
  `data-z-props`, the import map, the runtime script, the `tsc` props gate,
  and the dev island-usage manifest all apply unchanged). The hyphen is
  required: superhtml's `.html`-mode validator (used to vet the fence body)
  rejects a non-hyphenated custom element name per the HTML spec, unlike the
  lax `.superhtml` layout mode where `<island>` has always worked. See
  `docs/islands.md`, "Islands in content (`.smd`)".
- Opt-in `auto_heading_ids` site setting (`Site`/`MultilingualSite` in `zigapagos.ziggy`):
  injects a GitHub-compatible slug `id` into every heading that doesn't already carry an
  explicit `$heading.id(...)`/`$section.id(...)`, so a same-page `#anchor` or cross-page
  `/page#anchor` link written against a doc's existing GitHub rendering keeps working
  without hand-writing an id on every heading. Off by default; an explicit id always wins
  and is never overwritten. See `docs/migration/astro-to-zigapagos.md`'s "Heading anchors:
  `auto_heading_ids`" section.
- `$site.asset(...).absLink()` / `$page.asset(...).absLink()`: like `link()`,
  but always returns an absolute URL (`host_url` + `url_path_prefix` + asset
  path), and installs the asset the same way `link()` does. Use it for URLs
  consumed outside the page itself — `og:*`/`twitter:*` meta tags, canonical
  links, feeds — since `link()`'s output is root-relative and scrapers do not
  resolve those (#25).
- `.asset_fingerprint = true` in `zigapagos.ziggy` installs every *linked* site asset under a
  content-hashed filename (`assets/style.css` → `/style.a1b2c3d4.css`), and every seam that
  prints a site-asset URL — `.link()`/`.absLink()`, the `![](…)` content directives, and
  `spa.head` hrefs — resolves to that name through one shared formatter, so an installed file
  and a link to it cannot drift apart. A changed file is a changed URL, which is what lets a
  deploy put `Cache-Control: immutable` on the asset tree. Opt-in and release-only;
  `static_assets` entries, build assets, page assets and the in-memory live server keep verbatim
  names. See `docs/assets.md`.
- `--allow-missing-pages` (`zigapagos release` and the live server; for a `zigapagos dev`
  loop set `allow_missing_pages` in your `build.zig`, since `dev` re-runs your rebuild
  command rather than building the site itself — the tolerance is identical either way,
  so a green dev preview and a CI release agree):
  tolerate a `$link.page`/`$link.sibling`/`$link.sub` (content) or
  `$site.page(...)` (template) reference to a page that doesn't exist YET, instead of
  hard-failing the build. The reference renders as the real, `url_prefix`-aware `href`
  the target page will have once it's written (a 404 until then), and the build log gets
  a warning naming the ref and the computed href instead of a fatal error. This is the
  fix for incremental authoring: previously, adding a navigation link before its target
  page existed broke the *entire* build (one dangling link → zero pages built), which is
  exactly what "site under construction" always looks like.
- A relative `.aliases` entry that basenames as `404.html`, `robots.txt`, or `sitemap.xml`
  now prints a build-time warning showing where it actually resolves. Alias resolution
  itself is unchanged — a relative entry still joins to the page's own output directory,
  exactly as before; this only flags the common mistake of meaning a site-wide override
  (e.g. `"/404.html"` to replace the SPA fallback) but writing the bare relative form
  instead.
- A layout route now receives its matched child as a `children` prop as well as
  through `<Outlet/>` — the two are the same channel (`children` *is* an
  `<Outlet/>`), so a layout written as `<div>{children}</div>` renders its child
  instead of an empty container. Rendering both warns, and so does rendering
  neither.
- `zigapagos` warns at build time when a SPA declares no `spa.head` on a site
  that has stylesheet assets, since SPA shells have a fixed `<head>` and do not
  inherit site styles. `head: []` declares the omission deliberate and silences
  it.
- `docs/generated-content.md`: documents the generated-content pattern this site's own
  docs pages use as a copyable recipe (a registry, a deterministic generator, per-file
  `.gitignore` entries, and a freshness gate), instead of a built-in `content_generators`
  config hook. The verdict on #34 is that a hook would only automate the cheap part
  (invoking a script); the actual cost is the five SuperMD transformations a generator has
  to apply, which are documented here in full instead.

### Changed

- `:else` is now a build error. SuperHTML validates it at parse time and then never
  evaluates it — the renderer null-unwraps its (mandatorily absent) value, so no template
  using `:else` has ever rendered. The error names the fix: write the negated condition on
  a second `<ctx>`, `<ctx :if="$cond">…</ctx><ctx :if="$cond.not()">…</ctx>`.
- `:if` / `:loop` on an element with no end tag — a void element like `<img>`, `<br>`,
  `<input>`, or a self-closing `<item/>` in an `.xml` alternative layout — is now a build
  error. SuperHTML restarts a conditional or a loop by rewinding to the element's end tag;
  with none it rewinds to the start of the file and splices the **whole raw template
  source** into the page (previously with exit code 0), or slices backwards and panics.
  The error names the fix: wrap the element in `<ctx>`.
- A `<Link>` rendered outside a `<Router>` is now a build error rather than a
  silently dead anchor: without router context the href cannot resolve against
  the SPA base and the click is never intercepted, so the prerendered shell
  shipped a link that 404s on a path-prefixed host. On the client the same
  situation warns once per href instead of throwing. Use a plain `<a>` for a
  non-router anchor.
- The build error for a dynamic route with no `skeleton` now names the concrete
  pathname the shell is prerendered at.

### Fixed

- `absLink()` on a multilingual site returned a root-relative URL for page
  assets (`$page.asset(...)`). It is now absolute in every locale, and stays
  correct across locales too: `$page.locale('de').asset(...).absLink()` emits
  the target locale's host exactly once, including when that locale sets
  `host_url_override`.
- On a multilingual site whose locale sets `host_url_override`, a site asset
  linked with `link()` lost the separator after `assets_prefix_path` and came
  out as `https://example.com/staticfoo.css` (or `https://example.comfoo.css`
  with no prefix). This affected `link()` on those sites before `absLink()`
  existed, and is fixed for both.
- A full build now names the site assets it pruned. An asset installs only when something bumps
  its refcount, and everything else was dropped in silence — a hand-authored SVG vanished from a
  build when its last `.link()` went away, and finding out why meant reading the refcount logic.
  The report is a sorted, capped list with the true total and both fixes spelled out. It stays a
  warning, since staging a file ahead of the page that will use it is legitimate, and it is
  suppressed wherever it would fire on correct code: incremental rebuilds, a build whose render
  pass failed, assets consumed by `.bytes()`/`.size()`/`.sriHash()`/`.ziggy()`,
  `.keep`/`.gitkeep` placeholders, and an `assets_dir_path` that doubles as a content dir.
- A content directory that holds `.smd` pages but no `index.smd` now produces a build-log
  warning. Such a directory never becomes a section, so its pages join the enclosing
  section with deeper URLs, no page is built at the directory's own URL, and
  `$page.subpages()` aimed at it returns an empty list — which previously looked like
  "my section is empty" with nothing pointing at the cause. The warning names the
  directory, the URL that is not built, and the `index.smd` to create; when a sibling
  `<dirname>.smd` already occupies that URL it says so, since that is the usual shape of
  the mistake. It is a warning, not an error: an index-less directory is a legitimate
  URL-shaping tool.
- An unknown code-fence language (e.g. a typo like ` ```zig++ `) is now a build-log
  WARNING instead of a fatal error. The fence still renders — as escaped, unhighlighted
  text, the same output `enable_treesitter=false` already produces for every language —
  and the warning includes a did-you-mean suggestion when one is available (run
  `zigapagos languages` to see the full registered list).
- A `$link` reference starting with a leading `.` (SuperMD's syntax for "subpage of this
  section") that fails because the current page isn't a section now includes a note
  clarifying that a leading `.` means "subpage of this section", not a relative path, and
  points at `$link.page(...)` for linking a sibling page instead.
- `$link.page('')` — which looks like it should work, because `$site.page('')` accepts an
  empty ref for the homepage — now fails with a note pointing at `$link.site()`, the
  correct builtin for linking to the site's homepage, instead of just SuperMD's bare
  "path is empty".
- Under `--format=json`, a `fatal.msg` no longer aborts a Debug build with SIGABRT: it
  emits one `ZP_FATAL` object and exits 1. The `std.Progress` bar and the
  Debug/tracy/tsan warning banners are suppressed in that mode too, since all three write
  to the same stderr the NDJSON stream uses.
- The site's `url_path_prefix` is now composed into `Router.base` in both
  environments, so a path-prefixed deploy (a GitHub project-pages site) emits
  prerendered `<a href>` values that carry the prefix, works without JavaScript,
  and soft-navigates to a URL that survives a hard refresh. The prefix reaches
  the build's SSR pass over the sidecar protocol and the browser over a
  `data-z-prefix` attribute on the shell's hydration root, so the two can never
  disagree. Sites with no `url_path_prefix` are unaffected, byte for byte.
- `zigapagos serve` prefixes the SPA bundle and runtime URLs it bakes into dev
  shells, which its own request handler already required.
- An island's SSR pathname (`host.pathname()`, `useLocation()`) now carries the
  site's `url_path_prefix`, matching what the browser reports. An island that
  branches on the path — active-nav highlighting, breadcrumbs — used to render
  one thing at build time and another after hydration.
- The generated nginx, Apache and ZigBase host configs now account for a site's
  `url_path_prefix`, each according to its own semantics rather than by
  prepending the prefix everywhere: nginx prefixes its `location` selectors and
  `try_files` targets; Apache emits a `RewriteBase` and keeps its per-directory
  patterns relative; ZigBase prefixes its `.match` patterns but leaves `.serve`
  targets pointing at the output tree, which has no prefix directory.
  `routing-manifest.json` carries the prefix as its own `url_path_prefix` field
  for them to apply — its route values stay tree-relative.
- The migration guide now spells out the three separate `:if` traps, including the one
  that is still legal and still surprising: `:if` on a real element gates only its BODY,
  so the tag and **every one of its attributes** are emitted either way (this is how a
  documentation sidebar shipped `aria-current="page"` on all 14 nav items with a green
  build). Wrap the element in `<ctx>` to make the element itself conditional.

### Known limitations

- With `auto_heading_ids` on, a same-page reference through the `$link.ref('slug')` Scripty
  directive still fails with `unknown ref` — SuperMD's own `invalid_ref` check runs inside
  `Ast.init`, before ids can be injected. Plain Markdown links (`[t](#slug)`,
  `[t](/other#slug)`) are validated later and work fine; `$link.unsafeRef('slug')` is the
  workaround for the Scripty-directive case.
- A content-authored `<z-island>` only accepts static props (`:props` Ziggy
  literals and literal `prop-NAME="value"` attributes). `prop-NAME="$page.*"`
  Scripty expressions do **not** resolve in content — Scripty is evaluated by
  SuperHTML at layout render time, and an `=html` fence's body is emitted
  verbatim, never run through SuperHTML's template evaluator. A page-bound
  prop still needs a layout.
- **No Windows support** until the Zig 0.17 port. Inherited upstream code
  (`src/cli/serve/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile on
  stable Zig 0.16.0, and the fix rides upstream's 0.17-dev branch.
- **FreeBSD needs 15 or newer** for live reload: the watcher reuses the
  inotify-based `LinuxWatcher`, and inotify entered the FreeBSD base system in 15.
  There is no kqueue backend. Building and serving static output is unaffected.
- **Strict CSP requires deploying the emitted header.** The build writes the
  hash-strict policy, but serving it (and re-serving it after a rebuild, since the
  hashes are byte-exact) is the host's job. `style-src` still needs
  `unsafe-inline` for the framework's inline `style` attributes.
- `host_url_override` on a locale is not supported by the live server.
- **Prebuilt binaries cover x64 only.** GitHub Releases ship an
  `x86_64-linux-musl.tar.xz`, an `x86_64-macos.zip` and `SHA256SUMS`, from `v0.1.1`
  onward, and the npm packages repackage those same two binaries. An arm64 host —
  Apple Silicon included — and any commit earlier than `v0.1.1` still need a source
  build.
- Pre-1.0: APIs may change between minor versions.

### Internal

- `zig build test-assets` had been compiling and running **zero** tests while exiting 0, for as
  long as the step has existed: `filters` is a compile-time `--test-filter`, and no test in
  `main.zig` matched `assets:`, so nothing past `main.zig` was ever analysed. It now carries the
  anchor the other suites already had. Fallout: that finally compiled `src/PathTable.zig`'s
  inherited `test PathTable`, which had rotted against a `getPath` → `getPathNoName` rename and
  no longer built — repaired in place.
- CI no longer resolves an npm package at workflow runtime. `browser-e2e.yml`'s site job
  served the built site with `bunx serve`, which downloads whatever the registry has at
  the moment the job runs, in a repository that pins its toolchain in `mise.toml`, passes
  `--frozen-lockfile` to every `bun install` and materializes its Zig dependencies from
  hashes. It now uses `python3 -m http.server`, already present on every runner, and
  `tests/meta/ci-package-pins.sh` fails the build on an unpinned `npx` / `bunx` /
  `bun x` / `pnpm dlx` in any workflow so the hole cannot reopen. (#50)
- CI builds `site/` on the pull-request path (new `site` job in `ci.yml`), running the four
  assertions — `build.sh`, `docs-mirror.sh`, `links.sh`, `js-budget.sh` — that previously ran
  only as deploy gates in `pages.yml` and in the scheduled `browser-e2e.yml`. It reuses the
  `zigapagos` binary the `build-binary` job already publishes, so nothing compiles.
- The branding gate takes an inline opt-out. `<!-- branding-ok: why -->` sanctions the
  upstream project's name on that line and `<!-- branding-ok:begin why -->` /
  `<!-- branding-ok:end -->` sanctions a block, for the cases where naming it literally is
  the accurate thing to do — this repository's fork-point tag is named after the upstream
  release it marks, so the passage in `CHANGELOG.md` explaining which tags exist here can
  now say so instead of gesturing at it. A reason is required, an unbalanced block fails,
  a marker that exempts nothing fails as stale, and every sanctioned mention is printed on
  success. The gate also no longer excludes itself from its own search, and
  `tests/branding.test.sh` pins each of those rules from both sides. (#60)
- Extracted the SuperMD transformer out of `site/scripts/gen-docs-mirror.ts` into
  `site/scripts/md-to-smd.ts`, a repo-agnostic module with no repo-specific constants
  (paths, URLs, or fence-language remaps are all passed in via `TransformOptions`), so it
  is the thing `docs/generated-content.md` tells a reader to copy. Verified byte-identical
  output against the pre-extraction generator across all 9 existing mirrors.
- That transformer tracked fenced code blocks by toggling a boolean on any line that was
  exactly three backticks (or tildes) followed by a bare `[A-Za-z0-9_-]*` language. A doc
  that shows fenced Markdown nests a three-backtick block inside a four-backtick one, and
  SuperMD's own raw-HTML escape hatch is the fence info string `=html` — neither is that
  shape, so the inner closing fence was read as an opener and the tracker stayed inverted
  for the rest of the file, silently dropping every `$heading.id(...)` and every link
  rewrite after it. `docs/islands.md` hit this, and the two links whose targets had lost
  their ids then failed the site build with `unknown ref`. Fence recognition now follows
  CommonMark: a run of three OR MORE delimiters, an arbitrary info string (with no backtick
  in a backtick fence's), and a closer that must match the opener's character, be at least
  as long, and carry no info string.
- Templated `site/test/docs-mirror.sh`'s repo-specific paths behind variables at the top,
  and fixed its rendered-HTML directive check, which used to grep the built page for
  a literal Scripty directive with no way to tell a real leak from a directive shown as a
  documented code sample — a false positive `docs/generated-content.md` would have tripped
  immediately. It now strips `<pre>`/`<code>` before matching.
- Added `site/test/md-to-smd.test.ts`, unit tests for the extracted transformer covering
  heading-slug edge cases (the em-dash double-hyphen, dedup, an indented fence), link
  rewriting, the leading-title strip, and the Ziggy frontmatter emitter, wired into
  `site/test/docs-mirror.sh` so CI runs them without a workflow change.
- The release target matrix is declared in three places — `build/release.zig`,
  `npm/cli/targets.json` and `release.yml`'s build matrix — and
  `npm/check-targets.mjs` now fails when they disagree, deriving each npm
  key/cpu/os and archive name from the zig triple rather than trusting the JSON.
  Wired into CI through `tests/npm/targets.sh` and into the release workflow before
  anything is packed. A stale `targets.json` would otherwise publish a platform
  package whose binary nobody built.
- `release.yml` gained an `npm-package` job that assembles and install-tests the
  packages from the archives the release already builds — on pull requests too, so
  a packaging defect is caught before a tag rather than by a published version that
  cannot be replaced. Publishing is a separate job gated on a `v*` tag and the
  `NPM_PUBLISH_ENABLED` repository variable.

## [0.1.1] - 2026-07-28

### Internal

- Changelog entries are now recorded as one fragment file per change in `changelog.d/`,
  assembled into a version section by `scripts/assemble-changelog.sh` at release, so
  parallel pull requests never conflict on `CHANGELOG.md`. See `changelog.d/README.md`.
- Four byte-identical private copies of `escapeRegExp` in build-time TypeScript are
  gone, replaced by the right tool for each of the two contexts they were serving.
  The three JavaScript call sites (`lint-island-imports.ts`, `react-alias.ts`,
  `sidecar/bundle-island.ts`) now use the standard `RegExp.escape`, which is
  specified for exactly the ECMAScript `RegExp` position they feed. The fourth,
  `emit-host-config.ts`, emits Apache `RewriteRule` patterns — PCRE, a different
  dialect — so it gets a purpose-named `escapePcre` whose contract matches its
  output language and which keeps a deployed `.htaccess` readable
  (`^app/.*$`, not `^\x61pp/.*$`).
- Generated Apache config now has a validation net rather than only literal-string
  greps: `emit-host-config.test.ts` runs each emitted `RewriteRule` pattern through
  a real Perl-compatible regex engine and asserts it matches the URLs it should and
  rejects the near-misses an unescaped `.` would have swallowed. `buildAllow` gained
  the metacharacter-escaping test it never had.
- Eleven of the fourteen test scripts `tests/meta/unrun-scripts.txt` inventoried as knowingly
  unrun now run in CI: the non-browser `examples/tsx-site/test/*.sh` — island SSR and the
  bundle/import-map wiring, SSR↔CSR parity, byte-parity against a raw `bun build`, depfile
  incrementality, the props-check gate in both directions, `migrate --doctor`, and the four SPA
  prerender scripts (routing manifest, nginx/zigbase host config, code splitting, baked flag
  defaults, guarded routes, nested layouts) — plus the live-server smoke test.

  They are a step in the existing `e2e-dev-loop` job rather than a `tests/<area>/` shim, and the
  distinction is the whole point. Every one of them runs `zig build` inside `examples/tsx-site`,
  i.e. a full consumer build of zigapagos-as-a-dependency, and `e2e-dev-loop` is the only job
  that already pays for one — its `tests/serve/dev.sh` step drives that project's own
  `zig build dev`. A shim would have put them in `e2e-rest`, which builds the repo and not the
  example, buying a cold ~265s consumer build and making that job the run's critical path.
  Measured against the warm tree the job already has, the eleven cost **49s** in CI (29s
  locally) against the 468s the `dev.sh` step above them takes. `serve.sh` alone was
  inventoried at 76.1s; behind `dev.sh` it is ~5s, which is the placement argument in one
  number.

  The list is literal, not a glob, for the opposite reason `e2e-rest` uses a glob: a new sibling
  in that directory should NOT be adopted onto the PR path automatically — it might be the next
  one that needs a browser or four minutes. Being unnamed there is exactly what makes
  `script-coverage.sh` stop and ask.

- `tests/meta/script-coverage.sh` no longer counts a script as CI-run because a workflow
  *comment* names it. Its rule (b) was a plain `git grep` over `.github/workflows/`, so prose
  saying "these two are deliberately not run here" would have vouched for precisely the scripts
  it was disclaiming — and, since both are also inventoried, would have failed the gate with
  "run by CI but also listed". Rule (b) now applies the same non-comment filter rule (c) already
  had. The two Playwright paths are spelled in full in that comment on purpose: they pin the
  filter, because removing it turns the gate red by name.

  (`site/test/build.sh` and the two Playwright scripts were the three still inventoried at this
  point; all three were wired up before this release shipped — see the entry below for where
  each ended up and why.)
- The `typescript` devDependency moves 5.9.3 → 6.0.3, the final JavaScript-based TypeScript
  line. The compiler API that `runtime/scripts/slice-host.ts` and
  `runtime/sidecar/hot-transform.ts` parse with is fully present, so neither needed
  re-platforming, and the runtime suite is unchanged at 617 passing. `site/bun.lock` and
  `examples/tsx-site/bun.lock` are regenerated in step: each embeds its own copy of
  `@z/runtime`'s resolved dependencies and bun does not refresh them for a linked package on a
  plain install, so left alone they would have kept the props-check gate running 5.9.3 while the
  runtime was tested on 6.0.3.

- TypeScript 7.x is capped out via a Dependabot `ignore` on `>=7.0.0`. 7.0 is the Go rewrite and
  its npm package no longer ships the JavaScript compiler API — `import ts from "typescript"`
  resolves to `lib/version.cjs` and yields only `{version, versionMajorMinor}`, taking the
  runtime suite to 566 passing / 51 failing. The cap is deliberately a version bound rather than
  a major-block, which is what let 6.x through. It lifts when a 7.x ships a usable programmatic
  API (7.1 at the earliest).

- The `tsconfig.json` files were audited against TypeScript 6.0's deprecation list and needed no
  changes: none uses `baseUrl`, `outFile`, `downlevelIteration`, `target: es5`,
  `moduleResolution: node|node10|classic`, `module: amd|umd|system|none`, or an explicitly false
  `esModuleInterop` / `allowSyntheticDefaultImports` / `alwaysStrict`. No source file uses the
  `module` namespace keyword or import `assert` syntax. `ignoreDeprecations` is therefore not
  needed, and the config surface is already clean for whatever 7.x removes.

- Dependabot no longer groups major version bumps with routine ones. The `bun` groups for
  `runtime/` are restricted to minor and patch, and a new `runtime-majors` group collects every
  major into its own pull request, so a breaking major can no longer block unrelated updates
  from merging. `github-actions` deliberately keeps its single group: every `uses:` is pinned to
  a bare major tag, so majors are the only update it can produce and splitting would reintroduce
  per-action pull-request spam.

- `happy-dom` and `@happy-dom/global-registrator` move to 20.11.0.
- `tests/meta/unrun-scripts.txt` is **empty**. All 36 tracked test scripts are now run by CI;
  the inventory that started at 14 rows and was cut to 3 is at 0. The file stays because the
  gate reading it is the point, not the list.

  `site/test/build.sh` moved into `pages.yml`, between `Build site` and `Upload artifact`. That
  makes it a **deploy gate**: a failed assertion fails the build job, the artifact is never
  uploaded, and `deploy` (which `needs: build`) never runs, so the previous good deployment
  stays live. It is nearly free there — the workflow has already built `site/`, so the script's
  own install and build are warm no-ops and the five greps measured 1.7s — against ~120s in any
  `ci.yml` job, because `site/` is a third consumer project with its own `.zig-cache` that
  nothing else warms. The residual gap is stated rather than glossed: `pages.yml` triggers on
  push to `main` and manual dispatch only, so these assertions gate the deploy and not the PR.

  `examples/tsx-site/test/{hydrate,spa_slice}.sh` moved into a new `browser-e2e.yml` on a
  nightly `schedule:` plus `workflow_dispatch:`. Scheduled rather than PR-gating because each is
  ~125s on top of a ~265s cold consumer build plus a ~150MB browser install, and because what
  they catch — a real-browser hydration or runtime-slicing regression — arrives with a
  `runtime/src` change or a dependency bump, unattended. Each script gets its own matrix runner
  (`fail-fast: false`): `spa_slice.sh` opens by `rm -rf`ing `.zig-cache` and `zig-out`, so the
  two cannot share a build, and separate runners make that hazard structurally impossible rather
  than merely avoided.

  One correction to the plan the inventory carried: the install step is
  `playwright install --with-deps chrome`, **not** `chromium`. All ten `*_playwright.py` helpers
  launch with `channel="chrome"`, which on Linux resolves to `/opt/google/chrome/chrome` — the
  bundled Chromium build satisfies none of them, and the run would have died at browser launch
  after paying for the whole consumer build.

- `tests/meta/script-coverage.sh` gained a self-test, `tests/meta/script-coverage.test.sh`,
  in the shape of `scripts/check-allocator-contracts.test.sh`: seven cases against throwaway git
  repos in `$TMPDIR`. That gate has shipped three defects already — a self-vouching inventory, a
  `pipefail` + `grep -q` SIGPIPE race, and a comment filter applied to one rule but not the
  other — and every one made it pass when it should have failed.

  Two of the cases exist because emptying the inventory silently removed the only thing pinning
  the comment filter. That filter is what stops a script a workflow merely *mentions* in prose
  from counting as run, and it was pinned by accident: while the two Playwright scripts were
  inventoried, dropping the filter made the gate see them as both CI-run and listed and fail by
  name. With the inventory empty, removing the filter now breaks nothing in the tree —
  confirmed by deleting the filter line and watching the real gate still pass 36/36. Case 5
  makes the pin deliberate; case 6 is its guard rail, that comment-awareness has not become
  "never believe a workflow".
- `contract/test/drift.sh` — the test that proves the cross-tier codegen gate is not vacuous —
  was itself vacuous, and now runs in CI. Its Case B asserted only that `tsc --noEmit` exited
  non-zero, which a compiler that fails to *launch* also does: `contract/` has no
  `node_modules`, so `bun x tsc` resolved `tsc` off `PATH`, hit mise's shim, and died with
  `No version is set for shim: tsc` — exit 1, nothing type-checked, `PASS Case B` printed. Cases
  A and B now assert on the diagnostic text (the `experiments` → `variants` hunk in api-check's
  staged diff; both assignability directions of the `_assert.ts` tripwire, and no diagnostic
  from anywhere else), and a new Case D feeds those assertions canned "the tool never ran"
  output to prove they reject it.

- The same script now runs the repo's *pinned* TypeScript rather than whatever `bun x` resolves.
  `bun x tsc` with no local install can fetch from npm, where `latest` is 7.x — the line this
  repo deliberately caps out — so the gate could have silently type-checked with a compiler the
  manifest pins away from. It now invokes `runtime/node_modules/typescript` through bun and
  fails if the installed version does not match the one locked in `runtime/bun.lock`.

- `drift.sh`'s restore no longer discards more than it mutates. It used to
  `git checkout HEAD -- contract/`, which covers `contract/test/drift.sh` itself — editing the
  script and running it reverted the edit mid-run. The restore set is now exactly the two paths
  a case writes to, a pre-flight refuses to start when either is already dirty, and the EXIT
  trap both restores and fails the run if anything is left behind.

- A `tests/contract/drift.sh` shim puts the gate in CI's `tests/*/*.sh` glob, alongside the
  existing `tests/changelog/assemble.sh` and `tests/release/scripts.sh` hooks. It costs ~1.5s
  and spawns no server, so it runs in the `e2e-rest` shard rather than a job of its own. Being
  outside that glob, and unnamed in `ci.yml`, is why the rot above went unseen.

- `examples/tsx-site/test/spa.sh` had rotted the same way, and is fixed. Its two nginx
  assertions expected the *unquoted* `try_files $uri $uri/ /app/index.html;`, but
  `emit-host-config.ts` has run every interpolated route value through `nginxQuote()` since
  that helper landed, so both greps had matched nothing for as long as they had existed — and
  the script sits outside the `tests/*/*.sh` glob, so nothing ran it. They now match the quoted
  form byte-for-byte, with a third assertion covering the dynamic `location`'s `try_files`
  order. The emitter itself was never at risk: `runtime/scripts/emit-host-config.test.ts` pins
  the same strings and does run in CI. What the e2e assertions add is that those bytes actually
  reach `zig-out/site/app/nginx.nginx.conf` in a real build.

- A new gate, `tests/meta/script-coverage.sh`, makes that class of rot impossible to introduce
  silently: every test script must be either run by CI or listed in `tests/meta/unrun-scripts.txt`
  with a written reason, and the gate fails on one that is neither — as well as on a stale row
  for a script that has since been wired up or deleted. This is the same shape as
  `scripts/allocator-allowlist.txt` and its checker. It is `git ls-files` plus `grep` over
  tracked text, so it costs no toolchain and runs in well under a second.

  The inventory it enforces records the audit behind it: all 34 tracked test scripts were run by
  hand, 20 are covered by CI, and the 14 that are not (`site/test/build.sh` plus the 13 under
  `examples/tsx-site/test/`) all currently pass. Each row carries its measured wall-clock and
  what adopting it would cost, so the trade-off can be re-checked rather than re-derived.

## [0.1.0] - 2026-07-26

First public release. Fork point: upstream `496e42d` (`v0.11.2-17-g496e42d`).

Everything below is "added" relative to that fork point; the sections separate
what is new from what the port changed and removed.

### Added

- **TSX islands.** Each `.island.tsx` is server-rendered at build time through a
  Bun sidecar and spliced into the page as real HTML with a `data-z-props` JSON
  block. In the browser it hydrates on `client:load`, `client:idle`,
  `client:visible`, `client:media` or `client:only`. Islands share **one** Preact
  instance via a generated import map pointing at a single shared runtime, so a
  page with no islands ships no JavaScript.
- **`@z/runtime`**, the first-party shipped runtime: the hook set
  (`useState`/`useEffect`/`useLayoutEffect`/`useRef`/`useMemo`/`useCallback`/`useReducer`/`useContext`/`useSyncExternalStore`),
  `createContext`, `createPortal`, the `host.*` bindings (store, `fetchShared`,
  cookies, clock, scroll/resize/`matchMedia`, scoped enhancers, `loadScript`,
  `portal`, `reportError`, `pathname`), feature-flag hooks
  (`useFlag`/`useVariant`/`FeatureFlag`/`Experiment`/`initFlags`), and the island
  lifecycle (`bootIsland`/`initIslands`).
- **Native SPAs** from a single `.spa.tsx` exporting `spa` + `routes`:
  prerendered per-route skeletons, a `_shell.html` for dynamic routes, two-phase
  hydration, soft navigation, route guards with a cascade over nested scopes,
  nested layouts via `children` + `<Outlet/>`, a site-wide `404.html`, a
  `spa.head` hook, per-route code splitting via `lazy()`, and host-agnostic
  routing manifests emitted for ZigBase, nginx and Apache.
- **Dev loop.** `zigapagos dev` builds, serves through the stock ZigBase binary,
  and rebuilds on change; the bundled live server adds live reload over SSE, a
  `--proxy PREFIX=UPSTREAM` reverse proxy for cookie-auth backends, and live
  feature flags. Both understand SPAs, including incremental island rebuilds.
- **Astro migration tooling.** `zigapagos migrate <dir>` scans an Astro project,
  detects `client:*` usage and writes a `MIGRATION.md` worklist;
  `zigapagos init --from-astro` scaffolds islands with the React → `@z/runtime`
  import swaps already applied and refuses to clobber existing files. The specs
  in `docs/migration/` are written as a deterministic mapping so an agent can
  complete a port unattended.
- **Cross-tier codegen** for a typed backend client, with `zig build api-check`
  failing the build when `contract/generated` drifts from the schema.
- **Strict-CSP emit.** For any site with islands or SPAs, the build scans the
  emitted HTML, computes a sha256 for each unique inline script, and writes
  `csp.nginx.conf`, `csp.apache.conf` and `csp.zigbase.txt` at the site root:
  `script-src` is `'self'` plus hashes with no `unsafe-inline`. Verified with zero
  CSP violations in real Chrome against a hardened vhost.
- **Correctness gates**, all wired into CI: eleven `test-*` unit suites, a
  616-test Bun suite for `runtime/`, twelve hermetic shell e2e scripts (real
  server boots against a stub ZigBase), a `zig fmt --check` gate over every
  tracked `.zig` file, a `-Dsingle-threaded` compile gate over the exe *and*
  every test binary, an island-props `tsc` gate, and
  `scripts/check-allocator-contracts.sh`, which fails on any new test that wraps
  `std.testing.allocator` in an arena (that turns Zig's leak detector off) unless
  it is allowlisted with a written justification.
- **`NO_SLOP.md`**, the review standard every Zig change is held to, including the
  four allocator-ownership contracts and the `RenderArena` marker type that makes
  contract 4 compiler-checked rather than convention.
- **Docs and examples:** `docs/islands.md`, `docs/spa.md`,
  `docs/observability.md`, `docs/cross-tier-codegen.md`, `docs/migration/*`,
  `docs/ROADMAP.md`; a worked `examples/tsx-site/` with SSR and real-browser
  hydration tests; and `site/`, the project's own dogfooded site.

### Changed

- Ported to **released Zig 0.16.0**. Upstream moved to 0.17-dev; this fork tracks
  released Zig only and defers the 0.17 port until 0.17.0 ships, at which point it
  lands together with the next upstream release-tag sync.
- Renamed throughout — binary, branding, generated asset names — with a CI gate
  that fails on a stray upstream name outside the attribution allowlist.
- **Build-pass order in `src/root.zig` is now load-bearing.** The SPA prerender
  runs *before* the page render/emit pass, because it is the pass that executes
  the author's own code and holds the SPA spec validation (overlapping bases,
  basename collisions, `..` in a route path, a declared SPA with no sidecar).
  Running it after the page pass meant those failures aborted with every page
  already rewritten. This is not atomicity: a failure partway through writing
  shells still leaves partial output.
- The import map is emitted before any `modulepreload` or module script in
  `<head>`, since the first module script closes the window in which a map may be
  declared.

### Removed

- The old Zig-WASM island path (`render(*Z)`) and its `engine/` tree. Islands are
  TSX only; porting from React is now a near-mechanical import swap.
- `windows-latest` from CI. Inherited upstream code
  (`src/cli/serve/watcher/WindowsWatcher.zig`, `src/wuffs.zig`) does not compile
  on stable Zig 0.16.0 — `std.os.windows` no longer exposes `OVERLAPPED` /
  `PAGE_READONLY` — and the fix rides upstream's 0.17-dev branch. It returns with
  the 0.17 port.

### Known limitations

- **No Windows support** until the Zig 0.17 port (above).
- **FreeBSD needs 15 or newer** for live reload: the watcher reuses the
  inotify-based `LinuxWatcher`, and inotify entered the FreeBSD base system in 15.
  There is no kqueue backend. Building and serving static output is unaffected.
- **Strict CSP requires deploying the emitted header.** The build writes the
  hash-strict policy, but serving it (and re-serving it after a rebuild, since the
  hashes are byte-exact) is the host's job. `style-src` still needs
  `unsafe-inline` for the framework's inline `style` attributes.
- `host_url_override` on a locale is not supported by the live server.
- **Binary releases** (`SHA256SUMS`, an `x86_64-linux-musl.tar.xz`, an
  `x86_64-macos.zip`) are published via GitHub Releases.
- Pre-1.0: APIs may change between minor versions. **Only the most recent
  release is supported** — there are no backports.

[Unreleased]: https://github.com/valthon/zigapagos/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/valthon/zigapagos/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/valthon/zigapagos/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/valthon/zigapagos/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/valthon/zigapagos/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/valthon/zigapagos/compare/22ea4a0...v0.1.1
[0.1.0]: https://github.com/valthon/zigapagos/compare/496e42d...22ea4a0
