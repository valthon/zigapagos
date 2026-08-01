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
    dropped, so the whole string is semver and orders against the releases below.
  - `unknown` — `git` is missing, or `git describe` failed because the checkout
    is shallow and carries no tags. CI's own `build-binary` job is exactly that,
    so the binary it uploads says `unknown` while a release build says the tag.

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
  cannot be replaced. Publishing is a separate job gated on a `v*` tag, the
  `NPM_PUBLISH_ENABLED` repository variable and the `NPM_TOKEN` secret.

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
- **Binary releases are published from `v0.1.1` onward** (`SHA256SUMS`, an
  `x86_64-linux-musl.tar.xz`, an `x86_64-macos.zip`) via GitHub Releases.
  Earlier commits still need a source build.
- Pre-1.0: APIs may change between minor versions.

[Unreleased]: https://github.com/valthon/zigapagos/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/valthon/zigapagos/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/valthon/zigapagos/compare/22ea4a0...v0.1.1
[0.1.0]: https://github.com/valthon/zigapagos/compare/496e42d...22ea4a0
