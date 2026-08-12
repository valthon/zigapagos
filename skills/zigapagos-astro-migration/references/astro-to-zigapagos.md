> This documentation is also published, web-native, at <https://valthon.github.io/zigapagos/docs/migrate-from-astro/> — the site is the canonical reading experience.

# Astro → Zigapagos migration reference

A **deterministic mapping** from Astro constructs to their Zigapagos equivalents,
written to be followed mechanically (by a human or an AI agent) with minimal
judgment. Each row/section says: *Astro thing → Zigapagos thing*, with the exact
target syntax. Where a construct has no equivalent yet, it is listed under
[Gaps](#gaps-not-yet-supported) with the recommended workaround.

Zigapagos is a permanent fork of the upstream SSG (see the repository
[README's Acknowledgements](../../README.md#acknowledgements) for attribution):
the **static layer** is inherited near-verbatim (content in SuperMD `.smd`,
layouts in SuperHTML `.shtml`, config in Ziggy `zigapagos.ziggy`), and the
**interactive layer** is islands — components authored in
**TypeScript TSX** against `@z/runtime` (a vendored Preact runtime), SSR'd at build
time by a Bun sidecar, and hydrated client-side via an import map.

> **Migration is two jobs:** (1) the static layer maps almost 1:1 and is largely
> mechanical; (2) React/Preact islands become `.island.tsx` files — swap `react`/
> `react-dom` imports to `@z/runtime`, use `host.*` where SSR-safety matters, and
> drop any third-party npm deps. Hooks, JSX, events, and component structure are
> unchanged. See the [recipes](recipes.md) for the full authoring guide.

---

## 1. Project structure

| Astro | Zigapagos | Notes |
|---|---|---|
| `src/pages/**/*.astro` | `content/**/*.smd` | File path → URL path (both file-based routing). |
| `src/layouts/*.astro` | `layouts/*.shtml` | SuperHTML layouts. |
| `src/components/*.{astro,jsx,tsx}` | `components/*.island.tsx` (islands) or `layouts/templates/*.shtml` (static partials) | Interactive → TSX island; static-only → SuperHTML partial. |
| `src/content/**` (content collections) | `content/**/*.smd` | Collections → content directories; see §11. |
| `public/**` | `assets/**` (+ `static_assets` in config) | Static passthrough. |
| `astro.config.mjs` | `zigapagos.ziggy` + `build.sh` | Config split: site config in Ziggy, island/SPA entries on the `zigapagos release` command line. |
| `package.json` / `node_modules` (for the site) | `package.json` with `@z/runtime` | Bun manages island deps; `@z/runtime` is the only runtime dep. There is no Zig-side dependency: `zigapagos` is a binary you run. |

## 2. Config: `astro.config.mjs` → `zigapagos.ziggy`

```
// astro.config.mjs                         // zigapagos.ziggy
export default defineConfig({               Site {
  site: "https://example.com",                  .title = "My Site",
  // ...                                          .host_url = "https://example.com",
});                                              .content_dir_path = "content",
                                                 .layouts_dir_path = "layouts",
                                                 .assets_dir_path = "assets",
                                                 .static_assets = ["**"],
                                             }
```

`zigapagos.ziggy` **must** begin with `Site {` (the typed root). Site title has no Astro
config equivalent (Astro takes it per-page) — set it here as the default.

**`static_assets` — don't skip this, or your CSS/images will 404.** Unlike Astro,
Zigapagos does **not** copy the assets directory verbatim. An asset under
`assets_dir_path` is only installed into the output if it is either (a) referenced
from a layout/content via `$site.asset('path').link()`, or (b) listed in
`static_assets`. A plain `<link href="/style.css">` or `<img src="/logo.png">` to an
asset that is *neither* **silently 404s** — nothing warns you. So any asset you
reference by a raw URL (site-wide CSS, favicons, OG images, fonts, `CNAME`, JS you
include with a literal `<script src>`) must be in `static_assets`.

`static_assets` entries are relative to `assets_dir_path` and may be:

- an **exact file**: `"favicon.ico"`, `"css/site.css"`;
- a **`**` glob** to install a whole subtree without enumerating every file —
  `"**"` installs the entire assets directory (the closest equivalent to Astro's
  "copy `public/` verbatim"), `"img/**"` installs everything under `assets/img/`.

```
.static_assets = ["**"],                    // copy the whole assets dir (Astro-like)
.static_assets = ["css/**", "favicon.ico"], // a subtree glob + an exact file
```

(The glob is a simple prefix match — `a/b/**` installs everything whose path starts
with `a/b/`. A glob that matches nothing is a build error, so a typo'd directory is
caught rather than silently dropped.)

**`@astrojs/sitemap` → `.sitemap = true`.** Zigapagos generates its own `sitemap.xml`
at release time — opt in with `.sitemap = true` (requires `host_url`, which is already
mandatory). Coverage: every canonical page URL (drafts and alias/alternative duplicates
excluded), a paginated section's page-2+ windows, and a prerendered SPA route that is a
real page (a static route, or a `staticPaths` concrete entry — a dynamic route's own
pattern shell is never listed). `zigapagos migrate` flags `@astrojs/sitemap` in the
generated `MIGRATION.md` worklist when it finds the dependency. Not built: a
sitemap-index for sites past the 50k-URL single-file limit, and `<lastmod>`.

## 3. Routing

Both are file-based and 1:1:

| Astro | Zigapagos | Notes |
|---|---|---|
| `src/pages/index.astro` → `/` | `content/index.smd` → `/` | |
| `src/pages/about.astro` → `/about` | `content/about.smd` → `/about/` | |
| `src/pages/blog/index.astro` | `content/blog/index.smd` (a section index) | |
| `src/pages/blog/[slug].astro` (dynamic) | one `content/blog/<slug>.smd` per entry | Zigapagos has no dynamic-route params; generate one `.smd` per item, or use a section + page assets — or use a `.spa.tsx` dynamic route with `staticPaths` (§13). |
| `src/pages/blog/[page].astro` / `[...page].astro` + `paginate()` | `.pagination = { .page_size = N }` on `content/blog/index.smd` | Native pagination (§11). Delete the route file; the section index renders once per window. |

## 4. Pages & frontmatter

Astro page frontmatter (JS) → SuperMD Ziggy frontmatter:

```
---                                         ---
// src/pages/post.astro                     .title = "My Post",
const title = "My Post";                     .date = @date("2024-01-01T00:00:00"),
const pubDate = new Date("2024-01-01");      .author = "Jane",
---                                          .layout = "post.shtml",
<Layout title={title}>…</Layout>             ---
                                            Body content in Markdown (SuperMD).
```

- `.layout` is **mandatory** and names a file in `layouts/`. `.title` is also
  required.
- **`.author` and `.date` are optional** (default: `""` and the Unix epoch). A
  marketing/landing/contact page can omit both — `$page.author` is then `""` and
  `$page.date` is `1970-01-01`. Only `.title` and `.layout` are required by the
  default schema. (Earlier versions required `.author`/`.date`, which surfaced as
  `missing field: 'author'`.)
- **Custom fields don't need a schema change.** Anything site-specific goes under
  `.custom = { … }` (a free-form, always-optional bag) and is read as `$page.custom`
  in the layout. You do **not** edit any schema to add custom fields.
- **Which top-level fields exist / are required is fixed by the compiled-in schema**
  (the `Page` type), not by a per-site config file. A field is optional iff it has a
  default; a field with no default and no value in a page's frontmatter is reported
  as `missing field: '<name>'` at build time. The shipped default requires only
  `.title` and `.layout`; everything else (`author`, `date`, `description`, `tags`,
  `aliases`, …) is optional.
- **`frontmatter.ziggy-schema` is the *editor* schema**, not a runtime override.
  It mirrors the compiled-in schema so the Ziggy LSP can validate/autocomplete your
  `.smd` frontmatter in-editor; changing it does **not** change build-time
  validation. Keep it in sync with the real schema. To actually add or re-require a
  typed top-level field you change the compiled schema (`src/context/Page.zig`,
  since Zigapagos is a fork) and mirror the change in `frontmatter.ziggy-schema` for
  the editor. For per-page data, prefer `.custom` (above) — no rebuild needed.
- Astro's frontmatter is arbitrary JS; Zigapagos frontmatter is typed Ziggy. Put
  custom fields under `.custom = { … }` → read as `$page.custom` in the layout.
- Page body: Astro JSX/Markdown → SuperMD Markdown (`.smd`).

### Heading anchors: `auto_heading_ids`

SuperMD only gives a heading an `id` when the author writes an explicit
`$heading.id(...)`/`$section.id(...)` directive — unlike GitHub (and most
Markdown renderers Astro content was likely written against), it does **not**
auto-slugify heading text. Content ported verbatim from a GitHub-rendered doc
often relies on GitHub's implicit heading anchors for same-page navigation
(`[Contents](#installation)`), and without a matching id those links fail the
build with `unknown ref` — every heading would otherwise need a hand-written
id before the port compiles.

Set `auto_heading_ids = true` on `Site` (or `MultilingualSite`) in
`zigapagos.ziggy` to inject a GitHub-compatible slug id into every heading
that doesn't already have one (see `src/heading_slugs.zig`). It's opt-in and
off by default — existing sites that rely on "an unmatched anchor is a build
error" keep that behaviour unless they turn it on. An explicit
`$heading.id(...)`/`$section.id(...)` always wins and is never overwritten,
and GitHub's own duplicate-heading dedupe (`foo`, `foo-1`, `foo-2`, ...) and
double-hyphen-around-punctuation behaviour are matched, so anchors computed
from a doc's existing GitHub rendering keep working unchanged.

**Known limitation:** a same-page reference through the `$link.ref('slug')`
Scripty directive still fails with `unknown ref`, because SuperMD's own
`invalid_ref` check runs *inside* `Ast.init`, before ids can be injected.
Plain Markdown links do work, because they take a different, later-validated
path: `[t](#slug)` (same page) and `[t](/other-page#slug)` (cross page) are
both fine. Only the Scripty form is affected, and its workaround is
`$link.unsafeRef('slug')` — which emits the same anchor but, as the name
says, skips the id-existence check, so a typo in the slug becomes a dead
link instead of a build error.

## 5. Layouts & templating: `.astro` → `.shtml` (SuperHTML)

| Astro (JSX-ish) | Zigapagos (SuperHTML + Scripty) |
|---|---|
| `{title}` | `:text="$page.title"` (on the element) |
| `<Fragment set:html={content} />` | `:html="$page.content()"` |
| `{cond && <p>…</p>}` | `<ctx :if="$cond"><p>…</p></ctx>` |
| `{items.map(i => <li>{i}</li>)}` | `<ul :loop="$items"><li :text="$loop.it"></li></ul>` |
| `<Layout>` wrapper / `<slot/>` | `<extend template="base.shtml">` + `<super>` slots |
| `import Header from …; <Header/>` (static) | `<extend>`/partials in `layouts/templates/` |
| `<a href={url}>` | `<a href="$expr">` (Scripty) or static `href="/x"` |

SuperHTML is **valid HTML5 + special attributes**; logic is Scripty (a sandboxed
expression language). See the upstream SuperHTML docs linked from the
[repository README's Acknowledgements](../../README.md#acknowledgements).

> **A dynamic attribute uses the BARE name — not a `:` prefix.** The only `:`
> directives are `:if`, `:loop`, `:text`, `:html` (plus `:props` on
> `<island>`). For a dynamic `src`/`href`/`class`/etc., write the **bare** name
> with a Scripty value — `src="$page.custom.get('hero')"`, **not**
> `:src="$expr"`. By analogy with `:text`, migrators reach for `:src`/`:href`;
> that used to evaluate the value but keep the literal `:src` attribute (so the
> real `src` was never set and the asset silently broke). **This is now a build
> error** naming the attribute and line, with the bare-name fix.

> **`:loop` is a CONTAINER directive — this is the #1 migration mistake.** The
> element that carries `:loop` is rendered **once**; its **children** are what
> repeat, once per item, with the current item bound to `$loop.it`. So to turn a
> JSX `items.map(i => <li>{i}</li>)` into N `<li>`s, put `:loop` on the **wrapper**
> (`<ul>`) and make the repeated node (`<li>`) its child:
>
> ```html
> <!-- CORRECT: one <ul>, one <li> per item -->
> <ul :loop="$items"><li :text="$loop.it"></li></ul>
>
> <!-- WRONG: :loop on the <li> renders ONE <li> whose children repeat,
>      i.e. a single <li> containing N <span>s — not N <li>s. -->
> <li :loop="$items"><span :text="$loop.it"></span></li>
> ```
>
> If the items are objects/maps, index fields with `$loop.it.get('field')` (e.g.
> `<ul :loop="$rows"><li :text="$loop.it.get('name')"></li></ul>`). The loop body
> can contain multiple repeated children — they all repeat together per item.

> **`:if` does NOT make the element conditional — and there is no `:else`.**
> Three separate traps, all of which used to build green and emit wrong HTML:
>
> 1. **`:if` on a real element only gates its BODY.** The tag and **every one of
>    its attributes** are emitted either way, with `$if` bound to the value. So
>    `<a aria-current="page" :if="$isCurrent">Docs</a>` marks *every* nav link as
>    the current page and merely blanks the ones that should not be — the exact
>    bug this repo shipped. To make the element itself conditional, wrap it in
>    `<ctx>`, which never prints a tag of its own:
>
>    ```html
>    <ctx :if="$isCurrent"><a aria-current="page" href="$url">Docs</a></ctx>
>    <ctx :if="$isCurrent.not()"><a href="$url">Docs</a></ctx>
>    ```
>
> 2. **`:if`/`:loop` on a void element is a build error.** `<img>`, `<br>`,
>    `<input>`, … (and a self-closing `<item/>` in an `.xml` alternative layout)
>    have no end tag, and SuperHTML restarts a conditional or a loop by rewinding
>    to the end tag. With none it rewinds to the start of the file and splices the
>    **whole raw template source** into the page, so the build rejects it.
>    Wrap the element instead.
>
> 3. **There is no `:else`.** SuperHTML parses it and then never evaluates it;
>    it is now a build error. Write the negated condition on a second `<ctx>`,
>    as in the pair above.

**No `:with`/scoping directive — repeat the full path (or flatten the
frontmatter).** There is **no** way to bind a sub-object to a short alias for a
block: `:with` and `$ctx`/`$with` do not exist (you'll get `builtin function not
found`). Reference nested `.custom` frontmatter with the full Scripty path each
time:

```html
<!-- nested: .custom = { .hero = { .eyebrow = "Hi", .title = "We build things" } } -->
<p :text="$page.custom.get('hero').get('eyebrow')"></p>
<h1 :text="$page.custom.get('hero').get('title')"></h1>
```

Two ways to keep this manageable:

- **Iterating a list of objects already scopes** — `:loop` binds each element to
  `$loop.it`, so `$loop.it.get('title')` is the per-item short form. The full-path
  repetition only hurts for a *single* deeply-nested object referenced many times.
- **Flatten in frontmatter** for that single-object case: lift the values you use
  repeatedly to top-level `.custom` keys (`.custom = { .hero_eyebrow = "Hi",
  .hero_title = "…" }`) so the layout reads `$page.custom.get('hero_eyebrow')` — one
  `.get` instead of a chain. This keeps the typed nested shape out of the hot path.

(A real `:with`/scoping directive would be a SuperHTML/Scripty change — the static
layer is inherited from the upstream SSG (see the [repository README's
Acknowledgements](../../README.md#acknowledgements)) — so it is out of
scope here; this is the current, documented behaviour.)

## 6. Interactive components → TSX islands (the core of the work)

The migration from React to a Zigapagos island is a **near-mechanical import swap**,
not a from-scratch rewrite. Hooks, JSX, events, and component structure are
identical; the only changes are:

1. Rename the file `<Name>.island.tsx`.
2. Swap `import … from "react"` / `"react-dom"` → `import … from "@z/runtime"`.
3. Replace `document.*`/`window.*` calls with `host.*` equivalents where SSR-safety
   matters (anything that must not execute on the server).
4. Remove third-party npm imports (see [no-npm guardrail](recipes.md#no-npm-guardrail)).

**Before (React):**

```tsx
import { useState } from "react";

interface Props { headline: string }

export default function Hero({ headline }: Props) {
  const [open, setOpen] = useState(false);
  return (
    <section>
      <h1>{headline}</h1>
      <button onClick={() => setOpen(!open)}>{open ? "−" : "+"}</button>
    </section>
  );
}
```

**After (Zigapagos `.island.tsx`):**

```tsx
import { useState } from "@z/runtime";

export interface Props { headline: string }

export default function Hero({ headline }: Props) {
  const [open, setOpen] = useState(false);
  return (
    <section>
      <h1>{headline}</h1>
      <button onClick={() => setOpen(!open)}>{open ? "−" : "+"}</button>
    </section>
  );
}
```

And in a layout:

```html
<island src="components/Hero.island.tsx" client:load prop-headline="$page.title"></island>
```

**Component model mapping:**

| React / Astro | Zigapagos TSX island |
|---|---|
| `import { useState } from "react"` | `import { useState } from "@z/runtime"` |
| `import { createPortal } from "react-dom"` | `import { createPortal } from "@z/runtime"` |
| `document.cookie` | `host.cookies.get(name)` / `host.cookies.set(name, value, opts?)` |
| `window.location.pathname` | `host.pathname()` |
| `window.location.search` | `host.search()` |
| `window.location.hash` | `host.hash()` |
| `window.scrollY` via listener | `host.onScroll(cb, signal?)` |
| `window.matchMedia(q)` | `host.matchMedia(query, cb, signal?)` |
| `fetch(url)` | `host.fetchShared(url, storeName)` (shared) or `host.fetchOpts(req)` (richer) |
| `window.zigapagosOnError` seam | `host.reportError(msg)` |
| script injection | `host.loadScript(url)` |
| cross-island shared state | `host.store.*` + `useSyncExternalStore` |

Use `host.*` for anything that touches the DOM or browser APIs directly. Everything
else — hooks, context, refs, memos, reducers — is standard Preact-compat and needs
no changes. See the [recipes](recipes.md) for the full `host.*` API table and
worked examples.

## 7. Client directives (1:1 names)

| Astro | Zigapagos | Behaviour |
|---|---|---|
| `client:load` | `client:load` | Hydrate immediately. |
| `client:idle` | `client:idle` | Hydrate on `requestIdleCallback`. |
| `client:visible` | `client:visible` | Hydrate when scrolled into view. |
| `client:media="(q)"` | `client:media="(q)"` | Hydrate when the media query matches. |
| `client:only` | `client:only` | No SSR; mount fresh on the client. |

## 8. Props

| Astro | Zigapagos |
|---|---|
| `<C count={5} label="hi" />` | `<island src="C.island.tsx" … prop-count="5" prop-label="hi">` |
| `<C config={{a:1}} />` (structured) | `prop-config="$page.custom.get('cfg').toJson()"` |
| props are JS values | props are serialised to JSON and passed via `data-z-props`; typed against `Props` at SSR |

- **Scalar props** (`string`, `number`, `boolean`) use `prop-NAME="$expr"` — the
  SuperHTML/Scripty expression is evaluated at build time and JSON-serialised.
- **Structured props** (objects, arrays) use `.toJson()` on a Scripty expression:
  `prop-items="$page.custom.get('faq').toJson()"`. The component's typed `Props`
  field is then JSON-parsed.
- Props are **dev-validated** against the exported `Props` interface at SSR time.

```html
<!-- .custom = { .faq = [ { .q = "…", .a = "…" }, … ] } -->
<island src="components/FAQList.island.tsx" client:visible
        prop-items="$page.custom.get('faq').toJson()"></island>
```

```tsx
export interface Item { q: string; a: string }
export interface Props { items: Item[] }
```

## 9. Slots / children

Both the **default slot** and **named slots** are supported, Astro-style. Content
between `<island>` tags is rendered by SuperHTML first, then routed to the island:
`<template slot="NAME">` blocks become named slots; everything else becomes the
default slot (`children`).

| Astro | Zigapagos |
|---|---|
| `<slot />` (in component) | `{children}` — declare `children?: ComponentChildren` in `Props` |
| `<slot name="heading" />` (in component) | `{slots?.heading}` — declare `slots?: Slots` in `Props` |
| `<slot>fallback</slot>` (fallback content) | `{children ?? <p>fallback</p>}` / `{slots?.heading ?? <h2>{title}</h2>}` |
| `<C><div slot="heading">…</div></C>` (usage) | `<island …><template slot="heading">…</template></island>` |
| `<C>default content</C>` (usage) | `<island …>default content</island>` |

```html
<island src="components/Panel.island.tsx" client:load :props='{ .title = "Panel" }'>
  <template slot="heading"><h2>Custom Heading</h2></template>
  <p>default body</p>
</island>
```

```tsx
import type { ComponentChildren } from "@z/runtime";
import type { Slots } from "@z/runtime";

export interface Props {
  title: string;
  children?: ComponentChildren;   // default slot
  slots?: Slots;                   // named slots
}

export default function Panel({ title, children, slots }: Props) {
  return (
    <section>
      <header>{slots?.heading ?? <h2>{title}</h2>}</header>
      <div>{children}</div>
    </section>
  );
}
```

- Slot content is **opaque, already-rendered HTML** — it may use full
  SuperHTML/Scripty, but the island receives it as pre-rendered DOM, not as VNodes
  it can introspect or map over.
- `children` and `slots` are **reserved prop names**; declare both optional and fall
  back gracefully (`?? <Default/>`).
- Nested `<island>` tags inside slot content work: they SSR in place and hydrate
  independently.

See [recipes — slot composition](recipes.md#slot-composition-named--default-slots)
for the full rules (whitespace trimming, `slot="default"`, hydration mechanics).

## 10. Build wiring (replaces bundler config)

One `zigapagos release` invocation builds the whole site. It:

1. Spawns a **Bun sidecar** to SSR each island (produces the HTML fragment + `data-z-props` JSON injected into the page).
2. **Bundles** each island to an ES module at `/islands/<Name>.island.js`, with `@z/runtime` kept external.
3. Emits `/zigapagos-runtime.js` (the shared Preact bundle) and an **import map** wiring `"@z/runtime"` to it, ensuring one Preact instance.

Put it in a `build.sh` so there is one place your entries are declared:

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

bun install --frozen-lockfile 2>/dev/null || bun install

exec zigapagos release \
  --force \
  --output=public \
  --island-props-check=error \
  --island=components/Hero.island.tsx \
  --island=components/Promo.island.tsx \
  "$@"
```

Each `--island=` value is the string you write in `<island src="...">`.
`zigapagos init --from-astro` writes this file for you, with one line per
detected island.

The consumer project also needs a **Bun project** for the island deps:

```json
// package.json
{ "dependencies": { "@z/runtime": "file:../../runtime" } }
```

```json
// tsconfig.json
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "@z/runtime",
    "moduleResolution": "bundler",
    "strict": true
  }
}
```

`build.sh` runs `bun install` first so the Bun sidecar can resolve `@z/runtime`.
See `examples/tsx-site/` for a complete working project (`build.sh`, `package.json`,
`tsconfig.json`, `components/Hero.island.tsx`, `layouts/index.shtml`, and the
`test/ssr.sh` + `test/hydrate.sh` test scripts).

> **Toolchain — you need `zigapagos` and `bun`, and no Zig.** `zigapagos` is a
> standalone executable: install it with `npx zigapagos` (which brings its
> runtime tree and Bun with it) or download a precompiled binary from the
> releases page. Nothing in a migrated project is compiled from Zig source, so
> no Zig toolchain error can come from your site — if you hit one, it is coming
> from a source build of zigapagos itself, not from the migration.

## 11. Content collections & site-wide data

### Per-section collections

| Astro | Zigapagos |
|---|---|
| `src/content/blog/*.md` + schema | `content/blog/*.smd` + section `index.smd` |
| `getCollection("blog")` | `$page.subpages()` from the section index |
| collection `schema` (zod) | Ziggy frontmatter (typed) + `frontmatter.ziggy-schema` |

### Pagination (`paginate()` → `.pagination`)

| Astro | Zigapagos |
|---|---|
| `paginate(posts, { pageSize: 10 })` | `.pagination = { .page_size = 10 }` on the section's `index.smd` |
| `page.data` | `$page.subpages()` (windowed automatically on a paginated render) |
| `page.currentPage` | `$page.pagination?()` → `.current` |
| `page.lastPage` | `.total` |
| `page.size` | `.page_size` |
| `page.total` | `.total_items` |
| `page.url.prev` / `page.url.next` | `.prevLink?()` / `.nextLink?()` |
| `page.url.first` / `page.url.last` | `pageLink(1)` / `pageLink($ctx.pg.total)` |
| `page.start` / `page.end` | no equivalent (compute from `.current` and `.page_size` if needed) |

- URL shape is `.url_style`: `page_dir` (`/blog/page/2/`, the default), `plain_dir`
  (`/blog/2/` — Astro's rest-parameter shape), `page_html` (`/blog/page-2.html`).
- Astro's two filename forms differ: `[...page].astro` puts page 1 at `/blog/`
  (exact parity with `plain_dir`); `[page].astro` puts page 1 at `/blog/1` —
  in Zigapagos page 1 is ALWAYS the section URL, so add
  `.aliases = ["1/index.html"]` if the old `/blog/1/` URL must keep working.
- Astro never emits `/page/2/` — that expectation comes from Hugo/Jekyll;
  `page_dir` provides it natively.
- Astro 7.1's `format()` option exists to patch pagination URLs for hosts
  without rewrite rules; Zigapagos emits directory-style outputs everywhere,
  so there is no equivalent to need — `page_html` covers the no-rewrites host.

```superhtml
<ul :loop="$page.subpages()"><li :text="$loop.it.title"></li></ul>
<ctx :if="$page.pagination?()">
  <ctx pg="$if">
    <ctx :if="$ctx.pg.prevLink?()"><a href="$if">Newer</a></ctx>
    <ctx :if="$ctx.pg.nextLink?()"><a href="$if">Older</a></ctx>
  </ctx>
</ctx>
```

### Site-wide shared data (the "content database" singleton)

Many Astro sites are **content-DB-driven**: one singleton (e.g.
`src/content/site/main.json`) holds owner bio, contact, hours, nav, hero copy,
discount config, etc., and **every** page reads it via `getSite()`. That's
*one source of truth, many consumers* — not a per-page value.

Zigapagos models this with a **global data layer**: drop a Ziggy file under the
project's `data/` directory and read it from any layout with **`$site.data('<name>')`**.

| Astro | Zigapagos |
|---|---|
| `src/content/site/main.json` (singleton) | `data/site.ziggy` |
| `const site = await getSite()` | `$site.data('site')` (a Ziggy map) |
| `site.owner.name` | `$site.data('site').get('owner').get('name')` |
| `site.nav.map(...)` | `<ul :loop="$site.data('site').get('nav')">…</ul>` |

```ziggy
// data/site.ziggy
{
    .owner = { .name = "Jane Runner", .email = "jane@example.com" },
    .hours = "Mon-Fri 9-5",
    .nav = ["Home", "Services", "Contact"],
}
```

```html
<!-- any layout, read the same data everywhere -->
<p :text="$site.data('site').get('owner').get('name')"></p>
<ul :loop="$site.data('site').get('nav')"><li :text="$loop.it"></li></ul>
```

- The file is parsed **once at build time** and shared across every page.
- Each `data/<name>.ziggy` is its own namespace. Index with `.get('field')`.
- The directory is configurable via `data_dir_path` in `zigapagos.ziggy` (default `data`).
- Use this for genuinely site-global data. For per-page values, keep using
  `.custom` frontmatter (§4).

**Build-time config into islands.** Use `$site.data(...)` to pass build-time config
(public API keys, feature endpoints, CDN base) into islands as props:

```html
<island src="components/ContactForm.island.tsx" client:visible
        prop-endpoint="$site.data('config').get('form_endpoint')"></island>
```

Keep **secrets** server-side; only public, client-safe config belongs in `data/`.

## 12. Styling

| Astro | Zigapagos |
|---|---|
| `<style>` scoped in `.astro` | a CSS file in `assets/`, linked from the layout |
| `import "./x.css"` | `<link rel="stylesheet" href="…">` (asset) |
| Tailwind/most integrations | plain CSS in `assets/` (no integration system yet) |
| `@astrojs/sitemap` | `.sitemap = true` (§2) | The one integration with a direct mapping — see §2 for the config and coverage rules. |

## 13. SPA mode (client-routed apps)

For an Astro site that embeds a client-routed app (React Router, wouter, …), port
the app to a single `.spa.tsx` with exported `spa` config and `routes`. Zigapagos
prerenders every route's skeleton, emits a host-agnostic `routing-manifest.json`,
and `@z/runtime`'s first-party `Router` handles History-API soft navigation,
nested/layout routes, async guards, lazy (code-split) routes, and scroll
restoration.

A translation table: `<BrowserRouter>`+`<Routes>` → `export const routes = [...]`
+ `<Router routes={routes}>`; `useParams`/`useNavigate`/`useSearchParams` → same
names from `@z/runtime`; `getStaticPaths` on `[id].astro` → `staticPaths` on the
dynamic route.

A dynamic route prerenders one `_shell.html` fallback; add `staticPaths` to also
emit real per-entry pages:

```ts
{ path: "/club/:id", component: ClubDetail, skeleton: ClubSkeleton,
  staticPaths: async () => (await loadClubs()).map((c) => ({ id: c.id })) }
```

Full reference: [docs/spa.md](../spa.md).

## 14. Images: `<Image>` / `astro:assets` → `image_optimize`

| Astro | Zigapagos | Notes |
|---|---|---|
| `import { Image } from "astro:assets"` + `<Image src={img} widths={[...]} />` | `.image_optimize = {}` on `Site`/`MultilingualSite` + `[]($image.asset('...'))` (or `.siteAsset(...)`) | Opt-in per site, not per import — every eligible `$image` directive gets variants once the config block is present. |
| `widths={[400, 800, 1200]}` (per `<Image>`) | `.image_optimize.widths = [400, 800, 1200]` (site-wide) | **Site-wide, not per-image.** Astro's `widths` is a prop on each `<Image>`; Zigapagos has one configured width list for the whole site. A per-image override does not exist yet (see [Gaps](#gaps-not-yet-supported)). |
| Astro upscales if you ask for a width larger than the source | filtered out, **never upscaled** | A configured width above the source's intrinsic width is silently dropped from that image's `srcset`; if none survive, one variant is generated at the source's own intrinsic width. |
| `<Picture formats={["avif", "webp"]}>` | `.image_optimize.avif_encoder = "avifenc"` (or a path) | AVIF is opt-in against an **external encoder binary** you provide — Zigapagos never vendors or downloads one. Unset `avif_encoder` (the default) emits WebP only. WebP itself needs no toggle; it is always produced for an eligible source once `image_optimize` is on. |
| `format="avif"` / per-`<Image>` format choice | not supported | No per-image format override — `image_optimize`'s codec set (WebP always, AVIF iff `avif_encoder` is set) applies uniformly. See [Gaps](#gaps-not-yet-supported). |
| `<Image>`'s automatic `<picture>`/`srcset`/`sizes` output | `<picture>` with one `<source>` per active codec (best-format-first: AVIF before WebP), `w`-descriptor `srcset`, and `.image_optimize.sizes` (default `"100vw"`) on each `<source>` | Same shape, generated the same way — no `<Picture>`-equivalent component to import; it happens automatically for every `$image` directive once the config block is on. |

Full reference: [docs/images.md](../images.md).

## Gaps (not yet supported)

Flag these during migration; use the workaround:

- **Dynamic routes (`[slug]`) in static content** — the content layer has no
  general `getStaticPaths`; generate one `.smd` per entry. Paginated routes
  (`[page]`/`[...page]` + `paginate()`) are the exception: they map to native
  `.pagination` (§11). For app-like pages, a `.spa.tsx` dynamic route
  (`/club/:id`) with a `staticPaths` hook prerenders one real page per
  enumerated entry (see [SPA mode](#13-spa-mode-client-routed-apps)).
- **Per-image `<Image>` overrides** (`widths`, `formats`) — `image_optimize`
  (§14) is a single site-wide policy; there is no per-image `widths=`/
  `formats=` prop equivalent. If different pages genuinely need different
  width sets, that is not yet supported — flag it during migration rather
  than guessing a workaround.
- **`client:only="framework"`** — there is one runtime, so the framework
  argument is meaningless; write plain `client:only`. A value on any
  directive other than `client:media` fails the build with a clear error.
- **`window.location`** — use `host.pathname()`, `host.search()`, and
  `host.hash()` (SSR/client parity: on the server `search` comes from the
  build-time SSR URL when one carries a query, else `""`; `hash` is always
  `""` server-side — fragments never reach a server). Inside a SPA, prefer
  the router hooks (`useLocation`, `useSearchParams`, `useParams`).
- **Client-side routing / History API on classic island pages** — a
  multi-page island site has no soft navigation; use plain `<a href>`. For a
  client-routed app, use SPA mode (§13): `@z/runtime`'s `Router` ships
  pushState/popstate soft-nav, nested routes, guards, and lazy chunks.
- **Third-party npm packages in islands** — allowed only via the opt-in
  bridge: add the package to `z-runtime.config.json` under
  `islandImports.npmCompat` (React-compatible packages, bundled per-island
  with `react` aliased to the shared runtime) or `islandImports.firstParty`
  (your own scopes). See the [npm guardrail](recipes.md#no-npm-guardrail).
  Packages that bundle their own React/Preact copy stay unsupported.
- **Implicit React context tree across island boundaries** — islands are
  isolated Preact roots. Coordinate via `host.store.*` +
  `useSyncExternalStore`. For auth/session, call
  `host.fetchShared("/api/session", "session")` in each island that needs
  it — the runtime makes one request and shares the result. (Within a
  single `.spa.tsx` app, context works normally — it is one tree.)

## Migration procedure (for an agent)

1. **Scaffold** the target: `zigapagos.ziggy` (§2), `content/`, `layouts/`, `assets/`,
   `components/`, `build.sh`, `package.json`, `tsconfig.json`.

   Run `zigapagos migrate <astro-dir>` to generate `MIGRATION.md`: a ready-to-follow
   worklist with all islands detected.

   Example:
   ```
   zigapagos migrate src/my-astro-site -o MIGRATION.md
   ```

   That report is the only thing `migrate` produces. It reads `<astro-dir>` and
   converts nothing in it: steps 2-7 below are the conversion, and the mapping
   sections above are what they follow. The one exception is `--scaffold DIR`,
   which writes a starter island per detected island — React imports already
   rewritten, `interface Props` carried over — as a head start on step 4.

2. **Static layer**: convert each `src/pages/*.astro` → `content/*.smd` (§4) and
   each `src/layouts/*.astro` → `layouts/*.shtml` (§5). Map routing per §3.
3. **Inventory islands**: list every component used with a `client:*` directive.
   Each becomes a `components/<Name>.island.tsx`.
4. **Port each island**: rename to `.island.tsx`, swap `react`/`react-dom` imports
   to `@z/runtime`, replace direct DOM/browser calls with `host.*`, remove npm deps
   not in the allowed set. See [recipes](recipes.md).
5. **Props/directives/slots**: translate per §7–§9. Check the [gaps](#gaps-not-yet-supported).
6. **Build wiring**: add one `--island=` per island to `build.sh` (§10). Run it;
   fix SSR/TS diagnostics until clean.
7. **Verify**: run the site and confirm each island SSRs correctly and hydrates.

**Machine-readable diagnostics for step 6's fix loop (issue #46).** An agent
driving this migration unattended can run the underlying release build with
`--format=json` (e.g. `zigapagos release --format=json -o public`) to get one
NDJSON object per build error on stderr instead of prose — a stable `code`
field to switch on, plus `file`/`line`/`col` when known. Run `zigapagos
explain-code <CODE>` for the long-form fix for any code that shows up
(`zigapagos explain-code` with no argument lists them all). See
[`docs/diagnostics.md`](../diagnostics.md)
for the full schema and stability contract, including what stays
prose (page-render errors, most `Config.load` fatals) as of this writing.
