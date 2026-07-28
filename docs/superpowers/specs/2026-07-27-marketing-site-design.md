# Zigapagos marketing + docs site — design

Status: approved 2026-07-27.

## Goal

Replace the current single-page `site/` with a comprehensive marketing and
documentation website: landing page, full docs, live demos, and honest
comparisons against competing tools. The reference for scope and quality is the
ZigBase site (`~/nothlav/zigbase/site`, published at
<https://valthon.github.io/zigbase/>).

## The central decision: the site is built with Zigapagos

The ZigBase site is built with **Astro**. Zigapagos competes with Astro, so its
own site must be built with Zigapagos. That is not a slogan — it is the design's
main structural constraint and its main source of content:

- every interactive example on the site is a real `.island.tsx`, server-rendered
  at build time and hydrated in the visitor's browser;
- the SPA demo is a real `.spa.tsx` compiled by the same pipeline the docs
  describe;
- the JS-budget figures printed on the site are measured from the emitted tree,
  not written by hand.

A secondary benefit is that the site is a dogfooding gate: anything the site
cannot express is a real product gap, and we would rather discover it here.

## Constraints discovered during design

These are load-bearing and were verified against the source, not assumed.

1. **SuperMD forbids raw HTML.** `supermd/src/Ast.zig` raises
   `html_is_forbidden` for `HTML_BLOCK` and `HTML_INLINE` nodes. Therefore
   `<island>` **cannot** appear in a `.smd` content file. Islands only work in
   `.shtml` layouts. Marketing pages are consequently thin `.smd` files whose
   frontmatter selects a rich per-page `.shtml` layout; the `.smd` body carries
   only prose that belongs in Markdown.

   This same strictness is a benefit for mirrored docs: a canonical doc that
   grows raw HTML fails the site build loudly instead of silently degrading.

2. **Frontmatter is Ziggy, not YAML.** The docs mirror must emit
   `.title = "…", .layout = "…"` form, and section membership is expressed with
   `.custom`.

3. **Sections are defined by `index.smd`.** `$page.subpages()` only works for a
   directory that has one. Every section directory therefore gets an
   `index.smd`.

4. **Syntax highlighting is static** (treesitter via `flow_syntax`), and needs a
   `highlight.css` in `assets/`. No client-side highlighter ships.

5. **`url_path_prefix` is `zigapagos`** (GitHub project pages). `src/spa.zig`
   handles the prefix end-to-end — there is an AUDF-005 regression test for
   exactly this deploy shape — so an SPA based at `/demos/app` resolves
   correctly under the prefix. All internal links must go through
   `$site.page(...).link()` / `$site.asset(...).link()` rather than being
   hand-written.

## Information architecture

```
/                          Landing
/docs/                     Docs shell: sidebar + on-this-page TOC
   overview                 authored
   quick-start              authored
   tutorial                 authored
   configuration            authored
   islands                  mirrored ← docs/islands.md
   spa                      mirrored ← docs/spa.md
   cross-tier-codegen       mirrored ← docs/cross-tier-codegen.md
   observability            mirrored ← docs/observability.md
   migrate-from-astro       mirrored ← docs/migration/astro-to-zigapagos.md
   migration-recipes        mirrored ← docs/migration/recipes.md
   react-spa-bridge         mirrored ← docs/migration/react-spa-bridge.md
   roadmap                  mirrored ← docs/ROADMAP.md
   changelog                mirrored ← CHANGELOG.md
/demos/                    Demo index
   directives               client:load|idle|visible|media|only, hydrating live
   migrate                  Astro → Zigapagos before/after with mapping rules
   app/                     a real .spa.tsx: routing, nested layout, guard
/compare/                  vs Astro, Next static export, Eleventy, Hugo, upstream
/download/                 install, build from source, releases
```

Sidebar groups, in order: **Getting started** (overview, quick-start, tutorial,
configuration) · **Guides** (islands, spa, cross-tier-codegen) · **Migrating**
(migrate-from-astro, migration-recipes, react-spa-bridge) · **Reference**
(observability, roadmap, changelog).

## Landing page

Nine sections:

1. **Hero** — headline, lede, primary/secondary CTA, and a live island present
   on the page itself.
2. **Zero JS by default** — states this page's measured JS budget, and contrasts
   it with the docs pages, which ship none. The honesty is the point: a demo
   page shipping JS is expected; claiming otherwise would be caught by anyone
   opening devtools.
3. **Islands in 30 seconds** — tabbed: `.island.tsx` source → emitted HTML →
   the running component.
4. **Five directives** — compact strip of `client:load|idle|visible|media|only`,
   linking to `/demos/directives`.
5. **Native SPAs** — one `.spa.tsx` → prerendered skeletons + client routing,
   linking to `/demos/app/`.
6. **Coming from Astro** — `zigapagos migrate`, a before/after pair, linking to
   `/demos/migrate`.
7. **One binary + Bun** — the content/islands/bundle pipeline diagram; no Node,
   Vite, or webpack.
8. **Deploy anywhere** — the zigbase / nginx / apache config emitters.
9. **Why Zigapagos — and when not to.** An explicit "do not use this if…" list.
   Naming the cases where another tool wins is worth more credibility than a
   further feature grid.

## Components

**`.shtml` partials** (under `site/layouts/templates/`): `base`, `nav`,
`footer`, `docs-sidebar`, `page-toc`, `feature-card`, `callout`, `button`,
`browser-chrome`.

**Islands** (`site/components/*.island.tsx`): `Counter`, `CodeTabs`,
`DirectiveDemo`, `MigrateDiff`, plus the SPA's own route components.

**The theme toggle is deliberately not an island.** It is a small inline
pre-paint script, so docs pages retain a genuinely zero-byte JS budget. The site
says so where the toggle lives.

## Content sourcing

`site/scripts/gen-docs-mirror.ts` (Bun, matching this repo's toolchain), driven
by `site/scripts/docs-registry.json`. This is a port of ZigBase's
`gen-docs-mirror.mjs` pattern, which splits docs into an authored on-ramp and a
generated reference.

Each registry entry maps: canonical repo path → mirror filename → sidebar group,
order, title, description.

The generator:

- emits **Ziggy** frontmatter with title, description, layout, and
  `.custom = { .group = …, .order = … }`;
- strips the canonical file's "also published on the site" banner blockquote;
- rewrites relative `.md` link *targets* (never link text) to site routes when
  the target is published, falling back to a GitHub blob/tree URL with a
  warning when it is not;
- writes `site/content/docs/<mirror>.smd` alongside the authored pages, with
  each generated filename listed individually in `site/.gitignore` (ZigBase's
  convention) so the canonical file stays the only editable copy and a stray
  mirror can never be committed.

Canonical `docs/*.md` gain a banner blockquote pointing at their published URL,
matching ZigBase's convention.

## Visual identity

Distinct brand, shared bones: keep ZigBase's token architecture (a `tokens.css`
with an explicit `:root[data-theme]` override beating
`@media (prefers-color-scheme: dark)`, a 1.25 type scale, a numbered spacing
scale, a container max-width), but a new palette and mark.

| token | light | dark |
| --- | --- | --- |
| bg | `#fdfdfc` | `#0d1013` |
| surface | `#f4f5f2` | `#151a1e` |
| border | `#e2e4df` | `#252c32` |
| text | `#16181a` | `#e6e9ea` |
| muted | `#5b6169` | `#9aa3ab` |
| accent (ocean teal) | `#0f7a6e` | `#3fd0bd` |
| secondary (volcanic) | `#d1663a` | `#e8865a` |

Typography is `system-ui` for prose and JetBrains Mono (with a `ui-monospace`
fallback) for code — **no webfont is downloaded**. A site arguing for a minimal
payload should not open with a font request; display character comes from weight
and letter-spacing instead.

**Mark:** an archipelago — four dots, one lit. It depicts islands architecture
directly, is a sub-300-byte SVG, and serves as favicon and OG image.

## Build, deploy, and testing

- `site/build.zig` grows an `islands` list and one `spas` entry
  (`.base = "/demos/app"`), with `.not_found` set explicitly.
- `.github/workflows/pages.yml` runs the docs mirror before `zig build`.
- `site/test/build.sh` extends its existing deploy-gate assertions with: every
  internal link resolves to an emitted file; mirrors are fresh with respect to
  their canonicals; the landing page's JS budget is under a pinned ceiling; the
  SPA shell and `data-z-props` hydration markers exist.
- A Playwright smoke (the repo already runs `browser-e2e.yml`) covers island
  hydration on `/` and soft navigation within `/demos/app/`.

## Phasing

1. Tokens, shell (nav, footer, theme), landing page.
2. Docs system: mirror generator, sidebar, TOC, the four authored pages.
3. Demos: directives, migrate, SPA.
4. `/compare`, `/download`, tests, Pages deploy.

## Explicitly out of scope

- Client-side docs search. It needs an index and an always-loaded island, which
  contradicts the zero-JS docs budget. Revisit once the docs are large enough to
  justify it.
- A WASM playground. Compiling the generator to WASM is a project of its own.
- Screenshots of third-party tools in `/compare`. Comparisons are stated as
  verifiable claims about behaviour and output, not marketing imagery.
