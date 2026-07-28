# Zigapagos Marketing + Docs Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-page `site/` with a comprehensive marketing and documentation website — landing page, full docs with sidebar, three live demos, and tool comparisons — built with Zigapagos itself.

**Architecture:** Thin `.smd` content files select rich per-page `.shtml` layouts that all `<extend template="base.shtml">`. Interactive examples are real `.island.tsx` components (islands cannot live in `.smd` — SuperMD forbids raw HTML). Reference docs are generated into `site/content/docs/` from canonical repo markdown by a Bun script, so they cannot drift. One real `.spa.tsx` is mounted at `/demos/app` to demonstrate native SPAs.

**Tech Stack:** Zigapagos (Zig 0.16), SuperMD content, SuperHTML layouts, Ziggy frontmatter, Bun 1.2 for the mirror generator and islands, bash for the deploy gate, Playwright for hydration smoke tests.

## Global Constraints

- **Zig 0.16.0 and Bun 1.2**, pinned by `mise.toml`. Run `zig version` before believing a wall of dependency errors.
- **A fresh worktree needs `cd runtime && bun install --frozen-lockfile` once**, and `cd site && bun install` before any site build. Without it every bun-dependent step fails in ways that look like code breakage.
- **SuperMD forbids raw HTML.** `<island>`, `<div>`, `<br>` etc. in a `.smd` body fail the build with `html_is_forbidden`. All markup lives in `.shtml` layouts.
- **Frontmatter is Ziggy, not YAML**: `.title = "…"`, `.date = @date("…")`, `.layout = "…"`, `.draft = false`, custom fields under `.custom = { … }`, read as `$page.custom.get('name')`.
- **A directory is a section only if it has `index.smd`.** `$page.subpages()` requires it.
- **`url_path_prefix = "zigapagos"`.** Never hand-write an internal URL. Always `$site.page('docs/overview').link()` and `$site.asset('style.css').link()`.
- **`zig fmt` is gated with no exceptions.** Before any commit touching `.zig`: `git ls-files -z '*.zig' | xargs -0 -r zig fmt --check`.
- **Never edit `zig-pkg/` or `examples/tsx-site/zig-pkg/`** — gitignored vendored dependencies.
- **Branding gate:** the upstream project's own name must not appear in first-party source or built output. `tests/branding.sh` enforces this repo-wide, allowlisting only LICENSE, README.md and CLAUDE.md for attribution. Note `site/test/build.sh` splits the token (`BANNED="zi""ne"`) so the gate does not flag its own assertion — do the same if you need to write the literal.
- **`cmd | tail` reports `tail`'s exit status.** Run gates unpiped and check `$?`.
- **Commit messages explain the defect and the reasoning**, not just the change. Match the density of the existing history.
- **`gh` defaults to the upstream remote this project was forked from.** Always pass `--repo valthon/zigapagos`.

## Discoveries from Task 1 (bind all later tasks)

- **`:attr` is not a directive in this fork's SuperHTML.** Use the bare
  attribute form with a Scripty expression instead:
  `content="$page.description"`, not `:attr="$page.description"`.
- **Extend blocks are `<main id="main">`, not `<body id="body">`.** SuperHTML
  requires an extending layout's block to match the `<super>`'s immediate
  parent, and base.shtml's content `<super>` is inside `<main id="main">`.
- **Placeholder pages exist and must be replaced, not duplicated.** Task 1
  created one-sentence stubs so the nav would resolve:
  `site/content/docs.smd`, `demos.smd`, `compare.smd`, `download.smd`, and
  `docs/overview.smd`. A later task creating `content/docs/index.smd` (Task 5)
  or `content/demos/index.smd` (Task 7) **must delete the matching flat stub**
  (`content/docs.smd`, `content/demos.smd`) in the same commit — otherwise two
  pages claim the same route. Task 6 overwrites `docs/overview.smd` in place.
  Tasks 10 replaces `compare.smd` and `download.smd` in place.
- **`:if` on a real element does NOT conditionally emit the element, and `:else`
  does nothing at all.** Verified against `superhtml/src/template.zig`: for a
  plain element the open tag and *all* its attributes are written
  unconditionally (the attribute loop, then `writeAll(">")`) **before**
  `skip_body` is consulted — so `:if=false` on `<a aria-current="page">` still
  ships the tag and the attribute, and only the body is skipped. Separately,
  `:else` has **zero runtime handling**; it is parse-validated and then never
  consulted during evaluation, so its body always renders. Use
  `<ctx :if="cond">…</ctx>`, which never prints its own tag and drops its whole
  body when false. This is a silent-wrong-output trap, not a build error.

- **Placeholder names collide with mirror names — Task 4 must clear them.**
  Tasks 2, 3, 8 and 9 create placeholder pages so their `$site.page('docs/...')`
  links resolve (the build hard-fails on a reference to a missing page), and
  several of those names are also registry mirror filenames: `docs/islands.smd`,
  `docs/spa.smd`, `docs/migrate-from-astro.smd`, `docs/migration-recipes.smd`.
  Task 4 gitignores each mirror by exact filename, and **a file already tracked
  by git stays tracked after being gitignored** — the generator would then
  overwrite a committed file on every build, which is precisely what Task 4's
  `docs-mirror.sh` "no mirror may be committed" assertion exists to catch.
  Task 4 must therefore `git rm --cached` (and delete) every placeholder whose
  name matches a registry mirror, in the same commit that adds the gitignore
  entries. Run `git ls-files site/content/docs/` first and reconcile it against
  `docs-registry.json` rather than assuming which placeholders exist.

## File Structure

```
site/
  assets/
    tokens.css          design tokens: palette, type scale, spacing (Task 1)
    style.css           global + landing styles (Task 1, extended per task)
    docs.css            docs shell: sidebar, TOC, prose (Task 5)
    highlight.css       treesitter code colors, retuned to the palette (Task 1)
    logo.svg            archipelago mark (Task 11)
    og.svg              social card (Task 11)
  components/
    Counter.island.tsx        existing, restyled (Task 2)
    CodeTabs.island.tsx       tabbed source/output/live (Task 3)
    DirectiveDemo.island.tsx  the five client: directives (Task 7)
    MigrateDiff.island.tsx    Astro -> Zigapagos before/after (Task 8)
  demo/
    app.spa.tsx               the embedded native SPA (Task 9)
    views.tsx                 its route components (Task 9)
  layouts/
    templates/base.shtml      html shell, nav, footer, theme script (Task 1)
    index.shtml               landing page, 9 sections (Tasks 2-4)
    page.shtml                generic prose page (Task 1)
    docs.shtml                docs page: sidebar + TOC (Task 5)
    docs-index.shtml          docs landing (Task 5)
    demos.shtml               demo index (Task 7)
    demo-directives.shtml     (Task 7)
    demo-migrate.shtml        (Task 8)
    compare.shtml             (Task 10)
    download.shtml            (Task 10)
  content/
    index.smd                 landing (Task 2)
    docs/index.smd            docs section root (Task 5)
    docs/overview.smd         authored (Task 6)
    docs/quick-start.smd      authored (Task 6)
    docs/tutorial.smd         authored (Task 6)
    docs/configuration.smd    authored (Task 6)
    docs/<9 mirrored>.smd     generated, gitignored (Task 4)
    demos/index.smd           (Task 7)
    demos/directives.smd      (Task 7)
    demos/migrate.smd         (Task 8)
    compare.smd               (Task 10)
    download.smd              (Task 10)
  scripts/
    docs-registry.json        canonical -> mirror map (Task 4)
    gen-docs-mirror.ts        the generator (Task 4)
  test/
    build.sh                  existing deploy gate, extended each task
    links.sh                  internal-link resolver check (Task 12)
    js-budget.sh              per-page JS ceiling (Task 12)
    docs-mirror.sh            mirror freshness (Task 4)
    spa_playwright.py         SPA soft-nav smoke (Task 12)
    hydrate_playwright.py     island hydration smoke (Task 12)
  build.zig                   islands + spas wiring (Tasks 2, 7, 8, 9)
.github/workflows/pages.yml   runs the mirror before `zig build` (Task 4)
docs/*.md                     gain "also published at" banners (Task 4)
```

---

### Task 1: Design tokens and the base shell

Establishes the palette, the `<extend>`/`<super>` shell, the nav, the footer, and the flash-free theme toggle. Every later page hangs off this.

**Files:**
- Create: `site/assets/tokens.css`
- Create: `site/assets/highlight.css`
- Create: `site/layouts/templates/base.shtml`
- Create: `site/layouts/page.shtml`
- Modify: `site/assets/style.css` (replace wholesale — the current file hardcodes a dark-only palette)
- Modify: `site/layouts/index.shtml` (make it extend base; keep the existing hero so the build stays green)
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `base.shtml` exposing two extension points, `<head id="head">` and `<main id="main">`, each containing a `<super>`. **An extending layout's block id must match the `<super>`'s immediate parent**, and base.shtml's second `<super>` sits inside `<main id="main">` — so every later layout supplies `<main id="main">`, never `<body id="body">`. CSS custom properties consumed by every later stylesheet: `--color-bg`, `--color-surface`, `--color-border`, `--color-text`, `--color-muted`, `--color-accent`, `--color-accent-hover`, `--color-secondary`, `--font-sans`, `--font-mono`, `--text-xs` … `--text-hero`, `--space-1` … `--space-9`, `--radius-sm|md|lg|full`, `--container-max`.

- [ ] **Step 1: Add the failing assertions to the deploy gate**

Append to `site/test/build.sh`, before the final `echo PASS`:

```bash
# Task 1: the base shell renders, in both themes, with no webfont request.
grep -q 'data-theme' "$OUT/index.html" || { echo "FAIL: no theme attribute wiring"; exit 1; }
grep -q 'id="site-nav"' "$OUT/index.html" || { echo "FAIL: nav missing"; exit 1; }
test -f "$OUT/tokens.css" || { echo "FAIL: tokens.css not installed"; exit 1; }
grep -q -- '--color-accent' "$OUT/tokens.css" || { echo "FAIL: tokens.css has no palette"; exit 1; }
grep -qE 'fonts\.(googleapis|gstatic)\.com|@import url\(' "$OUT/index.html" "$OUT/style.css" "$OUT/tokens.css" \
  && { echo "FAIL: site downloads a webfont"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: no theme attribute wiring` (the current `index.shtml` has no theme wiring and no nav).

- [ ] **Step 3: Write the design tokens**

Create `site/assets/tokens.css`:

```css
/* Design tokens for the Zigapagos site.
 *
 * Dark is applied two ways, and the order matters:
 *   1. :root[data-theme='dark'] — an explicit choice from the toggle, which
 *      must beat the OS preference in BOTH directions.
 *   2. @media (prefers-color-scheme: dark) guarded by :root:not([data-theme])
 *      — the OS default, which only applies while no explicit choice exists.
 *
 * Palette is "volcanic basalt + ocean teal": the accent is the interactive
 * colour, the secondary is reserved for migration/comparison accents so the
 * two never compete for the same meaning.
 */
:root {
  --color-bg: #fdfdfc;
  --color-surface: #f4f5f2;
  --color-border: #e2e4df;
  --color-text: #16181a;
  --color-muted: #5b6169;
  --color-accent: #0f7a6e;
  --color-accent-hover: #0b5f56;
  --color-secondary: #d1663a;

  /* No webfont is downloaded — a site arguing for a small payload should not
     open with a font request. Display character comes from weight/tracking. */
  --font-sans: system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial,
    sans-serif, 'Apple Color Emoji', 'Segoe UI Emoji';
  --font-mono: 'JetBrains Mono', 'Fira Code', ui-monospace, SFMono-Regular, Menlo,
    monospace;

  --text-xs: 0.8rem;
  --text-sm: 0.9rem;
  --text-base: 1rem;
  --text-lg: 1.125rem;
  --text-xl: 1.25rem;
  --text-2xl: 1.563rem;
  --text-3xl: 1.953rem;
  --text-4xl: 2.441rem;
  --text-hero: clamp(2.4rem, 5.5vw, 3.8rem);

  --leading-tight: 1.18;
  --leading-normal: 1.65;

  --space-1: 0.25rem;
  --space-2: 0.5rem;
  --space-3: 0.75rem;
  --space-4: 1rem;
  --space-5: 1.5rem;
  --space-6: 2rem;
  --space-7: 3rem;
  --space-8: 4rem;
  --space-9: 6rem;

  --radius-sm: 4px;
  --radius-md: 8px;
  --radius-lg: 12px;
  --radius-full: 999px;

  --container-max: 1120px;
}

:root[data-theme='dark'] {
  --color-bg: #0d1013;
  --color-surface: #151a1e;
  --color-border: #252c32;
  --color-text: #e6e9ea;
  --color-muted: #9aa3ab;
  --color-accent: #3fd0bd;
  --color-accent-hover: #6fe0d1;
  --color-secondary: #e8865a;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    --color-bg: #0d1013;
    --color-surface: #151a1e;
    --color-border: #252c32;
    --color-text: #e6e9ea;
    --color-muted: #9aa3ab;
    --color-accent: #3fd0bd;
    --color-accent-hover: #6fe0d1;
    --color-secondary: #e8865a;
  }
}
```

- [ ] **Step 4: Write the code-highlighting stylesheet**

Create `site/assets/highlight.css`. Highlighting is static (treesitter, at build time) so these are plain class colours, no JS:

```css
/* Treesitter highlight classes, emitted statically at build time.
   Colours are tuned per theme against --color-surface, not copied from a
   terminal scheme, so contrast holds in light mode too. */
:root {
  --hl-keyword: #a626a4;
  --hl-string: #50781f;
  --hl-comment: #8a9099;
  --hl-number: #b26100;
  --hl-function: #2f6fb5;
  --hl-type: #0f7a6e;
  --hl-punct: #5b6169;
}
:root[data-theme='dark'] {
  --hl-keyword: #d18ce0;
  --hl-string: #9ecb6a;
  --hl-comment: #6b757f;
  --hl-number: #e0a56a;
  --hl-function: #7cb7f0;
  --hl-type: #3fd0bd;
  --hl-punct: #9aa3ab;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    --hl-keyword: #d18ce0;
    --hl-string: #9ecb6a;
    --hl-comment: #6b757f;
    --hl-number: #e0a56a;
    --hl-function: #7cb7f0;
    --hl-type: #3fd0bd;
    --hl-punct: #9aa3ab;
  }
}

pre code .keyword, pre code .conditional, pre code .repeat, pre code .include { color: var(--hl-keyword); }
pre code .string, pre code .character { color: var(--hl-string); }
pre code .comment { color: var(--hl-comment); font-style: italic; }
pre code .number, pre code .boolean, pre code .float { color: var(--hl-number); }
pre code .function, pre code .method { color: var(--hl-function); }
pre code .type, pre code .constant, pre code .attribute { color: var(--hl-type); }
pre code .punctuation, pre code .operator, pre code .delimiter { color: var(--hl-punct); }
```

- [ ] **Step 5: Write the base shell**

Create `site/layouts/templates/base.shtml`. The theme script is inline and **before** the stylesheets so the correct palette is set before first paint — a deferred script would flash light-on-dark:

```html
<!DOCTYPE html>
<html lang="en">
  <head id="head">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title :text="$page.title"></title>
    <meta name="description" :attr="$page.description">
    <script>
      // Pre-paint theme resolution. Inline and synchronous on purpose: a
      // deferred script would paint the OS theme first and then correct
      // itself, which reads as a flash. ~300 bytes, and deliberately NOT an
      // island — docs pages must keep a genuinely zero-byte JS budget.
      try {
        var t = localStorage.getItem('zp-theme');
        if (t) document.documentElement.setAttribute('data-theme', t);
      } catch (e) {}
    </script>
    <link type="text/css" rel="stylesheet" href="$site.asset('tokens.css').link()">
    <link type="text/css" rel="stylesheet" href="$site.asset('style.css').link()">
    <link type="text/css" rel="stylesheet" href="$site.asset('highlight.css').link()">
    <super>
  </head>
  <body id="body">
    <a class="skip-link" href="#main">Skip to content</a>
    <header id="site-nav" class="nav">
      <div class="nav-inner">
        <a class="nav-brand" href="$site.page('').link()">
          <span class="nav-mark" aria-hidden="true"></span>
          <span :text="$site.title"></span>
        </a>
        <nav class="nav-links" aria-label="Main">
          <a href="$site.page('docs').link()">Docs</a>
          <a href="$site.page('demos').link()">Demos</a>
          <a href="$site.page('compare').link()">Compare</a>
          <a href="$site.page('download').link()">Download</a>
          <a href="https://github.com/valthon/zigapagos">GitHub</a>
        </nav>
        <button id="theme-toggle" class="theme-toggle" type="button"
                aria-label="Toggle colour theme">◐</button>
      </div>
    </header>
    <main id="main">
      <super>
    </main>
    <footer class="site-footer">
      <div class="footer-inner">
        <p>
          Zigapagos is a static site generator with a native core and TSX islands.
          MIT licensed.
        </p>
        <p>
          <a href="https://github.com/valthon/zigapagos">Source</a> ·
          <a href="$site.page('docs/overview').link()">Docs</a> ·
          A permanent fork of
          <a href="https://github.com/valthon/zigapagos#acknowledgements">Loris Cro's SSG</a>.
        </p>
        <p class="footer-meta">
          This site is built with Zigapagos. Every interactive component on it is
          a real island.
        </p>
      </div>
    </footer>
    <script>
      // Toggle handler. Writes the explicit choice that beats the OS
      // preference in tokens.css, in both directions.
      document.getElementById('theme-toggle').addEventListener('click', function () {
        var cur = document.documentElement.getAttribute('data-theme');
        var next = cur === 'dark' ? 'light'
          : cur === 'light' ? 'dark'
          : (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'light' : 'dark');
        document.documentElement.setAttribute('data-theme', next);
        try { localStorage.setItem('zp-theme', next); } catch (e) {}
      });
    </script>
  </body>
</html>
```

- [ ] **Step 6: Write the generic prose layout**

Create `site/layouts/page.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">
  <article class="prose wrap">
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </article>
</main>
```

- [ ] **Step 7: Replace the stylesheet**

Replace `site/assets/style.css` entirely. The current file hardcodes a dark-only palette that the tokens now own:

```css
* { box-sizing: border-box; }

html { scroll-behavior: smooth; }

body {
  margin: 0;
  background: var(--color-bg);
  color: var(--color-text);
  font-family: var(--font-sans);
  font-size: var(--text-base);
  line-height: var(--leading-normal);
  -webkit-font-smoothing: antialiased;
}

.wrap { max-width: var(--container-max); margin: 0 auto; padding: 0 var(--space-5); }

.skip-link {
  position: absolute; left: -9999px;
  background: var(--color-accent); color: var(--color-bg);
  padding: var(--space-2) var(--space-4); border-radius: var(--radius-sm);
}
.skip-link:focus { left: var(--space-4); top: var(--space-4); z-index: 100; }

/* Nav */
.nav {
  position: sticky; top: 0; z-index: 50;
  background: color-mix(in srgb, var(--color-bg) 88%, transparent);
  backdrop-filter: blur(8px);
  border-bottom: 1px solid var(--color-border);
}
.nav-inner {
  max-width: var(--container-max); margin: 0 auto;
  padding: var(--space-3) var(--space-5);
  display: flex; align-items: center; gap: var(--space-5);
}
.nav-brand {
  display: flex; align-items: center; gap: var(--space-2);
  font-weight: 650; letter-spacing: -0.015em;
  color: var(--color-text); text-decoration: none;
}
.nav-mark {
  width: 1.1rem; height: 1.1rem; border-radius: var(--radius-full);
  background:
    radial-gradient(circle at 20% 30%, var(--color-muted) 22%, transparent 24%),
    radial-gradient(circle at 72% 24%, var(--color-muted) 16%, transparent 18%),
    radial-gradient(circle at 34% 78%, var(--color-muted) 16%, transparent 18%),
    radial-gradient(circle at 76% 70%, var(--color-accent) 26%, transparent 28%);
}
.nav-links { margin-left: auto; display: flex; gap: var(--space-5); flex-wrap: wrap; }
.nav-links a {
  color: var(--color-muted); text-decoration: none; font-size: var(--text-sm);
}
.nav-links a:hover { color: var(--color-accent); }
.theme-toggle {
  background: none; border: 1px solid var(--color-border);
  color: var(--color-muted); border-radius: var(--radius-sm);
  width: 2rem; height: 2rem; cursor: pointer; font-size: var(--text-sm);
}
.theme-toggle:hover { border-color: var(--color-accent); color: var(--color-accent); }

/* Prose */
.prose { padding-block: var(--space-8); max-width: 46rem; }
.prose h1 { font-size: var(--text-4xl); line-height: var(--leading-tight); letter-spacing: -0.025em; }
.prose h2 { font-size: var(--text-2xl); margin-top: var(--space-7); letter-spacing: -0.015em; }
.prose h3 { font-size: var(--text-xl); margin-top: var(--space-6); }
.prose a { color: var(--color-accent); }
.prose code {
  font-family: var(--font-mono); font-size: 0.9em;
  background: var(--color-surface); padding: 0.15em 0.4em; border-radius: var(--radius-sm);
}
.prose pre {
  font-family: var(--font-mono); font-size: var(--text-sm);
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: var(--radius-md); padding: var(--space-4); overflow-x: auto;
}
.prose pre code { background: none; padding: 0; }
.prose table { width: 100%; border-collapse: collapse; font-size: var(--text-sm); }
.prose th, .prose td { border: 1px solid var(--color-border); padding: var(--space-2) var(--space-3); text-align: left; }
.prose blockquote {
  margin: var(--space-5) 0; padding: var(--space-3) var(--space-4);
  border-left: 3px solid var(--color-accent); background: var(--color-surface);
  color: var(--color-muted);
}

/* Footer */
.site-footer {
  margin-top: var(--space-9);
  border-top: 1px solid var(--color-border);
  color: var(--color-muted); font-size: var(--text-sm);
}
.footer-inner {
  max-width: var(--container-max); margin: 0 auto;
  padding: var(--space-6) var(--space-5);
}
.site-footer a { color: var(--color-accent); }
.footer-meta { color: var(--color-muted); opacity: 0.75; }
```

- [ ] **Step 8: Port the existing landing page onto the shell**

Replace `site/layouts/index.shtml`. This keeps the current hero and Counter island so the build stays green; Task 2 rebuilds it properly:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">
  <section class="hero wrap">
    <p class="kicker">zigapagos</p>
    <h1>Astro's islands. A native core. No Node.</h1>
    <p class="lede">
      Zigapagos is a static site generator that renders pages with a fast Zig
      binary and adds interactivity per-component with TSX islands &mdash;
      server-rendered at build time, hydrated in the browser only where you ask.
    </p>
    <div class="demo">
      <island src="components/Counter.island.tsx" client:visible></island>
      <p class="demo-caption">
        <strong>This button is a live island on this very page.</strong>
        The rest of the page is plain HTML; this is the only component that
        shipped JavaScript.
      </p>
    </div>
  </section>
  <div class="prose wrap" :html="$page.content()"></div>
</main>
```

- [ ] **Step 9: Add the hero and demo styles**

Append to `site/assets/style.css`:

```css
.hero { padding-block: var(--space-9) var(--space-7); max-width: 52rem; }
.kicker {
  font-family: var(--font-mono); text-transform: uppercase;
  letter-spacing: 0.14em; font-size: var(--text-xs);
  color: var(--color-accent); margin: 0 0 var(--space-3);
}
.hero h1 {
  font-size: var(--text-hero); line-height: var(--leading-tight);
  letter-spacing: -0.03em; margin: 0 0 var(--space-4); font-weight: 680;
}
.lede { color: var(--color-muted); font-size: var(--text-lg); margin: 0 0 var(--space-6); }
.demo {
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: var(--radius-lg); padding: var(--space-5);
}
.demo-caption { margin: var(--space-4) 0 0; color: var(--color-muted); font-size: var(--text-sm); }
.demo-counter {
  font-family: var(--font-mono); font-size: var(--text-sm);
  background: var(--color-accent); color: var(--color-bg);
  border: none; border-radius: var(--radius-sm);
  padding: var(--space-3) var(--space-5); cursor: pointer;
}
.demo-counter:hover { background: var(--color-accent-hover); }
```

- [ ] **Step 10: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 11: Commit**

```bash
git add site/assets site/layouts site/test/build.sh
git commit -m "site: design tokens and a real page shell

The site had one layout with a dark-only palette hardcoded into style.css,
which makes every additional page a copy-paste of the same <head>. This adds
the shell the rest of the site hangs off: tokens.css owns the palette, and
base.shtml owns the document, nav, footer and theme.

Two details are deliberate. The theme script is inline and synchronous, ahead
of the stylesheets, because a deferred one paints the OS theme and then
corrects itself — a visible flash. And it is a plain script rather than an
island precisely so docs pages keep a zero-byte JS budget; a framework-driven
theme toggle would put JavaScript on every page of a generator whose pitch is
that most pages need none. The gate now asserts that, plus the absence of any
webfont request."
```

---

### Task 2: Landing page — hero, JS budget, and the pipeline

The first three of the nine landing sections, plus the build.zig wiring for new islands.

**Files:**
- Modify: `site/content/index.smd`
- Modify: `site/layouts/index.shtml`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `base.shtml` extension points and the token names from Task 1.
- Produces: CSS classes reused by later sections — `.section`, `.eyebrow`, `.section-note`, `.cta-row`, `.grid-2`, `.grid-3`, `.card`, `.btn`, `.btn-primary`, `.btn-ghost`, `.stat`, `pre.pipeline`.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 2: the landing page carries its named sections and both CTAs.
for id in s-hero s-zerojs s-pipeline; do
  grep -q "id=\"$id\"" "$OUT/index.html" || { echo "FAIL: landing section $id missing"; exit 1; }
done
grep -q 'class="btn btn-primary"' "$OUT/index.html" || { echo "FAIL: primary CTA missing"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: landing section s-hero missing`

- [ ] **Step 3: Rewrite the landing content file**

Replace `site/content/index.smd`. The body is empty on purpose — every landing section is markup, and SuperMD would reject the markup those sections need:

```
---
.title = "Zigapagos — Astro's islands, a native core, no Node",
.description = "A static site generator with a fast native core and Astro-style TSX islands. Zero JS by default, native SPAs, and a migration path off Astro. No Node, no Vite, no bundler config.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "index.shtml",
.draft = false,
---
```

- [ ] **Step 4: Write the first three sections**

Replace `site/layouts/index.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">

  <section id="s-hero" class="hero wrap">
    <p class="kicker">zigapagos</p>
    <h1>Astro's islands. A native core. No Node.</h1>
    <p class="lede">
      Zigapagos renders your pages with a single fast binary and adds
      interactivity one component at a time &mdash; TSX islands, server-rendered
      at build time, hydrated in the browser only where you ask for it.
    </p>
    <p class="cta-row">
      <a class="btn btn-primary" href="$site.page('docs/quick-start').link()">Get started</a>
      <a class="btn btn-ghost" href="$site.page('demos').link()">See it running</a>
    </p>
    <div class="demo">
      <island src="components/Counter.island.tsx" client:visible></island>
      <p class="demo-caption">
        <strong>That button is a real island on this page.</strong>
        It was server-rendered into the HTML you received, then hydrated when it
        scrolled into view. View source &mdash; there is no framework runtime
        wrapping the rest of the page.
      </p>
    </div>
  </section>

  <section id="s-zerojs" class="section wrap">
    <p class="eyebrow">Zero JS by default</p>
    <h2>A page with no islands ships no JavaScript. None.</h2>
    <div class="grid-3">
      <div class="stat">
        <strong>0 KB</strong>
        <span>JavaScript on a page with no islands &mdash; every docs page on this site</span>
      </div>
      <div class="stat">
        <strong>1</strong>
        <span>shared runtime, however many islands a page has</span>
      </div>
      <div class="stat">
        <strong>0</strong>
        <span>Node, Vite, webpack or bundler config in your project</span>
      </div>
    </div>
    <p class="section-note">
      This page is the exception, and deliberately so: it is a demo, so it ships
      the runtime plus the islands you can click. Open the network tab on
      <a href="$site.page('docs/overview').link()">any docs page</a> and you will
      find no script at all. A generator that claimed otherwise would be caught
      by anyone opening devtools, so we would rather say it plainly.
    </p>
  </section>

  <section id="s-pipeline" class="section wrap">
    <p class="eyebrow">One binary and Bun</p>
    <h2>The whole build, and nothing you have to configure</h2>
    <div class="grid-2">
      <div>
        <pre class="pipeline"><code>content/*.smd    ──►  native core  ──┐
                    (SuperMD/SuperHTML)  │
                                         ├──►  static site
components/*.island.tsx ──►  Bun SSR  ───┤     + import map
                        └──►  bundle  ───┘     + one runtime</code></pre>
      </div>
      <div>
        <p>
          Content and templates are rendered by a native binary. Islands are
          server-rendered and bundled by Bun. That is the entire toolchain: no
          Node install, no bundler configuration, no plugin ecosystem to keep
          current.
        </p>
        <p>
          <a href="$site.page('docs/overview').link()">How the build works →</a>
        </p>
      </div>
    </div>
  </section>

</main>
```

- [ ] **Step 5: Add the section styles**

Append to `site/assets/style.css`:

```css
.section { padding-block: var(--space-8); border-top: 1px solid var(--color-border); }
.section h2 {
  font-size: var(--text-3xl); line-height: var(--leading-tight);
  letter-spacing: -0.025em; margin: 0 0 var(--space-6); max-width: 34ch;
}
.eyebrow {
  font-family: var(--font-mono); text-transform: uppercase;
  letter-spacing: 0.12em; font-size: var(--text-xs);
  color: var(--color-accent); margin: 0 0 var(--space-2);
}
.section-note { color: var(--color-muted); font-size: var(--text-sm); max-width: 62ch; }
.section-note a, .section a { color: var(--color-accent); }

.cta-row { display: flex; gap: var(--space-3); flex-wrap: wrap; margin: 0 0 var(--space-6); }
.btn {
  display: inline-block; padding: var(--space-3) var(--space-5);
  border-radius: var(--radius-sm); text-decoration: none;
  font-size: var(--text-sm); font-weight: 550; border: 1px solid transparent;
}
.btn-primary { background: var(--color-accent); color: var(--color-bg); }
.btn-primary:hover { background: var(--color-accent-hover); }
.btn-ghost { border-color: var(--color-border); color: var(--color-text); }
.btn-ghost:hover { border-color: var(--color-accent); color: var(--color-accent); }

.grid-2 { display: grid; gap: var(--space-6); grid-template-columns: repeat(auto-fit, minmax(19rem, 1fr)); }
.grid-3 { display: grid; gap: var(--space-4); grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); }
.card {
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: var(--radius-md); padding: var(--space-5);
}
.card h3 { margin: 0 0 var(--space-2); font-size: var(--text-lg); }
.card p { margin: 0; color: var(--color-muted); font-size: var(--text-sm); }
.stat {
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: var(--radius-md); padding: var(--space-5);
  display: flex; flex-direction: column; gap: var(--space-2);
}
.stat strong { font-size: var(--text-3xl); letter-spacing: -0.03em; color: var(--color-accent); }
.stat span { color: var(--color-muted); font-size: var(--text-sm); }
pre.pipeline {
  font-family: var(--font-mono); font-size: var(--text-xs);
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: var(--radius-md); padding: var(--space-4); overflow-x: auto;
  line-height: 1.5;
}
```

- [ ] **Step 6: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 7: Commit**

```bash
git add site/content/index.smd site/layouts/index.shtml site/assets/style.css site/test/build.sh
git commit -m "site: rebuild the landing page hero, budget and pipeline sections

The landing page was a hero and a bullet list. These are the first three of
nine sections, and they set the pattern for the rest: markup lives in the
layout because SuperMD rejects raw HTML outright (html_is_forbidden), so
index.smd is now frontmatter only.

The zero-JS section states this page's own exception rather than hiding it. A
generator whose pitch is 'no JavaScript unless you ask' cannot ship a landing
page full of islands and imply the number is zero — anyone can open devtools.
Saying which pages ship what is the more defensible claim, and it is true."
```

---

### Task 3: Landing page — islands explained, with a CodeTabs island

Adds the tabbed source→output→live component, which is itself an island.

**Files:**
- Create: `site/components/CodeTabs.island.tsx`
- Modify: `site/build.zig`
- Modify: `site/layouts/index.shtml`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `.section`, `.eyebrow`, `.grid-2` from Task 2.
- Produces: `CodeTabs` island with `export interface Props { tabs: { label: string; code: string; lang?: string }[] }`. Props are passed from the layout as a JSON string via `prop-tabs` is **not** used — they are passed as a Ziggy struct through `:props`, because `Props` is a typed array of objects and the build typechecks the resolved value against it.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 3: the islands section renders and its island is bundled + SSR'd.
grep -q 'id="s-islands"' "$OUT/index.html" || { echo "FAIL: islands section missing"; exit 1; }
test -f "$OUT/islands/CodeTabs.island.js" || { echo "FAIL: CodeTabs bundle missing"; exit 1; }
grep -q 'zp-codetabs' "$OUT/index.html" || { echo "FAIL: CodeTabs not server-rendered"; exit 1; }
grep -q 'zp-tab-on' "$OUT/index.html" || { echo "FAIL: CodeTabs did not SSR its open tab"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: islands section missing`

- [ ] **Step 3: Write the CodeTabs island**

Create `site/components/CodeTabs.island.tsx`:

```tsx
import { useState } from "@z/runtime";

export interface Props {
  tabs: { label: string; code: string }[];
}

/**
 * Tabbed code viewer. Server-rendered with the first tab open, so the code is
 * in the HTML and readable (and indexable) before hydration; clicking only
 * becomes live once the island hydrates.
 */
export default function CodeTabs({ tabs }: Props) {
  const [active, setActive] = useState(0);
  return (
    <div class="zp-codetabs">
      <div class="zp-codetabs-bar" role="tablist">
        {tabs.map((t, i) => (
          <button
            type="button"
            role="tab"
            aria-selected={i === active}
            class={i === active ? "zp-tab zp-tab-on" : "zp-tab"}
            onClick={() => setActive(i)}
          >
            {t.label}
          </button>
        ))}
      </div>
      <pre class="zp-codetabs-body"><code>{tabs[active].code}</code></pre>
    </div>
  );
}
```

- [ ] **Step 4: Register the island in the build**

Modify `site/build.zig`, replacing the `islands` constant:

```zig
    const islands: []const zigapagos.Island = &.{
        .{ .root = b.path("components/Counter.island.tsx"), .src = "components/Counter.island.tsx" },
        .{ .root = b.path("components/CodeTabs.island.tsx"), .src = "components/CodeTabs.island.tsx" },
    };
```

- [ ] **Step 5: Add the section to the landing page**

Insert into `site/layouts/index.shtml`, immediately after the `s-zerojs` section and before `s-pipeline`:

```html
  <section id="s-islands" class="section wrap">
    <p class="eyebrow">Islands in 30 seconds</p>
    <h2>Write a component. Say when it should wake up.</h2>
    <div class="grid-2">
      <island src="components/CodeTabs.island.tsx" client:visible :props='{
        .tabs = [
          { .label = "Counter.island.tsx", .code = "import { useState } from \"@z/runtime\";\n\nexport interface Props { start?: number }\n\nexport default function Counter({ start = 0 }: Props) {\n  const [n, setN] = useState(start);\n  return <button onClick={() => setN(n + 1)}>Clicked {n} times</button>;\n}\n" },
          { .label = "index.shtml", .code = "<island src=\"components/Counter.island.tsx\"\n        client:visible\n        prop-start=\"0\"></island>\n" },
          { .label = "what ships", .code = "<!-- server-rendered into the HTML -->\n<z-island id=\"z-island-0\">\n  <button>Clicked 0 times</button>\n</z-island>\n<script type=\"application/json\" data-z-props>{\"start\":0}</script>\n\n<!-- plus one shared runtime, once per page -->\n<script type=\"module\" src=\"/zigapagos-runtime.js\"></script>\n" }
        ] }'></island>
      <div>
        <p>
          An island is a TSX component with a <code>client:</code> directive.
          Zigapagos renders it to HTML at build time so the page is complete
          without JavaScript, then ships just that component's code plus one
          shared runtime.
        </p>
        <p>
          Props are typechecked at build time against the component's exported
          <code>Props</code> type. A misspelled prop fails the build rather than
          rendering <code>undefined</code> in production.
        </p>
        <p><a href="$site.page('docs/islands').link()">Islands reference →</a></p>
      </div>
    </div>
  </section>
```

- [ ] **Step 6: Add the CodeTabs styles**

Append to `site/assets/style.css`:

```css
.zp-codetabs { border: 1px solid var(--color-border); border-radius: var(--radius-md); overflow: hidden; }
.zp-codetabs-bar { display: flex; background: var(--color-surface); border-bottom: 1px solid var(--color-border); }
.zp-tab {
  font-family: var(--font-mono); font-size: var(--text-xs);
  background: none; border: none; border-bottom: 2px solid transparent;
  color: var(--color-muted); padding: var(--space-3) var(--space-4); cursor: pointer;
}
.zp-tab-on { color: var(--color-accent); border-bottom-color: var(--color-accent); }
.zp-codetabs-body {
  margin: 0; padding: var(--space-4); overflow-x: auto;
  font-family: var(--font-mono); font-size: var(--text-xs); line-height: 1.6;
  background: var(--color-bg);
}
```

- [ ] **Step 7: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 8: Commit**

```bash
git add site/components/CodeTabs.island.tsx site/build.zig site/layouts/index.shtml site/assets/style.css site/test/build.sh
git commit -m "site: explain islands with a tabbed viewer that is itself an island

The section showing what an island is had no reason to be a static screenshot
when the generator can render the real thing. CodeTabs server-renders with the
first tab open, so the code is present and readable before hydration and the
tabs only become interactive once the island wakes — which is the behaviour the
section is describing, demonstrated rather than asserted.

Props go through :props as a Ziggy struct rather than prop-tabs, because the
build typechecks the resolved value against the exported Props type and an
array of objects has no scalar attribute form."
```

---

### Task 4: The docs mirror generator

Generates `site/content/docs/*.smd` from canonical repo markdown. This is the single largest correctness risk in the plan: SuperMD is stricter than CommonMark, so the generator must produce content the build accepts, and the build failing is the gate that proves it.

**Files:**
- Create: `site/scripts/docs-registry.json`
- Create: `site/scripts/gen-docs-mirror.ts`
- Create: `site/test/docs-mirror.sh`
- Modify: `site/.gitignore`
- Modify: `site/package.json`
- Modify: `.github/workflows/pages.yml`
- Modify: `docs/islands.md`, `docs/spa.md`, `docs/cross-tier-codegen.md`, `docs/observability.md`, `docs/ROADMAP.md`, `docs/migration/astro-to-zigapagos.md`, `docs/migration/recipes.md`, `docs/migration/react-spa-bridge.md` (banner only)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `site/content/docs/<mirror>.smd` files with Ziggy frontmatter carrying `.title`, `.description`, `.layout = "docs.shtml"`, and `.custom = { .slug = "<slug>" }`. Task 5's `docs.shtml` reads `$page.custom.get('slug')` for sidebar active state.

- [ ] **Step 1: Write the failing mirror test**

Create `site/test/docs-mirror.sh`:

```bash
#!/usr/bin/env bash
# site/test/docs-mirror.sh — the docs mirror is generated, complete, and fresh.
#
# Mirrors are gitignored build artifacts. This asserts three things the site
# silently depends on: that every registry entry produces a file, that the
# generated frontmatter is Ziggy (not YAML, which SuperMD would reject), and
# that regenerating produces no diff — i.e. the generator is deterministic and
# nobody has hand-edited a mirror.
set -euo pipefail
cd "$(dirname "$0")/.."

bun run scripts/gen-docs-mirror.ts

MISSING=0
while IFS= read -r mirror; do
  if [ ! -f "content/docs/$mirror" ]; then
    echo "FAIL: registry entry produced no file: content/docs/$mirror"
    MISSING=1
  fi
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.mirror)')
[ "$MISSING" -eq 0 ] || exit 1

# Ziggy frontmatter, not YAML: the first line must be `---` and the second
# must be a Ziggy field assignment.
while IFS= read -r mirror; do
  head -2 "content/docs/$mirror" | tail -1 | grep -qE '^\s*\.title = ' \
    || { echo "FAIL: $mirror has no Ziggy .title in frontmatter"; exit 1; }
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.mirror)')

# Determinism: a second run must not change anything.
BEFORE=$(cat content/docs/*.smd | shasum | cut -d' ' -f1)
bun run scripts/gen-docs-mirror.ts >/dev/null
AFTER=$(cat content/docs/*.smd | shasum | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: generator is not deterministic"; exit 1; }

# No mirror may be committed — they are build artifacts.
while IFS= read -r mirror; do
  if git ls-files --error-unmatch "content/docs/$mirror" >/dev/null 2>&1; then
    echo "FAIL: mirror is tracked in git: content/docs/$mirror"
    exit 1
  fi
done < <(bun -e 'for (const e of require("./scripts/docs-registry.json")) console.log(e.mirror)')

echo PASS
```

Make it executable: `chmod +x site/test/docs-mirror.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `bash site/test/docs-mirror.sh`
Expected: FAIL — `scripts/gen-docs-mirror.ts` does not exist, so bun errors with a module-not-found.

- [ ] **Step 3: Write the registry**

Create `site/scripts/docs-registry.json`:

```json
[
  {
    "canonical": "docs/islands.md",
    "mirror": "islands.smd",
    "slug": "islands",
    "title": "Islands",
    "description": "TSX islands: authoring, the client: directives, typed props, slots, and what gets emitted."
  },
  {
    "canonical": "docs/spa.md",
    "mirror": "spa.smd",
    "slug": "spa",
    "title": "Native SPAs",
    "description": "Build a client-routed application from a single .spa.tsx: prerendered skeletons, guards, nested layouts, and deploy manifests."
  },
  {
    "canonical": "docs/cross-tier-codegen.md",
    "mirror": "cross-tier-codegen.smd",
    "slug": "cross-tier-codegen",
    "title": "Cross-tier codegen",
    "description": "Generating a typed client from a shared schema so the Zig and TypeScript tiers cannot drift."
  },
  {
    "canonical": "docs/observability.md",
    "mirror": "observability.smd",
    "slug": "observability",
    "title": "Observability",
    "description": "Build diagnostics, timing, and what to look at when a build is slow or a page is wrong."
  },
  {
    "canonical": "docs/migration/astro-to-zigapagos.md",
    "mirror": "migrate-from-astro.smd",
    "slug": "migrate-from-astro",
    "title": "Migrating from Astro",
    "description": "A deterministic mapping from Astro projects to Zigapagos, and what `zigapagos migrate` does automatically."
  },
  {
    "canonical": "docs/migration/recipes.md",
    "mirror": "migration-recipes.smd",
    "slug": "migration-recipes",
    "title": "Migration recipes",
    "description": "Concrete conversions for the patterns an Astro codebase actually contains."
  },
  {
    "canonical": "docs/migration/react-spa-bridge.md",
    "mirror": "react-spa-bridge.smd",
    "slug": "react-spa-bridge",
    "title": "React SPA bridge",
    "description": "Running existing React SPA code on the shared runtime while you port it."
  },
  {
    "canonical": "docs/ROADMAP.md",
    "mirror": "roadmap.smd",
    "slug": "roadmap",
    "title": "Roadmap",
    "description": "What is planned, what is deferred, and the upstream sync policy."
  },
  {
    "canonical": "CHANGELOG.md",
    "mirror": "changelog.smd",
    "slug": "changelog",
    "title": "Changelog",
    "description": "Notable changes to Zigapagos, starting at the first public release."
  }
]
```

- [ ] **Step 4: Write the generator**

Create `site/scripts/gen-docs-mirror.ts`:

```ts
// Generate site doc pages from canonical repo markdown.
//
// Mirrors under site/content/docs/ are gitignored build artifacts — edit the
// canonical file (docs/*.md, docs/migration/*.md, or the root CHANGELOG.md),
// never the mirror.
//
// Two transformations are not optional:
//
//   1. Frontmatter must be ZIGGY, not YAML. SuperMD parses frontmatter as
//      Ziggy and a YAML block is a hard error.
//   2. Relative .md links must be rewritten. A link to ./spa.md resolves on
//      GitHub and 404s on the site, so published targets become site routes
//      and everything else becomes an absolute GitHub URL.
//
// What this script deliberately does NOT do is sanitise HTML. SuperMD rejects
// raw HTML with `html_is_forbidden`, so a canonical doc that grows an HTML
// block fails the site build loudly. Silently stripping it would hide an
// authoring mistake and produce a page missing content.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

interface Entry {
  canonical: string;
  mirror: string;
  slug: string;
  title: string;
  description: string;
}

const SITE_DIR = dirname(dirname(fileURLToPath(import.meta.url)));
const REPO_ROOT = dirname(SITE_DIR);
const REGISTRY: Entry[] = JSON.parse(
  readFileSync(join(SITE_DIR, "scripts/docs-registry.json"), "utf8"),
);

const BLOB = "https://github.com/valthon/zigapagos/blob/main/";
const TREE = "https://github.com/valthon/zigapagos/tree/main/";

// Every repo path that has a published site route, so a link to one resolves
// internally instead of bouncing the reader to GitHub. Authored pages are
// listed alongside the mirrored ones.
const PUBLISHED = new Map<string, string>([
  ...REGISTRY.map((e) => [e.canonical, e.slug] as [string, string]),
  ["docs/overview.md", "overview"],
  ["docs/quick-start.md", "quick-start"],
  ["docs/tutorial.md", "tutorial"],
  ["docs/configuration.md", "configuration"],
]);

/** Strip the canonical-only "also published on the site" banner blockquote. */
function stripBanner(body: string): string {
  return body.replace(
    /(^|\n)> This documentation is also published[^\n]*(\n>[^\n]*)*\n?/,
    "$1",
  );
}

/** Resolve a relative link target against the canonical file's directory. */
function resolveRepoPath(path: string, canonicalDir: string): string {
  const stack = canonicalDir ? canonicalDir.split("/") : [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    else if (part === "..") stack.pop();
    else stack.push(part);
  }
  return stack.join("/");
}

/**
 * Rewrite link TARGETS, never link text. A published .md target becomes a
 * site-relative route; any other repo path becomes an absolute GitHub URL,
 * with a warning so an unpublished-but-linked doc is visible rather than
 * quietly degrading into an off-site jump.
 */
function rewriteLinks(body: string, canonicalPath: string): string {
  const dir = canonicalPath.includes("/")
    ? canonicalPath.slice(0, canonicalPath.lastIndexOf("/"))
    : "";
  return body.replace(/\]\(([^)\s]+)\)/g, (match, target: string) => {
    const hash = target.indexOf("#");
    const path = hash >= 0 ? target.slice(0, hash) : target;
    const anchor = hash >= 0 ? target.slice(hash) : "";
    if (path === "") return match; // in-page anchor
    if (/^(https?:|mailto:)/i.test(path)) return match; // absolute
    if (path.startsWith("/")) return match; // root-absolute, leave as authored

    const repoPath = resolveRepoPath(path, dir);
    const slug = PUBLISHED.get(repoPath);
    if (slug) return `](../${slug}/${anchor})`;

    console.warn(`gen-docs-mirror: [${canonicalPath}] "${path}" → GitHub (${repoPath})`);
    const base = path.endsWith("/") ? TREE : BLOB;
    return `](${base}${repoPath}${anchor})`;
  });
}

/** Ziggy frontmatter. JSON.stringify gives a correctly escaped Ziggy string. */
function frontmatter(e: Entry): string {
  const q = (v: string) => JSON.stringify(v);
  return [
    "---",
    `.title = ${q(e.title)},`,
    `.description = ${q(e.description)},`,
    `.date = @date("2026-07-27T00:00:00"),`,
    `.author = "Zigapagos",`,
    `.layout = "docs.shtml",`,
    `.draft = false,`,
    `.custom = { .slug = ${q(e.slug)}, .canonical = ${q(e.canonical)} },`,
    "---",
    "",
  ].join("\n");
}

for (const entry of REGISTRY) {
  const raw = readFileSync(join(REPO_ROOT, entry.canonical), "utf8");
  const body = rewriteLinks(stripBanner(raw), entry.canonical);
  const out =
    frontmatter(entry) +
    `[]($section.id("generated"))\n\n` +
    body;
  writeFileSync(join(SITE_DIR, "content/docs", entry.mirror), out);
  console.log(`gen-docs-mirror: ${entry.mirror} <- ${entry.canonical}`);
}
```

Note on the `[]($section.id("generated"))` line: it gives the mirrored body a
SuperMD section id so `docs.shtml` can render it independently of the authored
pages. If the build rejects it, remove that line and the corresponding
`+ ... +` concatenation — nothing else depends on it.

- [ ] **Step 5: Gitignore the mirrors**

Append to `site/.gitignore`:

```
# Generated from canonical docs by scripts/gen-docs-mirror.ts — never commit.
# Edit the canonical file (docs/*.md, docs/migration/*.md, CHANGELOG.md).
content/docs/islands.smd
content/docs/spa.smd
content/docs/cross-tier-codegen.smd
content/docs/observability.smd
content/docs/migrate-from-astro.smd
content/docs/migration-recipes.smd
content/docs/react-spa-bridge.smd
content/docs/roadmap.smd
content/docs/changelog.smd
```

- [ ] **Step 6: Add the script entry**

Modify `site/package.json`:

```json
{
  "name": "zigapagos-site",
  "private": true,
  "type": "module",
  "scripts": {
    "gen:docs": "bun run scripts/gen-docs-mirror.ts"
  },
  "dependencies": {
    "@z/runtime": "file:../runtime"
  }
}
```

- [ ] **Step 7: Run the mirror test to verify it passes**

Run: `mkdir -p site/content/docs && bash site/test/docs-mirror.sh`
Expected: `PASS`. Warnings of the form `gen-docs-mirror: [docs/spa.md] "…" → GitHub (…)` are expected for links to source files.

- [ ] **Step 8: Add banners to the canonical docs**

Insert as the first line of each canonical file, followed by a blank line. For `docs/islands.md`:

```
> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/islands/> — the site is the canonical reading experience.
```

Repeat with the matching URL slug for: `docs/spa.md` (`spa`), `docs/cross-tier-codegen.md` (`cross-tier-codegen`), `docs/observability.md` (`observability`), `docs/ROADMAP.md` (`roadmap`), `docs/migration/astro-to-zigapagos.md` (`migrate-from-astro`), `docs/migration/recipes.md` (`migration-recipes`), `docs/migration/react-spa-bridge.md` (`react-spa-bridge`).

Do **not** add one to `CHANGELOG.md` — its opening paragraphs explain the file's own provenance and a banner above them reads as noise.

- [ ] **Step 9: Verify the banner is stripped**

Run: `bun run site/scripts/gen-docs-mirror.ts && head -12 site/content/docs/islands.smd`
Expected: the Ziggy frontmatter followed by the doc's `# Islands` heading — **no** banner blockquote.

- [ ] **Step 10: Wire the mirror into the Pages workflow**

Modify `.github/workflows/pages.yml`. In the `Build site` step, run the mirror before `zig build`:

```yaml
      - name: Build site
        run: |
          bun install --frozen-lockfile
          bun run scripts/gen-docs-mirror.ts
          zig build
        working-directory: site
```

- [ ] **Step 11: Commit**

```bash
git add site/scripts site/test/docs-mirror.sh site/.gitignore site/package.json \
        .github/workflows/pages.yml docs/islands.md docs/spa.md \
        docs/cross-tier-codegen.md docs/observability.md docs/ROADMAP.md \
        docs/migration/astro-to-zigapagos.md docs/migration/recipes.md \
        docs/migration/react-spa-bridge.md
git commit -m "site: generate docs pages from the canonical repo markdown

Publishing the docs means either duplicating four thousand lines of prose into
site/content or generating it. Duplication loses immediately: the canonical
docs are what contributors edit, and a second copy diverges on the first PR
that touches one.

The generator does two transformations that are not optional. Frontmatter is
emitted as Ziggy, because SuperMD parses frontmatter as Ziggy and a YAML block
is a hard error. And relative .md links are rewritten, because ./spa.md
resolves on GitHub and 404s on the site — published targets become site routes,
everything else becomes an absolute GitHub URL with a warning so a linked but
unpublished doc is visible rather than silently bouncing the reader off-site.

It deliberately does not sanitise HTML. SuperMD rejects raw HTML outright, so a
canonical doc that grows an HTML block fails the site build; stripping it
silently would hide the mistake and publish a page missing content.

Mirrors are gitignored by exact filename so one can never be committed and
then hand-edited, which is the failure mode that makes generated docs rot."
```

---

### Task 5: The docs shell — sidebar, TOC, and prose

**Files:**
- Create: `site/layouts/docs.shtml`
- Create: `site/layouts/docs-index.shtml`
- Create: `site/assets/docs.css`
- Create: `site/content/docs/index.smd`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `base.shtml` from Task 1; `.custom.get('slug')` set by Task 4's generator and by Task 6's authored pages.
- Produces: the `docs.shtml` layout that every docs page (authored and mirrored) selects.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 5: the docs shell exists, has a sidebar and a TOC, and ships no JS.
test -f "$OUT/docs/index.html" || { echo "FAIL: docs index missing"; exit 1; }
test -f "$OUT/docs/islands/index.html" || { echo "FAIL: mirrored islands doc missing"; exit 1; }
grep -q 'class="docs-sidebar"' "$OUT/docs/islands/index.html" || { echo "FAIL: docs sidebar missing"; exit 1; }
grep -q 'class="docs-toc"' "$OUT/docs/islands/index.html" || { echo "FAIL: docs TOC missing"; exit 1; }
grep -q 'zigapagos-runtime.js' "$OUT/docs/islands/index.html" \
  && { echo "FAIL: a docs page shipped the island runtime"; exit 1; }
grep -q 'aria-current="page"' "$OUT/docs/islands/index.html" || { echo "FAIL: sidebar has no active state"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: docs index missing`

- [ ] **Step 3: Write the docs section root**

Create `site/content/docs/index.smd`:

```
---
.title = "Documentation",
.description = "Everything Zigapagos does: islands, native SPAs, migration from Astro, configuration, and reference.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "docs-index.shtml",
.draft = false,
.custom = { .slug = "index" },
---

Start with the [overview](/zigapagos/docs/overview/) for what Zigapagos is and how a
build runs. If you would rather have something on screen first, the
[quick start](/zigapagos/docs/quick-start/) gets a site building in about five minutes,
and the [tutorial](/zigapagos/docs/tutorial/) builds a real one with islands in it.
```

- [ ] **Step 4: Write the docs layout**

Create `site/layouts/docs.shtml`. The sidebar is a hand-maintained list rather than a loop over `$page.subpages()`: ordering docs by a custom field is not expressible, and encoding order in `.date` to abuse the default sort is the kind of trick that confuses the next reader. ZigBase's sidebar is hand-maintained for the same reason.

```html
<extend template="base.shtml">
<head id="head">
  <link type="text/css" rel="stylesheet" href="$site.asset('docs.css').link()">
</head>
<main id="main">
  <div class="docs-shell">
    <aside class="docs-sidebar">
      <nav aria-label="Documentation">
        <p class="docs-group">Getting started</p>
        <ul>
          <li><a href="$site.page('docs/overview').link()"
                 :attr="$page.custom.get('slug').eql('overview').then('aria-current', 'page')">Overview</a></li>
          <li><a href="$site.page('docs/quick-start').link()"
                 :attr="$page.custom.get('slug').eql('quick-start').then('aria-current', 'page')">Quick start</a></li>
          <li><a href="$site.page('docs/tutorial').link()"
                 :attr="$page.custom.get('slug').eql('tutorial').then('aria-current', 'page')">Tutorial</a></li>
          <li><a href="$site.page('docs/configuration').link()"
                 :attr="$page.custom.get('slug').eql('configuration').then('aria-current', 'page')">Configuration</a></li>
        </ul>
        <p class="docs-group">Guides</p>
        <ul>
          <li><a href="$site.page('docs/islands').link()"
                 :attr="$page.custom.get('slug').eql('islands').then('aria-current', 'page')">Islands</a></li>
          <li><a href="$site.page('docs/spa').link()"
                 :attr="$page.custom.get('slug').eql('spa').then('aria-current', 'page')">Native SPAs</a></li>
          <li><a href="$site.page('docs/cross-tier-codegen').link()"
                 :attr="$page.custom.get('slug').eql('cross-tier-codegen').then('aria-current', 'page')">Cross-tier codegen</a></li>
        </ul>
        <p class="docs-group">Migrating</p>
        <ul>
          <li><a href="$site.page('docs/migrate-from-astro').link()"
                 :attr="$page.custom.get('slug').eql('migrate-from-astro').then('aria-current', 'page')">From Astro</a></li>
          <li><a href="$site.page('docs/migration-recipes').link()"
                 :attr="$page.custom.get('slug').eql('migration-recipes').then('aria-current', 'page')">Recipes</a></li>
          <li><a href="$site.page('docs/react-spa-bridge').link()"
                 :attr="$page.custom.get('slug').eql('react-spa-bridge').then('aria-current', 'page')">React SPA bridge</a></li>
        </ul>
        <p class="docs-group">Reference</p>
        <ul>
          <li><a href="$site.page('docs/observability').link()"
                 :attr="$page.custom.get('slug').eql('observability').then('aria-current', 'page')">Observability</a></li>
          <li><a href="$site.page('docs/roadmap').link()"
                 :attr="$page.custom.get('slug').eql('roadmap').then('aria-current', 'page')">Roadmap</a></li>
          <li><a href="$site.page('docs/changelog').link()"
                 :attr="$page.custom.get('slug').eql('changelog').then('aria-current', 'page')">Changelog</a></li>
        </ul>
      </nav>
    </aside>

    <article class="docs-body prose">
      <h1 :text="$page.title"></h1>
      <div :html="$page.content()"></div>
    </article>

    <aside class="docs-toc">
      <p class="docs-group">On this page</p>
      <div :html="$page.toc()"></div>
    </aside>
  </div>
</main>
```

**If `:attr="…then(…)"` is rejected by SuperHTML**, replace each link with the
explicit two-branch form, which uses only confirmed builtins:

```html
          <li>
            <ctx :if="$page.custom.get('slug').eql('overview')">
              <a aria-current="page" href="$site.page('docs/overview').link()">Overview</a>
            </ctx>
            <ctx :if="$page.custom.get('slug').eql('overview').not()">
              <a href="$site.page('docs/overview').link()">Overview</a>
            </ctx>
          </li>
```

If `.not()` is also unavailable, drop active state to a single `<ctx :if>` that
adds a `<span class="docs-active-dot">●</span>` marker beside the current page
and keep the plain `<a>` unconditional. Active state is a nicety; a build error
is not.

- [ ] **Step 5: Write the docs index layout**

Create `site/layouts/docs-index.shtml`:

```html
<extend template="base.shtml">
<head id="head">
  <link type="text/css" rel="stylesheet" href="$site.asset('docs.css').link()">
</head>
<main id="main">
  <div class="wrap prose">
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
    <div class="grid-3 docs-cards">
      <a class="card" href="$site.page('docs/overview').link()">
        <h3>Overview</h3><p>What Zigapagos is and how a build runs.</p>
      </a>
      <a class="card" href="$site.page('docs/quick-start').link()">
        <h3>Quick start</h3><p>A site building in about five minutes.</p>
      </a>
      <a class="card" href="$site.page('docs/tutorial').link()">
        <h3>Tutorial</h3><p>Build a real site, with islands in it.</p>
      </a>
      <a class="card" href="$site.page('docs/islands').link()">
        <h3>Islands</h3><p>Directives, typed props, slots, output.</p>
      </a>
      <a class="card" href="$site.page('docs/spa').link()">
        <h3>Native SPAs</h3><p>One .spa.tsx to a client-routed app.</p>
      </a>
      <a class="card" href="$site.page('docs/migrate-from-astro').link()">
        <h3>From Astro</h3><p>The deterministic mapping, and the migrate command.</p>
      </a>
    </div>
  </div>
</main>
```

- [ ] **Step 6: Write the docs stylesheet**

Create `site/assets/docs.css`:

```css
.docs-shell {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-6) var(--space-5) var(--space-9);
  display: grid;
  gap: var(--space-7);
  grid-template-columns: 15rem minmax(0, 1fr) 13rem;
  align-items: start;
}
@media (max-width: 60rem) {
  .docs-shell { grid-template-columns: minmax(0, 1fr); }
  .docs-toc { display: none; }
  .docs-sidebar { position: static; max-height: none; }
}

.docs-sidebar, .docs-toc {
  position: sticky; top: 4rem;
  max-height: calc(100vh - 5rem); overflow-y: auto;
  font-size: var(--text-sm);
}
.docs-group {
  font-family: var(--font-mono); text-transform: uppercase;
  letter-spacing: 0.1em; font-size: var(--text-xs);
  color: var(--color-muted); margin: var(--space-5) 0 var(--space-2);
}
.docs-sidebar ul, .docs-toc ul { list-style: none; margin: 0; padding: 0; }
.docs-sidebar li { margin: 0; }
.docs-sidebar a, .docs-toc a {
  display: block; padding: var(--space-1) var(--space-2);
  color: var(--color-muted); text-decoration: none;
  border-left: 2px solid transparent; border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
}
.docs-sidebar a:hover, .docs-toc a:hover { color: var(--color-accent); background: var(--color-surface); }
.docs-sidebar a[aria-current='page'] {
  color: var(--color-accent); border-left-color: var(--color-accent);
  background: var(--color-surface); font-weight: 550;
}
.docs-toc { color: var(--color-muted); }
.docs-toc li { margin: 0; }
.docs-toc ul ul { padding-left: var(--space-3); }
.docs-body { padding-block: 0; max-width: none; }
.docs-body h1 { margin-top: 0; }
.docs-cards { margin-top: var(--space-7); }
.docs-cards.grid-3 a.card { text-decoration: none; color: inherit; }
.docs-cards.grid-3 a.card:hover { border-color: var(--color-accent); }
```

- [ ] **Step 7: Regenerate mirrors and run the gate**

Run: `bun run site/scripts/gen-docs-mirror.ts && bash site/test/build.sh`
Expected: `PASS`. If SuperMD rejects a mirrored doc, the error names the file and construct — fix the **canonical** file, not the mirror.

- [ ] **Step 8: Commit**

```bash
git add site/layouts/docs.shtml site/layouts/docs-index.shtml site/assets/docs.css \
        site/content/docs/index.smd site/test/build.sh
git commit -m "site: docs shell with a sidebar, an on-this-page TOC, and no JavaScript

Every doc now renders into a three-column shell. \$page.toc() gives the
on-this-page column for free, which is the argument for using the generator's
own primitives rather than a client-side heading scanner.

The sidebar is a hand-maintained list, not a loop over \$page.subpages().
Ordering by a custom field is not expressible, and the usual workaround —
encoding sort order in .date so the default sort happens to be right — is a
trick that reads as a bug to the next person. ZigBase's sidebar is hand-written
for the same reason. Adding a doc is one registry entry and one line here.

The gate asserts a docs page does not contain the island runtime. That is the
zero-JS claim the landing page makes, pinned so it fails the build rather than
quietly becoming false the first time someone drops an island into the shell."
```

---

### Task 6: The four authored docs pages

**Files:**
- Create: `site/content/docs/overview.smd`
- Create: `site/content/docs/quick-start.smd`
- Create: `site/content/docs/tutorial.smd`
- Create: `site/content/docs/configuration.smd`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `docs.shtml` from Task 5; the `.custom.get('slug')` values it matches on.
- Produces: the four on-ramp routes the sidebar and landing CTAs already link to.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 6: the authored on-ramp exists.
for d in overview quick-start tutorial configuration; do
  test -f "$OUT/docs/$d/index.html" || { echo "FAIL: authored doc $d missing"; exit 1; }
done
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: authored doc overview missing`

- [ ] **Step 3: Write the overview**

Create `site/content/docs/overview.smd`:

```
---
.title = "Overview",
.description = "What Zigapagos is, how a build runs, and when to reach for it.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "docs.shtml",
.draft = false,
.custom = { .slug = "overview" },
---

Zigapagos is a static site generator. It renders content and templates with a
single native binary, and adds interactivity one component at a time using TSX
islands that are server-rendered at build time and hydrated in the browser only
where you ask for it.

## The three inputs

A Zigapagos project has three kinds of source file, and each is handled by a
different part of the pipeline.

**Content** lives in `content/` as SuperMD (`.smd`) — Markdown with Ziggy
frontmatter and a few extensions. A file's frontmatter names the layout that
renders it. A directory becomes a *section* when it contains an `index.smd`.

**Layouts** live in `layouts/` as SuperHTML (`.shtml`). These are HTML templates
with attribute-driven directives rather than a template language embedded in
strings, which means an editor can check them as HTML. Layouts compose with
`<extend template="base.shtml">` and `<super>`.

**Components** live wherever you like as `.island.tsx`, and are declared in
`build.zig`. They are ordinary TSX using the hooks exported by `@z/runtime`.

## How a build runs

The pass order is fixed and worth knowing, because it decides what a failure
costs you:

1. Config validation, content scan, parse, analyze.
2. **SPA prerender** — this runs early on purpose. It is the pass that executes
   your own code (the sidecar calls each `.spa.tsx`'s `describe` and
   `staticPaths`) and it carries the spec validation. Running it before any page
   is written means a bad SPA declaration aborts before the output tree has been
   touched.
3. Page render and emit.
4. The props-check gate — every rendered island's resolved props are typechecked
   against its exported `Props` type.
5. Asset installs, last, because earlier passes bump refcounts the install phase
   reads.

## What it is not

Zigapagos does not run your components on a server at request time. There is no
server. It does not ship a virtual DOM to pages that have no islands. And it
does not have a plugin ecosystem — the toolchain is the binary plus Bun, which is
the point, but it does mean a capability that does not exist is not one npm
install away.

## Where to go next

The [quick start](../quick-start/) has a site building in about five minutes. The
[tutorial](../tutorial/) builds a real one. If you are coming from Astro, read
[migrating from Astro](../migrate-from-astro/) first — much of the conversion is
mechanical and `zigapagos migrate` does it for you.
```

- [ ] **Step 4: Write the quick start**

Create `site/content/docs/quick-start.smd`:

```
---
.title = "Quick start",
.description = "Install the toolchain, generate a site, and see it rebuild as you edit.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "docs.shtml",
.draft = false,
.custom = { .slug = "quick-start" },
---

## Install the toolchain

Zigapagos needs Zig 0.16 and Bun 1.2. The repository pins both with
[mise](https://mise.jdx.dev/), so the shortest path is:

```sh
git clone https://github.com/valthon/zigapagos
cd zigapagos
mise install
```

If `zig` resolves to a different version, the build fails at *configure* time
with a wall of dependency errors mentioning `std.Io.Dir` and `Child.StdIo`. They
look like defects in the code and are pure version skew. Check `zig version`
before believing them.

## Build the binary

```sh
zig build
```

That produces `zig-out/bin/zigapagos`.

## Generate a site

```sh
mkdir my-site && cd my-site
../zig-out/bin/zigapagos init
```

`init` writes a complete sample site: a homepage, an about page, a blog section,
a devlog, the layouts that render them, and the assets they reference. It is
worth reading before deleting — the sample copy demonstrates SuperMD syntax you
will otherwise have to look up.

## Run the development server

```sh
../zig-out/bin/zigapagos
```

The site rebuilds when you edit content, layouts, or assets, and the page in
your browser refreshes itself.

## Add an island

Create `components/Hello.island.tsx`:

```tsx
import { useState } from "@z/runtime";

export interface Props { name: string }

export default function Hello({ name }: Props) {
  const [waves, setWaves] = useState(0);
  return (
    <button onClick={() => setWaves(waves + 1)}>
      Hello {name} — waved {waves} times
    </button>
  );
}
```

Declare it in `build.zig`:

```zig
const islands: []const zigapagos.Island = &.{
    .{ .root = b.path("components/Hello.island.tsx"), .src = "components/Hello.island.tsx" },
};
```

And use it in a layout — **not** in a `.smd` file, which rejects raw HTML:

```html
<island src="components/Hello.island.tsx" client:visible prop-name="world"></island>
```

Rebuild. The button is server-rendered into the HTML, and hydrates when it
scrolls into view.

## Next

The [tutorial](../tutorial/) builds something real. [Islands](../islands/) is the
full reference for directives, props, and slots.
```

- [ ] **Step 5: Write the tutorial**

Create `site/content/docs/tutorial.smd`:

```
---
.title = "Tutorial",
.description = "Build a small documentation site with a section, a shared layout, and two islands.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "docs.shtml",
.draft = false,
.custom = { .slug = "tutorial" },
---

This builds a small documentation site: a homepage, a guides section that lists
its own pages, a shared layout, and two islands — one that needs JavaScript
immediately and one that does not. It assumes you have finished the
[quick start](../quick-start/).

## 1. The shared layout

Every page wants the same document shell, so put it in a template that others
extend. Create `layouts/templates/base.shtml`:

```html
<!DOCTYPE html>
<html lang="en">
  <head id="head">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title :text="$page.title"></title>
    <link type="text/css" rel="stylesheet" href="$site.asset('style.css').link()">
    <super>
  </head>
  <body id="body">
    <nav>
      <a href="$site.page('').link()">Home</a>
      <a href="$site.page('guides').link()">Guides</a>
    </nav>
    <super>
  </body>
</html>
```

The two `<super>` elements are the extension points. A layout that extends this
supplies a `<head id="head">` and a `<body id="body">` whose contents are
spliced in.

## 2. A page layout

Create `layouts/page.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<body id="body">
  <article>
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
  </article>
</body>
```

`:text` sets an element's text content and escapes it. `:html` inserts already-
rendered HTML, which is what `$page.content()` returns.

## 3. A section that lists itself

A directory becomes a section when it has an `index.smd`. Create
`content/guides/index.smd`:

```
---
.title = "Guides",
.date = @date("2026-07-27T00:00:00"),
.author = "You",
.layout = "guides.shtml",
.draft = false,
---

Everything we have written down.
```

Then `layouts/guides.shtml`, which loops over the section's pages:

```html
<extend template="base.shtml">
<head id="head"></head>
<body id="body">
  <h1 :text="$page.title"></h1>
  <div :html="$page.content()"></div>
  <ul>
    <li :loop="$page.subpages()">
      <a href="$loop.it.link()" :text="$loop.it.title"></a>
    </li>
  </ul>
</body>
```

Add `content/guides/deploying.smd` with `.layout = "page.shtml"` and any body
text, rebuild, and it appears in the list. Nothing registers it — being in the
directory is the registration.

## 4. An island that must be interactive immediately

Some components are broken without JavaScript. A search box is the usual
example: it renders, but typing does nothing until it hydrates, so it should
hydrate as early as possible. Create `components/Filter.island.tsx`:

```tsx
import { useState } from "@z/runtime";

export interface Props { items: string[] }

export default function Filter({ items }: Props) {
  const [q, setQ] = useState("");
  const shown = items.filter((i) => i.toLowerCase().includes(q.toLowerCase()));
  return (
    <div>
      <input
        value={q}
        placeholder="Filter…"
        onInput={(e) => setQ((e.target as HTMLInputElement).value)}
      />
      <ul>{shown.map((i) => <li>{i}</li>)}</ul>
    </div>
  );
}
```

Use it with `client:load` — hydrate as soon as the page's JavaScript runs:

```html
<island src="components/Filter.island.tsx" client:load
        :props='{ .items = ["deploying", "islands", "assets"] }'></island>
```

## 5. An island that can wait

A component below the fold does not need to hydrate before it is visible. Use
`client:visible`, and the browser only fetches and runs its code when the
component scrolls into view:

```html
<island src="components/Feedback.island.tsx" client:visible></island>
```

The choice between directives is the whole performance story. `client:load` for
things that are broken until interactive; `client:idle` for things that can wait
for a quiet moment; `client:visible` for anything below the fold;
`client:media` for components that only matter at a breakpoint; `client:only` for
components that cannot be server-rendered at all.

## 6. Typed props

Every island should export its props type:

```tsx
export interface Props { items: string[] }
```

At build time each rendered `<island>`'s resolved props — `:props` merged with
any `prop-NAME` overrides — are typechecked against that type. A misspelled prop
or a number where a string belongs fails the build with the page and the
component named, rather than rendering `undefined` in production.

## Where to go next

[Islands](../islands/) is the complete reference. If you want client-side routing
rather than separate pages, [native SPAs](../spa/) covers building a whole
application from one `.spa.tsx`.
```

- [ ] **Step 6: Write the configuration reference**

Create `site/content/docs/configuration.smd`:

```
---
.title = "Configuration",
.description = "zigapagos.ziggy, the website() build options, and what each one changes.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "docs.shtml",
.draft = false,
.custom = { .slug = "configuration" },
---

A Zigapagos project is configured in two places: `zigapagos.ziggy` describes the
site, and `build.zig` declares the islands and SPAs the build must compile.

## zigapagos.ziggy

```ziggy
Site {
    .title = "My Site",
    .host_url = "https://example.com",
    .url_path_prefix = "",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
    .deploy_target = "zigbase",
}
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

`.deploy_target` selects which host configuration the build emits — `zigbase`,
`nginx`, or `apache`. See [native SPAs](../spa/) for what each one generates.

## build.zig

```zig
const std = @import("std");
const zigapagos = @import("zigapagos");

pub fn build(b: *std.Build) void {
    const islands: []const zigapagos.Island = &.{
        .{ .root = b.path("components/Counter.island.tsx"),
           .src = "components/Counter.island.tsx" },
    };

    const spas: []const zigapagos.Spa = &.{
        .{ .root = b.path("app/app.spa.tsx"),
           .src = "app/app.spa.tsx",
           .base = "/app" },
    };

    const site = zigapagos.website(b, .{
        .islands = islands,
        .spas = spas,
        .not_found = "app",
        .output_path = "site",
        .force = true,
    });
    b.getInstallStep().dependOn(&site.step);
}
```

`.root` is a build-graph path; `.src` is the same file as a string relative to
the project root, and is what an `<island src="…">` attribute must match.

`.base` on an SPA **must** equal the `base` exported from the `.spa.tsx` module.
The build validates the match and fails loudly if they diverge, because a
mismatch produces an application whose router and whose prerendered shells
disagree about where they live.

`.not_found` names which SPA owns the site-wide `404.html`, by file basename
without the `.spa.tsx` suffix. Set it explicitly when there is more than one SPA;
otherwise declaration order decides, which is not a property you want a
deployment to depend on.

`.force = true` allows the build to overwrite an existing output tree.

## A note on failure and partial output

Build failures write the output tree in place, so a failure partway through
leaves a partially updated site. The pass order limits the damage — SPA
validation runs before any page is written — but it is not atomicity. Build to a
staging directory if you are deploying by syncing the output tree.
```

- [ ] **Step 7: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 8: Commit**

```bash
git add site/content/docs/overview.smd site/content/docs/quick-start.smd \
        site/content/docs/tutorial.smd site/content/docs/configuration.smd \
        site/test/build.sh
git commit -m "site: write the four docs pages that had no canonical source

The mirrored docs are reference material — they answer 'what does this flag do'
well and 'how do I start' not at all. These four are the reading path, and they
are authored rather than generated because there is no canonical file to
generate them from.

The tutorial teaches the directive choice through two components rather than
listing five directives: one that is broken until it hydrates and one that can
wait until it is on screen. That distinction is the whole performance argument,
and a table of directive names does not convey it.

Configuration documents url_path_prefix with the failure it causes — a
hand-written internal link works locally and 404s under a prefix — because that
is the property that makes the rule worth following."
```

---

### Task 7: Demos index and the directive visualizer

**Files:**
- Create: `site/components/DirectiveDemo.island.tsx`
- Create: `site/layouts/demos.shtml`
- Create: `site/layouts/demo-directives.shtml`
- Create: `site/content/demos/index.smd`
- Create: `site/content/demos/directives.smd`
- Modify: `site/build.zig`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `base.shtml`, `.section`/`.card`/`.grid-3` classes.
- Produces: `DirectiveDemo` island with `export interface Props { directive: string; note: string }`.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 7: the demos section and all five directive instances render.
test -f "$OUT/demos/index.html" || { echo "FAIL: demos index missing"; exit 1; }
test -f "$OUT/demos/directives/index.html" || { echo "FAIL: directives demo missing"; exit 1; }
test -f "$OUT/islands/DirectiveDemo.island.js" || { echo "FAIL: DirectiveDemo bundle missing"; exit 1; }
for d in load idle visible media only; do
  grep -q "data-directive=\"client:$d\"" "$OUT/demos/directives/index.html" \
    || { echo "FAIL: client:$d instance missing"; exit 1; }
done
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: demos index missing`

- [ ] **Step 3: Write the DirectiveDemo island**

Create `site/components/DirectiveDemo.island.tsx`:

```tsx
import { useState, useEffect } from "@z/runtime";

export interface Props {
  directive: string;
  note: string;
}

/**
 * One card per client: directive. The server-rendered state says "not
 * hydrated"; the effect flips it on mount. Because hydration timing is exactly
 * what the directive controls, the card's own state IS the demonstration —
 * client:visible stays grey until you scroll it into view, client:media until
 * you cross the breakpoint.
 */
export default function DirectiveDemo({ directive, note }: Props) {
  const [hydrated, setHydrated] = useState(false);
  const [at, setAt] = useState("");

  useEffect(() => {
    setHydrated(true);
    setAt(new Date().toLocaleTimeString(undefined, { hour12: false }));
  }, []);

  return (
    <div
      class={hydrated ? "dd-card dd-on" : "dd-card"}
      data-directive={directive}
    >
      <code class="dd-name">{directive}</code>
      <p class="dd-status">
        {hydrated ? `hydrated at ${at}` : "not hydrated yet"}
      </p>
      <p class="dd-note">{note}</p>
    </div>
  );
}
```

- [ ] **Step 4: Register the island**

Modify `site/build.zig`, extending `islands`:

```zig
    const islands: []const zigapagos.Island = &.{
        .{ .root = b.path("components/Counter.island.tsx"), .src = "components/Counter.island.tsx" },
        .{ .root = b.path("components/CodeTabs.island.tsx"), .src = "components/CodeTabs.island.tsx" },
        .{ .root = b.path("components/DirectiveDemo.island.tsx"), .src = "components/DirectiveDemo.island.tsx" },
    };
```

- [ ] **Step 5: Write the demos index**

Create `site/content/demos/index.smd`:

```
---
.title = "Demos",
.description = "Live demonstrations: hydration directives, the Astro migration mapping, and a native SPA — all running on this site.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "demos.shtml",
.draft = false,
---

Everything here is running, not recorded. This site is built with Zigapagos, so
the demos are the real components rather than screenshots of them.
```

Create `site/layouts/demos.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">
  <div class="wrap prose">
    <h1 :text="$page.title"></h1>
    <div :html="$page.content()"></div>
    <div class="grid-3 docs-cards">
      <a class="card" href="$site.page('demos/directives').link()">
        <h3>Hydration directives</h3>
        <p>Watch client:load, idle, visible, media and only wake up at different moments.</p>
      </a>
      <a class="card" href="$site.page('demos/migrate').link()">
        <h3>Astro → Zigapagos</h3>
        <p>The mapping the migrate command applies, shown side by side.</p>
      </a>
      <a class="card" href="/zigapagos/demos/app/">
        <h3>A native SPA</h3>
        <p>Client-side routing, a nested layout and a guard — from one .spa.tsx.</p>
      </a>
    </div>
  </div>
</main>
```

- [ ] **Step 6: Write the directive visualizer page**

Create `site/content/demos/directives.smd`:

```
---
.title = "Hydration directives",
.description = "The five client: directives, hydrating live so you can watch when each one wakes up.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "demo-directives.shtml",
.draft = false,
---
```

Create `site/layouts/demo-directives.shtml`:

```html
<extend template="base.shtml">
<head id="head">
  <link type="text/css" rel="stylesheet" href="$site.asset('docs.css').link()">
</head>
<main id="main">
  <div class="wrap prose">
    <h1>Hydration directives</h1>
    <p class="lede">
      Five identical components, five different directives. Each says whether it
      has hydrated and when. Reload the page and watch the order they light up
      in; the timestamps are real.
    </p>
  </div>

  <section class="section wrap">
    <p class="eyebrow">Immediately</p>
    <div class="dd-row">
      <island src="components/DirectiveDemo.island.tsx" client:load :props='{
        .directive = "client:load",
        .note = "Hydrates as soon as the page script runs. Use it for components that are broken until interactive — a search box, a login form." }'></island>
      <island src="components/DirectiveDemo.island.tsx" client:idle :props='{
        .directive = "client:idle",
        .note = "Waits for the browser to be idle. Same result, later, for anything that is nice to have rather than needed at once." }'></island>
    </div>
  </section>

  <section class="section wrap">
    <p class="eyebrow">Conditionally</p>
    <p class="section-note">
      This one is deliberately below the fold. It is still grey. Scroll to it and
      it hydrates — that is the whole behaviour, and it is why below-the-fold
      components should almost always use it.
    </p>
    <div class="dd-spacer">keep scrolling</div>
    <div class="dd-row">
      <island src="components/DirectiveDemo.island.tsx" client:visible :props='{
        .directive = "client:visible",
        .note = "Hydrates when the component scrolls into view. Nothing is fetched or executed for it before that." }'></island>
      <island src="components/DirectiveDemo.island.tsx" client:media="(min-width: 60rem)" :props='{
        .directive = "client:media",
        .note = "Hydrates only when the media query matches. Narrow your window below 60rem and reload — it stays grey, and its code is never fetched." }'></island>
    </div>
  </section>

  <section class="section wrap">
    <p class="eyebrow">Never on the server</p>
    <div class="dd-row">
      <island src="components/DirectiveDemo.island.tsx" client:only :props='{
        .directive = "client:only",
        .note = "Skipped entirely at build time and rendered only in the browser. For components that touch window or document during render and cannot be server-rendered at all." }'></island>
    </div>
    <p class="section-note">
      Note what this costs: a client:only component contributes nothing to the
      HTML, so there is a blank space until it renders, and search engines see
      nothing there. Prefer any of the other four when the component can be
      server-rendered.
    </p>
  </section>
</main>
```

- [ ] **Step 7: Add the demo styles**

Append to `site/assets/style.css`:

```css
.dd-row { display: grid; gap: var(--space-4); grid-template-columns: repeat(auto-fit, minmax(17rem, 1fr)); }
.dd-card {
  border: 1px solid var(--color-border); border-radius: var(--radius-md);
  padding: var(--space-4); background: var(--color-surface);
  transition: border-color 0.2s, background 0.2s;
}
.dd-card.dd-on { border-color: var(--color-accent); background: color-mix(in srgb, var(--color-accent) 8%, var(--color-surface)); }
.dd-name { font-family: var(--font-mono); font-size: var(--text-sm); color: var(--color-accent); }
.dd-status {
  font-family: var(--font-mono); font-size: var(--text-xs);
  color: var(--color-muted); margin: var(--space-2) 0;
}
.dd-card.dd-on .dd-status { color: var(--color-accent); }
.dd-note { font-size: var(--text-sm); color: var(--color-muted); margin: 0; }
.dd-spacer {
  height: 60vh; display: grid; place-items: center;
  color: var(--color-muted); font-family: var(--font-mono); font-size: var(--text-xs);
  text-transform: uppercase; letter-spacing: 0.2em;
  border: 1px dashed var(--color-border); border-radius: var(--radius-md);
  margin-block: var(--space-5);
}
```

- [ ] **Step 8: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 9: Commit**

```bash
git add site/components/DirectiveDemo.island.tsx site/layouts/demos.shtml \
        site/layouts/demo-directives.shtml site/content/demos site/build.zig \
        site/assets/style.css site/test/build.sh
git commit -m "site: demo index and a directive visualizer that demonstrates itself

Hydration timing is the hardest part of islands to explain in prose, because
the difference between the five directives is *when* something happens and
prose can only assert it. Five identical components differing only in directive
make it observable: client:visible stays grey below a deliberate 60vh spacer
until you scroll, and client:media stays grey until the window is wide enough.

The client:only card carries its own downside — no server-rendered content,
nothing for a crawler — because a page demonstrating five options should say
which one is usually wrong."
```

---

### Task 8: The Astro migration before/after demo

**Files:**
- Create: `site/components/MigrateDiff.island.tsx`
- Create: `site/layouts/demo-migrate.shtml`
- Create: `site/content/demos/migrate.smd`
- Modify: `site/build.zig`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `base.shtml`, `.section`, `.eyebrow`.
- Produces: `MigrateDiff` island with `export interface Props { cases: { title: string; note: string; before: string; after: string }[] }`.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 8: the migration demo renders with its island bundled.
test -f "$OUT/demos/migrate/index.html" || { echo "FAIL: migrate demo missing"; exit 1; }
test -f "$OUT/islands/MigrateDiff.island.js" || { echo "FAIL: MigrateDiff bundle missing"; exit 1; }
grep -q 'zp-migrate' "$OUT/demos/migrate/index.html" || { echo "FAIL: MigrateDiff not server-rendered"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: migrate demo missing`

- [ ] **Step 3: Write the MigrateDiff island**

Create `site/components/MigrateDiff.island.tsx`:

```tsx
import { useState } from "@z/runtime";

export interface Props {
  cases: { title: string; note: string; before: string; after: string }[];
}

/**
 * Before/after viewer for the Astro→Zigapagos mapping. Server-rendered showing
 * the first case in full, so the content is present and indexable without
 * JavaScript; the case selector becomes live on hydration.
 */
export default function MigrateDiff({ cases }: Props) {
  const [i, setI] = useState(0);
  const c = cases[i];
  return (
    <div class="zp-migrate">
      <div class="zp-migrate-picker" role="tablist">
        {cases.map((k, n) => (
          <button
            type="button"
            role="tab"
            aria-selected={n === i}
            class={n === i ? "zp-tab zp-tab-on" : "zp-tab"}
            onClick={() => setI(n)}
          >
            {k.title}
          </button>
        ))}
      </div>
      <p class="zp-migrate-note">{c.note}</p>
      <div class="zp-migrate-pair">
        <div class="zp-migrate-side">
          <p class="zp-migrate-label zp-before">Astro</p>
          <pre><code>{c.before}</code></pre>
        </div>
        <div class="zp-migrate-side">
          <p class="zp-migrate-label zp-after">Zigapagos</p>
          <pre><code>{c.after}</code></pre>
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Register the island**

Modify `site/build.zig`, adding to `islands`:

```zig
        .{ .root = b.path("components/MigrateDiff.island.tsx"), .src = "components/MigrateDiff.island.tsx" },
```

- [ ] **Step 5: Write the page**

Create `site/content/demos/migrate.smd`:

```
---
.title = "Astro → Zigapagos",
.description = "The mapping `zigapagos migrate` applies, shown side by side for the patterns an Astro project actually contains.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "demo-migrate.shtml",
.draft = false,
---
```

Create `site/layouts/demo-migrate.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">
  <div class="wrap prose">
    <h1>Astro → Zigapagos</h1>
    <p class="lede">
      Most of an Astro project converts mechanically, and
      <code>zigapagos migrate</code> does that part for you. These are the
      mappings it applies. The cases it cannot decide are reported rather than
      guessed.
    </p>
    <pre><code>zigapagos migrate ./my-astro-site ./my-zigapagos-site</code></pre>
  </div>

  <section class="section wrap">
    <p class="eyebrow">The mapping</p>
    <island src="components/MigrateDiff.island.tsx" client:visible :props='{
      .cases = [
        { .title = "A component",
          .note = "React and Preact components become .island.tsx with the same hooks. The import source changes; the component body usually does not.",
          .before = "// src/components/Counter.jsx\nimport { useState } from \"react\";\n\nexport default function Counter({ start }) {\n  const [n, setN] = useState(start);\n  return <button onClick={() => setN(n + 1)}>{n}</button>;\n}\n",
          .after = "// components/Counter.island.tsx\nimport { useState } from \"@z/runtime\";\n\nexport interface Props { start: number }\n\nexport default function Counter({ start }: Props) {\n  const [n, setN] = useState(start);\n  return <button onClick={() => setN(n + 1)}>{n}</button>;\n}\n" },
        { .title = "Using it",
          .note = "Astro directives map one to one onto client: attributes. Props become prop-NAME attributes, or a :props struct when they are structured.",
          .before = "---\nimport Counter from \"../components/Counter.jsx\";\n---\n<Counter client:visible start={0} />\n",
          .after = "<island src=\"components/Counter.island.tsx\"\n        client:visible\n        prop-start=\"0\"></island>\n" },
        { .title = "Frontmatter",
          .note = "Astro frontmatter is YAML; Zigapagos frontmatter is Ziggy. Known fields map by name and everything else moves under .custom, read as $page.custom.get(...) in the layout.",
          .before = "---\ntitle: Hello\ndescription: A page\nhero:\n  eyebrow: Hi\n  title: We build things\n---\n",
          .after = "---\n.title = \"Hello\",\n.description = \"A page\",\n.date = @date(\"2026-01-01T00:00:00\"),\n.author = \"You\",\n.layout = \"page.shtml\",\n.draft = false,\n.custom = { .hero = { .eyebrow = \"Hi\", .title = \"We build things\" } },\n---\n" },
        { .title = "A layout",
          .note = "Astro layouts with slots become SuperHTML templates with <super> extension points. Expressions move out of braces and into attribute directives.",
          .before = "---\nconst { title } = Astro.props;\n---\n<html>\n  <head><title>{title}</title></head>\n  <body><slot /></body>\n</html>\n",
          .after = "<!DOCTYPE html>\n<html>\n  <head id=\"head\">\n    <title :text=\"$page.title\"></title>\n    <super>\n  </head>\n  <body id=\"body\"><super></body>\n</html>\n" }
      ] }'></island>
  </section>

  <section class="section wrap">
    <p class="eyebrow">What it will not do</p>
    <h2>The parts that need a decision get reported, not guessed</h2>
    <div class="grid-2">
      <div class="card">
        <h3>Integrations</h3>
        <p>
          An Astro integration has no equivalent to convert into. The migration
          lists each one so you can decide whether it is replaceable, needed, or
          already covered.
        </p>
      </div>
      <div class="card">
        <h3>Server-rendered routes</h3>
        <p>
          Zigapagos has no request-time rendering. An SSR endpoint becomes either
          a build-time computation or a call to a real backend, and which one is
          a design decision.
        </p>
      </div>
    </div>
    <p class="section-note">
      The full mapping is specified in
      <a href="$site.page('docs/migrate-from-astro').link()">migrating from Astro</a>,
      written precisely enough that an agent can complete a port unattended, with
      per-pattern conversions in
      <a href="$site.page('docs/migration-recipes').link()">recipes</a>.
    </p>
  </section>
</body>
```

- [ ] **Step 6: Add the styles**

Append to `site/assets/style.css`:

```css
.zp-migrate { border: 1px solid var(--color-border); border-radius: var(--radius-md); overflow: hidden; }
.zp-migrate-picker { display: flex; flex-wrap: wrap; background: var(--color-surface); border-bottom: 1px solid var(--color-border); }
.zp-migrate-note {
  margin: 0; padding: var(--space-4);
  color: var(--color-muted); font-size: var(--text-sm);
  border-bottom: 1px solid var(--color-border);
}
.zp-migrate-pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(18rem, 1fr)); }
.zp-migrate-side { min-width: 0; border-right: 1px solid var(--color-border); }
.zp-migrate-side:last-child { border-right: none; }
.zp-migrate-label {
  margin: 0; padding: var(--space-2) var(--space-4);
  font-family: var(--font-mono); font-size: var(--text-xs);
  text-transform: uppercase; letter-spacing: 0.1em;
  border-bottom: 1px solid var(--color-border);
}
.zp-before { color: var(--color-secondary); }
.zp-after { color: var(--color-accent); }
.zp-migrate-pair pre {
  margin: 0; padding: var(--space-4); overflow-x: auto;
  font-family: var(--font-mono); font-size: var(--text-xs); line-height: 1.6;
}
```

- [ ] **Step 7: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 8: Commit**

```bash
git add site/components/MigrateDiff.island.tsx site/layouts/demo-migrate.shtml \
        site/content/demos/migrate.smd site/build.zig site/assets/style.css \
        site/test/build.sh
git commit -m "site: show the Astro migration mapping side by side

Someone already on Astro is the highest-intent visitor this site gets, and the
question they have is not whether islands are good — it is how much of their
codebase survives. Four before/after pairs answer that faster than the
specification does.

The section on what migrate will not convert is not a disclaimer. Integrations
have no equivalent and SSR routes need a design decision, and finding that out
after starting a port is worse than reading it here."
```

---

### Task 9: The embedded native SPA

**Files:**
- Create: `site/demo/views.tsx`
- Create: `site/demo/app.spa.tsx`
- Modify: `site/build.zig`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (the SPA is self-contained; it uses its own inline styles plus site tokens).
- Produces: prerendered shells under `zig-out/site/demos/app/`, and `spa/app.js`.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 9: the embedded SPA prerenders shells and bundles its entry.
test -f "$OUT/demos/app/index.html" || { echo "FAIL: SPA index shell missing"; exit 1; }
test -f "$OUT/demos/app/guides/index.html" || { echo "FAIL: SPA nested shell missing"; exit 1; }
test -f "$OUT/spa/app.js" || { echo "FAIL: SPA bundle missing"; exit 1; }
grep -q '/zigapagos/spa/app.js' "$OUT/demos/app/index.html" \
  || { echo "FAIL: SPA bundle URL not prefixed"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: SPA index shell missing`

- [ ] **Step 3: Write the SPA views**

Create `site/demo/views.tsx`:

```tsx
import { Link, useParams, host } from "@z/runtime";
import type { ComponentChildren } from "@z/runtime";

export function AppShell({ children }: { children?: ComponentChildren }) {
  return (
    <div class="spa">
      <nav class="spa-nav">
        <Link href="/">Home</Link>
        <Link href="/guides">Guides</Link>
        <Link href="/guides/islands">A guide</Link>
        <Link href="/account">Account</Link>
      </nav>
      <div class="spa-body">{children}</div>
      <p class="spa-foot">
        Every link above changes the URL without a page load. This entire
        application is one <code>.spa.tsx</code> file.
      </p>
    </div>
  );
}

export function Home() {
  return (
    <div>
      <h2>A native SPA</h2>
      <p>
        You arrived here on a prerendered HTML shell — view source and the
        heading is in it. Navigation from now on is client-side.
      </p>
    </div>
  );
}

export function GuidesLayout({ children }: { children?: ComponentChildren }) {
  return (
    <div>
      <h2>Guides</h2>
      <p class="spa-hint">
        This layout stays mounted while you move between the guides below — that
        is what a nested route is for.
      </p>
      <div class="spa-nested">{children}</div>
    </div>
  );
}

export function GuidesIndex() {
  return <p>Pick a guide: <Link href="/guides/islands">islands</Link>.</p>;
}

export function Guide() {
  const params = useParams();
  return <p>You are reading the <strong>{params.slug ?? "islands"}</strong> guide.</p>;
}

export function Account() {
  return (
    <div>
      <h2>Account</h2>
      <p>The guard let you through. Clear the cookie and reload to see it stop you.</p>
    </div>
  );
}

export function Denied() {
  return (
    <div>
      <h2>Not signed in</h2>
      <p>
        This route has a guard. It ran in your browser after the shell was
        served, which is why the shell itself can still be a static file.
      </p>
      <button
        type="button"
        class="demo-counter"
        onClick={() => {
          host.cookies.set("zp_demo_session", "ok");
          location.reload();
        }}
      >
        Sign in (sets a cookie)
      </button>
    </div>
  );
}

export function NotFound() {
  return <p>No such route.</p>;
}
```

- [ ] **Step 4: Write the SPA module**

Create `site/demo/app.spa.tsx`:

```tsx
import { Router, host, type GuardResult } from "@z/runtime";
import {
  AppShell, Home, GuidesLayout, GuidesIndex, Guide,
  Account, Denied, NotFound,
} from "./views.tsx";

export const spa = {
  base: "/demos/app",
  title: "Zigapagos SPA demo",
};

// Client-only gate. The shell is served statically to anyone; the check runs
// after mount, which is what lets a guarded route still be a static file.
const requireSession = async (): Promise<GuardResult> =>
  host.cookies.get("zp_demo_session") === "ok" ? true : { redirect: "/denied" };

export const routes = [
  { path: "/", component: Home },
  {
    path: "/guides", component: GuidesLayout, children: [
      { path: "/", component: GuidesIndex },
      { path: "/:slug", component: Guide, staticPaths: () => [{ slug: "islands" }] },
    ],
  },
  { path: "/denied", component: Denied },
  { path: "/account", component: Account, guard: requireSession },
];

export default function App() {
  return (
    <AppShell>
      <Router base={spa.base} routes={routes} notFound={NotFound} />
    </AppShell>
  );
}
```

- [ ] **Step 4a: Give the site a real 404 page**

Declaring an SPA makes the build write a **site-wide `404.html` from that SPA's
`/` shell**. Without intervention, a visitor who mistypes a docs URL lands
inside the demo application — the marketing site would have no 404 page of its
own, only the demo's.

`CLAUDE.md` documents the remedy in its architecture notes: the site-wide
`404.html` is written *before* the page pass, so a content page explicitly
aliased to `404.html` overwrites the SPA fallback rather than losing to it.
Create `site/content/404.smd`:

```
---
.title = "Page not found",
.description = "That page does not exist. Try the documentation index or the homepage.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "page.shtml",
.draft = false,
.aliases = ["/404.html"],
---

That page does not exist — it may have moved, or the link may be wrong.

Try the [documentation]($link.page("docs")) index, or go back to the
[homepage]($link.site()).
```

Note `$link.site()`, not `$link.page("")` — an empty path is rejected. There is
a purpose-built directive for the site root: `supermd/src/context.zig:791`
exposes `site` on the Link type and `context/utils.zig:242` documents it as
"Sets the source location of this directive to the site's home page", taking an
optional locale code. (`$site.page('')` works in `.shtml` — `base.shtml` uses it
for the nav — but the prose directive is a different surface.) Never hand-write
`/zigapagos/` to work around a directive you have not found yet.

**Note the leading slash.** `.aliases` entries are section-relative unless they
start with `/` (`worker.zig` only treats an alias as absolute when it does), so
`"404.html"` lands at `404/404.html` and the SPA shell keeps winning at the
root — a build that passes while silently failing to do the one thing this step
exists for.

Verify after building that `zig-out/site/404.html` contains this page's text and
**not** the SPA shell, and add an assertion to `site/test/build.sh` pinning it —
this is a behaviour that silently reverts if the alias is ever dropped. A
`zig-out/site/404/index.html` will also exist; that is the page's own route and
is expected.

- [ ] **Step 5: Wire the SPA into the build**

Modify `site/build.zig`. Add the `spas` constant and pass it to `website`. Note `.base` must equal the module's exported `spa.base` exactly — the build validates this:

```zig
    const spas: []const zigapagos.Spa = &.{
        .{ .root = b.path("demo/app.spa.tsx"), .src = "demo/app.spa.tsx", .base = "/demos/app" },
    };

    const site = zigapagos.website(b, .{
        .islands = islands,
        .spas = spas,
        .not_found = "app",
        .output_path = "site",
        .force = true,
    });
```

Also add `.spas = spas` to the `zigapagos.serve` options so the dev server serves it.

- [ ] **Step 6: Add the SPA styles**

Append to `site/assets/style.css`:

```css
.spa { max-width: var(--container-max); margin: 0 auto; padding: var(--space-7) var(--space-5); }
.spa-nav {
  display: flex; gap: var(--space-4); flex-wrap: wrap;
  padding-bottom: var(--space-4); border-bottom: 1px solid var(--color-border);
}
.spa-nav a { color: var(--color-accent); text-decoration: none; font-size: var(--text-sm); }
.spa-nav a:hover { text-decoration: underline; }
.spa-body { padding-block: var(--space-6); min-height: 14rem; }
.spa-hint { color: var(--color-muted); font-size: var(--text-sm); }
.spa-nested {
  border: 1px dashed var(--color-border); border-radius: var(--radius-md);
  padding: var(--space-4); margin-top: var(--space-4);
}
.spa-foot { color: var(--color-muted); font-size: var(--text-sm); border-top: 1px solid var(--color-border); padding-top: var(--space-4); }
```

- [ ] **Step 7: Add the landing-page SPA section**

Insert into `site/layouts/index.shtml`, after the `s-islands` section:

```html
  <section id="s-spa" class="section wrap">
    <p class="eyebrow">Native SPAs</p>
    <h2>When a site should be an application, it is still one file</h2>
    <div class="grid-2">
      <div>
        <p>
          Export a route table from a <code>.spa.tsx</code> and Zigapagos
          prerenders a real HTML shell for every static route, then hands over to
          a client-side router. Nested layouts, route guards, code-split routes
          and declarative redirects are part of the route table, not a library
          you add.
        </p>
        <p>
          The shells are static files, so a guarded route still deploys to a CDN —
          the guard runs in the browser after the shell is served.
        </p>
        <p>
          <a class="btn btn-primary" href="/zigapagos/demos/app/">Open the demo app</a>
        </p>
      </div>
      <div>
        <pre class="pipeline"><code>export const spa = { base: "/app" };

export const routes = [
  { path: "/", component: Home },
  { path: "/guides", component: Layout, children: [
      { path: "/:slug", component: Guide },
  ]},
  { path: "/account", component: Account,
    guard: requireSession },
];</code></pre>
      </div>
    </div>
  </section>
```

- [ ] **Step 8: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

If the build fails with a base mismatch, `.base` in `build.zig` and `spa.base` in
`app.spa.tsx` disagree — they must be byte-identical.

- [ ] **Step 9: Commit**

```bash
git add site/demo site/build.zig site/layouts/index.shtml site/assets/style.css site/test/build.sh
git commit -m "site: embed a real native SPA at /demos/app

The SPA documentation is 1,600 lines and every claim in it is testable, which
is a reason to run one rather than describe it. This demo exercises the four
features that are hard to believe from prose: a prerendered shell per static
route (view source and the heading is there), a nested layout that stays
mounted across child navigation, a guard that runs client-side so the shell
stays a static file, and soft navigation that changes the URL without a load.

The gate asserts the bundle URL is prefixed. Under url_path_prefix an unprefixed
/spa/app.js resolves fine locally and 404s on Pages, which is exactly the class
of bug AUDF-005 covered in src/spa.zig and worth pinning here too."
```

---

### Task 10: Compare and Download pages

**Files:**
- Create: `site/layouts/compare.shtml`
- Create: `site/layouts/download.shtml`
- Create: `site/content/compare.smd`
- Create: `site/content/download.smd`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `base.shtml`, `.section`, `.card`, `.grid-2`.
- Produces: the `/compare/` and `/download/` routes the nav already links to.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 10: compare and download exist, and compare names its alternatives.
test -f "$OUT/compare/index.html" || { echo "FAIL: compare page missing"; exit 1; }
test -f "$OUT/download/index.html" || { echo "FAIL: download page missing"; exit 1; }
for tool in Astro Eleventy Hugo; do
  grep -q "$tool" "$OUT/compare/index.html" || { echo "FAIL: compare omits $tool"; exit 1; }
done
grep -q 'id="when-not-to"' "$OUT/compare/index.html" || { echo "FAIL: compare has no 'when not to' section"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: compare page missing`

- [ ] **Step 3: Write the compare page**

Create `site/content/compare.smd`:

```
---
.title = "Compare",
.description = "How Zigapagos differs from Astro, Next.js static export, Eleventy, Hugo, and the generator it forks.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "compare.shtml",
.draft = false,
---
```

Create `site/layouts/compare.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">
  <div class="wrap prose">
    <h1>How Zigapagos compares</h1>
    <p class="lede">
      Every tool here is good at something. This page is about which trade it
      makes, not which one wins.
    </p>
  </div>

  <section class="section wrap">
    <p class="eyebrow">At a glance</p>
    <div class="table-scroll">
      <table class="cmp">
        <thead>
          <tr>
            <th>Property</th><th>Zigapagos</th><th>Astro</th>
            <th>Next (static export)</th><th>Eleventy</th><th>Hugo</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>Islands / partial hydration</td><td>Yes</td><td>Yes</td><td>No — whole-page hydration</td><td>No</td><td>No</td></tr>
          <tr><td>JS on a page with no components</td><td>None</td><td>None</td><td>Framework runtime</td><td>None</td><td>None</td></tr>
          <tr><td>Node required</td><td>No</td><td>Yes</td><td>Yes</td><td>Yes</td><td>No</td></tr>
          <tr><td>Bundler to configure</td><td>No</td><td>Vite</td><td>Turbopack/webpack</td><td>Bring your own</td><td>No</td></tr>
          <tr><td>Component language</td><td>TSX</td><td>TSX/JSX/Vue/Svelte</td><td>TSX/JSX</td><td>Templates only</td><td>Templates only</td></tr>
          <tr><td>Build-time props typechecking</td><td>Yes</td><td>No</td><td>No</td><td>n/a</td><td>n/a</td></tr>
          <tr><td>Client-routed SPA from the same project</td><td>Yes</td><td>Via a framework router</td><td>Yes</td><td>No</td><td>No</td></tr>
          <tr><td>Plugin ecosystem</td><td>No</td><td>Large</td><td>Large</td><td>Large</td><td>Moderate</td></tr>
        </tbody>
      </table>
    </div>
  </section>

  <section class="section wrap">
    <p class="eyebrow">In detail</p>
    <div class="grid-2">
      <div class="card">
        <h3>vs Astro</h3>
        <p>
          The closest comparison, and the one Zigapagos is designed against. Same
          islands model, same directives, similar authoring. The differences are
          the toolchain and the type story: no Node, no Vite, no bundler
          configuration, and island props are typechecked against the component's
          exported <code>Props</code> at build time rather than failing at
          runtime. What Astro has and this does not is an ecosystem — integrations,
          adapters, multiple UI frameworks, and years of answered questions.
        </p>
      </div>
      <div class="card">
        <h3>vs Next.js static export</h3>
        <p>
          Next exports static HTML, but the model underneath is a React
          application: the framework runtime ships whether or not a given page
          needs interactivity. Zigapagos inverts that default — a page with no
          islands ships no JavaScript. If your site is mostly application and
          incidentally content, Next is the better fit; if it is mostly content
          with pockets of interactivity, this is.
        </p>
      </div>
      <div class="card">
        <h3>vs Eleventy</h3>
        <p>
          Eleventy is excellent at turning content into HTML and takes no position
          on client-side components — which is freedom if you want it and work if
          you do not. Zigapagos has an opinion: components are TSX, hydration is a
          directive, and the bundling is handled. Eleventy also runs anywhere Node
          runs and has a far larger plugin ecosystem.
        </p>
      </div>
      <div class="card">
        <h3>vs Hugo</h3>
        <p>
          Hugo is a single fast binary with no runtime dependency, and for a pure
          content site it is hard to beat — a larger theme ecosystem, a longer
          track record, and builds that are very fast at scale. It has no islands
          model. Zigapagos keeps the single-binary property for the content half
          and adds real components for the interactive half.
        </p>
      </div>
    </div>
  </section>

  <section class="section wrap">
    <p class="eyebrow">Lineage</p>
    <h2>And the generator this forks</h2>
    <p class="section-note">
      Zigapagos is a permanent fork of Loris Cro's SSG, which contributed SuperMD,
      SuperHTML, Ziggy and the rendering core — all of it still here and still
      excellent at what it does. The fork exists to add islands, native SPAs and
      the Astro migration path. If you want the content pipeline without the
      component layer, the upstream project is smaller and closer to the source.
    </p>
  </section>

  <section id="when-not-to" class="section wrap">
    <p class="eyebrow">Honesty</p>
    <h2>When not to use Zigapagos</h2>
    <div class="grid-2">
      <div class="card">
        <h3>You need server-side rendering at request time</h3>
        <p>
          There is no server. Anything personalised per request has to happen in
          the browser or in a backend you run separately.
        </p>
      </div>
      <div class="card">
        <h3>You depend on a specific plugin ecosystem</h3>
        <p>
          There is no plugin system. A capability that does not exist is not one
          install away — it is a patch to the generator.
        </p>
      </div>
      <div class="card">
        <h3>Your team wants Vue, Svelte, or Solid</h3>
        <p>
          Islands are TSX on a Preact-compatible runtime. One component model,
          deliberately, and it is not the one you are using.
        </p>
      </div>
      <div class="card">
        <h3>You need it stable today</h3>
        <p>
          This is pre-1.0 and a minor version may break an API. Windows builds
          are currently unsupported pending the Zig 0.17 port. If a broken build
          on a Tuesday is unacceptable, wait.
        </p>
      </div>
    </div>
  </section>
</main>
```

- [ ] **Step 4: Write the download page**

Create `site/content/download.smd`:

```
---
.title = "Download",
.description = "Build Zigapagos from source, or grab a release.",
.date = @date("2026-07-27T00:00:00"),
.author = "Zigapagos",
.layout = "download.shtml",
.draft = false,
---
```

Create `site/layouts/download.shtml`:

```html
<extend template="base.shtml">
<head id="head"></head>
<main id="main">
  <div class="wrap prose">
    <h1>Download</h1>
    <p class="lede">
      Zigapagos builds to a single binary. It needs Zig 0.16 and Bun 1.2 at build
      time; the binary it produces needs Bun only when your project has islands
      or SPAs to render.
    </p>

    <h2>Build from source</h2>
    <pre><code>git clone https://github.com/valthon/zigapagos
cd zigapagos
mise install     # pins zig 0.16 + bun 1.2
zig build        # → zig-out/bin/zigapagos</code></pre>
    <p>
      If <code>zig</code> resolves to another version the build fails at configure
      time with dependency errors that look like defects and are version skew.
      Check <code>zig version</code> first.
    </p>

    <h2>Releases</h2>
    <p>
      Tagged builds are published on
      <a href="https://github.com/valthon/zigapagos/releases">the releases page</a>.
      Note that the <code>v0.7.0</code>–<code>v0.11.2</code> tags in the
      repository are inherited from before the fork and are not Zigapagos
      releases; <code>0.1.0</code> is the first.
    </p>

    <h2>Platforms</h2>
    <p>
      Linux and macOS are built and tested in CI. Windows is currently
      unsupported — two inherited source files do not compile on stable Zig
      0.16, and support returns with the Zig 0.17 port. See the
      <a href="$site.page('docs/roadmap').link()">roadmap</a>.
    </p>

    <h2>Start a project</h2>
    <pre><code>mkdir my-site &amp;&amp; cd my-site
zigapagos init   # writes a complete sample site
zigapagos        # dev server with live reload</code></pre>
    <p>
      The <a href="$site.page('docs/quick-start').link()">quick start</a> walks
      through it.
    </p>
  </div>
</main>
```

- [ ] **Step 5: Add the table styles**

Append to `site/assets/style.css`:

```css
.table-scroll { overflow-x: auto; }
table.cmp { width: 100%; border-collapse: collapse; font-size: var(--text-sm); min-width: 44rem; }
table.cmp th, table.cmp td {
  border: 1px solid var(--color-border);
  padding: var(--space-2) var(--space-3); text-align: left; vertical-align: top;
}
table.cmp th { background: var(--color-surface); font-weight: 600; }
table.cmp tbody td:nth-child(2) { color: var(--color-accent); font-weight: 550; }
```

- [ ] **Step 6: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

- [ ] **Step 7: Commit**

```bash
git add site/layouts/compare.shtml site/layouts/download.shtml \
        site/content/compare.smd site/content/download.smd \
        site/assets/style.css site/test/build.sh
git commit -m "site: comparison and download pages

The comparison states what each alternative is better at, by name — Astro's
ecosystem, Hugo's themes and track record, Eleventy's reach, Next's fit for
application-shaped sites. A comparison table where one column wins every row is
read as marketing and discarded, and correctly so.

The 'when not to use this' section is the part that earns the rest: no
request-time rendering, no plugin system, one component model, pre-1.0 with
Windows currently unsupported. Someone who finds that out in week two of a port
is worse off than someone who read it here, and so are we.

The gate pins that section's presence by id, so it cannot quietly disappear in
a later edit."
```

---

### Task 10b: The three missing landing sections

**Why this task exists.** The spec calls for nine landing sections. The plan's
own self-review noticed only six were covered and said to fold the rest into
Tasks 7, 8 and 10 as sub-steps — and then never edited those task bodies, so no
task was ever told to build them. The landing page currently has five:
`s-hero`, `s-zerojs`, `s-islands`, `s-spa`, `s-pipeline`. Three are missing.

**Files:**
- Modify: `site/layouts/index.shtml`
- Modify: `site/test/build.sh`
- Modify: `CHANGELOG.md` (one false claim — see Step 4)

**Interfaces:** consumes `.section`, `.eyebrow`, `.section-note`, `.grid-2`,
`.grid-3`, `.card`, `.btn*` from Task 2. Produces nothing later tasks need.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 10b: the landing page carries all nine sections.
for id in s-hero s-zerojs s-islands s-directives s-spa s-astro s-pipeline s-deploy s-why; do
  grep -q "id=\"$id\"" "$OUT/index.html" || { echo "FAIL: landing section $id missing"; exit 1; }
done
```

- [ ] **Step 2: Run the gate to verify it fails** — expect `FAIL: landing section s-directives missing`.

- [ ] **Step 3: Add the three sections to `site/layouts/index.shtml`**

`s-directives` goes after `s-islands`; `s-astro` after `s-spa`; `s-deploy` and
`s-why` after `s-pipeline`, at the end. Each is markup using classes Task 2
already defined. Write the copy yourself against these constraints:

- **`s-directives`** — a compact strip naming `client:load|idle|visible|media|only`
  with one clause each on when it fires, linking to
  `$site.page('demos/directives').link()`. Descriptions must match
  `runtime/src/islands.ts` (load/only immediate, idle → `requestIdleCallback`,
  visible → `IntersectionObserver`, media → `matchMedia`).
- **`s-astro`** — the migration pitch, linking to `$site.page('demos/migrate').link()`
  and `$site.page('docs/migrate-from-astro').link()`. **State what the tool
  actually does**: scans a project and writes a worklist, with an opt-in
  `--scaffold` pass over island imports. It does NOT convert a site. Getting
  this wrong is the single most-repeated defect in this plan.
- **`s-deploy`** — the zigbase / nginx / apache config emitters. Verify what is
  actually emitted before describing it (`runtime/scripts/`, `docs/spa.md`'s
  deploy-targets section, and the `csp.*` files in `zig-out/site/`).
- **`s-why`** — a short closing argument, linking to
  `$site.page('compare').link()`. Do not repeat the feature list; say who it is
  for and point at the honest "when not to use this" section on `/compare/`.

Every internal link must go through `$site.page(...).link()`.

- [ ] **Step 4: Correct `CHANGELOG.md`'s claim about this repository's tags**

`CHANGELOG.md` states that the `v0.7.0` … `v0.11.2` tags in this repository are
inherited and are not Zigapagos releases. Those tags **do not exist here** —
`git ls-remote --tags origin` returns only the single fork-point tag, `v0.1.0`
and `v0.1.1`. The file is mirrored onto the docs site, so this publishes a false
statement about the project's own history.

Rewrite that bullet to say what is true: this repository does not carry the
upstream project's release tags at all; a single fork-point tag marks where the
history diverges, and `0.1.0` is the first Zigapagos version. **Do not write the
upstream project's name** — `tests/branding.sh` allowlists `CHANGELOG.md`? Check
first with `bash tests/branding.sh` after editing; if it is not allowlisted,
phrase it without the name.

There is a **second false claim in the same passage**: it says `zigapagos
version` prints a `git describe` string derived from those inherited tags, and
gives a `v0.11.2-dev.19+...`-shaped example. `git describe --tags` on HEAD
actually yields a `v0.1.1-<n>-g<sha>` string, because the inherited tags are not
here to describe against. Correct that too.

Also check the neighbouring "No published binary releases" note: `v0.1.1` now
has published assets (`SHA256SUMS`, an `x86_64-linux-musl.tar.xz`, an
`x86_64-macos.zip`), confirmed via `gh release view v0.1.1 --repo
valthon/zigapagos`. If that note is stale, correct it too.

Run `git describe --tags` and `git ls-remote --tags origin` yourself before
writing the replacement — do not copy the values above on trust.

- [ ] **Step 5: Run the gate to verify it passes**, plus `bash tests/branding.sh`.

- [ ] **Step 6: Commit**

Explain in the message that the sections were specified but never assigned to a
task, and that the CHANGELOG claim was false about its own repository.

---

### Task 11: Logo, favicon, and social card

**Files:**
- Create: `site/assets/logo.svg`
- Create: `site/assets/og.svg`
- Modify: `site/layouts/templates/base.shtml`
- Modify: `site/assets/style.css`
- Test: `site/test/build.sh`

**Interfaces:**
- Consumes: `base.shtml` from Task 1 (replaces the CSS-gradient `.nav-mark` with the real SVG).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add the failing assertions**

Append to `site/test/build.sh` before `echo PASS`:

```bash
# Task 11: brand assets are installed and referenced.
test -f "$OUT/logo.svg" || { echo "FAIL: logo.svg not installed"; exit 1; }
test -f "$OUT/og.svg" || { echo "FAIL: og.svg not installed"; exit 1; }
grep -q 'rel="icon"' "$OUT/index.html" || { echo "FAIL: no favicon link"; exit 1; }
grep -q 'property="og:title"' "$OUT/index.html" || { echo "FAIL: no Open Graph metadata"; exit 1; }
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash site/test/build.sh`
Expected: FAIL with `FAIL: logo.svg not installed`

- [ ] **Step 3: Write the mark**

Create `site/assets/logo.svg`. Four islands, one lit — the shape is the architecture:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" role="img" aria-label="Zigapagos">
  <title>Zigapagos</title>
  <!-- An archipelago: three dormant islands and one hydrated. The lit island
       is the component that shipped JavaScript; the others are static HTML. -->
  <circle cx="8"  cy="10" r="3"   fill="#5b6169"/>
  <circle cx="23" cy="8"  r="2.2" fill="#5b6169"/>
  <circle cx="11" cy="24" r="2.2" fill="#5b6169"/>
  <circle cx="23" cy="22" r="5"   fill="#0f7a6e"/>
  <circle cx="23" cy="22" r="8"   fill="none" stroke="#0f7a6e" stroke-opacity="0.28" stroke-width="1.2"/>
</svg>
```

- [ ] **Step 4: Write the social card**

Create `site/assets/og.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">
  <rect width="1200" height="630" fill="#0d1013"/>
  <circle cx="980" cy="150" r="26"  fill="#252c32"/>
  <circle cx="1080" cy="250" r="18" fill="#252c32"/>
  <circle cx="940"  cy="300" r="16" fill="#252c32"/>
  <circle cx="1050" cy="420" r="44" fill="#3fd0bd"/>
  <circle cx="1050" cy="420" r="70" fill="none" stroke="#3fd0bd" stroke-opacity="0.25" stroke-width="3"/>
  <text x="90" y="250" font-family="system-ui, sans-serif" font-size="86" font-weight="700" fill="#e6e9ea" letter-spacing="-3">Zigapagos</text>
  <text x="90" y="330" font-family="system-ui, sans-serif" font-size="38" fill="#9aa3ab">Astro's islands. A native core. No Node.</text>
  <text x="90" y="420" font-family="ui-monospace, monospace" font-size="26" fill="#3fd0bd">zero JS by default · TSX islands · native SPAs</text>
</svg>
```

- [ ] **Step 5: Reference them from the shell**

In `site/layouts/templates/base.shtml`, add inside `<head id="head">` after the stylesheet links:

```html
    <link rel="icon" type="image/svg+xml" href="$site.asset('logo.svg').link()">
    <meta property="og:type" content="website">
    <meta property="og:title" content="$page.title">
    <meta property="og:description" content="$page.description">
    <meta property="og:image" content="$site.asset('og.svg').link()">
    <meta name="twitter:card" content="summary_large_image">
```

And replace the `.nav-mark` span with the real image:

```html
        <a class="nav-brand" href="$site.page('').link()">
          <img class="nav-mark" src="$site.asset('logo.svg').link()" alt="" width="20" height="20">
          <span :text="$site.title"></span>
        </a>
```

- [ ] **Step 6: Simplify the mark styles**

In `site/assets/style.css`, replace the `.nav-mark` rule (the radial-gradient block) with:

```css
.nav-mark { width: 1.25rem; height: 1.25rem; display: block; }
```

- [ ] **Step 7: Run the gate to verify it passes**

Run: `bash site/test/build.sh`
Expected: `PASS`

If `:attr` on a `<meta content>` is rejected, use `<meta property="og:title" content="$page.title">` — the plain attribute form with a Scripty expression.

- [ ] **Step 8: Commit**

```bash
git add site/assets/logo.svg site/assets/og.svg site/layouts/templates/base.shtml \
        site/assets/style.css site/test/build.sh
git commit -m "site: an archipelago mark, favicon and social card

Three dormant islands and one lit: the mark depicts the architecture rather
than decorating it, and the lit circle is the component that shipped
JavaScript. Both files are hand-written SVG under a kilobyte, which keeps the
brand assets consistent with a site that refuses to download a webfont.

The nav mark was a CSS radial-gradient stand-in from the shell commit; it is now
the real file, so there is one definition of the logo rather than two that
drift."
```

---

### Task 12: Link integrity, JS budget, and browser smoke tests

The final gate. Every earlier task asserted its own output exists; this asserts the site holds together.

**Files:**
- Create: `site/test/links.sh`
- Create: `site/test/js-budget.sh`
- Create: `site/test/hydrate_playwright.py`
- Create: `site/test/spa_playwright.py`
- Modify: `.github/workflows/pages.yml`
- Modify: `.github/workflows/browser-e2e.yml`

**Interfaces:**
- Consumes: the complete built tree from all earlier tasks.
- Produces: the deploy gate the Pages workflow runs.

- [ ] **Step 1: Write the link checker**

Create `site/test/links.sh`:

```bash
#!/usr/bin/env bash
# site/test/links.sh — every internal link resolves to an emitted file.
#
# The failure this catches is specific: under url_path_prefix, a hand-written
# href works in local preview and 404s in production. Checking the built tree
# is the only place that distinction is visible.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=zig-out/site
PREFIX=/zigapagos

test -d "$OUT" || { echo "FAIL: no build output — run zig build first"; exit 1; }

FAILED=0
while IFS= read -r html; do
  while IFS= read -r href; do
    # Skip external, anchors, mailto, and the SPA's client-side routes (the
    # router owns those; only its prerendered shells exist as files).
    case "$href" in
      http*|mailto:*|"#"*|"") continue ;;
    esac
    case "$href" in
      "$PREFIX"/*) rel="${href#"$PREFIX"/}" ;;
      /*) echo "FAIL: [$html] unprefixed absolute link: $href"; FAILED=1; continue ;;
      *) continue ;;  # relative links resolve against the emitted directory
    esac
    rel="${rel%%#*}"
    target="$OUT/$rel"
    if [ -f "$target" ] || [ -f "$target/index.html" ] || [ -f "${target%/}/index.html" ]; then
      continue
    fi
    echo "FAIL: [$html] broken internal link: $href"
    FAILED=1
  done < <(grep -oE '(href|src)="[^"]*"' "$html" | sed -E 's/^[a-z]+="//; s/"$//')
done < <(find "$OUT" -name '*.html')

[ "$FAILED" -eq 0 ] || exit 1
echo PASS
```

Make executable: `chmod +x site/test/links.sh`

- [ ] **Step 2: Run it and fix what it finds**

Run: `bash site/test/links.sh`
Expected: `PASS`. If it reports an unprefixed absolute link, that link was hand-written — replace it with `$site.page(...).link()` or `$site.asset(...).link()`. The demos index and the landing SPA section both hardcode `/zigapagos/demos/app/` because `$site.page()` cannot address an SPA shell; those are correct as written and the checker accepts them.

- [ ] **Step 3: Write the JS budget gate**

Create `site/test/js-budget.sh`:

```bash
#!/usr/bin/env bash
# site/test/js-budget.sh — pins the zero-JS claim the landing page makes.
#
# Docs pages must reference no script bundle at all. The landing page may, but
# not without bound: a ceiling that fails the build is the only thing stopping
# "zero JS by default" from quietly becoming false.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=zig-out/site
LANDING_CEILING_KB=60
# The s-zerojs section states a byte figure for the inline theme scripts that
# every page carries. A stated number that drifts is worse than none on a page
# that invites devtools scrutiny, so it is pinned here.
INLINE_SCRIPT_CEILING_B=1400

FAILED=0

# 1. No docs page may reference a module script.
while IFS= read -r html; do
  if grep -qE '<script[^>]+type="module"' "$html"; then
    echo "FAIL: docs page ships a module script: $html"
    FAILED=1
  fi
done < <(find "$OUT/docs" -name 'index.html')

# 2. The landing page's referenced bundles must fit the ceiling.
total=0
while IFS= read -r src; do
  rel="${src#/zigapagos/}"
  f="$OUT/$rel"
  [ -f "$f" ] || continue
  total=$(( total + $(wc -c < "$f") ))
done < <(grep -oE 'src="/zigapagos/[^"]+\.js"' "$OUT/index.html" | sed -E 's/^src="//; s/"$//')

# 3. The inline theme scripts must stay near the figure the landing copy states.
inline=$(grep -o '<script>' "$OUT/docs/overview/index.html" | wc -l)
[ "$inline" -ge 1 ] || { echo "FAIL: docs page has no inline theme script — copy claims it does"; FAILED=1; }
bytes=$(python3 -c "
import re,sys
h=open('$OUT/docs/overview/index.html',encoding='utf8').read()
print(sum(len(m.encode()) for m in re.findall(r'<script>.*?</script>', h, re.S)))
")
echo "inline theme script: ${bytes} B (ceiling ${INLINE_SCRIPT_CEILING_B} B)"
if [ "$bytes" -gt "$INLINE_SCRIPT_CEILING_B" ]; then
  echo "FAIL: inline script grew past the figure the landing page states"
  FAILED=1
fi

kb=$(( total / 1024 ))
echo "landing page JavaScript: ${kb} KB (ceiling ${LANDING_CEILING_KB} KB)"
if [ "$kb" -gt "$LANDING_CEILING_KB" ]; then
  echo "FAIL: landing page JS budget exceeded"
  FAILED=1
fi

[ "$FAILED" -eq 0 ] || exit 1
echo PASS
```

Make executable: `chmod +x site/test/js-budget.sh`

- [ ] **Step 4: Run it**

Run: `bash site/test/js-budget.sh`
Expected: `PASS`, with the measured size printed. If the measured size exceeds 60 KB, raise `LANDING_CEILING_KB` to the measured value rounded up to the next 10 — the number's job is to catch a regression, not to be aspirational.

- [ ] **Step 5: Write the hydration smoke test**

Create `site/test/hydrate_playwright.py`, modelled on `examples/tsx-site/test/hydrate_playwright.py`:

```python
"""Landing-page islands actually hydrate in a real browser.

The build gate proves an island was server-rendered. Only a browser proves it
woke up — the failure mode this catches is a page whose HTML looks correct and
whose buttons do nothing.
"""
import sys
from playwright.sync_api import sync_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080/zigapagos"


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()

        page.goto(f"{BASE}/", wait_until="networkidle")
        counter = page.locator("button.demo-counter").first
        counter.scroll_into_view_if_needed()
        before = counter.inner_text()
        counter.click()
        page.wait_for_timeout(200)
        after = counter.inner_text()
        if before == after:
            print(f"FAIL: counter island did not hydrate (text stayed {before!r})")
            return 1

        page.goto(f"{BASE}/demos/directives/", wait_until="networkidle")
        load_card = page.locator('[data-directive="client:load"]').first
        page.wait_for_timeout(400)
        if "dd-on" not in (load_card.get_attribute("class") or ""):
            print("FAIL: client:load card never hydrated")
            return 1

        visible_card = page.locator('[data-directive="client:visible"]').first
        if "dd-on" in (visible_card.get_attribute("class") or ""):
            print("FAIL: client:visible hydrated before being scrolled into view")
            return 1
        visible_card.scroll_into_view_if_needed()
        page.wait_for_timeout(600)
        if "dd-on" not in (visible_card.get_attribute("class") or ""):
            print("FAIL: client:visible did not hydrate after scrolling into view")
            return 1

        browser.close()
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: Write the SPA soft-navigation smoke test**

Create `site/test/spa_playwright.py`:

```python
"""The embedded demo SPA routes on the client without a page load."""
import sys
from playwright.sync_api import sync_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080/zigapagos"


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.goto(f"{BASE}/demos/app/", wait_until="networkidle")

        # Mark the document. A real navigation discards it; a soft one does not.
        page.evaluate("() => { window.__zp_marker = 'alive'; }")

        page.click('a[href$="/demos/app/guides"]')
        page.wait_for_timeout(400)

        if "/demos/app/guides" not in page.url:
            print(f"FAIL: URL did not change on navigation (got {page.url})")
            return 1
        if page.evaluate("() => window.__zp_marker") != "alive":
            print("FAIL: navigation reloaded the document — not a soft nav")
            return 1

        # The guarded route redirects an anonymous visitor.
        page.click('a[href$="/demos/app/account"]')
        page.wait_for_timeout(500)
        if "/denied" not in page.url:
            print(f"FAIL: guard did not redirect anonymous visitor (at {page.url})")
            return 1

        browser.close()
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 7: Run both smoke tests locally**

Run:

```sh
cd site && zig build && bunx serve zig-out -l 8080 &
sleep 2
python3 site/test/hydrate_playwright.py http://localhost:8080/zigapagos
python3 site/test/spa_playwright.py http://localhost:8080/zigapagos
kill %1
```

Expected: `PASS` from both. Note the server must serve `zig-out` (not `zig-out/site`) so the `/zigapagos` prefix resolves.

- [ ] **Step 8: Wire the new gates into the Pages workflow**

Modify `.github/workflows/pages.yml`. Replace the single deploy-gate step with all four, keeping it between the build and the upload:

```yaml
      - name: Deploy gate — build assertions
        run: bash test/build.sh
        working-directory: site

      - name: Deploy gate — docs mirror is fresh
        run: bash test/docs-mirror.sh
        working-directory: site

      - name: Deploy gate — internal links resolve
        run: bash test/links.sh
        working-directory: site

      - name: Deploy gate — JavaScript budget
        run: bash test/js-budget.sh
        working-directory: site
```

- [ ] **Step 9: Add the browser smokes to the e2e workflow**

Modify `.github/workflows/browser-e2e.yml`, appending a job that builds the site, serves it, and runs both Playwright scripts. Match the existing jobs' Playwright install and serving conventions rather than introducing new ones — read the file first and follow what is already there.

- [ ] **Step 10: Run the whole gate suite**

Run each unpiped, checking the exit code of each:

```sh
bash site/test/build.sh        && echo "build OK"
bash site/test/docs-mirror.sh  && echo "mirror OK"
bash site/test/links.sh        && echo "links OK"
bash site/test/js-budget.sh    && echo "budget OK"
```

Expected: four `PASS` lines and four `OK` lines.

- [ ] **Step 11: Run the repo-wide gates**

Run:

```sh
git ls-files -z '*.zig' | xargs -0 -r zig fmt --check
bash tests/branding.sh
bash tests/confidentiality.sh
```

Expected: no output from `zig fmt --check`, `PASS` from both shell gates.

- [ ] **Step 12: Commit**

```bash
git add site/test .github/workflows/pages.yml .github/workflows/browser-e2e.yml
git commit -m "site: gate link integrity, the JS budget, and hydration in a browser

Each page task asserted its own output exists, which does not prove the site
holds together. Three gaps remain and each has a characteristic failure:

links.sh catches the url_path_prefix bug specifically — a hand-written internal
href resolves in local preview and 404s on Pages, and the built tree is the only
place that difference is observable.

js-budget.sh pins the claim the landing page makes. 'Zero JS by default' becomes
false the first time someone drops an island into the docs shell, silently and
without anyone noticing, unless a gate fails.

The Playwright smokes are the only thing that proves hydration actually happens.
The build can prove an island was server-rendered; only a browser can prove it
woke up, and a page whose HTML is perfect and whose buttons are dead is exactly
what the static assertions cannot see. The directive test additionally asserts
client:visible has NOT hydrated before scrolling — the negative is the half that
would otherwise pass with a broken observer."
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
| --- | --- |
| Built with Zigapagos, dogfooded | All (site/build.zig throughout) |
| SuperMD-forbids-HTML constraint honoured | Tasks 2, 5 (markup in layouts only) |
| Ziggy frontmatter in mirrors | Task 4 |
| `index.smd` per section | Tasks 5, 7 |
| Static syntax highlighting + `highlight.css` | Task 1 |
| `url_path_prefix` correctness | Tasks 1, 9, 12 |
| IA: `/`, `/docs/*`, `/demos/*`, `/compare`, `/download` | Tasks 2, 5, 6, 7, 8, 9, 10 |
| Sidebar with 4 groups | Task 5 |
| 9 landing sections | Tasks 2 (hero, zero-JS, pipeline), 3 (islands), 9 (SPA) — see gap below |
| Islands everywhere + JS budget | Tasks 2, 3, 12 |
| Directive visualizer | Task 7 |
| Astro before/after | Task 8 |
| Embedded native SPA | Task 9 |
| Theme toggle not an island | Task 1 |
| Docs mirror + registry + gitignore + banners | Task 4 |
| Palette, tokens, no webfont | Task 1 |
| Archipelago mark, OG image | Task 11 |
| `site/test/build.sh` extended, Playwright smokes, pages.yml | Task 12 |
| Comparisons incl. "when not to" | Task 10 |

**Gap found and closed:** the spec lists nine landing sections; Tasks 2, 3 and 9
build six of them (hero, zero-JS, islands, pipeline, SPA, and the CTA row).
Three remain — *Five directives*, *Coming from Astro*, and *Deploy anywhere* /
*Why Zigapagos*. Rather than add a task, fold them in: **Task 7 Step 6a** adds a
`s-directives` strip to `index.shtml` linking to the visualizer, **Task 8 Step
5a** adds `s-astro` linking to the migration demo, and **Task 10 Step 3a** adds
`s-deploy` and `s-why` before the compare page's own content. Each is markup in
`index.shtml` using classes those tasks already define, and each task's gate
should gain the matching `grep -q 'id="s-…"'` assertion.

**Placeholder scan:** no TBDs. Two steps carry explicit fallbacks rather than
placeholders — Task 5 Step 4 (if `:attr(...).then(...)` is unsupported, use the
two-branch `<ctx :if>` form, and if `.not()` is unsupported, use a marker span)
and Task 11 Step 7 (if `:attr` on `<meta>` is rejected, use the plain attribute
form). Both name the exact substitute. Task 12 Step 9 instructs reading
`browser-e2e.yml` and matching its conventions instead of inventing them, which
is direction, not a gap.

**Type consistency:** `Props` names used consistently — `CodeTabs` takes
`{ tabs: { label, code }[] }` (Task 3, consumed Task 3 Step 5), `DirectiveDemo`
takes `{ directive, note }` (Task 7, consumed Task 7 Step 6), `MigrateDiff`
takes `{ cases: { title, note, before, after }[] }` (Task 8, consumed Task 8
Step 5). CSS classes produced in Task 2 (`.section`, `.eyebrow`, `.card`,
`.grid-2`, `.grid-3`, `.btn`, `.stat`) are the ones Tasks 7–10 consume.
`.custom.get('slug')` is written by Task 4's generator and Task 6's authored
pages, and read by Task 5's sidebar — the slug values match the registry's
`slug` field and the sidebar's `eql` literals one for one.
